#!/usr/bin/env bash

services_pick_from_output() {
  local units="$1" expected_state="$2" service
  [[ -n "$units" ]] || return 0
  ui_menu_footer "返回"
  ui_read_choice service "服务名"
  [[ "$service" == "0" ]] && return 0
  valid_service_name "$service" || { warn "服务名格式无效。"; return 1; }
  awk '{print $1}' <<<"$units" | grep -Fxq "$service" || {
    warn "$service 不在当前 $expected_state 清单中。"
    return 1
  }
  services_select "$service"
}

services_running() {
  local units
  ui_page "运行中的服务" "查看 active 服务，并直接进入生命周期管理"
  units="$(systemctl --type=service --state=running --no-pager --no-legend --plain 2>/dev/null | sed -n '1,100p')"
  if [[ -n "$units" ]]; then printf '%s\n' "$units"; else ui_empty "没有运行中的服务"; fi
  services_pick_from_output "$units" "running" || true
}

services_failed() {
  local units
  ui_page "失败的服务" "检查 failed 单元，并直接查看日志或重启"
  units="$(systemctl --failed --type=service --no-pager --no-legend --plain 2>/dev/null | sed -n '1,100p')"
  if [[ -n "$units" ]]; then printf '%s\n' "$units"; else ui_check pass "没有 failed 服务"; fi
  services_pick_from_output "$units" "failed" || true
}

services_boot_errors() {
  ui_page "本次启动的错误日志" "当前 boot 的 error 级别 Journal"
  journalctl -b -p err --no-pager -n 120 2>/dev/null || ui_empty "无法读取 Journal"
}

services_browser() {
  local choice running failed
  while true; do
    running="$(systemctl --type=service --state=running --no-legend --no-pager 2>/dev/null | grep -c . || true)"
    failed="$(systemctl --failed --type=service --no-legend --no-pager 2>/dev/null | grep -c . || true)"
    ui_page "服务浏览与管理"
    ui_stats "运行中" "$running" "失败" "$failed" "管理范围" "service"
    ui_section "浏览方式" "primary"
    ui_action_pair 1 "失败服务" "danger" 2 "运行中服务" "success"
    ui_action_pair 3 "按关键词查找" "action" 4 "输入完整服务名" "action"
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      1) services_failed ;;
      2) services_running ;;
      3) services_search || true ;;
      4) services_select || true ;;
      0) return 0 ;;
      *) warn "未知选项：$choice"; continue ;;
    esac
    pause
  done
}
