#!/usr/bin/env bash
# 离线验证：所有文件和 sysctl 替身都在临时目录，不更改主机网络。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
NODE_TEST_ROOT="$(mktemp -d)"
trap '[[ "$NODE_TEST_ROOT" == /tmp/* ]] && rm -rf -- "$NODE_TEST_ROOT"' EXIT
KEINE_STATE_ROOT="$NODE_TEST_ROOT/keine-state"
KEINE_BACKUP_ROOT="$NODE_TEST_ROOT/keine-backups"
KEINE_RESOLV_CONF="$NODE_TEST_ROOT/resolv.conf"
KEINE_NETWORK_TUNING_FILE="$NODE_TEST_ROOT/network.conf"
KEINE_BBR_FILE="$NODE_TEST_ROOT/bbr.conf"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/core/changes.sh"
. "$ROOT_DIR/src/core/backup.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/core/configuration.sh"
. "$ROOT_DIR/src/features/network/dns.sh"
. "$ROOT_DIR/src/features/network/proxy.sh"
. "$ROOT_DIR/src/features/network/parameters.sh"
. "$ROOT_DIR/src/features/network/tuning.sh"
CHANGES_ENABLED=1
require_root() { :; }
confirm() { return 0; }
audit() { :; }
apply_ok() { return 0; }
apply_fail() { return 1; }

[[ "$(network_dns_addresses '1.1.1.1,2606:4700:4700::1111')" == $'1.1.1.1\n2606:4700:4700::1111' ]] || die 'DNS 列表解析错误'
for invalid in '1.1.1.1.' '0.0.0.0' '1.1.1.1;reboot' '::1:' $'1.1.1.1\n2.2.2.2' '1.1.1.1,2.2.2.2,3.3.3.3,4.4.4.4'; do
  if network_dns_addresses "$invalid" >/dev/null 2>&1; then die "接受了无效 DNS：$invalid"; fi
done
printf 'search example.test\noptions timeout:2\nnameserver 192.0.2.1\n' >"$NETWORK_DNS_RESOLV"
payload="$(network_dns_payload plain "$NETWORK_DNS_RESOLV" '1.1.1.1')"
grep -q '^search example.test$' <<<"$payload" || die 'DNS 修改丢失了已有搜索域'
grep -q '^nameserver 1.1.1.1$' <<<"$payload" || die 'DNS 服务器未写入'
if grep -q '192.0.2.1' <<<"$payload"; then die '旧 DNS 未替换'; fi
resolved_payload="$(network_dns_payload resolved "$NODE_TEST_ROOT/resolved.conf" $'1.1.1.1\n2606:4700:4700::1111')"
grep -q '^DNS=1.1.1.1 2606:4700:4700::1111$' <<<"$resolved_payload" || die 'resolved 地址合并错误'
config_file_write "$NETWORK_DNS_RESOLV" 0644 "$payload" apply_ok >/dev/null
if config_file_write "$NETWORK_DNS_RESOLV" 0644 'broken' apply_fail >/dev/null 2>&1; then die '应用失败未返回错误'; fi
grep -q 'nameserver 1.1.1.1' "$NETWORK_DNS_RESOLV" || die '失败后没有回退文件'
if config_file_restore "$NETWORK_DNS_RESOLV" apply_fail >/dev/null 2>&1; then die '恢复验证失败仍报告成功'; fi
grep -q 'nameserver 1.1.1.1' "$NETWORK_DNS_RESOLV" || die '恢复失败未保留原配置'
config_file_restore "$NETWORK_DNS_RESOLV" apply_ok
grep -q 'nameserver 192.0.2.1' "$NETWORK_DNS_RESOLV" || die '初始 DNS 未恢复'

