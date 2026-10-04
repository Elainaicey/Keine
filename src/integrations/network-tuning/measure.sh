#!/usr/bin/env bash

tuning_measure_requirements() {
  local tool
  for tool in ip tc iperf3 jq timeout; do
    command_exists "$tool" || { warn "缺少 $tool；请先从软件中心安装。"; return 1; }
  done
  timeout --help 2>&1 | grep -q -- --foreground || { warn "需要支持 --foreground 的 GNU timeout。"; return 1; }
}

tuning_measure_resolve() {
  local target="$1" address
  valid_network_target "$target" || return 1
  if valid_ipv4_address "$target" || valid_ipv6_address "$target"; then printf '%s\n' "$target"; return 0; fi
  command_exists getent || return 1
  address="$(timeout --foreground --kill-after=2 5 getent ahosts "$target" | awk '$2=="STREAM" && !seen++{print $1}')" || return 1
  valid_ipv4_address "$address" || valid_ipv6_address "$address" || return 1
  printf '%s\n' "$address"
}

tuning_measure_route() {
  local iface="$1" address="$2" route device
  valid_ipv4_address "$address" || valid_ipv6_address "$address" || return 1
  route="$(ip route get "$address")" || return 1
  device="$(awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}' <<<"$route")"
  [[ "$device" == "$iface" ]] || { warn "测速出口为 ${device:-未知}，与 $iface 不一致。"; return 1; }
}

# Output: sender Mbps | receiver Mbps | retransmits | actual seconds.
# Reject partial/error JSON instead of treating failed measurements as zero loss.
tuning_measure_parse() {
  jq -er '
    if .error then error("iperf error") else .end end |
    .sum_sent as $s | .sum_received as $r |
    if ([$s.bits_per_second,$r.bits_per_second,$s.retransmits,$s.seconds] |
        all(. != null and type == "number")) and
       $s.bits_per_second > 0 and $r.bits_per_second > 0 and
       $s.retransmits >= 0 and ($s.retransmits | floor) == $s.retransmits and
       $s.seconds > 0 then
      [$s.bits_per_second/1000000,$r.bits_per_second/1000000,$s.retransmits,$s.seconds] |
      map(tostring) | join("|")
    else error("incomplete sample") end'
}

tuning_measure_sample() {
  local iface="$1" address="$2" port="$3" seconds="$4" streams="$5" result
  tuning_strategy_integer "$port" 65535 &&
    tuning_strategy_integer "$seconds" 30 && (( seconds >= 3 )) &&
    tuning_strategy_integer "$streams" 8 || return 1
  tuning_device_exists "$iface" && tuning_measure_route "$iface" "$address" || return 1
  (( DRY_RUN == 0 )) || { warn "预览模式不发起测速。"; return 1; }
  # Bound both connection setup and measurement; keep Ctrl-C in the foreground.
  result="$(timeout --foreground --signal=TERM --kill-after=3 "$((seconds+10))" \
    iperf3 -c "$address" -p "$port" --bind-dev "$iface" -t "$seconds" -P "$streams" -J)" || {
    warn "iperf3 失败或超时；检查对端服务、端口与 --bind-dev 支持。"; return 1;
  }
  tuning_measure_parse <<<"$result" || { warn "未取得完整的发送、接收和重传样本。"; return 1; }
}

tuning_measure_show() {
  local label="$1" sample="$2" sent received retrans seconds ratio
  IFS='|' read -r sent received retrans seconds <<<"$sample"
  ratio="$(tuning_tcpfit_calc loss_pct "$retrans" "$sent" "$seconds")"
  ui_kv "$label" "$(awk -v r="$received" 'BEGIN{printf "%.2f Mbps",r}') · $retrans 次重传 · $ratio%"
}

tuning_measure_probe() {
  local iface="$1" address="$2" port="$3" seconds="$4" sample sent received retrans elapsed rounded
  tuning_measure_route "$iface" "$address" || return 1
  tuning_queue_write "$iface" fq || return 1
  sample="$(tuning_measure_sample "$iface" "$address" "$port" "$seconds" 4)" || return 1
  tuning_measure_show "四流探测" "$sample"
  IFS='|' read -r sent received retrans elapsed <<<"$sample"
  rounded="$(awk -v b="$received" 'BEGIN{s=(b<50?1:(b<200?10:50)); v=int(b/s+0.5)*s; print (v<1?1:v)}')"
  ui_kv "参考带宽" "$rounded Mbps"
  ui_note "这是到指定对端的接收速率，不代表所有运营商；不会自动改写参数方案。"
}

tuning_measure_verify() {
  local iface="$1" address="$2" port="$3" seconds="$4" streams sample
  for streams in 1 4; do
    sample="$(tuning_measure_sample "$iface" "$address" "$port" "$seconds" "$streams")" || return 1
    tuning_measure_show "$streams 流验证" "$sample"
  done
}

# TCPFit's retransmission knee rule: absolute 0.1%, 5x clean baseline, capped at 1%.
tuning_measure_spike() {
  awk -v value="$1" -v base="$2" 'BEGIN{n=0.1; if(base*5>n)n=base*5; if(n>1)n=1; exit !(value>n)}'
}

