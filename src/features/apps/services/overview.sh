#!/usr/bin/env bash

apps_service_inventory_counts() {
  local _app_id _label service _catalog_id _package_name _category state
  local installed=0 running=0 failed=0
  while IFS='|' read -r _app_id _label service _catalog_id _package_name _category; do
    service_exists "$service" || continue
    installed=$((installed + 1))
    state="$(service_state "$service")"
    [[ "$state" == "active" ]] && running=$((running + 1))
    [[ "$state" == "failed" ]] && failed=$((failed + 1))
  done < <(apps_service_catalog)
  printf '%s|%s|%s\n' "$installed" "$running" "$failed"
}

apps_service_summary() {
  local app_id label service catalog_id _package_name category state enabled style
  local count=0 running=0 installed=0 failed=0 stopped=0 version last_category=""
  ui_page "应用服务管理" "按领域浏览应用版本、运行状态和可控边界"
  ui_context "目录来自 config/apps.tsv；选择未安装条目时只进入对应单项安装流程。"
  while IFS='|' read -r app_id label service catalog_id _package_name category; do
    count=$((count + 1))
    if [[ "$category" != "$last_category" ]]; then
      ui_section "$category" "$([[ -z "$last_category" ]] && printf 'primary' || printf 'accent')"
      last_category="$category"
    fi
    if service_exists "$service"; then
      installed=$((installed + 1))
      state="$(service_state "$service")"
      enabled="$(systemctl is-enabled "$service" 2>/dev/null || true)"
      enabled="${enabled:-disabled}"
      version="$(apps_service_version "$app_id")"
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
    elif [[ -n "$catalog_id" ]]; then
      ui_state_item "$count" "$label" "未安装" "muted" "$service · 可进入单项安装"
    else
      ui_state_item "$count" "$label" "未安装" "muted" "$service · 仅管理现有服务"
    fi
  done < <(apps_service_catalog)
  ui_stats "目录" "$count" "已安装" "$installed" "运行中" "$running"
  if (( failed > 0 )); then
    ui_callout "bad" "$failed 个应用服务处于 failed" "选择对应应用可直接查看健康、日志和生命周期操作。"
  elif (( stopped > 0 )); then
    ui_callout "warn" "$stopped 个已安装应用当前未运行" "这可能是预期状态；选择条目可核实并直接启动。"
  elif (( installed > 0 )); then
    ui_callout "good" "已安装应用服务当前均在运行" "深度健康与数据占用仍只在用户打开对应页面时检查。"
  fi
  ui_note "应用中心不会周期探测服务、扫描数据目录或创建后台监控。"
  ui_action 0 "返回" "muted"
}
