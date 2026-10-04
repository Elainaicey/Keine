#!/usr/bin/env bash

tuning_select_interface() {
  local iface fallback
  fallback="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}')"
  iface="$(read_input '网卡（0 返回）' "$fallback")"
  [[ "$iface" != 0 ]] || return 1
  tuning_device_exists "$iface" || { warn "网卡不存在或不支持。"; return 1; }
  printf '%s' "$iface"
}

tuning_runtime_list() {
  local entry
  while IFS= read -r entry; do
    tuning_runtime_valid_entry "$entry" || { warn "存在损坏的运行配置记录。"; continue; }
    ui_kv "$(<"$entry/iface") / $(<"$entry/kind")" "$(<"$entry/plan") · $(tuning_runtime_status "$entry")"
  done < <(tuning_runtime_entries)
}

tuning_runtime_restore_menu() {
  local entry choice index entries=() state
  while IFS= read -r entry; do
    tuning_runtime_valid_entry "$entry" && entries+=("$entry")
  done < <(tuning_runtime_entries)
  (( ${#entries[@]} > 0 )) || { ui_empty "没有托管运行配置"; return 0; }
  for index in "${!entries[@]}"; do
    entry="${entries[$index]}"; state="$(tuning_runtime_status "$entry")"
    case "$state" in ready) state=可撤销 ;; expired) state=上次启动记录 ;; *) state=外部修改或冲突 ;; esac
    ui_item "$((index+1))" "$(<"$entry/iface") / $(<"$entry/kind")" "$state"
  done
  ui_menu_footer "返回"; ui_read_choice choice
  [[ "$choice" != 0 ]] || return 0
  tuning_strategy_integer "$choice" "${#entries[@]}" || return 1
  entry="${entries[$((choice-1))]}"
  confirm "恢复首次基线？重启前的过期记录只清理、不修改当前配置。" || return 0
  tuning_runtime_restore "$entry"
}

tuning_runtime_menu() {
  local choice iface rate family window
  while true; do
    ui_page "调优 / 队列与初始窗口"
    tuning_runtime_list
    ui_hint "本次启动有效；影响整张网卡。操作前请保留服务商控制台。"
    ui_action 1 "应用 FQ 队列" "action" "保留多队列结构"
    ui_action 2 "设置 HTB 总出口限速" "action"
    ui_action 3 "设置 TCP 初始窗口" "action"
    ui_action R "撤销运行配置" "warning"
    ui_menu_footer "返回"; ui_read_choice choice
    case "$choice" in
      0) return 0 ;;
      R|r) tuning_runtime_restore_menu || true; pause; continue ;;
      1|2|3) ;;
      *) warn "未知选项"; continue ;;
    esac
    if ! command_exists ip || ! command_exists tc; then warn "需要 iproute2。"; pause; continue; fi
    iface="$(tuning_select_interface)" || continue
    case "$choice" in
      1)
        confirm "将 $iface 当前队列切换为 FQ？已有总出口限速将解除。" &&
          tuning_runtime_apply qdisc "$iface" fq || true ;;
      2)
        rate="$(read_input '总出口限速（Mbps）' 100)"
        tuning_strategy_integer "$rate" 100000 || { warn "请输入 1–100000。"; pause; continue; }
        ui_note "限制该网卡所有出口流量，包括 SSH、UDP 与代理连接；不是单个应用限速。"
        confirm "对 $iface 应用 $rate Mbps HTB + FQ？" &&
          tuning_runtime_apply qdisc "$iface" htb "$rate" || true ;;
      3)
        family="$(read_input '地址族（4 / 6）' 4)"
        [[ "$family" == 4 || "$family" == 6 ]] || { warn "请选择 4 或 6。"; pause; continue; }
        window="$(read_input '初始窗口（1–64 个报文段）' 32)"
        tuning_strategy_integer "$window" 64 || { warn "请输入 1–64。"; pause; continue; }
        ui_note "仅调整默认路由 initcwnd / initrwnd，不改网关；作用于新建 TCP 连接，增大可能加剧突发。"
        confirm "调整 $iface IPv$family 初始窗口为 $window？" &&
          tuning_runtime_apply "route$family" "$iface" window "$window" || true ;;
    esac
    pause
  done
}

