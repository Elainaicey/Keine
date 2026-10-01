#!/usr/bin/env bash

SOFTWARE_EFFECTS_CATALOG="${KEINE_SOFTWARE_EFFECTS_CATALOG:-$CONFIG_DIR/software-effects.tsv}"

catalog_effect_rows() {
  [[ -r "$SOFTWARE_EFFECTS_CATALOG" ]] || return 1
  awk -F '|' '!/^#/ && NF == 6' "$SOFTWARE_EFFECTS_CATALOG"
}

catalog_effect_record() {
  local id="$1"
  [[ -r "$SOFTWARE_EFFECTS_CATALOG" ]] || return 1
  awk -F '|' -v wanted="$id" '!/^#/ && NF == 6 && $1 == wanted {print; found=1; exit} END {if (!found) exit 1}' \
    "$SOFTWARE_EFFECTS_CATALOG"
}

catalog_effect_runtime_label() {
  case "${1:-}" in
    service) printf '后台服务' ;;
    scheduled) printf '计划任务' ;;
    service+scheduled) printf '服务 + 计划任务' ;;
    boot-hook) printf '开机加载' ;;
    *) return 1 ;;
  esac
}

catalog_effect_scheduler_label() {
  case "${1:-}" in
    none) return 1 ;;
    timer) printf 'systemd Timer' ;;
    cron) printf 'Cron' ;;
    timer-or-cron) printf 'Timer / Cron' ;;
    *) return 1 ;;
  esac
}

catalog_effect_network_label() {
  case "${1:-}" in
    none) return 1 ;;
    local-socket) printf '本地 Socket' ;;
    tcp-listener) printf 'TCP 监听' ;;
    tcp-udp-listener) printf 'TCP / UDP 监听' ;;
    outbound) printf '主动联网' ;;
    *) return 1 ;;
  esac
}

catalog_effect_label() {
  local id="$1" record _id runtime _units _scheduler _network _note
  record="$(catalog_effect_record "$id")" || return 1
  IFS='|' read -r _id runtime _units _scheduler _network _note <<<"$record"
  catalog_effect_runtime_label "$runtime"
}

catalog_effect_summary() {
  local id="$1" record _id runtime units scheduler network _note value
  local parts=()
  record="$(catalog_effect_record "$id")" || return 1
  IFS='|' read -r _id runtime units scheduler network _note <<<"$record"
  value="$(catalog_effect_runtime_label "$runtime")" || return 1
  parts+=("$value")
  if value="$(catalog_effect_scheduler_label "$scheduler")"; then
    parts+=("$value")
  fi
  if value="$(catalog_effect_network_label "$network")"; then
    parts+=("$value")
  fi
  [[ "$units" == "-" ]] || parts+=("$units")
  local summary="" part
  for part in "${parts[@]}"; do
    [[ -z "$summary" ]] || summary+=" · "
    summary+="$part"
  done
  printf '%s' "$summary"
}

catalog_effect_has_persistent_impact() {
  catalog_effect_record "$1" >/dev/null
}

catalog_effect_note() {
  local record _id _runtime _units _scheduler _network note
  record="$(catalog_effect_record "$1")" || return 1
  IFS='|' read -r _id _runtime _units _scheduler _network note <<<"$record"
  printf '%s' "$note"
}
