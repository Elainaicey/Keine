#!/usr/bin/env bash

network_tuning_adapter_menu() {
  local choice
  while true; do
    ui_page "第三方网络调优适配" "预留适配入口 · 当前没有启用外部脚本"
    ui_panel_begin "适配状态"
    ui_panel_kv "提供方" "未选择"
    ui_panel_kv "自动下载 / 执行" "禁用"
    ui_panel_kv "可观测能力" "运行参数、持久来源与项目冲突"
    ui_panel_end
    ui_note "确定上游后新增独立适配器；菜单注册、来源验证、参数范围和撤销能力分别声明。"
    ui_hint "运行第三方调优前建议先撤销本项目参数，并保留实例快照。外部脚本的内核、路由、文件修改不能由本项目猜测性撤销。"
    ui_action 1 "查看参数与当前值" "action" "不执行外部脚本"
    ui_action 2 "查看持久配置来源" "action" "寻找重复键和开机覆盖"
    ui_action 3 "撤销项目网络参数" "warning" "不删除第三方配置"
    ui_action 0 "返回" "muted"
    choice="$(read_input "请选择" "0")"
    case "$choice" in
      1) network_tuning_menu; continue ;;
      2) network_tuning_sources ;;
      3) network_tuning_restore || true ;;
      0) return 0 ;; *) warn "未知选项"; continue ;;
    esac
    pause
  done
}
