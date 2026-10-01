#!/usr/bin/env bash
# Journal 查询通过运行时调用这些测试替身。
# shellcheck disable=SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/features/services/journal.sh"

ui_page() { :; }
ui_section() { :; }
ui_action() { :; }
ui_action_pair() { :; }
ui_menu_footer() { :; }
ui_hint() { :; }
ui_empty() { :; }
ui_note() { :; }
unit_exists() { [[ "$1" == "nginx.service" ]]; }
read_input() {
  case "$1" in
    "时间范围") printf '3' ;;
    "优先级") printf '2' ;;
    "systemd 单元") printf 'nginx.service' ;;
    "关键词") printf 'failure' ;;
    *) printf '%s' "${2:-}" ;;
  esac
}
journalctl() {
  printf 'failure'
  printf ' <%s>' "$@"
  printf '\nordinary message\n'
}

output="$(services_journal_query)"
grep -q 'failure.*<--since>.*<-24 hours>.*<-p>.*<warning>.*<-u>.*<nginx.service>' <<<"$output" || {
  printf 'FAIL: Journal 条件没有安全分发为独立参数\n' >&2
  exit 1
}
if grep -q 'ordinary message' <<<"$output"; then
  printf 'FAIL: Journal 关键词筛选没有排除不匹配日志\n' >&2
  exit 1
fi

printf 'PASS: journal\n'
