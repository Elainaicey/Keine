#!/usr/bin/env bash
# Transaction markers are dynamically scoped by runtime.sh.
# shellcheck disable=SC2034

tuning_device_exists() {
  valid_network_interface "$1" && [[ "$1" != lo ]] &&
    ip link show dev "$1" >/dev/null 2>&1
}

tuning_device_identity() {
  local iface="$1"
  tuning_device_exists "$iface" || return 1
  printf '%s:%s\n' "$(cat "/sys/class/net/$iface/ifindex")" "$(cat "/sys/class/net/$iface/address")"
}

tuning_boot_id() { cat /proc/sys/kernel/random/boot_id; }

# Only replay known, reversible qdisc options. Never execute captured text.
tuning_queue_options() {
  local kind="$1" value="$2" key argument count
  local -a words=() result=()
  local IFS=' '
  read -r -a words <<<"$value"
  while (( ${#words[@]} > 0 )); do
    key="${words[0]}"; words=("${words[@]:1}")
    case "$kind:$key" in
      class:leaf)
        [[ "${words[0]:-}" =~ ^[0-9a-f]+:$ ]] || return 1
        words=("${words[@]:1}"); continue ;;
      fq:bands)
        [[ "${words[0]:-}" == 3 && "${words[1]:-}" == priomap && ${#words[@]} -ge 18 ]] || return 1
        result+=(bands 3 priomap); words=("${words[@]:2}")
        for ((count=0; count<16; count++)); do
          [[ "${words[0]}" =~ ^[012]$ ]] || return 1
          result+=("${words[0]}"); words=("${words[@]:1}")
        done ;;
      fq:weights)
        (( ${#words[@]} >= 3 )) || return 1
        result+=(weights)
        for ((count=0; count<3; count++)); do
          [[ "${words[0]}" =~ ^[1-9][0-9]*$ ]] || return 1
          result+=("${words[0]}"); words=("${words[@]:1}")
        done ;;
      fq:pacing|fq:nopacing|fq:horizon_drop|fq:horizon_cap|fq_codel:ecn|fq_codel:noecn)
        result+=("$key"); continue ;;
      htb:direct_packets_stat|htb:ver|class:level)
        (( ${#words[@]} > 0 )) || return 1
        words=("${words[@]:1}"); continue ;;
      fq:limit|fq:flow_limit|fq:buckets|fq:orphan_mask|fq:quantum|fq:initial_quantum|fq:low_rate_threshold|fq:refill_delay|fq:maxrate|fq:timer_slack|fq:horizon|fq:ce_threshold|fq:offload_horizon|\
      fq_codel:limit|fq_codel:flows|fq_codel:quantum|fq_codel:target|fq_codel:interval|fq_codel:memory_limit|fq_codel:drop_batch|fq_codel:ce_threshold|\
      htb:r2q|htb:default|htb:direct_qlen|class:prio|class:rate|class:ceil|class:burst|class:cburst|class:quantum)
        (( ${#words[@]} > 0 )) || return 1
        argument="${words[0]}"; words=("${words[@]:1}")
        [[ "$kind:$key:$argument" != fq:maxrate:unlimited ]] || continue
        [[ "$argument" =~ ^([0-9]+([.][0-9]+)?(p|b|Kb|Mb|Gb|bit|Kbit|Mbit|Gbit|ns|us|ms|s)?|0x[0-9a-f]+)$ ]] || return 1
        if [[ "$argument" =~ ^[0-9]+[pb]$ ]]; then argument="${argument%?}"; fi
        if [[ "$kind" == fq && ( "$key" == quantum || "$key" == initial_quantum ) && "$argument" == *b ]]; then
          argument="$(awk -v n="$argument" 'BEGIN{s=1; if(n~/Kb$/)s=1024; if(n~/Mb$/)s=1048576; if(n~/Gb$/)s=1073741824; printf "%.0f",n*s}')"
        fi
        result+=("$key" "$argument") ;;
      *) return 1 ;;
    esac
  done
  printf '%s' "${result[*]}"
}

tuning_queue_snapshot() {
  local iface="$1" output line kind handle where parent options normalized classes filters details quantum root='' leaves=0
  local -a words=() rows=()
  tuning_device_exists "$iface" || return 1
  output="$(tc qdisc show dev "$iface")" || return 1
  filters="$(tc filter show dev "$iface")" || return 1
  [[ -z "$filters" ]] || { warn "网卡存在外部 tc filter，停止接管。"; return 1; }
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=' ' read -r -a words <<<"$line"
    [[ "${words[0]:-}" == qdisc ]] || return 1
    kind="${words[1]}"; handle="${words[2]}"; where="${words[3]}"
    case "$where" in
      root) [[ -z "$root" ]] || return 1; root="$kind"; parent=root; words=("${words[@]:4}") ;;
      parent)
        parent="${words[4]}"
        [[ "$parent" =~ ^[0-9a-f]*:[0-9a-f]+$ ]] || return 1
        parent="${parent##*:}"; leaves=$((leaves+1)); words=("${words[@]:5}") ;;
      *) warn "队列包含 ingress/clsact 或未知结构，停止接管。"; return 1 ;;
    esac
    [[ "${words[0]:-}" != refcnt ]] || words=("${words[@]:2}")
    case "$kind" in
      mq) [[ "$parent" == root && ${#words[@]} == 0 ]] || return 1; normalized='' ;;
      pfifo_fast)
        [[ "$(IFS=' '; printf '%s' "${words[*]}")" == 'bands 3 priomap  1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1' ||
           "$(IFS=' '; printf '%s' "${words[*]}")" == 'bands 3 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1' ]] || return 1
        normalized='' ;;
      fq|fq_codel|htb)
        [[ "$kind" != htb || ( "$handle" == 7e10: && "$parent" == root ) ]] || { warn "已有外部 HTB，停止接管。"; return 1; }
        options="$(IFS=' '; printf '%s' "${words[*]}")"
        normalized="$(tuning_queue_options "$kind" "$options")" || { warn "无法完整恢复 $kind 队列选项，停止接管。"; return 1; } ;;
      *) warn "暂不接管 $kind 自定义队列。"; return 1 ;;
    esac
    rows+=("$parent|$kind|$normalized")
  done <<<"$output"
  case "$root" in
    mq) (( leaves > 0 )) || return 1 ;;
    htb) (( leaves == 1 )) || return 1 ;;
    fq|fq_codel|pfifo_fast) (( leaves == 0 )) || return 1 ;;
    *) return 1 ;;
  esac
  classes="$(tc class show dev "$iface")" || return 1
  if [[ "$root" == htb ]]; then
    [[ "$classes" != *$'\n'* && "$classes" == 'class htb 7e10:1 root '* ]] || return 1
    normalized="$(tuning_queue_options class "${classes#class htb 7e10:1 root }")" || return 1
    details="$(tc -d class show dev "$iface")" || return 1
    quantum="$(awk '{for(i=1;i<NF;i++)if($i=="quantum"){print $(i+1); exit}}' <<<"$details")"
    [[ "$quantum" =~ ^[0-9]+$ ]] || return 1
    normalized="$normalized quantum $quantum"
    rows+=("class|htb|$normalized")
  elif [[ "$root" != mq && -n "$classes" ]]; then return 1
  fi
  printf '%s\n' "${rows[@]}" | LC_ALL=C sort
}

tuning_queue_handle() {
  case "$1" in htb) printf 7e10 ;; fq) printf 7e20 ;; mq) printf 7e30 ;;
    fq_codel) printf 7e40 ;; pfifo_fast) printf 7e50 ;; *) return 1 ;; esac
}

