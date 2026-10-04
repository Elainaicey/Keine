#!/usr/bin/env bash

tuning_runtime_root() { printf '%s/network-runtime' "$(changes_root)"; }

tuning_runtime_entry() {
  case "$1" in qdisc|route4|route6) ;; *) return 1 ;; esac
  valid_network_interface "$2" && [[ "$2" != lo ]] || return 1
  printf '%s/%s-%s' "$(tuning_runtime_root)" "$1" "$2"
}

tuning_runtime_entries() {
  local entry
  for entry in "$(tuning_runtime_root)"/*; do
    [[ -d "$entry" && ! -L "$entry" ]] && printf '%s\n' "$entry"
  done
  return 0
}

tuning_runtime_read() {
  case "$1" in
    qdisc) tuning_queue_snapshot "$2" ;;
    route4|route6) tuning_route_snapshot "${1#route}" "$2" ;;
    *) return 1 ;;
  esac
}

tuning_runtime_replay() {
  case "$1" in
    qdisc) tuning_queue_restore "$2" "$3" ;;
    route4|route6) tuning_route_restore "${1#route}" "$2" "$3" ;;
    *) return 1 ;;
  esac
}

tuning_runtime_valid_entry() {
  local entry="$1" file kind iface
  [[ -d "$entry" && ! -L "$entry" && "$(readlink -m -- "$entry")" == "$entry" ]] || return 1
  for file in kind iface boot identity before last plan; do
    [[ -f "$entry/$file" && ! -L "$entry/$file" ]] || return 1
  done
  kind="$(<"$entry/kind")"; iface="$(<"$entry/iface")"
  [[ "$(tuning_runtime_entry "$kind" "$iface")" == "$entry" ]]
}

tuning_runtime_status() {
  local entry="$1" kind iface current
  tuning_runtime_valid_entry "$entry" || { printf conflict; return 0; }
  [[ "$(<"$entry/boot")" == "$(tuning_boot_id)" ]] || { printf expired; return 0; }
  kind="$(<"$entry/kind")"; iface="$(<"$entry/iface")"
  [[ "$(<"$entry/identity")" == "$(tuning_device_identity "$iface")" ]] || { printf conflict; return 0; }
  current="$(tuning_runtime_read "$kind" "$iface")" || { printf conflict; return 0; }
  if [[ "$current" == "$(<"$entry/last")" || "$current" == "$(<"$entry/before")" ]]; then printf ready
  else printf conflict; fi
}

tuning_runtime_prepare() {
  local kind="$1" iface="$2" before="$3" entry temporary file
  for file in /etc/systemd/system/tcpfit-qdisc.service /etc/systemd/system/tcpfit-initcwnd.service /etc/systemd/system/bbr-optimize-persist.service; do
    [[ ! -e "$file" && ! -L "$file" ]] || { warn "请先处理已有调优服务：$file"; return 1; }
  done
  entry="$(tuning_runtime_entry "$kind" "$iface")" || return 1
  if [[ -e "$entry" || -L "$entry" ]]; then
    [[ "$(tuning_runtime_status "$entry")" == ready ]] || {
      warn "存在外部修改或上次启动的记录，请先从运行配置中处理。"; return 1;
    }
    return 0
  fi
  [[ "$kind" != qdisc || "$before" != *'|htb|'* ]] || { warn "未找到此 HTB 的归属记录。"; return 1; }
  [[ ! -L "$(tuning_runtime_root)" ]] || return 1
  mkdir -p "$(tuning_runtime_root)" || return 1
  chmod 0700 "$(tuning_runtime_root)" || return 1
  temporary="$(mktemp -d "$(tuning_runtime_root)/.pending.XXXXXX")" || return 1
  if ! {
    printf '%s\n' "$kind" >"$temporary/kind" &&
    printf '%s\n' "$iface" >"$temporary/iface" &&
    tuning_boot_id >"$temporary/boot" &&
    tuning_device_identity "$iface" >"$temporary/identity" &&
    printf '%s\n' "$before" >"$temporary/before" &&
    printf '%s\n' "$before" >"$temporary/last" &&
    printf 'unchanged\n' >"$temporary/plan";
  }; then rm -rf -- "$temporary"; return 1; fi
  for file in "$temporary"/*; do chmod 0600 "$file" || { rm -rf -- "$temporary"; return 1; }; done
  mv -- "$temporary" "$entry" || { rm -rf -- "$temporary"; return 1; }
}

tuning_runtime_save_last() {
  local entry="$1" current temporary
  current="$(tuning_runtime_read "$(<"$entry/kind")" "$(<"$entry/iface")")" || return 1
  temporary="$(mktemp "$entry/.last.XXXXXX")" || return 1
  printf '%s\n' "$current" >"$temporary" && mv -f -- "$temporary" "$entry/last"
}

# Runs in the transaction/session subshell, including on signal or failed writes.
tuning_runtime_abort() {
  local result="$1"
  trap - EXIT INT TERM HUP
  if (( runtime_mutating == 1 )); then
    if [[ "$(<"$runtime_entry/identity")" != "$(tuning_device_identity "$runtime_iface")" ]] ||
      ! tuning_runtime_can_rollback; then
      warn "当前配置或网卡归属已改变；保留原记录，不接管外部状态。"
      result=1
    else
      if tuning_runtime_replay "$runtime_kind" "$runtime_iface" "$runtime_before"; then
        if tuning_runtime_save_last "$runtime_entry"; then
          if (( runtime_created == 1 )); then rm -rf -- "$runtime_entry"; fi
        else result=1; fi
      else
        warn "运行配置未能完整恢复；撤销记录已保留，请进入运行配置检查。"
        result=1
      fi
    fi
  fi
  exit "$result"
}

tuning_runtime_can_rollback() {
  local current root filters
  if (( runtime_dirty == 0 )); then
    current="$(tuning_runtime_read "$runtime_kind" "$runtime_iface")" || return 1
    [[ "$current" == "$runtime_last" ]] || { warn "操作期间检测到外部修改，不覆盖当前配置。"; return 1; }
  elif [[ "$runtime_kind" == qdisc ]]; then
    # A partially built HTB cannot be fully snapshotted. Only roll back our handles.
    filters="$(tc filter show dev "$runtime_iface")" || return 1
    [[ -z "$filters" ]] || return 1
    root="$(tc qdisc show dev "$runtime_iface" | awk '$4=="root"{print $2 ":" $3}')"
    case "$root" in htb:7e10:|fq:7e20:|mq:7e30:|fq_codel:7e40:|pfifo_fast:7e50:) ;;
      *) [[ "$(tuning_queue_snapshot "$runtime_iface")" == "$runtime_before" ]] || return 1 ;;
    esac
  fi
}

tuning_runtime_apply() (
  local runtime_kind="$1" runtime_iface="$2" mode="$3" value="${4:-0}"
  local runtime_before runtime_entry runtime_mutating=0 runtime_created=0
  local runtime_last runtime_dirty=0
  case "$runtime_kind:$mode" in qdisc:fq) ;; qdisc:htb) tuning_strategy_integer "$value" 100000 || return 1 ;;
    route4:window|route6:window) tuning_strategy_integer "$value" 64 || return 1 ;; *) return 1 ;; esac
  require_root
  runtime_before="$(tuning_runtime_read "$runtime_kind" "$runtime_iface")" || return 1
  if (( DRY_RUN == 1 )); then info "将修改 $runtime_iface / $runtime_kind：$mode $value（本次启动有效）。"; return 0; fi
  changes_ready || return 1
  tuning_strategy_lock || return 1
  runtime_before="$(tuning_runtime_read "$runtime_kind" "$runtime_iface")" || return 1
  runtime_entry="$(tuning_runtime_entry "$runtime_kind" "$runtime_iface")" || return 1
  runtime_last="$runtime_before"
  [[ -d "$runtime_entry" ]] || runtime_created=1
  tuning_runtime_prepare "$runtime_kind" "$runtime_iface" "$runtime_before" || return 1
  trap 'tuning_runtime_abort $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  runtime_mutating=1
  case "$runtime_kind" in
    qdisc) tuning_queue_write "$runtime_iface" "$mode" "$value" || return 1 ;;
    route4|route6) tuning_route_write "${runtime_kind#route}" "$runtime_iface" "$value" || return 1 ;;
  esac
  tuning_runtime_save_last "$runtime_entry" || return 1
  printf '%s|%s\n' "$mode" "$value" >"$runtime_entry/plan" || return 1
  runtime_mutating=0
  audit "action=network-runtime-apply kind=$runtime_kind interface=$runtime_iface"
  ui_success "已应用并核对实际状态；本次启动有效，可单独撤销。"
)

tuning_runtime_restore() (
  local entry="$1" kind iface status before
  require_root
  tuning_runtime_valid_entry "$entry" || return 1
  (( DRY_RUN == 0 )) || { info "将撤销此网卡运行配置。"; return 0; }
  tuning_strategy_lock || return 1
  status="$(tuning_runtime_status "$entry")"
  case "$status" in
    expired) rm -rf -- "$entry"; info "已清除上次启动的记录；当前运行配置未改变。"; return 0 ;;
    ready) ;;
    *) warn "运行配置已被外部修改，停止恢复。"; return 1 ;;
  esac
  kind="$(<"$entry/kind")"; iface="$(<"$entry/iface")"; before="$(<"$entry/before")"
  if ! tuning_runtime_replay "$kind" "$iface" "$before"; then
    warn "恢复未完成，记录已保留。"; return 1
  fi
  rm -rf -- "$entry" || return 1
  audit "action=network-runtime-restore kind=$kind interface=$iface"
  ui_success "已恢复首次修改前的运行配置。"
)

tuning_runtime_session() (
  local runtime_iface="$1" operation="$2"
  shift 2
  case "$operation" in probe|sweep) ;; *) return 1 ;; esac
  local runtime_kind=qdisc runtime_before runtime_entry runtime_mutating=0 runtime_created=0
  local runtime_last runtime_dirty=0
  require_root
  (( DRY_RUN == 0 )) || { info "预览不会发起测速或改写队列。"; return 0; }
  changes_ready || return 1
  tuning_strategy_lock || return 1
  runtime_before="$(tuning_queue_snapshot "$runtime_iface")" || return 1
  runtime_last="$runtime_before"
  runtime_entry="$(tuning_runtime_entry qdisc "$runtime_iface")" || return 1
  [[ -d "$runtime_entry" ]] || runtime_created=1
  tuning_runtime_prepare qdisc "$runtime_iface" "$runtime_before" || return 1
  trap 'tuning_runtime_abort $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  runtime_mutating=1
  case "$operation" in
    probe) tuning_measure_probe "$runtime_iface" "$@" ;;
    sweep) tuning_measure_sweep "$runtime_iface" "$@" ;;
  esac
  # EXIT restores the exact scheduling parameters present before this session.
)
