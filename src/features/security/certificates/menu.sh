#!/usr/bin/env bash

security_certificates_menu() {
  local choice
  while true; do
    ui_page "TLS 与证书"
    ui_section "证书管理" primary
    ui_action 1 "本机 Certbot 证书" action
    ui_action 2 "检查本地 PEM 证书" action
    ui_action 3 "检查在线 TLS 证书" action
    ui_section "安装组件" accent
    ui_action 4 "Certbot" action
    ui_action 5 "Certbot Nginx 插件" action
    ui_action 6 "Certbot Apache 插件" action
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      1) security_certbot_menu; continue ;;
      2) security_certificate_file_inspect || true ;;
      3) security_tls_inspect || true ;;
      4) catalog_item_menu certbot; continue ;;
      5) catalog_item_menu certbot-nginx; continue ;;
      6) catalog_item_menu certbot-apache; continue ;;
      0) return 0 ;;
      *) warn "未知选项" ;;
    esac
    pause
  done
}
