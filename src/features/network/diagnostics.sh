#!/usr/bin/env bash

network_interface_counter() {
  local interface="$1" counter="$2" path
  valid_network_interface "$interface" || return 1
  case "$counter" in
    rx_bytes|tx_bytes|rx_errors|tx_errors|rx_dropped|tx_dropped) ;;
    *) return 1 ;;
  esac
  path="/sys/class/net/$interface/statistics/$counter"
  [[ -r "$path" ]] || return 1
  tr -d '[:space:]' <"$path"
}

network_interface_detail() {
  local interface="${1:-}" state mtu mac rx_bytes tx_bytes rx_errors tx_errors rx_dropped tx_dropped
  if [[ -z "$interface" ]]; then
    ui_page "网络接口" "选择接口查看地址、路由、链路和错误计数"
    ip -brief link 2>/dev/null || true
    interface="$(read_input "接口名称" "")"
  fi
  valid_network_interface "$interface" || { warn "网络接口名称格式无效。"; return 1; }
  [[ -e "/sys/class/net/$interface" ]] || { warn "网络接口不存在：$interface"; return 1; }
  state="$(cat "/sys/class/net/$interface/operstate" 2>/dev/null || printf 'unknown')"
  mtu="$(cat "/sys/class/net/$interface/mtu" 2>/dev/null || printf '未知')"
  mac="$(cat "/sys/class/net/$interface/address" 2>/dev/null || printf '未知')"
  rx_bytes="$(network_interface_counter "$interface" rx_bytes 2>/dev/null || printf '0')"
  tx_bytes="$(network_interface_counter "$interface" tx_bytes 2>/dev/null || printf '0')"
  rx_errors="$(network_interface_counter "$interface" rx_errors 2>/dev/null || printf '0')"
  tx_errors="$(network_interface_counter "$interface" tx_errors 2>/dev/null || printf '0')"
  rx_dropped="$(network_interface_counter "$interface" rx_dropped 2>/dev/null || printf '0')"
  tx_dropped="$(network_interface_counter "$interface" tx_dropped 2>/dev/null || printf '0')"
  ui_page "网络接口 / $interface" "链路、地址、路由、流量和错误计数"
  ui_panel_begin "接口状态"
  if [[ "$state" == "up" ]]; then
    ui_panel_kv "链路" "● $state" "$GREEN"
  else
    ui_panel_kv "链路" "● $state" "$YELLOW"
  fi
  ui_panel_kv "MTU" "$mtu"
  ui_panel_kv "MAC" "$mac"
  ui_panel_kv "接收" "$(backup_human_bytes "$rx_bytes")"
  ui_panel_kv "发送" "$(backup_human_bytes "$tx_bytes")"
  ui_panel_end
  ui_stats "接收错误" "$rx_errors" "发送错误" "$tx_errors" "丢弃" "$((rx_dropped + tx_dropped))"
  ui_section "地址" "primary"
  ip address show dev "$interface" 2>/dev/null || true
  ui_section "关联路由" "accent"
  ip route show dev "$interface" 2>/dev/null || ui_empty "没有 IPv4 路由"
  ip -6 route show dev "$interface" 2>/dev/null || true
  if command_exists ethtool && [[ "$interface" != "lo" ]]; then
    ui_section "链路能力" "primary"
    ethtool "$interface" 2>/dev/null | sed -n '1,35p' || ui_empty "无法读取 ethtool 信息"
  fi
  if command_exists resolvectl; then
    ui_section "接口 DNS" "accent"
    resolvectl status "$interface" 2>/dev/null | sed -n '1,24p' || ui_empty "没有接口级 DNS 信息"
  fi
  if (( rx_errors + tx_errors + rx_dropped + tx_dropped > 0 )); then
    ui_note "错误和丢弃是本次启动累计值；持续增长通常比单个历史数值更值得关注。"
  fi
}

network_tcp_state_rows() {
  awk '
    NF {
      state=toupper($1)
      if (state ~ /^[A-Z0-9-]+$/) count[state]++
    }
    END {
      for (state in count) print state "|" count[state]
    }
  ' | sort
}

