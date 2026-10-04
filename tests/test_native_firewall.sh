#!/usr/bin/env bash
# 夹具和事务回调共享局部/全局状态；所有内核操作均替换为文件中的模拟规则。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/core/platform.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/core/changes.sh"
. "$ROOT_DIR/src/core/configuration.sh"
. "$ROOT_DIR/src/features/security/firewall.sh"

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
KEINE_IPTABLES_DIR="$test_root/iptables"
STATE_ROOT="$test_root/keine-state"
CHANGES_ENABLED=1
mkdir -p "$KEINE_IPTABLES_DIR"

platform_cloud_provider() { printf oracle; }
if platform_ufw_preflight >/dev/null 2>&1; then die 'Oracle 环境允许 UFW 接管'; fi
platform_cloud_provider() { printf unknown; }
package_installed() { [[ "$1" == netfilter-persistent ]]; }
if platform_ufw_preflight >/dev/null 2>&1; then die 'UFW 与原生持久组件冲突未拦截'; fi
platform_firewall_active() { return 1; }
platform_firewall_service_active() { return 1; }
[[ "$(platform_firewall_backend)" == iptables ]] || die '原生防火墙未识别'

base=$'*filter\n:INPUT ACCEPT [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\n:InstanceServices - [0:0]\n-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n-A INPUT -p tcp --dport 22 -j ACCEPT\n-A INPUT -j REJECT\n-A OUTPUT -d 169.254.0.0/16 -j InstanceServices\n-A InstanceServices -d 169.254.2.0/24 -p tcp --dport 3260 -j ACCEPT\nCOMMIT\n*nat\n:PREROUTING ACCEPT [0:0]\nCOMMIT'
rows=$'tcp|443|any\nudp|10000:10100|192.0.2.0/24'
rendered="$(security_native_render 4 "$rows" <<<"$base")"
[[ "$(security_native_rows 4 <<<"$rendered")" == "$rows" ]] || die '原生规则无法往返解析'
[[ "$(grep -v 'keine-port_' <<<"$rendered")" == "$base" ]] || die '原有云平台 / NAT 规则被修改'
first_rule="$(awk '/^-A INPUT/ {print; exit}' <<<"$rendered")"
[[ "$first_rule" == *keine-port_tcp_443_any* ]] || die '新增放行规则位于原有拒绝规则之后'
[[ "$(security_native_render 4 '' <<<"$rendered")" == "$base" ]] || die '移除托管规则未保留原文'
for bad in 'tcp|99999999999999999999999999|any' 'tcp|443|::1' 'tcp|443|any;reboot' 'sctp|443|any'; do
  if security_native_valid_row 4 "$bad"; then die "接受非法规则：$bad"; fi
done
security_native_valid_row 6 'tcp|443|2001:db8::/32' || die 'IPv6 来源规则被拒绝'
if security_native_rows 4 <<<"${rendered/--dport 443/--dport 22}" >/dev/null; then die '外部篡改规则被接受'; fi
if security_native_rows 4 <<<"$first_rule"$'\n'"$first_rule" >/dev/null; then die '重复归属标记未拒绝'; fi
platform_ssh_ports() { printf '22\n2222\n'; }
if security_native_protect_removal 'tcp|2222|any' '' >/dev/null 2>&1; then die '第二个 SSH 端口未被保护'; fi

# 真实文件事务与真实变更记录；只替换 root、锁和内核调用。
require_root() { :; }
security_native_lock() { :; }
security_native_preflight() { config_file_safe "$(security_native_file "$1")"; }
audit() { changes_commit_pending; }
runtime_with_timeout() { shift; "$@"; }
iptables-restore() { cat >/dev/null; }
live="$test_root/live"
calls="$test_root/calls"
printf '%s\n' "$base" >"$KEINE_IPTABLES_DIR/rules.v4"
: >"$live"; : >"$calls"
security_native_live_rows() { cat "$live"; }
security_native_rule_command() {
  local family="$1" action="$2" row="$3" content
  printf '%s|%s|%s\n' "$family" "$action" "$row" >>"$calls"
  case "$action" in
    add)
      if [[ -f "$test_root/fail" && "$row" == 'tcp|8443|any' ]]; then return 1; fi
      content="$(<"$live")"; printf '%s\n' "$row" ${content:+"$content"} >"$live"
      ;;
    delete) content="$(grep -Fxv -- "$row" "$live" || true)"; printf '%s' "$content" >"$live" ;;
    check) grep -Fxq -- "$row" "$live" ;;
  esac
}
security_native_write 4 'tcp|443|any' >/dev/null
[[ "$(<"$live")" == 'tcp|443|any' ]] || die '规则没有应用到模拟内核'
entry="$(changes_file_entry "$KEINE_IPTABLES_DIR/rules.v4")"
[[ "$(<"$entry/original")" == "$base" ]] || die '没有保存首次原始规则'
[[ "$(grep -v 'keine-port_' "$KEINE_IPTABLES_DIR/rules.v4")" == "$base" ]] || die '保存污染了云端存储规则'
security_native_write 4 'tcp|443|any' >/dev/null
[[ "$(wc -l <"$calls" | tr -d ' ')" == 1 ]] || die '重复应用产生重复规则'

previous="$(<"$KEINE_IPTABLES_DIR/rules.v4")"
touch "$test_root/fail"
if security_native_write 4 $'tcp|8443|any\ntcp|8080|any\ntcp|443|any' >/dev/null 2>&1; then die '部分失败没有中止'; fi
[[ "$(<"$KEINE_IPTABLES_DIR/rules.v4")" == "$previous" && "$(<"$live")" == 'tcp|443|any' ]] || die '部分失败没有同时回退文件与运行规则'
[[ "$(changes_file_status "$entry")" == ready ]] || die '失败回退污染了恢复记录'

DRY_RUN=1
security_native_write 4 '' >/dev/null
[[ "$(<"$live")" == 'tcp|443|any' && "$(<"$KEINE_IPTABLES_DIR/rules.v4")" == "$previous" ]] || die '预览改变了规则'
DRY_RUN=0
printf '\n# external\n' >>"$KEINE_IPTABLES_DIR/rules.v4"
if security_native_write 4 '' >/dev/null 2>&1; then die '持久文件外部修改未被拒绝'; fi
[[ "$(<"$live")" == 'tcp|443|any' ]] || die '冲突判断前修改了内核'
printf '%s\n' "$previous" >"$KEINE_IPTABLES_DIR/rules.v4"
printf 'tcp|444|any\n' >"$live"
if security_native_write 4 '' >/dev/null 2>&1; then die '内核规则外部修改未被拒绝'; fi
printf 'tcp|443|any\n' >"$live"
security_native_restore 4
[[ "$(<"$KEINE_IPTABLES_DIR/rules.v4")" == "$base" && ! -s "$live" && ! -e "$entry" ]] || die '原生规则撤销不完整'
printf 'PASS: native firewall\n'