payload="$(network_proxy_payload '::1' 1080 socks5h user 'p"a\ss$')"
network_proxy_content_valid <<<"$payload" || die '合法代理凭据转义错误'
grep -q '^proxy = "socks5h://\[::1\]:1080"$' <<<"$payload" || die 'IPv6 代理端点错误'
if network_proxy_content_valid <<<$'proxy = "socks5h://user:password@host:1080"'; then die '代理端点包含可泄露凭据'; fi
if network_proxy_content_valid <<<"$payload"$'\noutput = "/etc/passwd"'; then die '接受了额外 curl 写入选项'; fi
if network_proxy_payload host 1080 socks5h $'user\nurl' pass >/dev/null 2>&1; then die '凭据注入被接受'; fi

mkdir "$NODE_TEST_ROOT/sysctl"
printf '0\n' >"$NODE_TEST_ROOT/sysctl/net_ipv4_tcp_mtu_probing"
printf 'cubic\n' >"$NODE_TEST_ROOT/sysctl/net_ipv4_tcp_congestion_control"
printf 'fq_codel\n' >"$NODE_TEST_ROOT/sysctl/net_core_default_qdisc"
fail_new_value=0
sysctl() {
  local arg key value
  if [[ "$1" == -n ]]; then
    key="${2//./_}"; [[ -f "$NODE_TEST_ROOT/sysctl/$key" ]] || return 1
    tr -d '\n' <"$NODE_TEST_ROOT/sysctl/$key"
  elif [[ "$1" == -w ]]; then
    shift
    for arg in "$@"; do
      key="${arg%%=*}"; key="${key//./_}"; value="${arg#*=}"
      printf '%s\n' "$value" >"$NODE_TEST_ROOT/sysctl/$key"
      if (( fail_new_value == 1 )) && [[ "$value" == 2 ]]; then return 1; fi
    done
  else return 1; fi
}
network_tuning_value_valid net.ipv4.tcp_mtu_probing 1 || die '合法参数被拒绝'
if network_tuning_value_valid net.ipv4.tcp_mtu_probing 3; then die '参数范围未校验'; fi
payload=$'# Managed by keine\nnet.ipv4.tcp_mtu_probing = 1'
config_file_write "$NETWORK_TUNING_FILE" 0644 "$payload" network_tuning_apply_file >/dev/null
[[ "$(sysctl -n net.ipv4.tcp_mtu_probing)" == 1 ]] || die '参数未生效'
fail_new_value=1
if config_file_write "$NETWORK_TUNING_FILE" 0644 "${payload/= 1/= 2}" network_tuning_apply_file >/dev/null 2>&1; then die '未发现参数应用失败'; fi
[[ "$(sysctl -n net.ipv4.tcp_mtu_probing)" == 1 ]] || die '参数失败回退未生效'
fail_new_value=0
sysctl -w net.ipv4.tcp_mtu_probing=2
if config_file_write "$NETWORK_TUNING_FILE" 0644 "$payload" network_tuning_apply_file >/dev/null 2>&1; then die '写入覆盖了外部运行值'; fi
[[ "$(sysctl -n net.ipv4.tcp_mtu_probing)" == 2 ]] || die '失败补偿覆盖了外部运行值'
if network_tuning_restore >/dev/null 2>&1; then die '覆盖了外部调优脚本改动'; fi
sysctl -w net.ipv4.tcp_mtu_probing=1
network_tuning_restore >/dev/null
[[ ! -e "$NETWORK_TUNING_FILE" && "$(sysctl -n net.ipv4.tcp_mtu_probing)" == 0 ]] || die '托管文件或初始运行值未恢复'
payload=$'# Managed by keine\nnet.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr'
config_file_write "$NETWORK_BBR_FILE" 0644 "$payload" network_bbr_apply_file >/dev/null
network_restore_bbr >/dev/null
[[ "$(sysctl -n net.core.default_qdisc)" == fq_codel && "$(sysctl -n net.ipv4.tcp_congestion_control)" == cubic ]] || die 'BBR 原始队列或算法未恢复'
DRY_RUN=1
config_file_write "$NODE_TEST_ROOT/dry.conf" 0644 'data' apply_ok >/dev/null
[[ ! -e "$NODE_TEST_ROOT/dry.conf" ]] || die 'dry-run 写入了文件'
printf 'PASS: node network configuration\n'