tuning_queue_is_managed_mq() {
  local current
  current="$(tc qdisc show dev "$1")" || return 1
  grep -q '^qdisc mq 7e30: root' <<<"$current"
}

tuning_queue_restore() {
  local iface="$1" snapshot="$2" slot kind options root_kind root_options handle
  local -a args=()
  root_kind="$(awk -F'|' '$1=="root"{print $2}' <<<"$snapshot")"
  root_options="$(awk -F'|' '$1=="root"{print $3}' <<<"$snapshot")"
  case "$root_kind" in mq|fq|fq_codel|pfifo_fast|htb) ;; *) return 1 ;; esac
  # Validate the entire stored plan before the first kernel write.
  while IFS='|' read -r slot kind options; do
    case "$slot:$kind" in
      root:mq|root:pfifo_fast|*:pfifo_fast) [[ -z "$options" ]] || return 1 ;;
      class:htb) tuning_queue_options class "$options" >/dev/null || return 1 ;;
      root:htb|*:fq|*:fq_codel) tuning_queue_options "$kind" "$options" >/dev/null || return 1 ;;
      *) return 1 ;;
    esac
    [[ "$slot" == root || "$slot" == class || "$slot" =~ ^[0-9a-f]+$ ]] || return 1
  done <<<"$snapshot"
  handle="$(tuning_queue_handle "$root_kind")" || return 1
  # A stable handle makes kernel-created mq leaves addressable.
  IFS=' ' read -r -a args <<<"$root_options"
  if [[ "$root_kind" != mq ]] || ! tuning_queue_is_managed_mq "$iface"; then
    tc qdisc replace dev "$iface" root handle "$handle:" "$root_kind" "${args[@]}" || return 1
  fi
  if [[ "$root_kind" == htb ]]; then
    options="$(awk -F'|' '$1=="class"{print $3}' <<<"$snapshot")"
    [[ -n "$options" ]] || return 1
    IFS=' ' read -r -a args <<<"$options"
    tc class replace dev "$iface" parent 7e10: classid 7e10:1 htb "${args[@]}" || return 1
  fi
  while IFS='|' read -r slot kind options; do
    case "$slot" in root|class) continue ;; esac
    [[ "$slot" =~ ^[0-9a-f]+$ ]] || return 1
    case "$kind" in fq|fq_codel|pfifo_fast) ;; *) return 1 ;; esac
    IFS=' ' read -r -a args <<<"$options"
    tc qdisc replace dev "$iface" parent "$handle:$slot" "$kind" "${args[@]}" || return 1
  done <<<"$snapshot"
  [[ "$(tuning_queue_snapshot "$iface")" == "$snapshot" ]]
}

