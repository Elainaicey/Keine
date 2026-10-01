#!/usr/bin/env bash

system_menu() {
  local choice
  while true; do
    ui_page "系统管理" "基础设置、终端环境、系统维护与资源管理"
    ui_context "所有检查均为当前快照；修改操作逐项确认，不创建后台任务。"
    ui_section "基础设置" "primary"
    ui_item 1 "主机名" "修改名称并同步 hosts"
    ui_item 2 "系统时区" "使用系统 zoneinfo 数据库"
    ui_item 3 "时间同步" "NTP 状态与同步服务控制"
    ui_item 4 "终端与美化" "默认 Shell、框架、提示符切换与恢复"
    ui_section "系统维护" "accent"
    ui_item 5 "系统更新" "预览并更新当前发行版；不自动重启"
    ui_item 6 "软件包健康" "hold、来源、依赖修复与缓存"
    ui_section "资源管理" "primary"
    ui_item 7 "Swap 管理" "创建、即时启停与托管文件删除"
    ui_item 8 "存储中心" "占用、最大文件、挂载与已删除占用"
    ui_item 9 "进程与资源" "高占用、详情、优先级与终止信号"
    ui_section "诊断与排障" "warning"
    ui_item 10 "资源压力分析" "负载、内存、空间、inode 与 OOM"
    ui_item 11 "重启与内核状态" "运行内核、重启提示与启动历史"
    ui_item 12 "故障快速排查" "跨领域检查与操作建议"
    ui_item 0 "返回"
    choice="$(read_input "请选择" "0")"
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
