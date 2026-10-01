#!/usr/bin/env bash
# 应用健康函数通过运行时调用这些测试桩，并消费场景变量。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/core/platform.sh"
. "$ROOT_DIR/src/features/apps.sh"

HEALTH_STATE="active"
HEALTH_RUNTIME_STATUS=0
HEALTH_LISTENERS=2
HEALTH_ERRORS=3
HEALTH_RESTARTS=6
HEALTH_RESULT="success"
HEALTH_EXIT_STATUS=0
HEALTH_SUMMARY=""
HEALTH_CALLOUT=""
HEALTH_CHECKS=""
APP_HEALTH_JOURNAL_FILE="$(mktemp)"
trap 'rm -f -- "$APP_HEALTH_JOURNAL_FILE"' EXIT

service_state() { printf '%s' "$HEALTH_STATE"; }
apps_service_listener_count() { printf '%s' "$HEALTH_LISTENERS"; }
apps_service_runtime_check() { return "$HEALTH_RUNTIME_STATUS"; }
journalctl() {
  local index
  printf '%s\n' "$@" >"$APP_HEALTH_JOURNAL_FILE"
  for ((index = 0; index < HEALTH_ERRORS; index++)); do printf 'error\n'; done
}
systemctl() {
  if [[ "$1" == "is-enabled" ]]; then
    printf 'enabled\n'
    return 0
  fi
  if [[ "$1" == "show" ]]; then
    printf '%s\n' \
      "NRestarts=$HEALTH_RESTARTS" "Result=$HEALTH_RESULT" "ExecMainStatus=$HEALTH_EXIT_STATUS" \
      'ActiveEnterTimestamp=Wed 2026-07-30 00:00:00 CST' 'MemoryCurrent=1048576' \
      'TasksCurrent=8' 'CPUUsageNSec=2000000000'
  fi
}
services_format_bytes() { printf '1 MiB'; }
services_format_cpu_time() { printf '2 秒'; }
ui_page() { :; }
ui_context() { :; }
ui_section() { :; }
ui_metric_row() { :; }
ui_note() { :; }
ui_hint() { :; }
ui_check() { HEALTH_CHECKS+="$1:$2"$'\n'; }
ui_health_summary() { HEALTH_SUMMARY="$1|$2|$3"; }
ui_callout() { HEALTH_CALLOUT="$1:$2"; }

apps_service_health nginx
grep -Fxq -- '--quiet' "$APP_HEALTH_JOURNAL_FILE" || {
  printf 'FAIL: Journal 健康计数没有抑制无条目提示\n' >&2
  exit 1
}
[[ "$HEALTH_SUMMARY" == "3|2|0" ]] || {
  printf 'FAIL: 应用健康关注场景统计错误：%s\n' "$HEALTH_SUMMARY" >&2
  exit 1
}
[[ "$HEALTH_CALLOUT" == warn:* && "$HEALTH_CHECKS" == *"warn:最近 1 小时有 3 条"* ]] || {
  printf 'FAIL: 应用健康没有汇总近期错误与重启关注项\n' >&2
  exit 1
}

HEALTH_STATE="failed"
HEALTH_RUNTIME_STATUS=1
HEALTH_LISTENERS=0
HEALTH_ERRORS=25
HEALTH_RESTARTS=0
HEALTH_RESULT="exit-code"
HEALTH_EXIT_STATUS=1
HEALTH_SUMMARY=""
HEALTH_CALLOUT=""
HEALTH_CHECKS=""

apps_service_health nginx
[[ "$HEALTH_SUMMARY" == "1|2|3" ]] || {
  printf 'FAIL: 应用健康异常场景统计错误：%s\n' "$HEALTH_SUMMARY" >&2
  exit 1
}
[[ "$HEALTH_CALLOUT" == bad:* && "$HEALTH_CHECKS" == *"fail:应用级只读检查失败"* ]] || {
  printf 'FAIL: 应用健康没有输出异常结论\n' >&2
  exit 1
}

printf 'PASS: app health\n'
