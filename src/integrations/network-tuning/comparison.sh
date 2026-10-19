#!/usr/bin/env bash

# Manual measurements only: no scheduling, background process or tuning changes.
tuning_comparison_root() { printf '%s/network-comparison' "$(changes_root)"; }

tuning_comparison_snapshot() {
  local iface="$1" address="$2" family=-4 key value route
  valid_ipv6_address "$address" && family=-6
  for key in \
    net.core.default_qdisc net.core.netdev_budget net.core.netdev_max_backlog \
    net.core.optmem_max net.core.rmem_default net.core.rmem_max \
    net.core.somaxconn net.core.wmem_default net.core.wmem_max \
    net.ipv4.ip_local_port_range net.ipv4.tcp_adv_win_scale net.ipv4.tcp_congestion_control \
    net.ipv4.tcp_dsack net.ipv4.tcp_fastopen net.ipv4.tcp_fin_timeout \
    net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes net.ipv4.tcp_keepalive_time \
    net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_mem \
    net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_mtu_probing net.ipv4.tcp_no_metrics_save \
    net.ipv4.tcp_notsent_lowat net.ipv4.tcp_rmem net.ipv4.tcp_sack \
    net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_syncookies net.ipv4.tcp_timestamps \
    net.ipv4.tcp_tw_reuse net.ipv4.tcp_window_scaling net.ipv4.tcp_wmem \
    net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min; do
    value="$(sysctl -n "$key" 2>/dev/null)" || value=unsupported
    printf '%s=%s\n' "$key" "$value"
  done
  tc qdisc show dev "$iface" || return 1
  tc class show dev "$iface" || return 1
  route="$(ip "$family" route get "$address")" || return 1
  # Omit changing cache expiry/RTT estimates, keep the effective path and window settings.
  awk '{for(i=1;i<NF;i++) if($i ~ /^(via|dev|src|initcwnd|initrwnd|mtu|advmss)$/) print $i "=" $(i+1)}' <<<"$route"
}

tuning_comparison_valid() {
  local path="$1" iface address port seconds direction
  config_file_safe "$path" && [[ -f "$path" && $(stat -c %s -- "$path") -le 131072 ]] || return 1
  jq -e '
    .version == 1 and
    ([.iface,.address,.boot,.identity,.direction,.snapshot,.time,.iperf] | all(type == "string")) and
    (.port|type=="number") and (.seconds|type=="number") and
    (.samples|type=="array" and length==6) and
    ([.samples[] | (.streams==1 or .streams==4) and
      ([.sent,.received,.retrans,.elapsed]|all(type=="number")) and
      .sent>0 and .received>0 and .retrans>=0 and (.retrans|floor)==.retrans and .elapsed>0] | all) and
    ([.samples[]|select(.streams==1)]|length==3) and
    ([.samples[]|select(.streams==4)]|length==3)' "$path" >/dev/null || return 1
  iface="$(jq -r .iface "$path")"; address="$(jq -r .address "$path")"
  port="$(jq -r .port "$path")"; seconds="$(jq -r .seconds "$path")"; direction="$(jq -r .direction "$path")"
  valid_network_interface "$iface" && { valid_ipv4_address "$address" || valid_ipv6_address "$address"; } &&
    tuning_strategy_integer "$port" 65535 && tuning_strategy_integer "$seconds" 30 && (( seconds >= 3 )) &&
    [[ "$direction" == forward || "$direction" == reverse ]]
}

