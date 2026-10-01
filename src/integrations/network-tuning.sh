#!/usr/bin/env bash

network_tuning_adapter_menu() {
  local choice
  while true; do
    ui_page "第三方网络调优适配"
    ui_panel_begin "适配状态"
    ui_panel_kv "提供方" "未选择"
    ui_panel_kv "自动下载 / 执行" "禁用"
    ui_panel_kv "可观测能力" "运行参数、持久来源与项目冲突"
    ui_panel_end
    ui_hint "建议先撤销项目参数；第三方修改不能由 keine 自动撤销。"
    ui_action 1 "参数与当前值" "action"
    ui_action 2 "持久配置来源" "action"
    ui_action 3 "撤销项目参数" "warning"
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      1) network_tuning_menu; continue ;;
      2) network_tuning_sources ;;
      3) network_tuning_restore || true ;;
      0) return 0 ;; *) warn "未知选项"; continue ;;
    esac
    pause
  done
}
