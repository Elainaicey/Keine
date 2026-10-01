#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/features/system/storage.sh"

for path in /var /home /opt /srv /tmp; do
  system_storage_allowed_root "$path" || {
    printf 'FAIL: 正常存储扫描根目录被拒绝：%s\n' "$path" >&2
    exit 1
  }
done
if system_storage_allowed_root / || system_storage_allowed_root /etc ||
  system_storage_allowed_root /var/lib || system_storage_allowed_root '../var'; then
  printf 'FAIL: 存储扫描接受了未声明或危险目录\n' >&2
  exit 1
fi

ui_action_pair() { :; }
ui_action() { :; }
ui_menu_footer() { :; }
read_input() { printf '%s' "$STORAGE_TEST_CHOICE"; }
STORAGE_TEST_CHOICE=1
test_pick_root() {
  local root=""
  system_storage_pick_root root
  [[ "$root" == /var ]]
}
test_pick_root || { printf 'FAIL: 扫描目录选择未写入调用方\n' >&2; exit 1; }
STORAGE_TEST_CHOICE=0
if test_pick_root; then printf 'FAIL: 取消后仍选择了扫描目录\n' >&2; exit 1; fi
STORAGE_TEST_CHOICE=Q
quit_output="$(test_pick_root; printf unexpected)"
[[ -z "$quit_output" ]] || { printf 'FAIL: 扫描范围页退出后仍继续执行\n' >&2; exit 1; }

printf 'PASS: storage\n'