tuning_comparison_capture() (
  local mode="$1" iface="${2:-}" address="${3:-}" port="${4:-}" seconds="${5:-}" direction="${6:-}"
  local root base output temporary='' snapshot identity boot iperf sample streams round sent received retrans elapsed base_hash=''
  [[ "$mode" == baseline || "$mode" == repeat ]] || return 1
  require_root
  (( DRY_RUN == 0 )) || { info "预览不发起测试或保存结果。"; return 0; }
  tuning_measure_requirements && tuning_strategy_lock || return 1
  root="$(tuning_comparison_root)"; base="$root/baseline.json"
  config_file_safe "$root/baseline.json" && config_file_safe "$root/latest.json" || return 1
  mkdir -p -- "$root" && chmod 700 "$root" || return 1
  iperf="$(iperf3 --version | head -n 1)" || return 1
  if [[ "$mode" == repeat ]]; then
    tuning_comparison_valid "$base" || { warn "没有完整基准，请先采集。"; return 1; }
    iface="$(jq -r .iface "$base")"; address="$(jq -r .address "$base")"
    port="$(jq -r .port "$base")"; seconds="$(jq -r .seconds "$base")"; direction="$(jq -r .direction "$base")"
    [[ "$(jq -r .boot "$base")" == "$(tuning_boot_id)" &&
       "$(jq -r .identity "$base")" == "$(tuning_device_identity "$iface")" &&
       "$(jq -r .iperf "$base")" == "$iperf" ]] || { warn "系统已重启、网卡或 iperf3 版本变化，请重新采集基准。"; return 1; }
    base_hash="$(changes_fingerprint "$base")"
    output="$root/latest.json"
  else output="$base"; fi
  tuning_device_exists "$iface" && tuning_measure_route "$iface" "$address" &&
    tuning_strategy_integer "$port" 65535 && tuning_strategy_integer "$seconds" 30 && (( seconds >= 3 )) &&
    [[ "$direction" == forward || "$direction" == reverse ]] || return 1
  ui_kv "条件" "$iface · $address · $port · $direction · 每轮 $seconds 秒"
  ui_note "单流、四流各 3 轮，最多约 $((6*(seconds+13))) 秒。会产生真实满速流量；仅使用获准的 iperf3 对端。"
  confirm "$([[ "$mode" == baseline ]] && printf '采集并替换基准' || printf '按相同条件复测')？" || return 0
  snapshot="$(tuning_comparison_snapshot "$iface" "$address")" || return 1
  identity="$(tuning_device_identity "$iface")"; boot="$(tuning_boot_id)"
  umask 077
  temporary="$(mktemp "$root/.sample.XXXXXX")" || return 1
  trap 'rm -f -- "$temporary" "$temporary.json"' EXIT
  trap 'exit 130' INT; trap 'exit 143' TERM HUP
  for streams in 1 4; do
    for round in 1 2 3; do
      ui_kv "采样" "$streams 流 · $round/3"
      sample="$(tuning_measure_sample "$iface" "$address" "$port" "$seconds" "$streams" "$direction")" || return 1
      IFS='|' read -r sent received retrans elapsed <<<"$sample"
      jq -cn --argjson streams "$streams" --argjson sent "$sent" --argjson received "$received" \
        --argjson retrans "$retrans" --argjson elapsed "$elapsed" \
        '{streams:$streams,sent:$sent,received:$received,retrans:$retrans,elapsed:$elapsed}' >>"$temporary" || return 1
    done
  done
  [[ "$snapshot" == "$(tuning_comparison_snapshot "$iface" "$address")" && "$boot" == "$(tuning_boot_id)" &&
     "$identity" == "$(tuning_device_identity "$iface")" ]] || { warn "测量期间配置或网卡发生变化，丢弃混合样本。"; return 1; }
  [[ -z "$base_hash" || "$base_hash" == "$(changes_fingerprint "$base")" ]] || return 1
  jq -s --arg iface "$iface" --arg address "$address" --argjson port "$port" --argjson seconds "$seconds" \
    --arg direction "$direction" --arg boot "$boot" --arg identity "$identity" --arg snapshot "$snapshot" \
    --arg time "$(date -Is)" --arg iperf "$iperf" --arg baseline "$base_hash" \
    '{version:1,iface:$iface,address:$address,port:$port,seconds:$seconds,direction:$direction,boot:$boot,
      identity:$identity,snapshot:$snapshot,time:$time,iperf:$iperf,baseline:$baseline,samples:.}' "$temporary" >"$temporary.json" || return 1
  tuning_comparison_valid "$temporary.json" && mv -fT -- "$temporary.json" "$output" || return 1
  ui_success "完整结果已保存。"
  [[ "$mode" != repeat ]] || tuning_comparison_show
)

