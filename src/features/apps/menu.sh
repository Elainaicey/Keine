#!/usr/bin/env bash

apps_menu() {
  local choice counts installed running failed app_style docker_state docker_style
  while true; do
    counts="$(apps_service_inventory_counts)"
    IFS='|' read -r installed running failed <<<"$counts"
    app_style="good"
    (( installed == 0 )) && app_style="muted"
    (( installed > running )) && app_style="warn"
    (( failed > 0 )) && app_style="bad"
    docker_state="未安装"
    docker_style="muted"
    if service_exists docker.service; then
      docker_state="$(service_state docker.service)"
      docker_style="warn"
      [[ "$docker_state" == "active" ]] && docker_style="good"
      [[ "$docker_state" == "failed" ]] && docker_style="bad"
    fi
    ui_page "应用与容器" "集中管理应用资产、运行健康、服务生命周期与容器"
    ui_context "所有检查均按需执行；不会创建监控进程、Cron 或 Timer，也不会隐式修改防火墙。"
    ui_section "应用服务" "primary"
    ui_state_item 1 "应用服务管理" "$running/$installed 运行" "$app_style" "版本、健康、资产、日志与生命周期"
    ui_section "容器" "accent"
    ui_state_item 2 "Docker" "$docker_state" "$docker_style" "容器、镜像、网络、存储卷与清理"
    ui_item 0 "返回"
    choice="$(read_input "请选择" "0")"
    case "$choice" in
      1) apps_service_manage ;;
      2) docker_menu ;;
      0) return 0 ;;
      *) warn "未知选项"; pause ;;
    esac
  done
}
