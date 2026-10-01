#!/usr/bin/env bash

apps_service_manage() {
  local choice record app_id label service catalog_id _package _category
  while true; do
    apps_service_summary
    choice="$(read_input "请选择应用" "0")"
    [[ "$choice" == "0" ]] && return 0
    [[ "$choice" =~ ^[0-9]+$ ]] || { warn "选项无效。"; pause; continue; }
    record="$(apps_service_record "$choice" 2>/dev/null || true)"
    [[ -n "$record" ]] || { warn "未知应用编号：$choice"; pause; continue; }
    IFS='|' read -r app_id label service catalog_id _package _category <<<"$record"
    if service_exists "$service"; then
      apps_service_detail "$app_id"
    elif [[ -n "$catalog_id" ]]; then
      ui_note "$label 尚未安装，将进入单项软件安装流程。"
      catalog_install "$catalog_id" || true
      pause
    else
      warn "$label 未安装，当前只管理已经存在的 $service。"
      pause
    fi
  done
}
