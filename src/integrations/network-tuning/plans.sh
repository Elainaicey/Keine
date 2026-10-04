#!/usr/bin/env bash

TUNING_STRATEGY_FILE="${KEINE_TUNING_STRATEGY_FILE:-/etc/sysctl.d/99-keine-tuning.conf}"

tuning_tcpfit_calc() (
  local operation="$1"
  shift
  case "$operation" in calc_margin|calc_burst|loss_pct) ;; *) return 1 ;; esac
  . "$ROOT_DIR/src/integrations/network-tuning/upstream/tcpfit.sh"
  "$operation" "$@"
)

tuning_strategy_id() {
  local id
  [[ -f "$TUNING_STRATEGY_FILE" && ! -L "$TUNING_STRATEGY_FILE" ]] || return 1
  config_project_marker "$TUNING_STRATEGY_FILE" || return 1
  id="$(sed -n 's/^# Strategy: //p' "$TUNING_STRATEGY_FILE" | head -n 1)"
  case "$id" in tcpfit|vps-tcp-tune) printf '%s' "$id" ;; *) return 1 ;; esac
}

tuning_strategy_guard() {
  [[ ! -e "$TUNING_STRATEGY_FILE" && ! -L "$TUNING_STRATEGY_FILE" ]] || {
    warn "请先在调优方案中撤销当前方案，再修改独立参数或 BBR。"; return 1;
  }
}

tuning_strategy_integer() {
  [[ "$1" =~ ^[1-9][0-9]{0,7}$ ]] && (( $1 <= $2 ))
}

# Each provider runs in a subshell: upstream globals and function names never leak.
tuning_strategy_plan() (
  local engine="$1" bandwidth="$2" selector="$3" rtt="${4:-150}" ram="${5:-}"
  local available cc buffer_bytes buffer_default tcp_mem bdp tw_buckets
  tuning_strategy_integer "$bandwidth" 100000 || return 1
  [[ -n "$ram" ]] || ram="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
  tuning_strategy_integer "$ram" 99999999 || return 1
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)" || return 1
  cc=cubic; [[ " $available " != *' bbr '* ]] || cc=bbr
  case "$engine" in
    tcpfit)
      case "$selector" in proxy|bulk|mixed) ;; *) return 1 ;; esac
      tuning_strategy_integer "$rtt" 2000 || return 1
      [[ "$(getconf PAGESIZE)" == 4096 ]] || { warn "tcpfit 的内存公式按 4 KiB 页计算；当前内核页大小不匹配。"; return 1; }
      . "$ROOT_DIR/src/integrations/network-tuning/upstream/tcpfit.sh"
      bdp="$(calc_bdp "$bandwidth" "$rtt")"
      buffer_bytes="$(calc_buf_max "$bdp" "$ram")"
      buffer_default="$(calc_buf_default "$selector" "$bdp")"
      tcp_mem="$(calc_tcp_mem "$ram")"
      cat <<EOF
