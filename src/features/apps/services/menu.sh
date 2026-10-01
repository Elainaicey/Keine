#!/usr/bin/env bash

apps_service_manage() {
  local choice record app_id label service catalog_id _package _category
  while true; do
    apps_service_cache_build
    apps_service_summary
    choice="$(read_input "请选择应用" "0")"
    [[ "$choice" == "0" ]] && return 0
    case "$choice" in R|r) apps_service_cache_invalidate; continue ;; esac
    [[ "$choice" =~ ^[0-9]+$ ]] || { warn "选项无效。"; pause; continue; }
    record="$(apps_service_record "$choice" 2>/dev/null || true)"
    [[ -n "$record" ]] || { warn "未知应用编号：$choice"; pause; continue; }
    IFS='|' read -r app_id label service catalog_id _package _category <<<"$record"
    if (( APPS_SERVICE_CACHE_ERROR == 1 )); then
      warn "服务快照没有完整读取，请先 R 刷新；不会将查询失败当作未安装。"
      pause
      continue
    fi
    if apps_service_cached_exists "$service"; then
      apps_service_detail "$app_id"
    elif [[ -n "$catalog_id" ]]; then
      ui_note "$label 尚未安装，将进入单项软件安装流程。"
      catalog_install "$catalog_id" || true
      apps_service_cache_invalidate
      pause
    else
      warn "$label 未安装，当前只管理已经存在的 $service。"
      pause
    fi
  done
}
