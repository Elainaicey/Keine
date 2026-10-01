#!/usr/bin/env bash

security_menu() {
  local choice
  while true; do
    ui_page "安全中心" "评估暴露面并控制防火墙、SSH 与登录防护"
    ui_section "访问与防护" "primary"
    ui_item 1 "SSH 安全设置" "认证、连接/转发策略、会话、密钥与恢复"
    ui_item 2 "UFW 防火墙" "放行/拒绝、来源、SSH 限速与运行控制"
    ui_item 3 "Fail2ban 登录防护" "持久策略、白名单、Jail 与误封恢复"
    ui_section "检查与处置" "accent"
    ui_item 4 "安全基线检查" "防火墙、SSH、UID 0、Fail2ban 与重启"
    ui_item 5 "公网暴露分析" "关联监听、进程、systemd、Docker 与 UFW"
    ui_item 6 "SSH 登录分析" "成功/失败统计、高频来源与明确封禁"
    ui_section "证书" "primary"
    ui_item 7 "TLS 证书检查" "签发者、有效期、指纹与主机名"
    ui_item 0 "返回"
    choice="$(read_input "请选择" "0")"
    case "$choice" in
      1) security_ssh_manage || pause; continue ;;
      2) security_firewall_manage || pause; continue ;;
      3) security_fail2ban || pause; continue ;;
      4) security_audit ;;
      5) security_exposure_analysis || true ;;
      6) security_auth_center; continue ;;
      7) security_tls_inspect || true ;;
      0) return 0 ;;
      *) warn "未知选项"; continue ;;
    esac
    pause
  done
}
