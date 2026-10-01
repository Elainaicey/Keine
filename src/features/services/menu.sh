#!/usr/bin/env bash

services_menu() {
  local choice
  while true; do
    ui_page "服务与日志" "systemd 服务、启动错误、Journal 与项目操作记录"
    ui_context "只管理 service 单元；不提供 Cron 或 Timer 调度入口。"
    ui_section "服务" "primary"
    ui_item 1 "服务浏览与管理" "失败/运行清单、关键词、详情与生命周期"
    ui_item 2 "本次启动错误" "当前 boot 的 error 级别 Journal"
    ui_section "日志" "accent"
    ui_item 3 "Journal 中心" "条件查询、验证、内核警告与空间清理"
    ui_item 4 "项目操作记录" "只记录由 keine 确认执行的修改"
    ui_item 0 "返回"
    choice="$(read_input "请选择" "0")"
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
