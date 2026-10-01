#!/usr/bin/env bash

apps_service_inventory_counts() {
  local _app_id _label service _catalog_id _package_name _category state
  local installed=0 running=0 failed=0
  while IFS='|' read -r _app_id _label service _catalog_id _package_name _category; do
    apps_service_cached_exists "$service" || continue
    installed=$((installed + 1))
    state="$(apps_service_cached_state "$service")"
    [[ "$state" == "active" ]] && running=$((running + 1))
    [[ "$state" == "failed" ]] && failed=$((failed + 1))
  done < <(apps_service_catalog)
  printf '%s|%s|%s\n' "$installed" "$running" "$failed"
}

apps_service_summary() {
  local app_id label service _catalog_id _package_name category state enabled style
  local count=0 running=0 installed=0 failed=0 stopped=0 version last_category=""
  ui_page "应用服务管理"
  while IFS='|' read -r app_id label service _catalog_id _package_name category; do
    count=$((count + 1))
    if [[ "$category" != "$last_category" ]]; then
      ui_section "$category" "$([[ -z "$last_category" ]] && printf 'primary' || printf 'accent')"
      last_category="$category"
    fi
    if (( APPS_SERVICE_CACHE_ERROR == 1 )); then
      ui_state_item "$count" "$label" "未读取" "warn"
    elif apps_service_cached_exists "$service"; then
      installed=$((installed + 1))
      state="$(apps_service_cached_state "$service")"
      enabled="$(apps_service_cached_enabled "$service")"
      version="$(apps_service_package_version "$app_id" 2>/dev/null || true)"
      version="${version:-—}"
      if [[ "$state" == "active" ]]; then
        style="good"
        running=$((running + 1))
      elif [[ "$state" == "failed" ]]; then
        style="danger"
        failed=$((failed + 1))
      else
        style="warn"
        stopped=$((stopped + 1))
      fi
      ui_state_item "$count" "$label" "$state" "$style" "$version · 开机 $enabled"
    else
      ui_state_item "$count" "$label" "未安装" "muted"
    fi
  done < <(apps_service_catalog)
  if (( APPS_SERVICE_CACHE_ERROR == 1 )); then
    ui_stats "目录" "$count" "已安装" "—" "运行中" "—"
  else
    ui_stats "目录" "$count" "已安装" "$installed" "运行中" "$running"
  fi
  if (( failed > 0 )); then
    ui_callout "bad" "$failed 个服务异常"
  elif (( stopped > 0 )); then
    ui_callout "warn" "$stopped 个服务未运行"
  fi
  ui_action R "刷新状态与版本" "accent"
  ui_menu_footer "返回"
}