network_socket_pressure() {
  local rows state count time_wait=0 syn_recv=0 established=0 total=0
  command_exists ss || { warn "缺少 ss 命令。"; return 1; }
  rows="$(ss -H -tan 2>/dev/null | network_tcp_state_rows)"
  while IFS='|' read -r state count; do
    [[ "$count" =~ ^[0-9]+$ ]] || continue
    total=$((total + count))
    case "$state" in
      ESTAB) established="$count" ;;
      TIME-WAIT|TIME_WAIT) time_wait="$count" ;;
      SYN-RECV|SYN_RECV) syn_recv="$count" ;;
    esac
  done <<<"$rows"
  ui_page "套接字压力" "TCP 状态、内核 Socket 计数与异常积压提示"
  ui_stats "TCP 总数" "$total" "已建立" "$established" "TIME-WAIT" "$time_wait"
  ui_section "TCP 状态分布" "primary"
  while IFS='|' read -r state count; do
    [[ -n "$state" ]] && ui_kv "$state" "$count"
  done <<<"$rows"
  ui_section "内核 Socket" "accent"
  sed -n '1,12p' /proc/net/sockstat 2>/dev/null || true
  sed -n '1,12p' /proc/net/sockstat6 2>/dev/null || true
  if (( syn_recv >= 100 )); then
    ui_check fail "SYN-RECV 达到 $syn_recv，可能存在连接积压或异常流量"
  elif (( syn_recv > 0 )); then
    ui_check warn "当前有 $syn_recv 个半连接，请结合业务峰值观察"
  else
    ui_check pass "未检测到 TCP 半连接积压"
  fi
  ui_note "单次快照不能替代持续监控；TIME-WAIT 较多也可能是短连接业务的正常表现。"
}

network_endpoint_probe() {
  local target="${1:-}" port="${2:-}" address route_result
  if [[ -z "$target" ]]; then
    ui_hint "检测从本机到目标 TCP 端口的 DNS、路由和握手，例如 example.com:443。"
    target="$(read_input "域名或 IP" "github.com")"
  fi
  if [[ -z "$port" ]]; then port="$(read_input "TCP 端口" "443")"; fi
  valid_network_target "$target" || { warn "目标格式无效。"; return 1; }
  valid_port "$port" || { warn "TCP 端口必须在 1-65535 之间。"; return 1; }
  ui_page "TCP 端点探测" "$target:$port · 解析、路由与三次握手"
  address="$(getent ahostsv4 "$target" 2>/dev/null | awk 'NR==1{print $1}')"
  [[ -n "$address" ]] || address="$(getent ahostsv6 "$target" 2>/dev/null | awk 'NR==1{print $1}')"
  if [[ -z "$address" ]]; then
    ui_check fail "目标无法解析"
    return 1
  fi
  ui_check pass "目标解析为 $address"
  route_result="$(ip route get "$address" 2>/dev/null || ip -6 route get "$address" 2>/dev/null || true)"
  if [[ -n "$route_result" ]]; then
    ui_check pass "系统存在到目标的路由"
    printf '  %s\n' "$(terminal_safe_text "$route_result")"
  else
    ui_check fail "没有找到到目标的路由"
    return 1
  fi
  if ! command_exists nc; then
    ui_check warn "未安装 Netcat，无法执行 TCP 握手"
    ui_note "可在软件中心安装 netcat 后重试；诊断不会自动安装软件。"
    return 1
  fi
  if nc -z -w 4 "$address" "$port" >/dev/null 2>&1; then
    ui_check pass "TCP $target ($address):$port 可以建立连接"
  else
    ui_check fail "TCP $target ($address):$port 无法建立连接"
    ui_note "可能原因包括服务未监听、目标防火墙拒绝、链路过滤或超时。"
    return 1
  fi
}

network_path_trace() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    ui_hint "输入域名或 IP；优先使用 mtr，其次使用 traceroute。"
    target="$(read_input "链路目标" "github.com")"
  fi
  valid_network_target "$target" || { warn "目标格式无效。"; return 1; }
  ui_page "链路路径" "$target · 跳点、延迟与丢包"
  if command_exists mtr; then
    mtr --report --report-cycles 5 --no-dns "$target" 2>/dev/null || { warn "mtr 诊断失败。"; return 1; }
  elif command_exists traceroute; then
    traceroute -n -m 20 -w 2 "$target" 2>/dev/null || { warn "traceroute 诊断失败。"; return 1; }
  else
    ui_empty "未安装 mtr 或 traceroute"
    ui_note "可在软件中心按 ID 安装 mtr 或 traceroute。"
    return 1
  fi
  ui_note "中间节点不响应 ICMP 并不等于业务链路中断，应结合最终目标是否可达判断。"
}
