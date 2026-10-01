#!/usr/bin/env bash

toolkit_menu() {
  local choice
  while true; do
    ui_page "项目与扩展" "版本、环境、扩展接口和安装生命周期"
    ui_action 1 "项目与安装信息" "action"
    ui_action 2 "运行环境与完整性" "action"
    ui_action 3 "更新 keine" "success"
    ui_action 4 "项目变更与撤销" "warning"
    ui_action 5 "卸载项目" "danger" "可先撤销有记录的系统变更"
    ui_action 0 "返回" "muted"
    choice="$(read_input "请选择" "0")"
    case "$choice" in
      1) toolkit_about; pause ;;
      2) toolkit_doctor; pause ;;
      3) toolkit_self_update || true; pause ;;
      4) recovery_changes_menu ;;
      5) toolkit_uninstall || true ;;
      0) return 0 ;;
      *) warn "未知选项" ;;
    esac
  done
}
