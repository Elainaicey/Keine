#!/usr/bin/env bash
# Offline deterministic iperf fixtures, no real traffic or kernel changes.
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
comparison_test_root="$(mktemp -d)"
trap '[[ "$comparison_test_root" == /tmp/* ]] && rm -rf -- "$comparison_test_root"' EXIT
KEINE_STATE_ROOT="$comparison_test_root/keine-state"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/core/changes.sh"
. "$ROOT_DIR/src/core/configuration.sh"
. "$ROOT_DIR/src/integrations/network-tuning.sh"
require_root() { :; }
confirm() { :; }
flock() { :; }
tuning_measure_requirements() { :; }
tuning_device_exists() { [[ "$1" == eth0 ]]; }
tuning_device_identity() { printf '2:00:11:22:33:44:55'; }
tuning_boot_id() { printf '%s' "${test_boot:-boot-one}"; }
sysctl() { printf '%s' "${test_parameter:-bbr}"; }
tc() { printf 'qdisc fq 8000: root'; }
ip() {
  printf '%s\n' "$*" >>"$comparison_test_root/routes"
  printf '2001:db8::1 dev eth0 src 2001:db8::2\n'
}
timeout() { shift 4; "$@"; }
iperf3() {
  [[ "$1" != --version ]] || { printf 'iperf 3.test\n'; return 0; }
  printf '%s\n' "$*" >>"$comparison_test_root/iperf-args"
  [[ "${test_fail:-0}" == 0 ]] || return 1
  [[ "${test_partial:-0}" == 0 ]] || { printf '{"end":{}}'; return 0; }
  local count
  count="$(cat "$comparison_test_root/count" 2>/dev/null || printf 0)"
  count=$((count+1)); printf '%s' "$count" >"$comparison_test_root/count"
  printf '{"end":{"sum_sent":{"bits_per_second":100000000,"retransmits":3,"seconds":3},"sum_received":{"bits_per_second":%s}}}' "${test_speed:-95000000}"
}
DRY_RUN=1
tuning_comparison_capture baseline eth0 2001:db8::1 5201 3 reverse >/dev/null
[[ ! -e "$STATE_ROOT" ]] || die '预览产生结果'
DRY_RUN=0
tuning_comparison_capture baseline eth0 2001:db8::1 5201 3 reverse >/dev/null
baseline="$(tuning_comparison_root)/baseline.json"
latest="$(tuning_comparison_root)/latest.json"
tuning_comparison_valid "$baseline" || die '基准格式无效'
[[ "$(cat "$comparison_test_root/count")" == 6 ]] || die '没有完成六轮采样'
grep -Fxq -- '-6' "$comparison_test_root/routes" || die 'IPv6 未明确选择路由族'
[[ "$(grep -c -- '-R' "$comparison_test_root/iperf-args")" == 6 ]] || die '接收方向未传递给 iperf'
test_speed=114000000; test_parameter=cubic
tuning_comparison_capture repeat >/dev/null
report="$(tuning_comparison_show)"
[[ "$report" == *'20%'* && "$report" == *'95 → 114'* ]] || die '对比计算错误'
previous="$(changes_fingerprint "$latest")"
test_fail=1
if tuning_comparison_capture repeat >/dev/null 2>&1; then die '接受失败样本'; fi
[[ "$previous" == "$(changes_fingerprint "$latest")" ]] || die '失败覆盖完整复测'
unset test_fail
test_partial=1
if tuning_comparison_capture repeat >/dev/null 2>&1; then die '接受不完整 JSON'; fi
unset test_partial
test_boot=boot-two
if tuning_comparison_capture repeat >/dev/null 2>&1; then die '重启后沿用旧基准'; fi
unset test_boot
# Configuration changes during a capture invalidate all its samples.
tuning_comparison_snapshot() { cat "$comparison_test_root/count"; }
if tuning_comparison_capture repeat >/dev/null 2>&1; then die '接受测量期间变化的配置'; fi
[[ "$previous" == "$(changes_fingerprint "$latest")" ]] || die '混合样本覆盖结果'
# Replacing the baseline invalidates a previous comparison.
printf ' ' >>"$baseline"
if tuning_comparison_show >/dev/null 2>&1; then die '显示不属于当前基准的对比'; fi
# Hostile persisted parameters are rejected, never evaluated.
jq '.iface="eth0;touch /tmp/unsafe"' "$baseline" >"$baseline.invalid"
if tuning_comparison_valid "$baseline.invalid"; then die '接受异常网卡参数'; fi
[[ -z "$(find "$(tuning_comparison_root)" -name '.sample.*' -print)" ]] || die '测量临时文件未清理'
printf 'PASS: tuning_comparison\n'
