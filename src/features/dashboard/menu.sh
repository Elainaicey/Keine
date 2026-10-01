#!/usr/bin/env bash

dashboard_menu() {
  local choice
  while true; do
    dashboard_show
    ui_section "继续操作" "primary"
    ui_action_pair 1 "刷新总览" "success" 2 "故障快速排查" "action"
    ui_action_pair 3 "软件包更新" "warning" 4 "公网暴露分析" "action"
    ui_action_pair 5 "服务管理" "action" 6 "备份与恢复" "action"
    ui_action 0 "返回主菜单" "muted"
    choice="$(read_input "请选择" "0")"
    case "$choice" in
      1) continue ;;
      2) system_triage; continue ;;
      3) system_update_menu; continue ;;
      4) security_exposure_analysis; continue ;;
      5) services_browser; continue ;;
      6) backups_menu; continue ;;
      0) return 0 ;;
      *) warn "未知选项：$choice"; pause ;;
    esac
  done
}
