#!/usr/bin/env bash

# 只管理 root 的标准公钥文件；自定义路径、CA 和命令取钥保留原生管理。
security_ssh_root_home() { getent passwd root | awk -F: '$1=="root" && $3==0 {print $6;exit}'; }
security_ssh_key_path() { printf '%s/.ssh/authorized_keys' "$(security_ssh_root_home)"; }

security_ssh_key_path_active() {
  local settings="$1" home path
  home="$(security_ssh_root_home)"; [[ "$home" == /* && "$home" != / ]] || return 1
  while IFS= read -r path; do
    case "$path" in .ssh/authorized_keys|%h/.ssh/authorized_keys|"$home/.ssh/authorized_keys") return 0 ;; esac
  done < <(awk '$1=="authorizedkeysfile" {for(i=2;i<=NF;i++)print $i}' <<<"$settings")
  return 1
}

security_ssh_key_safe() {
  local path home mode
  home="$(security_ssh_root_home)"; [[ "$home" == /* && "$home" != / && -d "$home" ]] || return 1
  config_file_safe "$(security_ssh_key_path)" || return 1
  for path in "$home" "$home/.ssh" "$(security_ssh_key_path)"; do
    [[ ! -L "$path" ]] || return 1
    [[ -e "$path" ]] || continue
    [[ "$(stat -c '%u' -- "$path")" == 0 ]] || return 1
    mode="$(stat -c '%a' -- "$path")"; [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
  done
  [[ ! -e "$home/.ssh" || -d "$home/.ssh" ]] || return 1
  path="$(security_ssh_key_path)"
  [[ ! -e "$path" || ( -f "$path" && "$(stat -c '%h' -- "$path")" == 1 && "$(stat -c '%s' -- "$path")" -le 1048576 ) ]]
}

# ssh-keygen 从 stdin 解析单条公钥；不创建或读取客户端私钥。
security_ssh_key_fingerprint() {
  local line="$1" result
  [[ -n "$line" && ${#line} -le 16384 && "$line" != *$'\n'* && "$line" != *$'\r'* && "$line" != *PRIVATE* ]] || return 1
  result="$(printf '%s\n' "$line" | ssh-keygen -lf /dev/stdin -E sha256 2>/dev/null)" || return 1
  [[ "$result" != *$'\n'* && "$result" == *' SHA256:'* ]] || return 1
  printf '%s\n' "$result" | awk '$2 ~ /^SHA256:/ {print $2}'
}

security_ssh_key_plain_valid() {
  local line="$1" type blob _comment bits
  [[ "$line" != *[[:cntrl:]]* ]] || return 1
  IFS=' ' read -r type blob _comment <<<"$line"
  case "$type" in ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;; *) return 1 ;; esac
  [[ "$blob" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1
  [[ -n "$(security_ssh_key_fingerprint "$line")" ]] || return 1
  if [[ "$type" == ssh-rsa ]]; then
    bits="$(printf '%s\n' "$line" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $1}')"
    [[ "$bits" =~ ^[0-9]+$ ]] && (( bits >= 2048 )) || return 1
  fi
}

security_ssh_key_rows() {
  local path="${1:-$(security_ssh_key_path)}" line number=0 state fingerprint
  [[ -f "$path" && ! -L "$path" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    number=$((number+1)); state=enabled
    if [[ "$line" == '# keine-disabled '* ]]; then state=disabled; line="${line#\# keine-disabled }"; fi
    [[ "$line" != \#* && -n "$line" ]] || continue
    fingerprint="$(security_ssh_key_fingerprint "$line")" || continue
    [[ -n "$fingerprint" ]] && printf '%s|%s|%s\n' "$number" "$state" "$fingerprint"
  done <"$path"
}

security_ssh_key_sources_valid() {
  local source="$1"
  [[ -z "$source" ]] || { [[ "$source" != any ]] && valid_firewall_source "$source"; }
}

# 锁覆盖读、确认和写入；摘要在写入前复核，避免将等待输入期间的外部修改纳入项目。
security_ssh_keys_locked() (
  local operation="$1" lock
  case "$operation" in add|change|restore) ;; *) return 1 ;; esac
  require_root
  command_exists ssh-keygen || { warn "缺少 ssh-keygen，请先安装 openssh-client。"; return 1; }
  command_exists flock || { warn "缺少 flock，不能安全修改公钥。"; return 1; }
  security_ssh_key_safe || { warn "root 公钥路径、所有者、权限或文件类型不安全；请先运行登录诊断。"; return 1; }
  if (( DRY_RUN == 1 )); then "security_ssh_keys_$operation"; return; fi
  changes_storage_ready || return 1
  lock="$(changes_root)/ssh-keys.lock"
  config_file_safe "$lock" || return 1
  exec 9>"$lock" || return 1
  flock -n 9 || { warn "另一个公钥操作正在进行。"; return 1; }
  "security_ssh_keys_$operation"
)

security_ssh_key_write() {
  local payload="$1" expected="$2" path settings entry
  path="$(security_ssh_key_path)"
  security_ssh_key_safe || return 1
  if ! settings="$(security_ssh_context_values)" || ! security_ssh_key_path_active "$settings"; then
    warn "当前 root 上下文未使用标准 authorized_keys；请通过原生配置管理自定义取钥方式。"; return 1;
  fi
  [[ "$(changes_fingerprint "$path")" == "$expected" ]] || { warn "公钥文件已改变，停止覆盖。"; return 1; }
  entry="$(changes_file_entry "$path")"
  if [[ -f "$path" && ! -d "$entry" ]]; then
    confirm "明确接管此 root 公钥文件的后续修改？保留现有条目并记录首次基线，外部改动后停止覆盖。" || return 1
    [[ "$(changes_fingerprint "$path")" == "$expected" ]] || return 1
  fi
  if (( DRY_RUN == 1 )); then info "将原子更新 root 公钥文件，权限 0600；不重载 SSH。"; return 0; fi
  changes_ready || { warn "恢复记录未启用，拒绝写入公钥。"; return 1; }
  # 新建目录只作容器，不整体登记；撤销时保留目录中后来添加的其他文件。
  if [[ ! -d "$(dirname -- "$path")" ]]; then (umask 077; mkdir -- "$(dirname -- "$path")") || return 1; fi
  security_ssh_key_install "$payload" "$expected"
}

security_ssh_key_verify() {
  security_ssh_key_safe && [[ "$(stat -c '%a' -- "$(security_ssh_key_path)")" == 600 ]]
}

# 公钥不需要 reload；事务只登记本次写入摘要，回退前再次检查外部修改。
security_ssh_key_install() (
  local payload="$1" expected="$2" path entry temporary previous installed="" checksum done=0 existed=0
  path="$(security_ssh_key_path)"; entry="$(changes_file_entry "$path")"
  changes_ready && security_ssh_key_safe || return 1
  [[ "$(changes_fingerprint "$path")" == "$expected" ]] || return 1
  temporary="$(mktemp "$(dirname -- "$path")/.keine-key.XXXXXX")" || return 1
  previous="$(mktemp "$(dirname -- "$path")/.keine-key-before.XXXXXX")" || { rm -f -- "$temporary"; return 1; }
  # shellcheck disable=SC2317,SC2329
  security_ssh_key_finish() {
    local status="$1"
    trap - EXIT HUP INT TERM
    if [[ -n "$installed" && "$done" == 0 ]]; then
      # 捕获信号可能发生在替换之前；原文件仍在时无需回退。
      if [[ "$(changes_fingerprint "$path")" == "$expected" ]]; then
        rm -f -- "$temporary" "$previous"; return "$status"
      fi
      if [[ "$(changes_fingerprint "$path")" != "$installed" ]]; then
        warn "公钥在事务期间被外部修改，保留恢复副本：$previous"
        rm -f -- "$temporary"; return 1
      fi
      if (( existed == 1 )); then
        mv -fT -- "$previous" "$path" || { warn "回退失败，保留 $previous"; return 1; }
      else rm -f -- "$path" || return 1; fi
      printf '%s\n' "$expected" >"$entry/last" || return 1
      warn "公钥操作未完成，已恢复操作前状态。"
    fi
    rm -f -- "$temporary" "$previous"
    return "$status"
  }
  trap 'security_ssh_key_finish "$?"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' HUP TERM
  if [[ -f "$path" ]]; then existed=1; cp -p -- "$path" "$previous" || return 1; fi
  changes_prepare_file "$path" || return 1
  # 子目录不应被其他整体目录记录接管。
  [[ -d "$entry" ]] || return 1
  printf '%s\n' "$payload" >"$temporary" && chmod 0600 "$temporary" || return 1
  if (( existed == 1 )); then chown --reference="$path" "$temporary" || return 1; fi
  # 预先计算目标路径的摘要，捕获紧邻 rename 的信号也能判断是否已经替换。
  # 安全路径不含反斜杠，保持与 sha256sum 的文件名序列化一致。
  [[ "$path" != *\\* ]] || return 1
  checksum="$(sha256sum -- "$temporary")" || return 1
  checksum="${checksum%"$temporary"}$path"
  installed="$( { stat -c '%a:%u:%g' -- "$temporary"; printf '%s\n' "$checksum"; } | sha256sum | awk '{print $1}')" || return 1
  [[ "$(changes_fingerprint "$path")" == "$expected" ]] || { installed=""; return 1; }
  mv -fT -- "$temporary" "$path" || { installed=""; return 1; }
  printf '%s\n' "$installed" >"$entry/last" || return 1
  security_ssh_key_verify || return 1
  [[ "$(changes_fingerprint "$path")" == "$installed" ]] || return 1
  done=1
)

security_ssh_keys_add() {
  local path expected input method file source options="" fingerprint existing payload
  path="$(security_ssh_key_path)"; expected="$(changes_fingerprint "$path")"
  ui_page "SSH / 添加 root 公钥" "只粘贴客户端 .pub 公钥；私钥留在客户端"
  ui_action 1 "粘贴一行公钥" "action"
  ui_action 2 "导入服务器上的 .pub 文件" "action"
  ui_menu_footer "取消"; ui_read_choice method
  case "$method" in
    1) input="$(read_input "公钥（类型 Base64 可选备注）" "")" ;;
    2)
      file="$(read_input "公钥文件绝对路径" "")"
      [[ "$file" == /*.pub && -f "$file" && ! -L "$file" && "$(stat -c '%s' -- "$file")" -le 16384 ]] || { warn "需要不超过 16 KiB 的普通 .pub 文件。"; return 1; }
      input="$(cat -- "$file")"; input="${input%$'\r'}"
      ;;
    0) return 0 ;; *) return 1 ;;
  esac
  security_ssh_key_plain_valid "$input" || { warn "公钥无效：仅支持单行普通 OpenSSH 公钥，RSA 至少 2048 位；不导入私钥、证书或预置选项。"; return 1; }
  fingerprint="$(security_ssh_key_fingerprint "$input")"
  existing="$(security_ssh_key_rows)"
  if awk -F'|' -v fp="$fingerprint" '$3==fp {found=1} END{exit !found}' <<<"$existing"; then warn "该指纹已存在（可能已停用），请管理已有条目。"; return 1; fi
  ui_kv "指纹" "$fingerprint"
  source="$(read_input "允许来源 IP 或 CIDR；留空不限" "")"
  security_ssh_key_sources_valid "$source" || { warn "来源必须是单个 IPv4/IPv6 地址或 CIDR。"; return 1; }
  [[ -z "$source" ]] || options="from=\"$source\""
  if confirm "禁止这把公钥的 TCP、Agent 和 X11 转发？保留交互终端与 SFTP。"; then
    options+="${options:+,}no-port-forwarding,no-agent-forwarding,no-X11-forwarding"
  fi
  ui_kv "公钥限制" "${options:-无限制}"
  ui_note "来源限制需覆盖客户端实际出口；有效认证还受 Match、Allow/Deny、PAM 和公钥算法策略影响。"
  confirm "添加此 root 公钥？添加后请在新窗口验证登录。" || return 0
  payload=""; [[ ! -f "$path" ]] || payload="$(cat -- "$path")"
  payload+="${payload:+$'\n'}${options:+$options }$input"
  security_ssh_key_write "$payload" "$expected" || return 1
  audit "action=ssh-key-add fingerprint=$fingerprint"
  if (( DRY_RUN == 0 )); then ui_success "公钥已写入；无需重载 SSH。请从客户端验证新连接。"; fi
}

security_ssh_keys_change() {
  local path expected rows number selected state fingerprint action payload active line
  path="$(security_ssh_key_path)"; expected="$(changes_fingerprint "$path")"; rows="$(security_ssh_key_rows)"
  [[ -n "$rows" ]] || { ui_empty "没有可管理公钥"; return 0; }
  security_ssh_keys_list
  number="$(read_input "选择文件行号；留空取消" "")"; [[ -n "$number" ]] || return 0
  [[ "$number" =~ ^[1-9][0-9]{0,6}$ ]] || return 1
  selected="$(awk -F'|' -v n="$number" '$1==n {print}' <<<"$rows")"; [[ -n "$selected" ]] || { warn "该行不是可解析的公钥。"; return 1; }
  IFS='|' read -r number state fingerprint <<<"$selected"
  line="$(sed -n "${number}p" "$path")"
  ui_kv "选中条目" "$(terminal_safe_text "$line")"
  ui_action 1 "$([[ "$state" == enabled ]] && printf 停用 || printf 启用)此公钥" "warning"
  ui_action 2 "删除此公钥" "danger"
  ui_menu_footer "取消"; ui_read_choice action
  case "$action" in 0) return 0 ;; 1|2) ;; *) return 1 ;; esac
  active="$(awk -F'|' '$2=="enabled" {n++} END{print n+0}' <<<"$rows")"
  if [[ "$state" == enabled ]] && (( active <= 1 )); then warn "拒绝停用或删除本文件最后一把可解析的启用公钥。请先添加并验证替代公钥。"; return 1; fi
  if [[ "$state" == enabled || "$action" == 2 ]]; then
    confirm "已使用另一把保留的公钥在新窗口登录成功，并保留服务商控制台？" || return 0
  fi
  confirm "确认修改 $fingerprint？只修改选中行，已有连接不会断开。" || return 0
  payload="$(awk -v n="$number" -v action="$action" -v state="$state" '
    NR!=n {print;next} action==2 {next}
    state=="enabled" {print "# keine-disabled " $0;next}
    {sub(/^# keine-disabled /, "");print}' "$path")"
  security_ssh_key_write "$payload" "$expected" || return 1
  audit "action=ssh-key-change fingerprint=$fingerprint operation=$action previous=$state"
  if (( DRY_RUN == 0 )); then ui_success "公钥条目已更新；请验证新连接。"; fi
}

security_ssh_keys_restore() {
  ui_hint "恢复首次基线会撤销本工具后来添加、停用或删除的公钥，可能移除当前使用的登录凭据。"
  confirm "已验证基线中的公钥或服务商控制台可用，确认恢复？" || return 1
  config_file_restore "$(security_ssh_key_path)" config_no_reload || return 1
  if (( DRY_RUN == 0 )); then audit 'action=ssh-keys-restore'; ui_success "公钥首次基线已恢复；请验证新的客户端连接。"; fi
}

security_ssh_keys_list() {
  local number state fingerprint path rows
  path="$(security_ssh_key_path)"
  ui_page "SSH / root 公钥管理" "$(terminal_safe_text "$path")"
  security_ssh_key_safe || { warn "路径或权限异常；请先运行登录诊断。"; return 1; }
  rows="$(security_ssh_key_rows)"
  while IFS='|' read -r number state fingerprint; do
    [[ -n "$number" ]] || continue
    ui_item "$number" "$fingerprint" "$([[ "$state" == enabled ]] && printf 启用 || printf 停用)"
  done <<<"$rows"
  [[ -n "$rows" ]] || ui_empty "没有可解析的公钥"
  ui_note "编号为文件行号；指纹解析不等于登录验证。外部选项和未识别行保留原样。"
}

security_ssh_keys_menu() {
  local choice
  while true; do
    security_ssh_keys_list || true
    ui_action 1 "添加 / 导入公钥" "action"
    ui_action 2 "选择公钥：启停 / 删除" "warning"
    ui_action 3 "登录诊断" "action"
    ui_action 4 "恢复首次公钥基线" "warning"
    ui_menu_footer "返回"; ui_read_choice choice
    case "$choice" in
      1) security_ssh_keys_locked add || true ;;
      2) security_ssh_keys_locked change || true ;;
      3) security_ssh_login_diagnose || true ;;
      4) security_ssh_keys_locked restore || true ;;
      0) return 0 ;; *) warn "未知选项"; continue ;;
    esac
    pause
  done
}