tuning_measure_scan_range() {
  local iface="$1" address="$2" port="$3" seconds="$4" low="$5" high="$6" step="$7"
  local rate="$low" sample sent received retrans elapsed ratio hits attempt clean='' slow=0
  while true; do
    tuning_measure_route "$iface" "$address" || return 1
    tuning_queue_write "$iface" htb "$rate" || return 1
    sample="$(tuning_measure_sample "$iface" "$address" "$port" "$seconds" 1)" || return 1
    IFS='|' read -r sent received retrans elapsed <<<"$sample"
    ratio="$(tuning_tcpfit_calc loss_pct "$retrans" "$sent" "$elapsed")"
    tuning_measure_show "$rate Mbps" "$sample"
    if tuning_measure_spike "$ratio" "$scan_base"; then
      hits=1; clean=''
      for attempt in 2 3; do
        sample="$(tuning_measure_sample "$iface" "$address" "$port" "$seconds" 1)" || return 1
        IFS='|' read -r sent received retrans elapsed <<<"$sample"
        ratio="$(tuning_tcpfit_calc loss_pct "$retrans" "$sent" "$elapsed")"
        tuning_measure_show "$rate / 复测 $attempt" "$sample"
        if tuning_measure_spike "$ratio" "$scan_base"; then hits=$((hits+1)); else clean="$sample"; fi
      done
      if (( hits >= 2 )); then scan_break="$rate"; return 0; fi
      [[ -n "$clean" ]] || return 1
      IFS='|' read -r sent received retrans elapsed <<<"$clean"
      ratio="$(tuning_tcpfit_calc loss_pct "$retrans" "$sent" "$elapsed")"
    fi
    if awk -v r="$received" -v n="$rate" 'BEGIN{exit !(r<n*0.7)}'; then
      slow=$((slow+1))
      if (( slow >= 3 )); then warn "对端或路径吞吐不足，不能据此判断限速拐点。"; return 1; fi
      # Unlike a verified tier, a slow tier cannot become a recommendation.
    else
      slow=0; scan_last="$rate"
      if [[ "$scan_base" == 0 ]]; then scan_base="$ratio"; fi
    fi
    (( rate < high )) || break
    rate=$((rate+step)); (( rate <= high )) || rate="$high"
  done
}

tuning_measure_sweep() {
  local iface="$1" address="$2" port="$3" seconds="$4" low="$5" high="$6" step="$7"
  local scan_base=0 scan_last=0 scan_break=0 coarse_break fine margin recommendation
  tuning_strategy_integer "$low" 100000 && tuning_strategy_integer "$high" 100000 &&
    tuning_strategy_integer "$step" 100000 && (( high > low && (high-low+step-1)/step <= 12 )) || return 1
  tuning_measure_scan_range "$iface" "$address" "$port" "$seconds" "$low" "$high" "$step" || return 1
  if (( scan_last == 0 || scan_break == 0 )); then
    ui_note "未得到可靠的干净档与重传拐点；不生成限速建议，原配置保持。"; return 0
  fi
  coarse_break="$scan_break"
  fine=$((step/4)); (( fine > 0 )) || fine=1
  (( fine >= (scan_break-scan_last+7)/8 )) || fine=$(((scan_break-scan_last+7)/8))
  if (( scan_break-scan_last > 1 )); then
    scan_break=0
    tuning_measure_scan_range "$iface" "$address" "$port" "$seconds" "$scan_last" "$coarse_break" "$fine" || return 1
    # Inconsistent coarse/fine results are not evidence for applying a shaper.
    if (( scan_break == 0 )); then ui_note "复扫未复现拐点；不生成限速建议。"; return 0; fi
  fi
  margin="$(tuning_tcpfit_calc calc_margin "$scan_last")"
  recommendation=$((scan_last-margin)); (( recommendation > 0 )) || recommendation="$scan_last"
  ui_kv "疑似拐点" "$scan_break Mbps"
  ui_kv "候选整形值" "$recommendation Mbps"
  ui_note "仅供本条路径参考；需换对端复核。不会自动应用，可到「队列与初始窗口」手动设置。"
}

tuning_measure_peers() {
  local input="$1" peer address output rtt best='' best_rtt=''
  local -a peers=()
  IFS=',' read -r -a peers <<<"$input"
  (( ${#peers[@]} > 0 && ${#peers[@]} <= 8 )) || return 1
  command_exists ping && command_exists timeout || return 1
  for peer in "${peers[@]}"; do
    address="$(tuning_measure_resolve "$peer")" || { warn "无法解析：$(terminal_safe_text "$peer")"; continue; }
    output="$(timeout --foreground --kill-after=2 6 ping -n -c 2 -W 2 "$address" 2>/dev/null)" || continue
    rtt="$(awk -F' = ' '/min\/avg\/max/{split($2,a,"/"); print a[2]}' <<<"$output")"
    [[ "$rtt" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
    ui_kv "$address" "$rtt ms"
    if [[ -z "$best_rtt" ]] || awk -v a="$rtt" -v b="$best_rtt" 'BEGIN{exit !(a<b)}'; then best="$address"; best_rtt="$rtt"; fi
  done
  [[ -n "$best" ]] || { warn "未收到 ICMP 响应；不代表 TCP 不可用。"; return 1; }
  ui_kv "低延迟候选" "$best"
  ui_note "只比较你提供的节点；延迟低不保证 iperf3 可用或带宽更高。"
}
