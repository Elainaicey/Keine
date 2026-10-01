#!/usr/bin/env bash

docker_menu() {
  local choice
  while true; do
    apps_service_cache_build
    ui_page "应用与容器 / Docker"
    if ! command_exists docker; then
      ui_empty "Docker 未安装"
      ui_action 1 "安装 Docker" "success"
      ui_menu_footer "返回"
      ui_read_choice choice
      case "$choice" in
        1) catalog_item_menu docker ;;
        0) return 0 ;;
        *) warn "未知选项：$choice" ;;
      esac
      continue
    fi
    ui_kv "服务快照" "$(apps_service_cached_state docker.service)"
    ui_hint "容器发布端口可能绕过 UFW。"
    ui_section "观察" "primary"
    ui_item 1 "Docker 概览"
    ui_item 2 "Docker 健康检查"
    ui_item 3 "全部容器"
    ui_item 4 "镜像"
    ui_item 5 "容器资源"
    ui_item 6 "存储卷与网络"
    ui_item 7 "Compose 项目管理"
    ui_section "操作" "accent"
    ui_item 8 "管理一个容器"
    ui_item 9 "安全清理"
    ui_item 10 "Docker 卷备份"
    ui_action R "刷新服务状态" "accent"
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      1) docker_overview || true ;;
      2) docker_health || true ;;
      3) docker_containers || true ;;
      4) docker_images || true ;;
      5) docker_resources || true ;;
      6) docker_storage || true ;;
      7) if ! docker_compose_manage ""; then pause; fi; continue ;;
      8) if ! docker_container_action; then pause; fi; continue ;;
      9) docker_cleanup || true ;;
      10) docker_volume_backups_menu; continue ;;
      R|r) apps_service_cache_invalidate; continue ;;
      0) return 0 ;;
      *) warn "未知选项"; continue ;;
    esac
    pause
  done
}
