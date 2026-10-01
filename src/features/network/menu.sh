#!/usr/bin/env bash

network_menu() {
  local choice
  while true; do
    ui_page "网络与端口" "接口、路由、连接、监听端口与目标诊断"
    ui_context "网络检查只运行一次；不持续抓包、采样流量或创建监控任务。"
    ui_section "本机网络" "primary"
    ui_item 1 "网络概览" "地址、默认路由、DNS 与拥塞控制"
    ui_item 2 "出站连通性" "DNS、IPv4/IPv6 路由与 HTTPS"
    ui_item 3 "连接会话" "套接字汇总、远端端点与状态分布"
    ui_item 4 "路由与策略规则" "IPv4、IPv6 与策略路由"
    ui_item 5 "网络接口详情" "地址、流量、错误、路由与链路能力"
    ui_section "端口" "accent"
    ui_item 6 "监听端口" "TCP/UDP 地址与关联进程"
    ui_item 7 "查询一个端口" "定位监听套接字与占用进程"
    ui_section "目标诊断" "primary"
    ui_item 8 "快速目标诊断" "解析、路由、延迟与丢包"
    ui_item 9 "DNS 诊断" "解析器、系统结果与 A/AAAA/CNAME"
    ui_item 10 "TCP 端点探测" "验证目标端口的解析、路由和握手"
    ui_item 11 "HTTP / HTTPS 诊断" "HEAD 状态、重定向、地址、TLS 与请求阶段耗时"
    ui_item 12 "链路路径" "使用 mtr 或 traceroute 查看跳点"
    ui_item 13 "套接字压力" "TCP 状态、半连接和内核 Socket 计数"
    ui_section "网络设置" "accent"
    ui_item 14 "系统 DNS 配置" "解析器识别、服务器切换、验证与恢复"
    ui_item 15 "SOCKS 出站代理" "已有代理、认证、DNS 位置与连接验证"
    ui_item 16 "可撤销网络参数" "BBR、Keepalive、MTU 探测、缓冲与来源"
    ui_item 17 "原生 WARP" "识别官方客户端及已有 wgcf 隧道"
    ui_item 18 "第三方调优适配" "预留入口、参数来源与冲突检查"
    ui_item 0 "返回"
    choice="$(read_input "请选择" "0")"
    case "$choice" in
      1) network_show ;;
      2) network_connectivity_test ;;
      3) network_connections || true ;;
      4) network_routes ;;
      5) network_interface_detail "" || true ;;
      6) network_list_ports ;;
      7) network_port_detail || true ;;
      8) network_target_diagnose || true ;;
      9) network_dns_diagnose "" || true ;;
      10) network_endpoint_probe "" "" || true ;;
      11) network_http_diagnose "" || true ;;
      12) network_path_trace "" || true ;;
      13) network_socket_pressure || true ;;
      14) network_dns_menu; continue ;;
      15) network_proxy_menu; continue ;;
      16) network_tuning_menu; continue ;;
      17) warp_menu; continue ;;
      18) network_tuning_adapter_menu; continue ;;
      0) return 0 ;;
      *) warn "未知选项"; continue ;;
    esac
    pause
  done
}
