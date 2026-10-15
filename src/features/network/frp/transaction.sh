#!/usr/bin/env bash
# Transaction state is read by EXIT/rollback callbacks in the enclosing subshell.
# shellcheck disable=SC2034,SC2030,SC2031

declare -Ag FRP_CONFIG

frp_atomic_copy() {
  local source="$1" target="$2" mode="$3" temporary
  config_file_safe "$target" || return 1
  temporary="$(mktemp "$(dirname -- "$target")/.keine-frp.XXXXXX")" || return 1
  if ! cp -- "$source" "$temporary" || ! chmod "$mode" "$temporary" || ! mv -fT -- "$temporary" "$target"; then
    rm -f -- "$temporary"; return 1
  fi
}

frp_transaction_record() {
  local path entry
  for path in "$FRP_TX_CONFIG" "$FRP_TX_UNIT"; do
    # Record only our last known write, never a concurrent external modification.
    unset 'CHANGES_PENDING_FILES[$path]'
    entry="$(changes_file_entry "$path")"
    [[ ! -d "$entry" ]] || printf '%s\n' "${FRP_TX_EXPECTED[$path]}" >"$entry/last" || return 1
  done
}

frp_transaction_check() {
  local path
  frp_native_guard "$FRP_TX_ROLE" || return 1
  for path in "$FRP_TX_CONFIG" "$FRP_TX_UNIT"; do
    [[ "$(changes_fingerprint "$path")" == "${FRP_TX_EXPECTED[$path]}" ]] || {
      warn "FRP 事务期间检测到外部修改，停止覆盖：$path"; return 1;
    }
  done
}

frp_transaction_rollback() {
  local unit="${FRP_TX_UNIT##*/}" path key
  frp_transaction_check || return 1
  if [[ ! -f "$FRP_TX_TEMP/unit.before" ]]; then
    # Stop while the new unit still exists, so enablement links can be removed.
    if [[ -f "$FRP_TX_UNIT" ]]; then systemctl disable --now "$unit" || return 1
    elif systemctl is-active --quiet "$unit"; then return 1; fi
  fi
  for key in config unit; do
    if [[ "$key" == config ]]; then path="$FRP_TX_CONFIG"; else path="$FRP_TX_UNIT"; fi
    if [[ -f "$FRP_TX_TEMP/$key.before" ]]; then
      frp_atomic_copy "$FRP_TX_TEMP/$key.before" "$path" "$([[ "$key" == config ]] && printf 600 || printf 644)" || return 1
    else rm -f -- "$path" || return 1; fi
    FRP_TX_EXPECTED[$path]="$(changes_fingerprint "$path")" || return 1
  done
  systemctl daemon-reload || return 1
  if [[ -f "$FRP_TX_TEMP/unit.before" ]]; then
    if (( FRP_TX_BOOT == 1 )); then systemctl enable "$unit" || return 1
    else systemctl disable "$unit" || return 1; fi
    frp_verify_boot "$unit" "$FRP_TX_BOOT" || return 1
    if (( FRP_TX_ACTIVE == 1 )); then
      frp_load "$FRP_TX_ROLE" && systemctl restart "$unit" && frp_verify_running "$FRP_TX_ROLE" || return 1
    else systemctl stop "$unit" && ! systemctl is-active --quiet "$unit" || return 1; fi
  fi
  frp_transaction_check && frp_transaction_record
}

frp_transaction_finish() {
  local status="$1"
  trap - EXIT HUP INT TERM
  if (( FRP_TX_STARTED == 1 && FRP_TX_DONE == 0 )); then
    if ! frp_transaction_rollback; then
      frp_transaction_record || true
      warn "FRP 自动回退未完成，保留恢复副本：$FRP_TX_TEMP"
      return 1
    fi
    warn "FRP 操作未完成，已恢复此前配置和服务状态。"
  fi
  rm -rf -- "$FRP_TX_TEMP"
  if (( FRP_TX_NEW_DIR == 1 )); then rmdir -- "$(frp_config_dir)" 2>/dev/null || true; fi
  return "$status"
}