tuning_queue_write() {
  local iface="$1" mode="$2" rate="${3:-0}" snapshot slot kind options burst entry
  snapshot="$(tuning_queue_snapshot "$iface")" || return 1
  if [[ -n "${runtime_last:-}" && "$snapshot" != "$runtime_last" ]]; then
    warn "网卡队列在操作期间已变化，停止改写。"; return 1
  fi
  runtime_dirty=1
  case "$mode" in
    fq)
      # Restore mq topology when removing a shaper previously placed over mq.
      entry="$(tuning_runtime_entry qdisc "$iface")" || return 1
      if [[ "$snapshot" == *'root|htb|'* ]] && tuning_runtime_valid_entry "$entry" &&
        grep -q '^root|mq|' "$entry/before"; then snapshot="$(<"$entry/before")"; fi
      if grep -q '^root|mq|' <<<"$snapshot"; then
        if ! tuning_queue_is_managed_mq "$iface"; then
          tc qdisc replace dev "$iface" root handle 7e30: mq || return 1
        fi
        while IFS='|' read -r slot kind options; do
          [[ "$slot" != root ]] || continue
          tc qdisc replace dev "$iface" parent "7e30:$slot" fq || return 1
        done <<<"$snapshot"
      else
        tc qdisc replace dev "$iface" root handle 7e20: fq || return 1
      fi ;;
    htb)
      tuning_strategy_integer "$rate" 100000 || return 1
      burst="$(tuning_tcpfit_calc calc_burst "$rate")" || return 1
      tc qdisc replace dev "$iface" root handle 7e10: htb default 1 || return 1
      tc class replace dev "$iface" parent 7e10: classid 7e10:1 htb rate "${rate}mbit" ceil "${rate}mbit" burst "$burst" cburst "$burst" quantum 1514 || return 1
      tc qdisc replace dev "$iface" parent 7e10:1 handle 7e11: fq limit 40960 flow_limit 8192 maxrate "${rate}mbit" || return 1 ;;
    *) return 1 ;;
  esac
  snapshot="$(tuning_queue_snapshot "$iface")" || return 1
  if [[ "$mode" == fq ]]; then
    if awk -F'|' '$2!="mq" && $2!="fq"{bad=1} END{exit !bad}' <<<"$snapshot"; then return 1; fi
  else
    # tc changes rate units (e.g. 1000 Mbit -> 1 Gbit).
    tuning_queue_rate_matches "$snapshot" "$rate" || return 1
  fi
  runtime_last="$snapshot"; runtime_dirty=0
}

