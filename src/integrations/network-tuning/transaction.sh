#!/usr/bin/env bash

tuning_strategy_source_files() {
  local path
  for path in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf; do
    [[ ! -f "$path" || "$path" == "$TUNING_STRATEGY_FILE" ]] || printf '%s\n' "$path"
  done
}

tuning_strategy_conflicts() {
  local payload="$1" path matches failed=0
  for path in "$NETWORK_TUNING_FILE" "$NETWORK_BBR_FILE" \
    /etc/systemd/system/tcpfit-qdisc.service /etc/systemd/system/tcpfit-initcwnd.service \
    /etc/systemd/system/bbr-optimize-persist.service; do
    if [[ -e "$path" || -L "$path" ]]; then warn "请先撤销或处理已有调优资源：$path"; failed=1; fi
  done
  while IFS= read -r path; do
    matches="$(awk -F= 'FNR==NR {if(!/^#/ && NF==2) keys[$1]=$2; next}
      !/^[[:space:]]*#/ && NF>=2 {
        key=$1; value=$2; gsub(/[[:space:]]/,"",key); sub(/^-/,"",key); gsub(/\//,".",key);
        sub(/[[:space:]]*[#;].*$/, "", value); gsub(/^[[:space:]]+|[[:space:]]+$/,"",value); gsub(/[[:space:]]+/," ",value);
        if(key in keys && value!=keys[key]) print key;
        else if(key ~ /[*?\[]/ && key ~ /^(net|vm|fs|kernel)[.]/) print key;
      }' <(printf '%s\n' "$payload") "$path")" || return 1
    if [[ -n "$matches" ]]; then warn "持久配置重叠：$(terminal_safe_text "$path")"; printf '  %s\n' "$(terminal_safe_text "$matches")" >&2; failed=1; fi
  done < <(tuning_strategy_source_files)
  (( failed == 0 ))
}

tuning_strategy_preflight() {
  local payload key value setting entry current
  entry="$(changes_file_entry "$TUNING_STRATEGY_FILE")"
  [[ -e "$TUNING_STRATEGY_FILE" || -d "$entry" ]] || return 0
  if [[ ! -e "$TUNING_STRATEGY_FILE" && ! -L "$TUNING_STRATEGY_FILE" && -f "$entry/last" ]] &&
    [[ "$(<"$entry/last")" == absent && "$(changes_file_status "$entry")" == unchanged ]]; then return 0; fi
  tuning_strategy_id >/dev/null || { warn "调优配置缺失或不属于 keine，拒绝覆盖。"; return 1; }
  case "$(changes_file_status "$entry")" in ready|unchanged) ;; *) warn "调优文件已被外部修改或缺少恢复记录。"; return 1 ;; esac
  payload="$(<"$TUNING_STRATEGY_FILE")"
  tuning_strategy_validate <<<"$payload" || return 1
  while IFS='=' read -r key value; do
    setting="$(changes_sysctl_key "$key")"; entry="$(changes_setting_entry "$setting")"
    [[ "$(changes_setting_key "$entry")" == "$setting" ]] || { warn "缺少 $key 的恢复记录。"; return 1; }
    current="$(changes_setting_value "$setting")" || return 1
    [[ "$current" == "$(<"$entry/last")" || "$current" == "$(<"$entry/before")" ]] || { warn "运行参数已被外部修改：$key"; return 1; }
    changes_sysctl_value_valid "$key" "$(<"$entry/before")" || return 1
  done < <(tuning_strategy_values <<<"$payload")
}

tuning_strategy_transaction_apply() {
  network_sysctl_apply_values "${TUNING_TRANSACTION_VALUES[@]}"
}

tuning_strategy_transaction_rollback() {
  local previous="$CHANGES_RESTORING" item setting failed=0
  CHANGES_RESTORING=1
  run sysctl -w "${TUNING_TRANSACTION_BEFORE[@]}" || failed=1
  CHANGES_RESTORING="$previous"
  for item in "${TUNING_TRANSACTION_BEFORE[@]}"; do
    [[ "$(changes_sysctl_read "${item%%=*}" || true)" == "${item#*=}" ]] || failed=1
    setting="$(changes_sysctl_key "${item%%=*}")"; changes_setting_commit "$setting" || failed=1
  done
  (( failed == 0 ))
}

tuning_strategy_lock() {
  command_exists flock || { warn "缺少 flock，请先安装 util-linux。"; return 1; }
  changes_storage_ready || return 1
  local lock_path
  lock_path="$(changes_root)/network-tuning.lock"
  [[ ! -L "$lock_path" ]] || return 1
  # The descriptor lives in the caller's subshell and closes on exit.
  exec {TUNING_LOCK_FD}>"$lock_path" || return 1
  flock -n "$TUNING_LOCK_FD" || { warn "另一个调优操作正在执行。"; return 1; }
}

tuning_strategy_cleanup_unchanged() {
  local entry setting
  for entry in "$@"; do
    setting="$(changes_setting_key "$entry")" || continue
    [[ "$(changes_setting_value "$setting" || true)" != "$(<"$entry/before")" ]] || changes_restore_setting "$entry" || return 1
  done
}

tuning_strategy_apply() (
  local payload="$1" key value setting entry item old_payload='' current file_entry new_file=0
  local -a TUNING_TRANSACTION_VALUES=() TUNING_TRANSACTION_BEFORE=() retired=() created=()
  local -A wanted=()
  tuning_strategy_validate <<<"$payload" || return 1
  require_root
  if (( DRY_RUN == 1 )); then info "将应用独立调优方案；预演不会写入配置或恢复记录。"; return 0; fi
  changes_ready || return 1
  tuning_strategy_lock || return 1
  tuning_strategy_preflight && tuning_strategy_conflicts "$payload" || return 1
  file_entry="$(changes_file_entry "$TUNING_STRATEGY_FILE")"
  [[ -d "$file_entry" ]] || new_file=1
  [[ ! -f "$TUNING_STRATEGY_FILE" ]] || old_payload="$(<"$TUNING_STRATEGY_FILE")"
  while IFS='=' read -r key value; do
    wanted["$key"]=1; TUNING_TRANSACTION_VALUES+=("$key=$value")
  done < <(tuning_strategy_values <<<"$payload")
  # Keys absent from the new provider return to their FIRST baseline, not to the other provider's values.
  while IFS='=' read -r key value; do
    [[ ! -v 'wanted[$key]' ]] || continue
    setting="$(changes_sysctl_key "$key")"; entry="$(changes_setting_entry "$setting")"
    TUNING_TRANSACTION_VALUES+=("$key=$(<"$entry/before")"); retired+=("$entry")
  done < <(tuning_strategy_values <<<"$old_payload")
  for item in "${TUNING_TRANSACTION_VALUES[@]}"; do
    key="${item%%=*}"; current="$(changes_sysctl_read "$key")" || return 1
    changes_sysctl_value_valid "$key" "$current" || return 1
    TUNING_TRANSACTION_BEFORE+=("$key=$current")
    setting="$(changes_sysctl_key "$key")"
    entry="$(changes_setting_entry "$setting")"
    [[ -d "$entry" ]] || created+=("$entry")
    changes_setting_prepare "$setting" || return 1
  done
  if ! config_file_write "$TUNING_STRATEGY_FILE" 0644 "$payload" tuning_strategy_transaction_apply tuning_strategy_transaction_rollback; then
    tuning_strategy_cleanup_unchanged "${created[@]}" || true
    if (( new_file == 1 )) && [[ -f "$file_entry/last" && "$(changes_file_status "$file_entry")" == unchanged ]] &&
      [[ "$(<"$file_entry/last")" == absent ]]; then changes_restore_file "$file_entry" || true; fi
    return 1
  fi
  for entry in "${retired[@]}"; do changes_restore_setting "$entry" || return 1; done
  audit "action=network-strategy-apply provider=$(tuning_strategy_id)"
  ui_success "调优方案已应用；另一方案独有的参数已恢复，不叠加。"
)

tuning_strategy_restore() (
  local key value setting entry
  local -a NETWORK_TUNING_GROUP_ENTRIES=() NETWORK_TUNING_PREVIOUS_VALUES=()
  require_root
  if (( DRY_RUN == 1 )); then info "将撤销当前调优方案；预演不修改主机。"; return 0; fi
  tuning_strategy_lock || return 1
  tuning_strategy_preflight || return 1
  if [[ ! -f "$TUNING_STRATEGY_FILE" ]]; then
    entry="$(changes_file_entry "$TUNING_STRATEGY_FILE")"
    [[ ! -d "$entry" ]] || changes_restore_file "$entry" || return 1
    info "没有托管的调优方案。"; return 0
  fi
  while IFS='=' read -r key value; do
    setting="$(changes_sysctl_key "$key")"; entry="$(changes_setting_entry "$setting")"
    NETWORK_TUNING_GROUP_ENTRIES+=("$entry")
    NETWORK_TUNING_PREVIOUS_VALUES+=("$key=$(changes_sysctl_read "$key")")
  done < <(tuning_strategy_values <"$TUNING_STRATEGY_FILE")
  config_file_restore "$TUNING_STRATEGY_FILE" network_tuning_restore_runtime network_tuning_restore_rollback || return 1
  for entry in "${NETWORK_TUNING_GROUP_ENTRIES[@]}"; do changes_restore_setting "$entry" || return 1; done
  audit 'action=network-strategy-restore'
  ui_success "调优方案已撤销，恢复首次应用前的运行值。"
)

tuning_strategy_entries() {
  local key value setting entry
  entry="$(changes_file_entry "$TUNING_STRATEGY_FILE")"
  [[ -d "$entry" ]] || return 0
  printf '%s\n' "$entry"
  [[ -f "$TUNING_STRATEGY_FILE" ]] || return 0
  while IFS='=' read -r key value; do
    setting="$(changes_sysctl_key "$key")" || continue
    printf '%s\n' "$(changes_setting_entry "$setting")"
  done < <(tuning_strategy_values <"$TUNING_STRATEGY_FILE")
}
