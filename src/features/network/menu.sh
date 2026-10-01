#!/usr/bin/env bash

network_connections_menu() {
  local choice
  while true; do
    ui_page "网络 / 连接与端口"
    ui_section "连接状态" "primary"
    ui_item 1 "网络接口详情"
    ui_item 2 "路由与策略规则"
    ui_item 3 "连接会话"
    ui_section "监听端口" "accent"
    ui_item 4 "全部监听"
    ui_item 5 "查询一个端口"
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      1) network_interface_detail "" || true ;;
      2) network_routes ;;
      3) network_connections || true ;;
      4) network_list_ports ;;
      5) network_port_detail || true ;;
      0) return 0 ;;
      *) warn "未知选项"; continue ;;
    esac
    pause
  done
}

network_diagnostics_menu() {
  local choice
  while true; do
    ui_page "网络 / 连通性诊断"
    ui_section "快速检查" "primary"
    ui_item 1 "本机出站连通性"
    ui_item 2 "目标快速诊断"
    ui_section "协议与链路" "accent"
    ui_item 3 "DNS 解析诊断"
    ui_item 4 "TCP 端点探测"
    ui_item 5 "HTTP / HTTPS 诊断"
    ui_item 6 "链路路径"
    ui_item 7 "套接字压力"
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      1) network_connectivity_test ;;
      2) network_target_diagnose || true ;;
      3) network_dns_diagnose "" || true ;;
      4) network_endpoint_probe "" "" || true ;;
      5) network_http_diagnose "" || true ;;
      6) network_path_trace "" || true ;;
      7) network_socket_pressure || true ;;
      0) return 0 ;;
      *) warn "未知选项"; continue ;;
    esac
    pause
  done
}

network_menu() {
  local choice
  while true; do
    ui_page "网络管理"
    ui_section "常用配置" "primary"
    ui_item 1 "网络概览"
    ui_item 2 "系统 DNS"
    ui_item 3 "SOCKS 出站代理"
    ui_item 4 "WARP 连接"
    ui_item 5 "网络调优"
    ui_section "状态与诊断" "accent"
    ui_item 6 "连接与端口"
    ui_item 7 "连通性诊断"
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      1) network_show; pause ;;
      2) network_dns_menu ;;
      3) network_proxy_menu ;;
      4) warp_menu ;;
      5) network_tuning_menu ;;
      6) network_connections_menu ;;
      7) network_diagnostics_menu ;;
      0) return 0 ;;
      *) warn "未知选项"; pause ;;
    esac
  done
}
