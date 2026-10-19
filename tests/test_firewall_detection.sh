#!/usr/bin/env bash
# Offline ruleset fixtures: no firewall commands mutate the host.
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/firewall.sh"
platform_cloud_provider() { printf unknown; }
package_installed() { return 1; }
platform_firewall_active() { [[ "${ufw_active:-0}" == 1 ]]; }
platform_firewall_service_active() {
  case "$1" in
    fail2ban.service) [[ "${f2b_active:-1}" == 1 ]] ;;
    nftables.service) [[ "${nft_active:-0}" == 1 ]] ;;
    firewalld.service) [[ "${firewalld_active:-0}" == 1 ]] ;;
    *) return 1 ;;
  esac
}
command_exists() { [[ "$1" == nft || ( "$1" == ufw && "${ufw_installed:-1}" == 1 ) ]]; }
runtime_with_timeout() { shift; "$@"; }
nft() { [[ "${nft_failure:-0}" == 0 ]] || return 1; printf '%s\n' "$test_rules"; }
test_rules='table inet f2b-table {
    set addr-set-sshd {
        type ipv4_addr
        elements = { 192.0.2.25 }
    }
    chain f2b-chain {
        type filter hook input priority filter - 1; policy accept;
        tcp dport 22 ip saddr @addr-set-sshd reject with icmp port-unreachable
    }
}'
base="$test_rules"
[[ "$(platform_nft_input_kind <<<"$test_rules")" == fail2ban ]] || die '未识别标准 Fail2ban 封禁链'
[[ "$(platform_firewall_backend)" == ufw-inactive ]] || die 'Fail2ban 隐藏了未启用 UFW'
platform_ufw_preflight || die '标准独立封禁链阻止了 UFW 预检'
ufw_installed=0
[[ "$(platform_firewall_backend)" == unknown ]] || die '未安装 UFW 的环境误报已安装'
platform_ufw_preflight || die '标准封禁链阻止 UFW 安装'
unset ufw_installed
for bad in 'policy drop' 'policy accept; accept' 'policy accept; jump other'; do
  test_rules="${base/policy accept/$bad}"
  [[ "$(platform_firewall_backend)" == nftables ]] || die '仅凭 f2b 表名忽略了其他策略'
  if platform_ufw_preflight >/dev/null 2>&1; then die '放过冲突入站策略'; fi
done
test_rules="${base/tcp dport 22 ip saddr @addr-set-sshd reject with icmp port-unreachable/drop}"
[[ "$(platform_firewall_backend)" == nftables ]] || die '忽略无来源限制的丢弃规则'
test_rules="$base"$'\ntable inet custom {\n chain input {\n  type filter hook input priority 0; policy drop;\n }\n}'
[[ "$(platform_firewall_backend)" == nftables ]] || die 'Fail2ban 掩盖其他入站防火墙'
test_rules="${base/f2b-table/custom}"
[[ "$(platform_firewall_backend)" == nftables ]] || die '忽略未知来源规则'
test_rules="$base"
f2b_active=0
[[ "$(platform_firewall_backend)" == nftables ]] || die '服务未运行仍认定为活动 Fail2ban 管理'
unset f2b_active
nft_active=1
[[ "$(platform_firewall_backend)" == nftables ]] || die '忽略运行中的 nftables 管理器'
unset nft_active
firewalld_active=1
[[ "$(platform_firewall_backend)" == firewalld ]] || die '忽略 firewalld'
unset firewalld_active
nft_failure=1
[[ "$(platform_firewall_backend)" == nftables ]] || die '读取失败被当作没有防火墙'
if platform_ufw_preflight >/dev/null 2>&1; then die '读取失败放行 UFW'; fi
unset nft_failure
ufw_active=1
[[ "$(platform_firewall_backend)" == ufw ]] || die '已启用 UFW 识别回归'
unset ufw_active
test_rules="${base/tcp dport 22 ip saddr @addr-set-sshd reject with icmp port-unreachable/udp dport \{ 53, 443 \} ip6 saddr @addr6-set-dns drop}"
[[ "$(platform_nft_input_kind <<<"$test_rules")" == fail2ban ]] || die '不识别 IPv6 / 多端口封禁'
test_rules=$'table inet filter {\n chain output {\n type filter hook output priority 0; policy accept;\n }\n}'
[[ "$(platform_nft_input_kind <<<"$test_rules")" == none ]] || die '非入站链被误判'
test_rules=''
[[ "$(platform_firewall_backend)" == ufw-inactive ]] || die '空规则集识别错误'
printf 'PASS: firewall backend and Fail2ban coexistence detection\n'