frp_preflight_remove() (
  local role="$1" path entry config unit
  frp_native_guard "$role" || return 1
  config="$(frp_config_path "$role")"; unit="$(frp_unit_path "$role")"
  if [[ -f "$config" || -f "$unit" ]]; then frp_owned "$role" || return 1
  else
    # Failed initial deployment can leave absent baselines for one or both files.
    if systemctl is-active --quiet "${unit##*/}" || systemctl is-enabled --quiet "${unit##*/}"; then return 1; fi
    frp_role_recorded "$role" || return 1
  fi
  for path in "$config" "$unit"; do
    entry="$(changes_file_entry "$path")"
    [[ -d "$entry" ]] || { [[ ! -e "$path" && ! -L "$path" ]] && continue; return 1; }
    [[ -f "$entry/before" && "$(<"$entry/before")" == absent ]] || return 1
    case "$(changes_file_status "$entry")" in ready|unchanged) ;; *) return 1 ;; esac
  done
)

frp_transaction() (
  local operation="$1" role="$2" path entry key
  local FRP_TX_ROLE="$role" FRP_TX_CONFIG FRP_TX_UNIT FRP_TX_TEMP
  local FRP_TX_STARTED=0 FRP_TX_DONE=0 FRP_TX_ACTIVE=0 FRP_TX_BOOT=0 FRP_TX_NEW_DIR=0 FRP_TX_RESTART=1
  local -A FRP_TX_EXPECTED=()
  frp_role_valid "$role" || return 1
  FRP_TX_CONFIG="$(frp_config_path "$role")"; FRP_TX_UNIT="$(frp_unit_path "$role")"
  require_root || return 1
  frp_native_guard "$role" || return 1
  if [[ "$operation" == save ]]; then
    if [[ "${FRP_CONFIG[role]:-}" != "$role" ]] || ! frp_values_valid; then warn "FRP 参数无效。"; return 1; fi
    software_release_integrity "$role" || { warn "请先从软件中心安装或修复官方 $role。"; return 1; }
  elif [[ "$operation" != remove ]]; then return 1; fi
  if (( DRY_RUN == 1 )); then info "将验证并${operation/save/保存} FRP $role 配置与服务；不显示令牌，不修改防火墙。"; return 0; fi
  (( CHANGES_ENABLED == 1 )) || return 1
  frp_lock || return 1
  # Recovery invokes removal with CHANGES_RESTORING=1. Rollback fingerprints still need updating.
  CHANGES_RESTORING=0
  if [[ "$operation" == remove ]]; then frp_preflight_remove "$role" || return 1
  elif [[ -e "$FRP_TX_CONFIG" || -L "$FRP_TX_CONFIG" || -e "$FRP_TX_UNIT" || -L "$FRP_TX_UNIT" ]]; then
    frp_owned "$role" || return 1
    [[ "${3:-edit}" != create ]] || { warn "FRP 实例已存在，请刷新后重试。"; return 1; }
  else
    if systemctl is-active --quiet "${FRP_TX_UNIT##*/}" || systemctl is-enabled --quiet "${FRP_TX_UNIT##*/}"; then return 1; fi
  fi
  for path in "$FRP_TX_CONFIG" "$FRP_TX_UNIT"; do FRP_TX_EXPECTED[$path]="$(changes_fingerprint "$path")" || return 1; done
  umask 077
  FRP_TX_TEMP="$(mktemp -d)" || return 1
  trap 'frp_transaction_finish $?' EXIT
  trap 'exit 130' HUP INT TERM
  if [[ "$operation" == save ]]; then
    frp_render_config >"$FRP_TX_TEMP/$role.toml" && frp_render_unit "$role" >"$FRP_TX_TEMP/${FRP_TX_UNIT##*/}" || return 1
    frp_verify_config "$role" "$FRP_TX_TEMP/$role.toml" || return 1
    runtime_with_timeout 10 systemd-analyze verify "$FRP_TX_TEMP/${FRP_TX_UNIT##*/}" >/dev/null 2>&1 || { warn "FRP 服务定义验证失败。"; return 1; }
    if [[ "${FRP_CONFIG[active]}" == 1 || "${FRP_CONFIG[boot]}" == 1 ]]; then frp_port_check "$role" || return 1; fi
  fi
  frp_transaction_check || return 1
  for key in config unit; do
    if [[ "$key" == config ]]; then path="$FRP_TX_CONFIG"; else path="$FRP_TX_UNIT"; fi
    [[ ! -f "$path" ]] || cp -p -- "$path" "$FRP_TX_TEMP/$key.before" || return 1
  done
  systemctl is-active --quiet "${FRP_TX_UNIT##*/}" && FRP_TX_ACTIVE=1
  systemctl is-enabled --quiet "${FRP_TX_UNIT##*/}" && FRP_TX_BOOT=1
  if [[ "$operation" == save && "${3:-edit}" != restart && -f "$FRP_TX_TEMP/config.before" ]] &&
    cmp -s <(sed '/^# frp\.\(active\|boot\)=/d' "$FRP_TX_TEMP/config.before") <(sed '/^# frp\.\(active\|boot\)=/d' "$FRP_TX_TEMP/$role.toml"); then
    FRP_TX_RESTART=0
  fi
  if [[ "$operation" == save ]]; then
    for path in "$FRP_TX_CONFIG" "$FRP_TX_UNIT"; do changes_prepare_file "$path" || return 1; done
    # Never register an existing parent directory as owned.
    if [[ ! -d "$(frp_config_dir)" ]]; then
      mkdir -m 0700 -- "$(frp_config_dir)" || return 1; FRP_TX_NEW_DIR=1
    fi
    frp_transaction_check || return 1
    FRP_TX_STARTED=1
    frp_atomic_copy "$FRP_TX_TEMP/$role.toml" "$FRP_TX_CONFIG" 600 || return 1
    FRP_TX_EXPECTED[$FRP_TX_CONFIG]="$(changes_fingerprint "$FRP_TX_CONFIG")" || return 1
    frp_atomic_copy "$FRP_TX_TEMP/${FRP_TX_UNIT##*/}" "$FRP_TX_UNIT" 644 || return 1
    FRP_TX_EXPECTED[$FRP_TX_UNIT]="$(changes_fingerprint "$FRP_TX_UNIT")" || return 1
    frp_apply_service "$role" && frp_transaction_check && frp_transaction_record || return 1
  else
    frp_transaction_check || return 1
    FRP_TX_STARTED=1
    if [[ -f "$FRP_TX_UNIT" ]]; then systemctl disable --now "${FRP_TX_UNIT##*/}" || return 1; fi
    ! systemctl is-active --quiet "${FRP_TX_UNIT##*/}" || return 1
    frp_transaction_check || return 1
    for path in "$FRP_TX_CONFIG" "$FRP_TX_UNIT"; do
      rm -f -- "$path" || return 1; FRP_TX_EXPECTED[$path]=absent
    done
    systemctl daemon-reload || return 1
    ! systemctl is-enabled --quiet "${FRP_TX_UNIT##*/}" || return 1
    frp_transaction_check && frp_transaction_record || return 1
    FRP_TX_DONE=1
    for path in "$FRP_TX_CONFIG" "$FRP_TX_UNIT"; do
      entry="$(changes_file_entry "$path")"; rm -rf -- "$entry" || return 1
    done
    rmdir -- "$(frp_config_dir)" 2>/dev/null || true
  fi
  FRP_TX_DONE=1
  audit "action=frp-$operation role=$role"
  if [[ "$operation" == save ]]; then
    if [[ "${FRP_CONFIG[active]}" == 1 ]]; then ui_success "FRP 配置已应用，运行检查通过。"
    else ui_success "FRP 配置已验证并保存，服务处于停止状态。"; fi
  else ui_success "FRP 实例已移除；二进制和独立防火墙规则保留。"; fi
)

frp_save() { frp_transaction save "${FRP_CONFIG[role]}" "${1:-edit}"; }
frp_remove() { frp_transaction remove "$1"; }
