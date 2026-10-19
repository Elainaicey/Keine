#!/usr/bin/env bash

# Outbound credentials stay outside the toolkit state/backup directories.
ssh_client_root() {
  local home
  home="$(security_ssh_root_home)"
  [[ "$home" == /* && "$home" != / && -d "$home" && "$home" != *[[:space:]]* && "$home" != *'%'* && "$home" != *'"'* && "$home" != *\\* ]] || return 1
  printf '%s/.ssh/keine-client' "$home"
}
ssh_client_id_valid() { [[ "$1" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; }

ssh_client_safe() {
  local path="$1" mode parent
  config_file_safe "$path" || return 1
  parent="$path"
  while [[ "$parent" != / ]]; do
    if [[ -e "$parent" ]]; then
      [[ "$(stat -c %u -- "$parent")" == 0 ]] || return 1
      mode="$(stat -c %a -- "$parent")" || return 1
      (( (8#$mode & 0022) == 0 )) || return 1
    fi
    parent="$(dirname -- "$parent")"
  done
  [[ ! -f "$path" || "$(stat -c %h -- "$path")" == 1 ]]
}

ssh_client_ready() {
  local root directory
  require_root
  root="$(ssh_client_root)" || return 1
  for directory in "$STATE_ROOT" "${BACKUP_ROOT:-/var/backups/keine}" "${DOCKER_VOLUME_BACKUP_ROOT:-/var/backups/keine-docker}" "$ROOT_DIR" "$(dirname -- "$AUDIT_LOG")"; do
    directory="$(readlink -m -- "$directory")" || return 1
    if [[ "$root" == "$directory" || "$root" == "$directory/"* || "$directory" == "$root/"* ]]; then
      warn "出站凭据目录与项目程序、备份或清理目录重叠，拒绝写入。"; return 1
    fi
  done
  ssh_client_safe "$root/profiles/check" || { warn "出站目录存在链接、非 root 所有者或可写权限冲突。"; return 1; }
  (( DRY_RUN == 0 )) || return 0
  for directory in "${root%/*}" "$root" "$root/profiles" "$root/keys"; do
    if [[ ! -e "$directory" ]]; then (umask 077; mkdir -- "$directory") || return 1; fi
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
  done
  ssh_client_safe "$root/keys/check"
}

ssh_client_lock() {
  local path
  path="$(ssh_client_root)/.lock"
  ssh_client_ready && ssh_client_safe "$path" || return 1
  command_exists flock || { warn "缺少 flock（util-linux）。"; return 1; }
  exec {SSH_CLIENT_LOCK_FD}>"$path" || return 1
  flock -n "$SSH_CLIENT_LOCK_FD" || { warn "另一个出站管理操作正在执行。"; return 1; }
}

declare -Ag SSH_CLIENT
ssh_client_values_valid() {
  valid_network_target "${SSH_CLIENT[host]:-}" && valid_port "${SSH_CLIENT[port]:-}" &&
    [[ "${SSH_CLIENT[user]:-}" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]{0,63}[$]?$ ]] || return 1
  local key="${SSH_CLIENT[key]:-}"
  [[ "$key" == none ]] && return 0
  safe_managed_path "$key" && [[ "$key" != *'%'* && "$key" != *'~'* && "$(readlink -m -- "$key")" == "$key" ]]
}

ssh_client_load() {
  local id="$1" path field value root
  ssh_client_id_valid "$id" || return 1
  root="$(ssh_client_root)" || return 1
  path="$root/profiles/$id.conf"
  ssh_client_safe "$path" && [[ -f "$path" && $(stat -c %s -- "$path") -le 8192 ]] || return 1
  SSH_CLIENT=()
  while IFS='=' read -r field value; do
    [[ "$field" == '# Managed by keine' ]] && continue
    case "$field" in host|port|user|key) ;; *) return 1 ;; esac
    [[ ! -v SSH_CLIENT[$field] ]] || return 1
    SSH_CLIENT[$field]="$value"
  done <"$path"
  [[ ${#SSH_CLIENT[@]} == 4 ]] && ssh_client_values_valid
}

ssh_client_key_valid() {
  local key="$1" mode
  [[ "$key" == none ]] && return 0
  ssh_client_safe "$key" && [[ -f "$key" && $(stat -c %s -- "$key") -le 1048576 ]] || return 1
  mode="$(stat -c %a -- "$key")"
  (( (8#$mode & 0077) == 0 )) || { warn "私钥必须仅 root 可读（建议 600）。"; return 1; }
  head -n 1 -- "$key" | grep -Eq '^-----BEGIN (OPENSSH |RSA |EC |DSA |ENCRYPTED )?PRIVATE KEY-----$'
}

ssh_client_save() (
  local id="$1" expected="$2" path payload
  ssh_client_id_valid "$id" && ssh_client_values_valid && ssh_client_key_valid "${SSH_CLIENT[key]}" || return 1
  (( DRY_RUN == 0 )) || { info "将保存出站连接 $id；不修改 SSH 服务端配置。"; return 0; }
  ssh_client_lock || return 1
  path="$(ssh_client_root)/profiles/$id.conf"
  [[ "$(changes_fingerprint "$path")" == "$expected" ]] || { warn "连接配置已变化，请刷新后重试。"; return 1; }
  if [[ -f "$path" ]]; then
    [[ -d "$(changes_file_entry "$path")" ]] || { warn "没有此连接的归属记录，拒绝覆盖。"; return 1; }
  fi
  payload="$(printf '# Managed by keine\nhost=%s\nport=%s\nuser=%s\nkey=%s' "${SSH_CLIENT[host]}" "${SSH_CLIENT[port]}" "${SSH_CLIENT[user]}" "${SSH_CLIENT[key]}")"
  config_file_write "$path" 0600 "$payload" config_no_reload || return 1
  audit "action=ssh-client-save id=$id"
)

ssh_client_edit() {
  local id="${1:-}" path expected=absent
  SSH_CLIENT=()
  if [[ -z "$id" ]]; then
    id="$(read_input '连接名称（小写字母、数字、连字符；0 返回）')"
    [[ "$id" != 0 ]] || return 0
    ssh_client_id_valid "$id" || { warn "名称须以字母开头，最多 32 字符。"; return 1; }
    path="$(ssh_client_root)/profiles/$id.conf"
    [[ ! -e "$path" && ! -L "$path" ]] || { warn "同名连接已存在。"; return 1; }
  else
    ssh_client_load "$id" || { warn "连接不存在或配置无效。"; return 1; }
    expected="$(changes_fingerprint "$(ssh_client_root)/profiles/$id.conf")"
  fi
  ui_page "SSH 出站 / $id"
  SSH_CLIENT[host]="$(read_input '目标 IP 或域名' "${SSH_CLIENT[host]:-}")"
  SSH_CLIENT[port]="$(read_input '目标端口' "${SSH_CLIENT[port]:-22}")"
  SSH_CLIENT[user]="$(read_input '远端账户' "${SSH_CLIENT[user]:-root}")"
  ui_hint "私钥填写绝对路径；none 使用交互密码认证。新密钥可在上级菜单生成。"
  SSH_CLIENT[key]="$(read_input '私钥路径' "${SSH_CLIENT[key]:-none}")"
  if ! ssh_client_values_valid || ! ssh_client_key_valid "${SSH_CLIENT[key]}"; then warn "参数或私钥权限无效。"; return 1; fi
  confirm "保存连接 $id？" || return 0
  ssh_client_save "$id" "$expected" && ui_success "连接已保存。"
}

ssh_client_connect() (
  local id="$1" root identity_path result=0
  local -a options
  require_root
  command_exists ssh || { warn "请安装 openssh-client。"; return 1; }
  ssh_client_load "$id" || { warn "连接不存在或配置无效。"; return 1; }
  root="$(ssh_client_root)" || return 1; identity_path="${SSH_CLIENT[key]}"
  ssh_client_key_valid "$identity_path" && ssh_client_safe "$root/known_hosts" || return 1
  (( DRY_RUN == 0 )) || { info "将前台连接 $id；预览不发起网络连接。"; return 0; }
  umask 077
  options=(-F /dev/null -o "UserKnownHostsFile=$root/known_hosts" -o StrictHostKeyChecking=ask
    -o IdentityAgent=none -o IdentitiesOnly=yes -o ForwardAgent=no -o ForwardX11=no
    -o ClearAllForwardings=yes -o PermitLocalCommand=no -o ControlMaster=no -o ControlPath=none
    -o ProxyCommand=none -o ProxyJump=none -o UpdateHostKeys=no -o AddKeysToAgent=no
    -o ConnectTimeout=10 -o ConnectionAttempts=1 -o ServerAliveInterval=30 -o ServerAliveCountMax=3)
  if [[ "$identity_path" == none ]]; then options+=(-o PubkeyAuthentication=no)
  else options+=(-i "$identity_path" -o CertificateFile=none -o PreferredAuthentications=publickey); fi
  ui_note "本机 root → ${SSH_CLIENT[user]}@${SSH_CLIENT[host]}；首次连接请核对对端主机指纹。exit 返回。"
  ssh "${options[@]}" -p "${SSH_CLIENT[port]}" -l "${SSH_CLIENT[user]}" -- "${SSH_CLIENT[host]}" || result=$?
  (( result == 0 )) || warn "SSH 已退出（$result）；主机身份变化时请通过对端控制台核实，工具不会自动清除记录。"
  return "$result"
)

ssh_client_key_owned() {
  local directory="$1" file
  [[ $(find "$directory" -mindepth 1 -maxdepth 1 -printf x | wc -c) == 3 ]] || return 1
  for file in key key.pub fingerprint; do
    ssh_client_safe "$directory/$file" && [[ -f "$directory/$file" ]] || return 1
  done
  [[ "$(cat -- "$directory/fingerprint")" == "$(sha256sum -- "$directory/key" "$directory/key.pub" | awk '{print $1}')" ]]
}

ssh_client_key_create() (
  local id="$1" root temporary=''
  ssh_client_id_valid "$id" || { warn "密钥名称无效。"; return 1; }
  command_exists ssh-keygen || { warn "请安装 openssh-client。"; return 1; }
  (( DRY_RUN == 0 )) || { info "将交互生成 Ed25519 专用密钥；预览不生成密钥。"; return 0; }
  ssh_client_lock || return 1
  root="$(ssh_client_root)" || return 1
  root+="/keys"
  [[ ! -e "$root/$id" && ! -L "$root/$id" ]] || { warn "同名密钥已存在。"; return 1; }
  umask 077
  temporary="$(mktemp -d "$root/.pending.XXXXXX")" || return 1
  trap '[[ -z "$temporary" ]] || rm -f -- "$temporary/key" "$temporary/key.pub" "$temporary/fingerprint"; [[ -z "$temporary" ]] || rmdir -- "$temporary"' EXIT
  trap 'exit 130' INT; trap 'exit 143' TERM HUP
  ui_note "由 ssh-keygen 询问私钥口令；建议设置。口令不保存到 keine。"
  ssh-keygen -t ed25519 -a 64 -f "$temporary/key" -C "keine-$id" || return 1
  chmod 600 "$temporary/key" "$temporary/key.pub" || return 1
  sha256sum -- "$temporary/key" "$temporary/key.pub" | awk '{print $1}' >"$temporary/fingerprint" || return 1
  mv -T -- "$temporary" "$root/$id" || return 1
  temporary=''
  audit "action=ssh-client-key-create id=$id"
  ui_kv "私钥路径" "$root/$id/key"
  ui_note "仅把以下公钥添加到远端账户；私钥留在本机。"
  cat -- "$root/$id/key.pub"
)

ssh_client_key_delete() (
  local id="$1" root directory profile identity_path
  ssh_client_id_valid "$id" || return 1
  (( DRY_RUN == 0 )) || { info "将检查引用后删除专用密钥 $id。"; return 0; }
  ssh_client_lock || return 1
  root="$(ssh_client_root)" || return 1; directory="$root/keys/$id"
  ssh_client_key_owned "$directory" || { warn "密钥归属或内容已变化，拒绝删除。"; return 1; }
  for profile in "$root/profiles/"*.conf; do
    [[ -e "$profile" || -L "$profile" ]] || continue
    profile="${profile##*/}"; profile="${profile%.conf}"
    ssh_client_load "$profile" || { warn "连接 $profile 无法解析，不能确认密钥引用。"; return 1; }
    identity_path="${SSH_CLIENT[key]}"
    [[ "$identity_path" != "$directory/key" ]] || { warn "连接 $profile 仍引用此密钥，请先修改或删除连接。"; return 1; }
  done
  confirm "永久删除本机密钥 $id？远端公钥不会自动撤销。" || return 0
  ssh_client_key_owned "$directory" || return 1
  rm -- "$directory/key" "$directory/key.pub" "$directory/fingerprint" && rmdir -- "$directory" || return 1
  audit "action=ssh-client-key-delete id=$id"
  ui_success "本机专用密钥已删除；远端公钥仍需单独撤销。"
)

ssh_client_delete() (
  local id="$1" path
  ssh_client_id_valid "$id" || return 1
  (( DRY_RUN == 0 )) || { info "将删除连接 $id，保留密钥和主机指纹。"; return 0; }
  ssh_client_lock || return 1
  path="$(ssh_client_root)/profiles/$id.conf"
  config_file_restore "$path" config_no_reload || return 1
  audit "action=ssh-client-delete id=$id"
  ui_success "连接已删除，密钥和主机指纹保留。"
)

ssh_client_menu() {
  local action id profile directory
  require_root
  ssh_client_root >/dev/null || { warn "root 主目录无效或路径含不支持的字符。"; return 1; }
  while true; do
    ui_page "SSH / 出站连接"
    ui_note "本机发起账户：root。远端账户可为普通用户；不改变本机入站认证。"
    for profile in "$(ssh_client_root)/profiles/"*.conf; do
      [[ -e "$profile" || -L "$profile" ]] || continue
      id="${profile##*/}"; id="${id%.conf}"
      if ssh_client_load "$id"; then
        ui_kv "$id" "${SSH_CLIENT[user]} @ ${SSH_CLIENT[host]} · ${SSH_CLIENT[port]} · $([[ "${SSH_CLIENT[key]}" == none ]] && printf 密码 || printf 公钥)"
      else ui_kv "$(terminal_safe_text "$id")" '配置异常'; fi
    done
    ui_action 1 '连接' action
    ui_action 2 '新建连接' action
    ui_action 3 '修改连接' action
    ui_action 4 '删除连接（保留密钥）' warning
    ui_section '专用密钥' primary
    ui_action 5 '生成密钥' action
    ui_action 6 '查看公钥与路径' action
    ui_action 7 '删除未引用的密钥' danger
    ui_menu_footer '返回'; ui_read_choice action
    case "$action" in
      0) return 0 ;;
      2) ssh_client_edit || true ;;
      1|3|4)
        id="$(read_input '连接名称（0 返回）')"; [[ "$id" != 0 ]] || continue
        case "$action" in
          1) ssh_client_connect "$id" || true ;;
          3) ssh_client_edit "$id" || true ;;
          4) if confirm '删除连接配置？密钥与主机指纹保留。'; then ssh_client_delete "$id" || true; fi ;;
        esac ;;
      5) id="$(read_input '新密钥名称（0 返回）')"; [[ "$id" != 0 ]] || continue; ssh_client_key_create "$id" || true ;;
      6)
        for directory in "$(ssh_client_root)/keys/"*; do
          [[ -d "$directory" && ! -L "$directory" ]] || continue
          id="${directory##*/}"; ssh_client_id_valid "$id" || continue
          if ssh_client_key_owned "$directory"; then
            ui_kv "$id" "$directory/key"; ssh-keygen -lf "$directory/key.pub"; cat -- "$directory/key.pub"
          else warn "密钥 $id 已变化，保留文件。"; fi
        done ;;
      7) id="$(read_input '密钥名称（0 返回）')"; [[ "$id" != 0 ]] || continue; ssh_client_key_delete "$id" || true ;;
      *) warn '未知选项'; continue ;;
    esac
    pause
  done
}
