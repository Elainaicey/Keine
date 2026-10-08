#!/usr/bin/env bash

apps_menu() {
  local choice counts installed running failed app_style docker_state docker_style
  apps_service_cache_invalidate
  while true; do
    apps_service_cache_build
    counts="$(apps_service_inventory_counts)"
    IFS='|' read -r installed running failed <<<"$counts"
    app_style="good"
    (( installed == 0 )) && app_style="muted"
    (( installed > running )) && app_style="warn"
    (( failed > 0 )) && app_style="bad"
    docker_state="未安装"
    docker_style="muted"
    if apps_service_cached_exists docker.service; then
      docker_state="$(apps_service_cached_state docker.service)"
      docker_style="warn"
      [[ "$docker_state" == "active" ]] && docker_style="good"
      [[ "$docker_state" == "failed" ]] && docker_style="bad"
    fi
    ui_page "应用与容器"
    if (( APPS_SERVICE_CACHE_ERROR == 1 )); then
      ui_callout warn "服务状态读取失败" "R 重试；不代表应用未安装。"
      docker_state="未读取"; docker_style="warn"
      app_style="warn"
    fi
    ui_section "应用服务" "primary"
    if (( APPS_SERVICE_CACHE_ERROR == 1 )); then
      ui_state_item 1 "应用服务管理" "未读取" "$app_style"
    else
      ui_state_item 1 "应用服务管理" "$running/$installed 运行" "$app_style"
    fi
    ui_section "容器" "primary"
    ui_state_item 2 "Docker" "$docker_state" "$docker_style"
    ui_section "网站与访问" "primary"
    ui_action 3 "反向代理与 HTTPS" "action"
    ui_section "操作" "primary"
    ui_action R "刷新状态" "accent"
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      1) apps_service_manage ;;
      2) docker_menu ;;
      3) web_menu ;;
      R|r) apps_service_cache_invalidate ;;
      0) return 0 ;;
      *) warn "未知选项"; pause ;;
    esac
  done
}
