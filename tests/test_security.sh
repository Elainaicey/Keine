#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"

# shellcheck source=../src/core/runtime.sh
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/core/firewall.sh"
# shellcheck source=../src/features/security.sh
. "$ROOT_DIR/src/features/security.sh"

now=1767225600
[[ "$(security_certificate_days_left '@1768089600' "$now")" == "10" ]] || {
  printf 'FAIL: 证书剩余天数计算错误\n' >&2
  exit 1
}
[[ "$(security_certificate_days_left '@1767139200' "$now")" == "-1" ]] || {
  printf 'FAIL: 过期证书天数计算错误\n' >&2
  exit 1
}
if security_certificate_days_left 'not-a-date' "$now" >/dev/null; then
  printf 'FAIL: 无效证书时间没有被拒绝\n' >&2
  exit 1
fi

auth_events="$(security_auth_event_rows <<'EOF'
Jul 24 10:00:00 host sshd[100]: Failed password for invalid user admin from 203.0.113.10 port 50000 ssh2
Jul 24 10:00:01 host sshd[101]: Failed password for root from 203.0.113.10 port 50001 ssh2
Jul 24 10:00:02 host sshd[102]: Invalid user guest from 203.0.113.11 port 50002
Jul 24 10:00:03 host sshd[103]: Accepted publickey for deploy from 198.51.100.20 port 50003 ssh2
EOF
)"
[[ "$(grep -c '^failed|' <<<"$auth_events")" -eq 3 &&
  "$(grep -c '^accepted|' <<<"$auth_events")" -eq 1 ]] || {
  printf 'FAIL: SSH 登录事件解析数量错误\n' >&2
  exit 1
}
failed_sources="$(security_auth_failed_sources <<<"$auth_events")"
grep -Fxq '2|203.0.113.10' <<<"$failed_sources" || {
  printf 'FAIL: SSH 失败来源聚合错误\n' >&2
  exit 1
}
if security_exact_ip_valid any || security_exact_ip_valid 10.0.0.0/8 ||
  security_exact_ip_valid 'host;reboot'; then
  printf 'FAIL: SSH 来源处置接受了非明确 IP\n' >&2
  exit 1
fi

fail2ban-client() {
  if [[ "${1:-}" == "get" ]]; then
    case "${3:-}" in
      bantime) printf '3600\n' ;;
      findtime) printf '600\n' ;;
      maxretry) printf '5\n' ;;
    esac
  else
    case "${2:-}" in
      sshd) printf 'Currently banned: 2\n' ;;
      nginx) printf 'Currently banned: 1\n' ;;
    esac
  fi
}
[[ "$(security_fail2ban_total_banned $'sshd\nnginx')" == "3" ]] || {
  printf 'FAIL: Fail2ban 封禁数量汇总错误\n' >&2
  exit 1
}
[[ "$(security_fail2ban_jail_setting sshd bantime)" == "3600" &&
  "$(security_fail2ban_seconds_label 3600)" == "1 小时" ]] || {
  printf 'FAIL: Fail2ban Jail 有效参数解析错误\n' >&2
  exit 1
}

ssh_settings=$'port 22\nlistenaddress 0.0.0.0:22\nlistenaddress [::]:22\npasswordauthentication no\npermitrootlogin prohibit-password'
[[ "$(security_ssh_effective_values "$ssh_settings" listenaddress)" == "0.0.0.0:22, [::]:22" ]] || {
  printf 'FAIL: SSH 多值有效配置解析错误\n' >&2
  exit 1
}
[[ "$(security_ssh_effective_values "$ssh_settings" passwordauthentication)" == "no" ]] || {
  printf 'FAIL: SSH 单值有效配置解析错误\n' >&2
  exit 1
}

# 由 security_ssh_effective_matches 间接调用。
# shellcheck disable=SC2317,SC2329
sshd() {
  cat <<'EOF'
port 2222
passwordauthentication no
kbdinteractiveauthentication no
pubkeyauthentication yes
permitrootlogin prohibit-password
EOF
}
security_ssh_effective_matches /tmp/sshd_config 2222 1 1 || {
  printf 'FAIL: SSH 最终生效值校验拒绝了安全配置\n' >&2
  exit 1
}
if security_ssh_effective_matches /tmp/sshd_config 22 1 1; then
  printf 'FAIL: SSH 最终生效值校验接受了错误配置\n' >&2
  exit 1
fi
# shellcheck disable=SC2317,SC2329
sshd() {
  cat <<'EOF'
port 2222
passwordauthentication yes
kbdinteractiveauthentication yes
pubkeyauthentication yes
permitrootlogin yes
EOF
}
if security_ssh_effective_matches /tmp/sshd_config 2222 1 1; then
  printf 'FAIL: SSH 最终生效值校验接受了不安全认证配置\n' >&2
  exit 1
fi
unset -f sshd

ssh_config="$(mktemp)"
printf '# comment\nInclude /etc/ssh/sshd_config.d/*.conf\nPort 22\n' >"$ssh_config"
security_ssh_dropin_has_precedence "$ssh_config" || {
  printf 'FAIL: SSH Include 优先级检查拒绝了首个有效指令\n' >&2
  exit 1
}
printf 'Port 22\nInclude /etc/ssh/sshd_config.d/*.conf\n' >"$ssh_config"
if security_ssh_dropin_has_precedence "$ssh_config"; then
  printf 'FAIL: SSH Include 优先级检查接受了后置 Include\n' >&2
  exit 1