tuning_queue_rate_matches() {
  awk -F'|' -v expected="$2" '
    function mbps(v) {
      if(v ~ /Gbit$/) return v*1000;
      if(v ~ /Mbit$/) return v+0;
      if(v ~ /Kbit$/) return v/1000;
      if(v ~ /bit$/) return v/1000000;
      return -1
    }
    $1=="class" {
      n=split($3,a," "); for(i=1;i<n;i++) {
        if(a[i]=="rate") rate=mbps(a[i+1]);
        if(a[i]=="ceil") ceil=mbps(a[i+1]);
      }
    }
    END {exit !(rate>=expected*0.99 && rate<=expected*1.01 && ceil>=expected*0.99 && ceil<=expected*1.01)}
  ' <<<"$1"
}

tuning_route_snapshot() {
  local family="$1" iface="$2" route
  [[ "$family" == 4 || "$family" == 6 ]] && tuning_device_exists "$iface" || return 1
  route="$(ip "-$family" route show table main default dev "$iface")" || return 1
  [[ -n "$route" && "$route" != *$'\n'* && "$route" == default* &&
     "$route" != *nexthop* && "$route" != *expires* && "$route" != *' lock '* &&
     "$route" =~ ^[a-zA-Z0-9_.:/\ +\-]+$ ]] || {
    warn "只接管主路由表中单一路径、无动态到期的默认路由。"; return 1;
  }
  printf '%s\n' "$route" | awk '{$1=$1; print}'
}

tuning_route_base() {
  awk '{for(i=1;i<=NF;i++) {if($i=="initcwnd" || $i=="initrwnd"){i++; continue} printf "%s%s", sep,$i; sep=" "} print ""}'
}

tuning_route_write() {
  local family="$1" iface="$2" window="$3" route base
  local -a args=()
  tuning_strategy_integer "$window" 64 || return 1
  route="$(tuning_route_snapshot "$family" "$iface")" || return 1
  base="$(tuning_route_base <<<"$route")"
  if [[ -n "${runtime_last:-}" && "$route" != "$runtime_last" ]]; then return 1; fi
  runtime_dirty=1
  IFS=' ' read -r -a args <<<"$base"
  ip "-$family" route change "${args[@]}" initcwnd "$window" initrwnd "$window" || return 1
  route="$(tuning_route_snapshot "$family" "$iface")" || return 1
  [[ "$(tuning_route_base <<<"$route")" == "$base" ]] || return 1
  awk -v n="$window" '{for(i=1;i<NF;i++){if($i=="initcwnd") c=$(i+1); if($i=="initrwnd") r=$(i+1)}} END{exit !(c==n && r==n)}' <<<"$route" || return 1
  runtime_last="$route"; runtime_dirty=0
}

tuning_route_restore() {
  local family="$1" iface="$2" before="$3" current
  local -a args=()
  current="$(tuning_route_snapshot "$family" "$iface")" || return 1
  [[ "$(tuning_route_base <<<"$current")" == "$(tuning_route_base <<<"$before")" ]] || {
    warn "默认路由已变化，停止恢复初始窗口。"; return 1;
  }
  IFS=' ' read -r -a args <<<"$before"
  ip "-$family" route change "${args[@]}" || return 1
  [[ "$(tuning_route_snapshot "$family" "$iface")" == "$before" ]]
}
