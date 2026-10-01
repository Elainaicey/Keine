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
    ui_page "应用与容器" "集中管理应用资产、运行健康、服务生命周期与容器"
    ui_context "所有检查均按需执行；不会创建监控进程、Cron 或 Timer，也不会隐式修改防火墙。"
    if (( APPS_SERVICE_CACHE_ERROR == 1 )); then
      ui_callout warn "暂时无法读取 systemd 状态" "查询已在 3 秒内停止；R 重试，不代表应用未安装。"
      docker_state="未读取"; docker_style="warn"
      app_style="warn"
    fi
    ui_section "应用服务" "primary"
    if (( APPS_SERVICE_CACHE_ERROR == 1 )); then
      ui_state_item 1 "应用服务管理" "快照未完整读取" "$app_style" "R 重试，不进行未安装判定"
    else
      ui_state_item 1 "应用服务管理" "$running/$installed 运行" "$app_style" "版本、健康、资产、日志与生命周期"
    fi
    ui_section "容器" "accent"
    ui_state_item 2 "Docker" "$docker_state" "$docker_style" "容器、镜像、网络、存储卷与清理"
    ui_action R "刷新服务状态" "accent" "菜单使用本次快照；操作后自动失效"
    ui_item 0 "返回"
    choice="$(read_input "请选择" "0")"
    case "$choice" in
      1) apps_service_manage ;;
      2) docker_menu ;;
      R|r) apps_service_cache_invalidate ;;
      0) return 0 ;;
      *) warn "未知选项"; pause ;;
    esac
  done
}
