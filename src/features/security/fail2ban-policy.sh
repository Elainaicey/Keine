#!/usr/bin/env bash

SECURITY_FAIL2BAN_POLICY="${KEINE_FAIL2BAN_POLICY:-/etc/fail2ban/jail.d/99-keine-sshd.local}"

security_fail2ban_policy_valid() {
  local bantime="$1" findtime="$2" maxretry="$3"
  [[ "$bantime" =~ ^[0-9]{1,6}$ && "$findtime" =~ ^[0-9]{1,5}$ && "$maxretry" =~ ^[0-9]{1,2}$ ]] || return 1
  (( 10#$bantime >= 60 && 10#$bantime <= 604800 && 10#$findtime >= 30 && 10#$findtime <= 86400 && 10#$maxretry >= 1 && 10#$maxretry <= 20 ))
}

security_fail2ban_ignore_addresses() {
  local raw="${1:-}" address source="${SSH_CONNECTION:-}"
  local addresses=() result=('127.0.0.1/8' '::1')
  local -A seen=(['127.0.0.1/8']=1 ['::1']=1)
  source="${source%% *}"; raw="${raw//,/ }"
  [[ "$raw" != *$'\n'* && "$raw" != *$'\r'* ]] || return 1
  IFS=$' \t' read -r -a addresses <<<"$raw"
  ((${#addresses[@]} <= 16)) || return 1
  if [[ -n "$source" ]] && security_exact_ip_valid "$source"; then addresses+=("$source"); fi
  for address in "${addresses[@]}"; do
    valid_firewall_source "$address" && [[ "$address" != any ]] || return 1
    if [[ -z "${seen[$address]:-}" ]]; then result+=("$address"); seen["$address"]=1; fi
  done
  printf '%s\n' "${result[@]}"
}

security_fail2ban_policy_payload() {
  local port="$1" bantime="$2" findtime="$3" maxretry="$4" ignore="$5"
  valid_port "$port" && security_fail2ban_policy_valid "$bantime" "$findtime" "$maxretry" || return 1
  printf '# Managed by keine\n[sshd]\nenabled = true\nbackend = systemd\nport = %s\nbantime = %s\nfindtime = %s\nmaxretry = %s\nignoreip = %s\n' \
    "$port" "$((10#$bantime))" "$((10#$findtime))" "$((10#$maxretry))" "${ignore//$'\n'/ }"
}

security_fail2ban_policy_reload() {
  fail2ban-client -t >/dev/null 2>&1 || { warn "Fail2ban 配置检查失败；未加载，请查看 fail2ban-client -t。"; return 1; }
  if systemctl is-active --quiet fail2ban.service; then
    run fail2ban-client reload || return 1
    fail2ban-client ping >/dev/null 2>&1 || return 1
  fi
}

security_fail2ban_policy_verify() {
  security_fail2ban_policy_reload || return 1
  if systemctl is-active --quiet fail2ban.service; then
    local key actual expected source="${SSH_CONNECTION:-}" ignored
    for key in bantime findtime maxretry; do
      actual="$(fail2ban-client get sshd "$key" 2>/dev/null)" || return 1
      case "$key" in bantime) expected="$SECURITY_F2B_BANTIME" ;; findtime) expected="$SECURITY_F2B_FINDTIME" ;; maxretry) expected="$SECURITY_F2B_MAXRETRY" ;; esac
      [[ "$actual" == "$expected" ]] || { warn "$key 最终值未匹配；其他配置可能覆盖项目策略。"; return 1; }
    done
    source="${source%% *}"
    if [[ -n "$source" ]] && security_exact_ip_valid "$source"; then
      ignored="$(fail2ban-client get sshd ignoreip 2>/dev/null | awk '$1=="|-" || $1=="`-" {print tolower($2)}')" || return 1
      if ! grep -Fxq "${source,,}" <<<"$ignored"; then
        warn "未在运行中的 sshd Jail 验证当前 SSH 来源白名单，停止应用。"; return 1
      fi
    fi
  fi
}

security_fail2ban_policy_configure() {
  local port bantime findtime maxretry raw ignore payload
  local SECURITY_F2B_BANTIME SECURITY_F2B_FINDTIME SECURITY_F2B_MAXRETRY
  command_exists fail2ban-client || { warn "请先安装 Fail2ban。"; return 1; }
  if [[ -e "$SECURITY_FAIL2BAN_POLICY" ]] && ! grep -Fqx '# Managed by keine' "$SECURITY_FAIL2BAN_POLICY"; then
    warn "目标文件不属于项目，拒绝覆盖。"; return 1
  fi
  ui_page "Fail2ban / SSH 防护策略" "持久 Jail、封禁参数、白名单与验证"
  port="$(detect_ssh_port)"
  ui_kv "SSH 端口" "$port/tcp"
  ui_hint "封禁 60–604800 秒；窗口 30–86400 秒；重试 1–20 次。只保护 SSH，不限制节点端口。"
  bantime="$(read_input "封禁时间（秒）" 3600)"
  findtime="$(read_input "观察窗口（秒）" 600)"
  maxretry="$(read_input "失败重试次数" 5)"
  security_fail2ban_policy_valid "$bantime" "$findtime" "$maxretry" || { warn "参数格式或范围无效。"; return 1; }
  raw="$(read_input "额外白名单 IP / CIDR；逗号分隔，可留空" "")"
  ignore="$(security_fail2ban_ignore_addresses "$raw")" || { warn "白名单只接受最多 16 个 IP / CIDR，不能填写 any。"; return 1; }
  ui_kv "白名单" "${ignore//$'\n'/ · }"
  ui_note "自动保留回环与当前 SSH 来源。公网 IP 改变后请检查白名单；白名单地址不参与封禁。"
  ui_note "使用原生 systemd 日志后端；缺少其 Python 支持会在配置检查阶段停止，不静默安装依赖。"
  confirm "保存以上 sshd Jail 策略？服务已运行时会验证并重载，停止时只保存。" || return 0
  require_root
  SECURITY_F2B_BANTIME="$((10#$bantime))"; SECURITY_F2B_FINDTIME="$((10#$findtime))"; SECURITY_F2B_MAXRETRY="$((10#$maxretry))"
  payload="$(security_fail2ban_policy_payload "$port" "$bantime" "$findtime" "$maxretry" "$ignore")" || return 1
  config_file_write "$SECURITY_FAIL2BAN_POLICY" 0640 "$payload" security_fail2ban_policy_verify security_fail2ban_policy_reload || return 1
  audit 'action=fail2ban-policy'
  if systemctl is-active --quiet fail2ban.service; then ui_success "SSH Jail 策略已验证并加载。"
  else ui_success "配置已保存；Fail2ban 未运行，请从服务生命周期显式启动。"; fi
}

security_fail2ban_policy_restore() {
  confirm "撤销本项目 SSH Jail 文件并加载原始配置？现有服务和其他 Jail 保留。" || return 0
  require_root
  config_file_restore "$SECURITY_FAIL2BAN_POLICY" security_fail2ban_policy_reload || return 1
  audit 'action=fail2ban-policy-restore'
  ui_success "项目 SSH Jail 配置已撤销；其他配置保持原样。"
}
