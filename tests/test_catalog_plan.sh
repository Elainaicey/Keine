#!/usr/bin/env bash
# APT/UI 测试替身由事务预览模块间接调用。
# shellcheck disable=SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
. "$ROOT_DIR/src/features/software/catalog/plan.sh"

PLAN_SCENARIO=install
CALLOUT=""
command_exists() { [[ "$1" == apt-get ]]; }
package_installed() { [[ "$1" == demo ]]; }
apt-get() {
  if [[ "$PLAN_SCENARIO" == install ]]; then
    printf '%s\n' \
      'Inst demo [1.0] (2.0 stable [amd64])' \
      'Inst helper (1.0 stable [amd64])' \
      'Remv conflicting [1.0]' \
      'After this operation, 2 MB of additional disk space will be used.'
  else
    printf '%s\n' 'Remv demo [1.0]' 'Remv helper [1.0]' 'After this operation, 2 MB disk space will be freed.'
  fi
}
ui_section() { :; }
ui_metric_row() { :; }
ui_status() { :; }
ui_hint() { :; }
ui_note() { :; }
terminal_safe_text() { printf '%s' "$1"; }
ui_callout() { CALLOUT="$1:$2"; }

catalog_apt_plan_simulate install demo || { printf 'FAIL: APT 安装模拟失败\n' >&2; exit 1; }
[[ "$CATALOG_PLAN_INSTALLS" -eq 1 && "$CATALOG_PLAN_UPGRADES" -eq 1 && "$CATALOG_PLAN_REMOVALS" -eq 1 ]] || {
  printf 'FAIL: APT 事务计数错误\n' >&2
  exit 1
}
grep -Fqx '安装 / 更新|demo|2.0' < <(catalog_apt_plan_items) || {
  printf 'FAIL: APT 事务没有提取目标版本\n' >&2
  exit 1
}
if catalog_apt_plan_render install demo >/dev/null; then
  printf 'FAIL: 安装事务包含移除项仍被允许\n' >&2
  exit 1
fi
[[ "$CALLOUT" == bad:* ]] || { printf 'FAIL: 危险事务没有明确提示\n' >&2; exit 1; }

PLAN_SCENARIO=remove
CALLOUT=""
catalog_apt_plan_render remove demo helper >/dev/null || { printf 'FAIL: 明确移除事务被错误阻止\n' >&2; exit 1; }
[[ "$CATALOG_PLAN_REMOVALS" -eq 2 && "$CALLOUT" == warn:* ]] || {
  printf 'FAIL: 联带移除没有显示警告\n' >&2
  exit 1
}

printf 'PASS: catalog plan\n'
