#!/usr/bin/env bash

network_show() {
  ui_page "网络概览" "接口地址、默认路由、DNS 与拥塞控制"
  ip -brief address 2>/dev/null || true
  ui_section "默认路由"; ip route show default 2>/dev/null || true; ip -6 route show default 2>/dev/null || true
  ui_section "DNS"; sed -n '1,12p' /etc/resolv.conf 2>/dev/null || true
  ui_section "拥塞控制"; sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_available_congestion_control 2>/dev/null || true
}

network_connectivity_test() {
  ui_page "连通性检查" "DNS、IPv4/IPv6 路由和 HTTPS 可用性"
  if getent hosts github.com >/dev/null 2>&1; then ui_check pass "DNS 解析 github.com"; else ui_check fail "DNS 解析失败"; fi
  if ip -4 route get 1.1.1.1 >/dev/null 2>&1; then ui_check pass "IPv4 默认路由"; else ui_check warn "没有 IPv4 默认路由"; fi
  if ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1; then ui_check pass "IPv6 默认路由"; else ui_check warn "没有 IPv6 默认路由"; fi
  if command_exists curl; then
    if curl --disable -4fsI --connect-timeout 3 --max-time 8 https://github.com >/dev/null 2>&1; then ui_check pass "IPv4 HTTPS"; else ui_check warn "IPv4 HTTPS 不可用"; fi
    if curl --disable -6fsI --connect-timeout 3 --max-time 8 https://github.com >/dev/null 2>&1; then ui_check pass "IPv6 HTTPS"; else ui_check warn "IPv6 HTTPS 不可用"; fi
  else
    ui_check warn "未安装 curl，跳过 HTTPS 检查"
  fi
}

network_list_ports() {
  ui_page "监听端口" "本机 TCP/UDP 监听地址及关联进程"
  if command_exists ss; then
    printf '%-8s %-24s %s\n' "协议" "本地地址" "进程"
    ss -H -lntup 2>/dev/null | awk '{printf "%-8s %-24s %s\n", $1, $5, substr($0,index($0,$7))}'
  else
    warn "缺少 ss 命令。"
  fi
}

network_port_detail() {
  local port
  ui_hint "输入 1-65535 的单个端口，例如 22、80 或 443。"
  port="$(read_input "端口" "80")"; valid_port "$port" || { warn "端口无效。"; return 1; }
  ui_page "端口 $port" "定位监听套接字和占用进程"
  ss -H -lntup "sport = :$port" 2>/dev/null || true
  if command_exists lsof; then
    lsof -nP -i ":$port" 2>/dev/null || true
  fi
}

network_routes() {
  ui_page "路由表" "IPv4、IPv6 和策略路由规则"
  ui_section "IPv4"
  ip -4 route show table all 2>/dev/null || true
  ui_section "IPv6"
  ip -6 route show table all 2>/dev/null || true
  ui_section "策略规则"
  ip rule show 2>/dev/null || true
}

network_connections() {
  ui_page "连接会话" "TCP/UDP 汇总与当前已建立的远端连接"
  command_exists ss || { warn "缺少 ss 命令。"; return 1; }
  ui_section "套接字汇总"
  ss -s 2>/dev/null || true
  ui_section "远端端点排行"
  printf '  %-8s %-32s %s\n' "数量" "远端地址" "状态"
  ss -H -tan 2>/dev/null |
    awk '$1=="ESTAB" {count[$5]++} END{for(endpoint in count) printf "%8d %-32s established\n",count[endpoint],endpoint}' |
    sort -nr | sed -n '1,20p'
  ui_section "连接状态分布"
  ss -H -tan 2>/dev/null | awk '{count[$1]++}END{for(state in count) printf "  %-16s %d\n",state,count[state]}' | sort
}

network_target_diagnose() {
  local target address
  ui_hint "输入域名、IPv4 或 IPv6 地址，例如 example.com 或 1.1.1.1。"
  target="$(read_input "域名或 IP" "github.com")"
  valid_network_target "$target" || { warn "目标格式无效。"; return 1; }
  ui_page "目标诊断" "$target · DNS、路由选择、延迟与丢包"
  ui_section "解析结果"
  getent ahosts "$target" 2>/dev/null | awk '!seen[$1]++ {print "  "$0}' | sed -n '1,12p' || true
  address="$(getent ahostsv4 "$target" 2>/dev/null | awk 'NR==1{print $1}')"
  if [[ -z "$address" ]]; then
    address="$(getent ahostsv6 "$target" 2>/dev/null | awk 'NR==1{print $1}')"
  fi
  [[ -n "$address" ]] || { warn "无法解析目标。"; return 1; }
  ui_section "路由选择"
  ip route get "$address" 2>/dev/null || ip -6 route get "$address" 2>/dev/null || true
  ui_section "延迟与丢包"
  if command_exists ping; then
    ping -c 3 -W 2 "$address" 2>/dev/null || warn "Ping 不可达；目标也可能主动禁用 ICMP。"
  else
    ui_empty "未安装 ping"
  fi
}

network_dns_diagnose() {
  local target="${1:-}" resolved
  if [[ -z "$target" ]]; then
    ui_hint "输入域名或地址；命令行也可使用 keine dns example.com。"
    target="$(read_input "待解析域名" "github.com")"
  fi
  valid_network_target "$target" || { warn "目标格式无效。"; return 1; }
  ui_page "DNS 诊断" "$target · 解析器配置、系统查询与 DNS 记录"
  ui_section "解析器配置" "primary"
  if command_exists resolvectl; then
    resolvectl status 2>/dev/null | sed -n '1,45p' || true
  else
    sed -n '1,20p' /etc/resolv.conf 2>/dev/null || ui_empty "无法读取 /etc/resolv.conf"
  fi
  ui_section "系统解析结果" "accent"
  resolved="$(getent ahosts "$target" 2>/dev/null | awk '!seen[$1]++ {print "  "$0}' | sed -n '1,16p' || true)"
  if [[ -n "$resolved" ]]; then
    printf '%s\n' "$resolved"
    ui_check pass "系统解析器可以解析 $target"
  else
    ui_check fail "系统解析器无法解析 $target"
  fi
  ui_section "DNS 记录" "primary"
  if command_exists dig; then
    printf '  A     %s\n' "$(dig +short +time=3 +tries=1 A "$target" 2>/dev/null | paste -sd, - || true)"
    printf '  AAAA  %s\n' "$(dig +short +time=3 +tries=1 AAAA "$target" 2>/dev/null | paste -sd, - || true)"
    printf '  CNAME %s\n' "$(dig +short +time=3 +tries=1 CNAME "$target" 2>/dev/null | paste -sd, - || true)"
  else
    ui_empty "未安装 dnsutils，无法显示原始 A、AAAA 与 CNAME 记录"
  fi
  ui_note "系统解析器结果受 /etc/nsswitch.conf、缓存和本机 hosts 配置影响。"
  [[ -n "$resolved" ]]
}