tuning_comparison_show() {
  local base latest line
  base="$(tuning_comparison_root)/baseline.json"; latest="$(tuning_comparison_root)/latest.json"
  if ! tuning_comparison_valid "$base" || ! tuning_comparison_valid "$latest"; then warn "尚无完整基准和复测结果。"; return 1; fi
  [[ "$(jq -r .baseline "$latest")" == "$(changes_fingerprint "$base")" ]] || { warn "基准已经更新，请重新复测。"; return 1; }
  ui_page '网络调优 / 前后对比'
  ui_kv '基准时间' "$(terminal_safe_text "$(jq -r .time "$base")")"
  ui_kv '复测时间' "$(terminal_safe_text "$(jq -r .time "$latest")")"
  while IFS= read -r line; do printf '  %s\n' "$line"; done < <(jq -nr --slurpfile b "$base" --slurpfile a "$latest" '
    def stats($n): [.samples[]|select(.streams==$n)] as $s |
      ($s|map(.received)|sort) as $v |
      {median:$v[1],spread:(($v[2]-$v[0])/$v[1]*100),retrans:($s|map(.retrans)|sort|.[1])};
    def round2: . * 100 | round / 100;
    (1,4) as $n | ($b[0]|stats($n)) as $old | ($a[0]|stats($n)) as $new |
    (($new.median/$old.median-1)*100) as $delta |
    "\($n) 流：\($old.median|round2) → \($new.median|round2) Mbps（\($delta|round2)%）",
    "  重传中位数：\($old.retrans) → \($new.retrans)；吞吐波动范围：\($old.spread|round2)% / \($new.spread|round2)%",
    (if ($old.spread>10 or $new.spread>10 or ($delta|fabs)<([$old.spread,$new.spread]|max)) then
      "  波动较大或变化未超过样本波动，建议复测。" else "  本轮差异较明显，仍需在其他时段复测。" end)')
  if [[ "$(jq -r .snapshot "$base")" == "$(jq -r .snapshot "$latest")" ]]; then
    ui_note '记录的本机调优参数相同；差异可能来自链路、对端或系统负载。'
  else ui_note '本机参数或路由已变化；可在保存的结果中核对前后快照。'; fi
  ui_note '这是固定对端的 TCP 观测，不代表所有线路或 UDP 性能；重传次数不是丢包率，不能单独证明调优有效。'
}

tuning_comparison_menu() {
  local choice iface target address port seconds direction
  while true; do
    ui_page '网络 / 调优前后对比'
    ui_note '先采集基准，手动调整后复测；不自动修改参数。结果仅保留一份基准和最近一次完整复测。'
    ui_action 1 '采集基准' action
    ui_action 2 '相同条件复测' action
    ui_action 3 '查看对比' action
    ui_menu_footer '返回'; ui_read_choice choice
    case "$choice" in
      0) return 0 ;;
      1)
        tuning_measure_requirements || { pause; continue; }
        iface="$(tuning_select_interface)" || continue
        target="$(read_input 'iperf3 对端 IP / 域名（0 返回）')"; [[ "$target" != 0 ]] || continue
        address="$(tuning_measure_resolve "$target")" || { warn '无法解析目标'; pause; continue; }
        port="$(read_input '对端端口' 5201)"; seconds="$(read_input '每轮时长（3–30 秒）' 10)"
        direction="$(read_input '方向：forward 本机发送 / reverse 本机接收' forward)"
        tuning_comparison_capture baseline "$iface" "$address" "$port" "$seconds" "$direction" || warn '采样未完成，原结果保留。' ;;
      2) tuning_comparison_capture repeat || warn '复测未完成，原结果保留。' ;;
      3) tuning_comparison_show || true ;;
      *) warn '未知选项'; continue ;;
    esac
    pause
  done
}