# Managed by keine
# Strategy: tcpfit
# Upstream: 0.5.9 / 38fbf5af30daf87735f2ffbc5e0905033ee2b86e
# Input: ${bandwidth} Mbps / ${rtt} ms / ${selector} / ${ram} MiB
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=$cc
net.core.rmem_max=$buffer_bytes
net.core.wmem_max=$buffer_bytes
net.core.rmem_default=$buffer_default
net.core.wmem_default=$buffer_default
net.ipv4.tcp_rmem=4096 $buffer_default $buffer_bytes
net.ipv4.tcp_wmem=4096 $buffer_default $buffer_bytes
net.ipv4.tcp_mem=$tcp_mem
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_adv_win_scale=1
net.core.netdev_max_backlog=16384
net.core.netdev_budget=600
net.core.optmem_max=65536
net.core.somaxconn=8192
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_no_metrics_save=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600
net.ipv4.ip_local_port_range=1024 65535
vm.min_free_kbytes=32768
fs.file-max=1000000
EOF
      ;;
    vps-tcp-tune)
      case "$selector" in asia|overseas) ;; *) return 1 ;; esac
      [[ "$cc" == bbr ]] || { warn "vps-tcp-tune 方案需要可用的 BBR；请先加载内核模块。"; return 1; }
      . "$ROOT_DIR/src/integrations/network-tuning/upstream/vps-tcp-tune.sh"
      # Upstream's confirmation is replaced with keine's complete transaction preview.
      # Read by the pinned upstream calculation function in this subshell.
      # shellcheck disable=SC2034
      local AUTO_MODE=1 gl_huang='' gl_bai='' gl_kjlan='' gl_lv=''
      local vm_swappiness=5 vm_dirty_ratio=15 vm_min_free_kbytes=65536
      (( ram >= 2048 )) || { vm_swappiness=20; vm_dirty_ratio=20; vm_min_free_kbytes=32768; }
      buffer_bytes="$(calculate_buffer_size "$bandwidth" "$selector" 2>/dev/null)" || return 1
      buffer_bytes=$((buffer_bytes * 1024 * 1024))
      tw_buckets="$(calculate_tw_buckets)" || return 1
      cat <<EOF
# Managed by keine
# Strategy: vps-tcp-tune
# Upstream: 5.4.11 / 2dbe1c8f7330ae220a17e2562d69d1a5e55f55a5
# Input: ${bandwidth} Mbps / ${selector} / ${ram} MiB
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=$buffer_bytes
net.core.wmem_max=$buffer_bytes
net.ipv4.tcp_rmem=4096 87380 $buffer_bytes
net.ipv4.tcp_wmem=4096 65536 $buffer_bytes
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=1024 65535
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=8192
net.core.netdev_max_backlog=5000
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_max_tw_buckets=$tw_buckets
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.tcp_syncookies=1
vm.swappiness=$vm_swappiness
vm.dirty_ratio=$vm_dirty_ratio
vm.dirty_background_ratio=5
vm.overcommit_memory=1
vm.min_free_kbytes=$vm_min_free_kbytes
vm.vfs_cache_pressure=50
kernel.sched_autogroup_enabled=0
kernel.numa_balancing=0
EOF
      ;;
    *) return 1 ;;
  esac
)

tuning_strategy_values() {
  awk -F= '!/^#/ && NF==2 {key=$1; value=$2; gsub(/[[:space:]]/,"",key); gsub(/^[[:space:]]+|[[:space:]]+$/,"",value); gsub(/[[:space:]]+/," ",value); print key "=" value}'
}

tuning_strategy_validate() {
  local line key value count=0 engine=0
  local -A seen=()
  while IFS= read -r line; do
    case "$line" in '# Strategy: tcpfit'|'# Strategy: vps-tcp-tune') engine=$((engine+1)); continue ;; \#*|'') continue ;; esac
    [[ "$line" == *=* ]] || return 1
    key="${line%%=*}"; value="${line#*=}"
    changes_sysctl_key "$key" >/dev/null || return 1
    [[ ! -v 'seen[$key]' ]] || return 1; seen["$key"]=1
    changes_sysctl_value_valid "$key" "$value" || return 1
    count=$((count+1))
  done
  (( engine == 1 && count >= 2 )) && [[ -v 'seen[net.core.default_qdisc]' && -v 'seen[net.ipv4.tcp_congestion_control]' ]]
}

tuning_strategy_supported() {
  local line key
  while IFS= read -r line; do
    [[ "$line" != \#* && -n "$line" ]] || { printf '%s\n' "$line"; continue; }
    key="${line%%=*}"
    if sysctl -n "$key" >/dev/null 2>&1; then printf '%s\n' "$line"
    else
      case "$key" in net.core.default_qdisc|net.ipv4.tcp_congestion_control) return 1 ;; esac
      printf '# Unsupported: %s\n' "$key"
    fi
  done
}
