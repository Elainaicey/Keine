#!/usr/bin/env bash

# 运行身份仍为 root；目标账户必须由用户明确选择，不根据 sudo 环境静默切换。
security_ssh_user() { printf '%s' "${SECURITY_SSH_USER:-root}"; }

security_ssh_account_record() {
  local user="${1:-$(security_ssh_user)}" record name _password uid gid _gecos directory shell
  [[ "$user" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*[$]?$ && ${#user} -le 64 ]] || return 1
  record="$(getent passwd "$user")" || return 1
  [[ "$record" != *$'\n'* ]] || return 1
  IFS=: read -r name _password uid gid _gecos directory shell <<<"$record"
  [[ "$name" == "$user" && "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ && "$directory" == /* && "$directory" != / && "$directory" != *[[:cntrl:]]* ]] || return 1
  [[ "$user" == root && "$uid" == 0 ]] || { [[ "$uid" != 0 && -n "$shell" && "$shell" != */nologin && "$shell" != */false ]] || return 1; }
  printf '%s\n' "$record"
}

security_ssh_account_home() {
  if [[ "$(security_ssh_user)" == root ]]; then security_ssh_root_home
  else security_ssh_account_record | awk -F: '{print $6}'; fi
}

security_ssh_account_uid() { security_ssh_account_record | awk -F: '{print $3}'; }
security_ssh_account_gid() { security_ssh_account_record | awk -F: '{print $4}'; }

security_ssh_account_select() {
  local name _password uid _gid _gecos directory _shell selected
  ui_page "SSH / 选择账户" "仅管理已有账户的公钥；不会创建账户或授予 sudo"
  while IFS=: read -r name _password uid _gid _gecos directory _shell; do
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    if [[ "$name" == root ]] || (( uid >= 1000 && uid < 65534 )); then
      security_ssh_account_record "$name" >/dev/null || continue
      ui_kv "$(terminal_safe_text "$name")" "$(terminal_safe_text "$directory")"
    fi
  done < <(getent passwd)
  selected="$(read_input "账户名；留空取消" "")"
  [[ -n "$selected" ]] || return 0
  security_ssh_account_record "$selected" >/dev/null || { warn "账户不存在、名称不支持或已禁止交互登录。"; return 1; }
  # shellcheck disable=SC2034
  SECURITY_SSH_USER="$selected"
}

# 恢复中心按原路径识别目标账户，不能依赖当前菜单选择。
security_ssh_account_for_key_path() {
  local wanted="$1" name _password _uid _gid _gecos directory _shell found=""
  while IFS=: read -r name _password _uid _gid _gecos directory _shell; do
    [[ "$directory/.ssh/authorized_keys" == "$wanted" ]] || continue
    security_ssh_account_record "$name" >/dev/null || continue
    [[ -z "$found" ]] || return 1
    found="$name"
  done < <(getent passwd)
  [[ -n "$found" ]] || return 1
  printf '%s' "$found"
}
