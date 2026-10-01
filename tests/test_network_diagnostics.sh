#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/features/network/diagnostics.sh"

states="$(printf '%s\n' \
  'ESTAB 0 0 192.0.2.10:22 198.51.100.2:50000' \
  'TIME-WAIT 0 0 192.0.2.10:443 198.51.100.3:50001' \
  'ESTAB 0 0 192.0.2.10:22 198.51.100.4:50002' \
  'SYN-RECV 0 0 192.0.2.10:443 198.51.100.5:50003' |
  network_tcp_state_rows)"
grep -Fxq 'ESTAB|2' <<<"$states" || {
  printf 'FAIL: TCP ESTAB 状态聚合错误\n' >&2
  exit 1
}
grep -Fxq 'TIME-WAIT|1' <<<"$states" || {
  printf 'FAIL: TCP TIME-WAIT 状态聚合错误\n' >&2
  exit 1
}
grep -Fxq 'SYN-RECV|1' <<<"$states" || {
  printf 'FAIL: TCP SYN-RECV 状态聚合错误\n' >&2
  exit 1
}

if network_endpoint_probe 'host;reboot' 443 >/dev/null 2>&1 ||
  network_endpoint_probe example.com 70000 >/dev/null 2>&1; then
  printf 'FAIL: TCP 端点探测接受了危险目标或端口\n' >&2
  exit 1
fi

getent() { printf '203.0.113.5 STREAM example.com\n'; }
ip() { printf '203.0.113.5 via 192.0.2.1 dev eth0\n'; }
nc() { [[ "$4" == "203.0.113.5" && "$5" == "443" ]]; }
command_exists() { [[ "$1" == "nc" ]]; }
ui_page() { :; }
ui_check() { printf '%s\n' "$2"; }
result="$(network_endpoint_probe example.com 443)"
grep -Fq 'TCP example.com (203.0.113.5):443 可以建立连接' <<<"$result" || {
  printf 'FAIL: TCP 握手没有使用路由检查过的解析地址\n' >&2
  exit 1
}

printf 'PASS: network diagnostics\n'
