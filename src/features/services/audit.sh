#!/usr/bin/env bash

services_audit_safe_line() {
  local line
  line="$(terminal_safe_text "${1:-}")"
  if [[ "$line" == *" command="* ]]; then
    line="${line%% command=*} command=[redacted]"
  fi
  printf '%s' "$line"
}

services_audit_log() {
  ui_page "项目操作记录" "最近 100 条"
  if [[ -r "$AUDIT_LOG" ]]; then
    tail -n 100 "$AUDIT_LOG" | while IFS= read -r line; do
      printf '%s\n' "$(services_audit_safe_line "$line")"
    done
  else
    ui_empty "尚无操作记录"
  fi
}
