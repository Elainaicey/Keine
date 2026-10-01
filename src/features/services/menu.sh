#!/usr/bin/env bash

services_menu() {
  local choice
  while true; do
    ui_page "服务与日志"
    ui_section "服务" "primary"
    ui_item 1 "服务浏览与管理"
    ui_item 2 "本次启动错误"
    ui_section "日志" "accent"
    ui_item 3 "Journal 中心"
    ui_item 4 "项目操作记录"
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      1) services_browser; continue ;;
      2) services_boot_errors ;;
      3) services_journal_info; continue ;;
      4) services_audit_log ;;
      0) return 0 ;;
      *) warn "未知选项"; continue ;;
    esac
    pause
  done
}
