#!/usr/bin/env bash

system_menu() {
  local choice
  while true; do
    ui_page "系统管理"
    ui_section "基础设置" "primary"
    ui_item 1 "主机名"
    ui_item 2 "系统时区"
    ui_item 3 "时间同步"
    ui_item 4 "终端与美化"
    ui_section "系统维护" "accent"
    ui_item 5 "系统更新"
    ui_item 6 "软件包健康"
    ui_section "资源管理" "primary"
    ui_item 7 "Swap 管理"
    ui_item 8 "存储中心"
    ui_item 9 "进程与资源"
    ui_section "诊断与排障" "warning"
    ui_item 10 "资源压力分析"
    ui_item 11 "重启与内核状态"
    ui_item 12 "故障快速排查"
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      1) system_set_hostname || true ;;
      2) system_set_timezone || true ;;
      3) system_time_sync || true ;;
      4) terminal_menu; continue ;;
      5) system_update_menu; continue ;;
      6) system_package_health; continue ;;
      7) system_swap_manage; continue ;;
      8) system_disk_usage; continue ;;
      9) system_processes; continue ;;
      10) system_pressure ;;
      11) system_reboot_status ;;
      12) system_triage; continue ;;
      0) return 0 ;;
      *) warn "未知选项：$choice"; continue ;;
    esac
    pause
  done
}
