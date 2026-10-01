#!/usr/bin/env bash
# 测试替身通过被加载的软件包健康模块间接调用。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/features/system/packages.sh"

apt() {
  printf 'Listing...\n'
  printf 'curl/stable-security 8.0.0 amd64 [upgradable from: 7.0.0]\n'
  printf 'jq/stable 1.7.1 amd64 [upgradable from: 1.6]\n'
}

removed=0
apt-get() {
  if [[ "$*" == *upgrade* ]]; then
    printf 'Inst curl [7.0.0] (8.0.0 Debian-Security:stable-security [amd64])\n'
    printf 'Inst jq [1.6] (1.7.1 Debian:stable [amd64])\n'
  elif [[ "$*" == *autoremove* && "$removed" -eq 0 ]]; then
    printf 'Remv old-library [1.0]\n'
    printf 'Remv old-helper [1.0]\n'
  fi
}

updates="$(system_package_upgradable_rows)"
grep -Fqx 'curl|7.0.0|8.0.0|amd64' <<<"$updates" || {
  printf 'FAIL: APT 更新版本解析错误\n' >&2
  exit 1
}
grep -Fqx 'jq|1.6|1.7.1|amd64' <<<"$updates" || {
  printf 'FAIL: APT 普通更新解析错误\n' >&2
  exit 1
}
[[ "$(system_package_security_rows)" == "curl" ]] || {
  printf 'FAIL: 安全更新识别错误\n' >&2
  exit 1
}
[[ "$(system_package_autoremove_rows)" == $'old-helper\nold-library' ]] || {
  printf 'FAIL: 自动清理软件包解析错误\n' >&2
  exit 1
}

valid_package_name linux-image-amd64 || {
  printf 'FAIL: 正常 Debian 软件包名被拒绝\n' >&2
  exit 1
}
valid_package_name 'libc6:amd64' || {
  printf 'FAIL: 带架构的软件包名被拒绝\n' >&2
  exit 1
}
if valid_package_name '../curl' || valid_package_name 'curl;reboot'; then
  printf 'FAIL: 接受了危险软件包名\n' >&2
  exit 1
fi

held_state=0
captured=()
apt-mark() {
  if [[ "$1" == "showhold" && "$held_state" -eq 1 ]]; then printf 'curl\n'; fi
}
package_installed() { [[ "$1" == "curl" ]]; }
read_input() {
  case "$1" in
    "软件包名") printf 'curl' ;;
    "选择") printf '1' ;;
    *) printf '%s' "${2:-}" ;;
  esac
}
confirm() { return 0; }
require_root() { :; }
run() {
  captured=("$@")
  [[ "$1" == "apt-mark" && "$2" == "hold" ]] && held_state=1
}
audit() { :; }
ui_page() { :; }
ui_section() { :; }
ui_empty() { :; }
ui_hint() { :; }
ui_action() { :; }
ui_success() { :; }
DRY_RUN=0

system_package_hold_manage >/dev/null
[[ "${#captured[@]}" -eq 3 && "${captured[0]}" == "apt-mark" && "${captured[1]}" == "hold" &&
  "${captured[2]}" == "curl" && "$held_state" -eq 1 ]] || {
  printf 'FAIL: apt-mark hold 操作构造或验证错误\n' >&2
  exit 1
}

apt_run() {
  [[ "$1" == "autoremove" ]] || return 1
  removed=1
}
ui_panel_begin() { :; }
ui_panel_kv() { :; }
ui_panel_end() { :; }
ui_danger() { :; }
system_package_autoremove >/dev/null
[[ "$removed" -eq 1 ]] || {
  printf 'FAIL: 残留依赖清理没有执行 autoremove\n' >&2
  exit 1
}

printf 'PASS: system packages\n'
