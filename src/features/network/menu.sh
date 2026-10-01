#!/usr/bin/env bash

network_connections_menu() {
  local choice
  while true; do
    ui_page "网络 / 连接与端口" "本机接口、路由、会话与监听进程"
    ui_section "连接状态" "primary"
    ui_item 1 "网络接口详情" "地址、流量、错误与链路能力"
    ui_item 2 "路由与策略规则" "IPv4、IPv6 与策略路由"
    ui_item 3 "连接会话" "远端端点与状态分布"
    ui_section "监听端口" "accent"
    ui_item 4 "全部监听" "TCP/UDP 地址与关联进程"
    ui_item 5 "查询一个端口" "定位监听与占用进程"
    ui_item 0 "返回网络管理"
    choice="$(read_input "请选择" "0")"
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
    ui_page "网络 / 连通性诊断" "按需检查出站、目标、协议与链路"
    ui_section "快速检查" "primary"
    ui_item 1 "本机出站连通性" "DNS、IPv4/IPv6 路由与 HTTPS"
    ui_item 2 "目标快速诊断" "解析、路由、延迟与丢包"
    ui_section "协议与链路" "accent"
    ui_item 3 "DNS 解析诊断" "系统解析器与 A/AAAA/CNAME"
    ui_item 4 "TCP 端点探测" "目标端口的解析、路由和握手"
    ui_item 5 "HTTP / HTTPS 诊断" "状态、重定向、TLS 与阶段耗时"
    ui_item 6 "链路路径" "mtr / traceroute 跳点"
    ui_item 7 "套接字压力" "TCP 状态、半连接和内核计数"
    ui_item 0 "返回网络管理"
    choice="$(read_input "请选择" "0")"
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
    ui_page "网络管理" "常用网络设置、连接状态与按需诊断"
    ui_context "不会隐式开放端口；检查只运行一次，不创建后台任务。"
    ui_section "常用配置" "primary"
    ui_item 1 "网络概览" "地址、默认路由、DNS 与拥塞控制"
    ui_item 2 "系统 DNS" "后端识别、服务器切换、验证与恢复"
    ui_item 3 "SOCKS 出站代理" "连接已有代理；不开放本机监听"
    ui_item 4 "WARP 连接" "官方客户端与已有 wgcf 隧道"
    ui_item 5 "网络调优" "BBR、内核参数、IP 优先级与第三方适配"
    ui_section "状态与诊断" "accent"
    ui_item 6 "连接与端口" "接口、路由、连接会话与监听"
    ui_item 7 "连通性诊断" "出站、DNS、TCP、HTTP 与链路"
    ui_item 0 "返回主菜单"
    choice="$(read_input "请选择" "0")"
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