tuning_measure_menu() {
  local choice iface target address port seconds low high step estimate slots
  while true; do
    ui_page "调优 / 按需测量"
    ui_action 1 "带宽探测" "action" "临时 FQ · 四流"
    ui_action 2 "限速拐点扫描" "action" "指定范围 · 粗扫 / 复扫"
    ui_action 3 "当前效果验证" "action" "单流 / 四流 · 不改配置"
    ui_action 4 "对端延迟比较" "action"
    ui_menu_footer "返回"; ui_read_choice choice
    case "$choice" in
      0) return 0 ;;
      4)
        (( DRY_RUN == 0 )) || { info "预览模式不发起探测。"; pause; continue; }
        target="$(read_input '候选主机（逗号分隔，最多 8 个）')"
        tuning_measure_peers "$target" || true; pause; continue ;;
      1|2|3) ;;
      *) warn "未知选项"; continue ;;
    esac
    tuning_measure_requirements || { pause; continue; }
    iface="$(tuning_select_interface)" || continue
    target="$(read_input 'iperf3 服务端地址（0 返回）')"
    [[ "$target" != 0 ]] || continue
    address="$(tuning_measure_resolve "$target")" || { warn "地址无法解析。"; pause; continue; }
    tuning_measure_route "$iface" "$address" || { pause; continue; }
    port="$(read_input '服务端端口' 5201)"
    seconds="$(read_input '每轮秒数（3–30）' 10)"
    if ! tuning_strategy_integer "$port" 65535 || ! tuning_strategy_integer "$seconds" 30 || (( seconds < 3 )); then
      warn "端口或时长无效。"; pause; continue
    fi
    slots=1
    if [[ "$choice" == 2 ]]; then
      low="$(read_input '扫描下限（Mbps）' 50)"; high="$(read_input '扫描上限（Mbps）' 150)"
      step="$(read_input '步长（Mbps）' 10)"
      if ! tuning_strategy_integer "$low" 100000 || ! tuning_strategy_integer "$high" 100000 ||
        ! tuning_strategy_integer "$step" 100000 || (( high <= low || (high-low+step-1)/step > 12 )); then
        warn "范围无效或超过 13 个粗扫档位，请增大步长。"; pause; continue
      fi
      slots=$(( ((high-low+step-1)/step+1+9)*3 ))
      estimate="$(awk -v b="$high" -v t="$seconds" -v n="$slots" 'BEGIN{printf "%.2f",b*t*n/8000*1.1}')"
      ui_kv "扫描预算" "最多 $slots 轮 · 测试数据约 ≤ $estimate GB（另有协议开销）"
    elif [[ "$choice" == 3 ]]; then slots=2
    fi
    ui_kv "测速对端" "$address:$port"
    ui_kv "时间上限" "约 $((slots*(seconds+13))) 秒"
    ui_note "会产生真实出站流量；探测/验证不限制速率，流量取决于可用带宽。重传比是估算，不是实测丢包率。"
    [[ "$choice" == 3 ]] || ui_hint "临时修改整张网卡队列，结束或中断后尝试恢复；请保留控制台。"
    confirm "开始测量？请确认对端允许 iperf3 测试。" || continue
    case "$choice" in
      1) tuning_runtime_session "$iface" probe "$address" "$port" "$seconds" || true ;;
      2) tuning_runtime_session "$iface" sweep "$address" "$port" "$seconds" "$low" "$high" "$step" || true ;;
      3) tuning_measure_verify "$iface" "$address" "$port" "$seconds" || true ;;
    esac
    pause
  done
}
