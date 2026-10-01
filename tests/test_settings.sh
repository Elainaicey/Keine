#!/usr/bin/env bash
# STATE_ROOT 由加载后的系统设置模块消费。
# shellcheck disable=SC2034
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/features/system/settings.sh"

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
STATE_ROOT="$test_root/keine"
mkdir -p "$STATE_ROOT"
swap_file="$test_root/swapfile"
touch "$swap_file"

[[ "$(system_swap_marker)" == "$STATE_ROOT/swapfile.managed" ]] || {
  printf 'FAIL: Swap 状态文件路径错误\n' >&2
  exit 1
}
identity="$(stat -c '%d:%i' "$swap_file")"
printf 'path=%s\nidentity=%s\nsize_mb=1024\n' "$swap_file" "$identity" >"$(system_swap_marker)"
system_owned_file_matches "$(system_swap_marker)" "$swap_file" || {
  printf 'FAIL: 未识别工具管理的 Swap 状态\n' >&2
  exit 1
}
printf 'path=%s\nidentity=0:0\n' "$swap_file" >"$(system_swap_marker)"
if system_owned_file_matches "$(system_swap_marker)" "$swap_file"; then
  printf 'FAIL: 接受了不属于工具的 Swap 路径\n' >&2
  exit 1
fi

printf 'PASS: settings\n'