fi
rm -f -- "$ssh_config"

mapfile -t expanded_rules < <(security_firewall_expand_specs '443/tcp, 80/tcp, 53/udp' tcp)
[[ "${#expanded_rules[@]}" -eq 3 && "${expanded_rules[0]}" == "443/tcp" &&
  "${expanded_rules[1]}" == "80/tcp" && "${expanded_rules[2]}" == "53/udp" ]] || {
  printf 'FAIL: 逗号分隔 UFW 规则解析错误\n' >&2
  exit 1
}
mapfile -t expanded_rules < <(security_firewall_expand_specs '80,443' both)
[[ "${#expanded_rules[@]}" -eq 4 && "${expanded_rules[0]}" == "80/tcp" &&
  "${expanded_rules[1]}" == "80/udp" && "${expanded_rules[2]}" == "443/tcp" &&
  "${expanded_rules[3]}" == "443/udp" ]] || {
  printf 'FAIL: UFW 公共协议展开错误\n' >&2
  exit 1
}
if security_firewall_expand_specs '443/tcp,,80/tcp' tcp >/dev/null ||
  security_firewall_expand_specs '70000/tcp' tcp >/dev/null; then
  printf 'FAIL: 接受了无效 UFW 规则列表\n' >&2
  exit 1
fi
security_firewall_specs_need_protocol '80,443/tcp' || {
  printf 'FAIL: 没有识别缺少协议的 UFW 规则\n' >&2
  exit 1
}
if security_firewall_specs_need_protocol '80/tcp,443/tcp'; then
  printf 'FAIL: 错误识别了已指定协议的 UFW 规则\n' >&2
  exit 1
fi

firewall_input='443/tcp,80/tcp'
captured_calls=()
command_exists() { [[ "$1" == "ufw" ]]; }
read_input() {
  case "$1" in
    "端口规则（逗号分隔）") printf '%s' "$firewall_input" ;;
    "公共协议") printf '2' ;;
    "来源") printf 'any' ;;
    *) printf '%s' "${2:-}" ;;
  esac
}
confirm() { return 0; }
require_root() { :; }
run() {
  local rendered=""
  printf -v rendered '%s ' "$@"
  captured_calls+=("${rendered% }")
}
ui_page() { :; }
ui_action() { :; }
ui_menu_footer() { :; }
ui_hint() { :; }
ui_section() { :; }
ui_kv() { :; }
ui_success() { :; }

security_firewall_rule allow >/dev/null
[[ "${#captured_calls[@]}" -eq 2 && "${captured_calls[0]}" == "ufw allow 443/tcp" &&
  "${captured_calls[1]}" == "ufw allow 80/tcp" ]] || {
  printf 'FAIL: 批量 UFW 规则构造错误\n' >&2
  exit 1
}

firewall_input='8443'
captured_calls=()
security_firewall_rule allow >/dev/null
[[ "${#captured_calls[@]}" -eq 1 && "${captured_calls[0]}" == "ufw allow 8443/udp" ]] || {
  printf 'FAIL: 未指定协议的 UFW 规则构造错误\n' >&2
  exit 1
}

detect_ssh_port() { printf '22'; }
firewall_input='22/tcp,443/tcp'
captured_calls=()
if security_firewall_rule deny >/dev/null 2>&1; then printf 'FAIL: 拒绝规则允许阻断当前 SSH 端口\n' >&2; exit 1; fi
[[ ${#captured_calls[@]} == 0 ]] || { printf 'FAIL: SSH 阻断验证前已修改防火墙\n' >&2; exit 1; }
platform_ssh_ports() { printf '22\n2222\n'; }
if security_ufw_rule_protect_ssh '2222/tcp ALLOW IN Anywhere' >/dev/null 2>&1 ||
  security_ufw_rule_protect_ssh 'OpenSSH ALLOW IN Anywhere' >/dev/null 2>&1; then die '允许删除 SSH 放行规则'; fi
security_ufw_rule_protect_ssh '443/tcp ALLOW IN Anywhere' || die '普通端口规则被误阻止'
security_ssh_policy_valid MaxAuthTries 3 || die '合法 SSH 策略被拒绝'
security_ssh_policy_valid AllowTcpForwarding no || die '合法转发策略被拒绝'
if security_ssh_policy_valid MaxAuthTries 0 || security_ssh_policy_valid AllowTcpForwarding 'yes;reboot' || security_ssh_policy_valid Unknown yes; then die 'SSH 策略缺少白名单或范围校验'; fi
security_fail2ban_policy_valid 3600 600 5 || die '合法 Fail2ban 策略被拒绝'
if security_fail2ban_policy_valid 0 600 5 || security_fail2ban_policy_valid 3600 600 21; then die 'Fail2ban 参数范围未校验'; fi
export SSH_CONNECTION='192.0.2.10 49152 198.51.100.10 22'
ignore="$(security_fail2ban_ignore_addresses '203.0.113.0/24,192.0.2.10')"
[[ "$(grep -cx '192.0.2.10' <<<"$ignore")" == 1 ]] || die '未保护当前 SSH 来源或未去重'
security_source_is_current 192.0.2.10 || die '当前 SSH 来源保护未生效'
if security_fail2ban_ignore_addresses 'any' >/dev/null || security_fail2ban_ignore_addresses $'192.0.2.1\n[DEFAULT]' >/dev/null; then die 'Fail2ban 白名单接受了危险输入'; fi
printf 'PASS: security\n'
