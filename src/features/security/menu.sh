#!/usr/bin/env bash

security_menu() {
  local choice
  while true; do
    ui_page "安全中心"
    ui_section "访问与防护" "primary"
    ui_item 1 "SSH 安全设置"
    ui_item 2 "主机防火墙"
    ui_item 3 "Fail2ban 登录防护"
    ui_section "检查与处置" "accent"
    ui_item 4 "安全基线检查"
    ui_item 5 "公网暴露分析"
    ui_item 6 "SSH 登录分析"
    ui_section "证书" "primary"
    ui_item 7 "TLS 与证书管理"
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      1) security_ssh_manage || pause; continue ;;
      2) security_firewall_manage || pause; continue ;;
      3) security_fail2ban || pause; continue ;;
      4) security_audit ;;
      5) security_exposure_analysis || true ;;
      6) security_auth_center; continue ;;
      7) security_certificates_menu; continue ;;
      0) return 0 ;;
      *) warn "未知选项"; continue ;;
    esac
    pause
  done
}
