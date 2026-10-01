#!/usr/bin/env bash

security_menu() {
  local choice
  while true; do
    ui_page "安全中心" "评估暴露面并控制防火墙、SSH 与登录防护"
    ui_section "评估与观察" "primary"
    ui_item 1 "安全基线检查" "防火墙、SSH、UID 0、Fail2ban 与重启"
    ui_item 2 "公网暴露分析" "关联监听、进程、systemd、Docker 与 UFW"
    ui_section "主机防护" "accent"
    ui_item 3 "UFW 防火墙管理" "放行/拒绝、来源、SSH 限速与运行控制"
    ui_item 4 "SSH 安全中心" "认证、连接/转发策略、会话、密钥与恢复"
    ui_item 5 "Fail2ban 管理" "SSH 持久策略、白名单、Jail 与误封恢复"
    ui_section "事件与证书" "primary"
    ui_item 6 "SSH 登录分析与处置" "成功/失败统计、高频来源与明确封禁"
    ui_item 7 "TLS 证书检查" "签发者、有效期、指纹与主机名"
    ui_item 0 "返回"
    choice="$(read_input "请选择" "0")"
    case "$choice" in
      1) security_audit ;;
      2) security_exposure_analysis || true ;;
      3) security_firewall_manage ;;
      4) security_ssh_manage ;;
      5) security_fail2ban || true ;;
      6) security_auth_center; continue ;;
      7) security_tls_inspect || true ;;
      0) return 0 ;;
      *) warn "未知选项"; continue ;;
    esac
    pause
  done
}
