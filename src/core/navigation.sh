#!/usr/bin/env bash

navigation_dispatch() {
  # 目录仅声明展示内容；执行目标必须进入白名单，不能 eval 配置或远端文本。
  case "$1" in
    dashboard_menu) dashboard_menu ;;
    system_menu) system_menu ;;
    network_menu) network_menu ;;
    security_menu) security_menu ;;
    services_menu) services_menu ;;
    software_catalog_menu) software_catalog_menu ;;
    apps_menu) apps_menu ;;
    terminal_menu) terminal_menu ;;
    recovery_menu) recovery_menu ;;
    toolkit_menu) toolkit_menu ;;
    *) warn "菜单没有已注册的执行目标：$1"; return 1 ;;
  esac
}

navigation_menu() {
  local choice row number _id section title handler hint previous section_style
  local rows=()
  platform_detect
  while true; do
    mapfile -t rows < <(awk -F '|' '!/^#/ && NF==6' "$CONFIG_DIR/navigation.tsv")
    ui_banner
    ui_context "$OS_NAME · $ARCH · ${MEMORY_MB} MB RAM"
    previous=""
    for row in "${rows[@]}"; do
      IFS='|' read -r number _id section title handler hint <<<"$row"
      if [[ "$section" != "$previous" ]]; then
        case "$section" in 主机与运行) section_style=primary ;; 工具与应用) section_style=accent ;; *) section_style=warning ;; esac
        ui_section "$section" "$section_style"; previous="$section"
      fi
      ui_item "$number" "$title" "$hint"
    done
    ui_item 0 "退出"
    choice="$(read_input "请选择" "0")"
    [[ "$choice" != 0 ]] || return 0
    handler=""
    for row in "${rows[@]}"; do
      IFS='|' read -r number _id section title handler hint <<<"$row"
      [[ "$number" != "$choice" ]] || break
      handler=""
    done
    if [[ -n "$handler" ]]; then navigation_dispatch "$handler" || true; else warn "未知选项：$choice"; pause; fi
  done
}
