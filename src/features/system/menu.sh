#!/usr/bin/env bash

system_menu() {
  local choice
  while true; do
    ui_page "系统管理" "诊断、资源与系统基础设置"
    ui_context "所有检查均为当前快照；修改操作逐项确认，不创建后台任务。"
    ui_section "诊断与资源" "primary"
    ui_item 1 "故障快速排查" "资源、失败服务、日志、暴露面、容器与备份"
    ui_item 2 "资源压力分析" "负载、内存、空间、inode 与 OOM"
    ui_item 3 "进程与资源" "高占用排行、详情、优先级与终止信号"
    ui_item 4 "重启与内核状态" "运行内核、重启提示与启动历史"
    ui_item 5 "软件包健康中心" "更新、安全补丁、hold、来源、修复与缓存"
    ui_item 6 "存储中心" "分类占用、最大文件、挂载、fstab 与已删除占用"
    ui_section "基础设置" "accent"
    ui_item 7 "Swap 管理" "状态、创建、即时启停与托管文件删除"
    ui_item 8 "修改主机名"
    ui_item 9 "修改时区"
    ui_item 10 "时间同步" "NTP 状态与同步服务控制"
    ui_item 0 "返回"
    choice="$(read_input "请选择" "0")"
    case "$choice" in
      1) system_triage; continue ;;
      2) system_pressure ;;
      3) system_processes; continue ;;
      4) system_reboot_status ;;
      5) system_package_health; continue ;;
      6) system_disk_usage; continue ;;
      7) system_swap_manage; continue ;;
      8) system_set_hostname || true ;;
      9) system_set_timezone || true ;;
      10) system_time_sync || true ;;
      0) return 0 ;;
      *) warn "未知选项：$choice"; continue ;;
    esac
    pause
  done
}
