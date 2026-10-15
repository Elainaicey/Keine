#!/usr/bin/env bash
# Callback state is consumed inside config_file_write/config_file_restore subshells.
# shellcheck disable=SC2034

declare -Ag FORWARD_RULE

forward_engine_available() { [[ -x /usr/bin/socat ]]; }

forward_native_guard() {
  local path="$1" fragment dropins
  if ! command_exists systemctl || ! command_exists ss || ! command_exists systemd-analyze || ! command_exists flock || ! command_exists ip; then
    warn "需要 systemd、systemd-analyze、ss、ip 与 flock。"; return 1
  fi
  fragment="$(systemctl show "${path##*/}" -p FragmentPath --value 2>/dev/null)" || return 1
  dropins="$(systemctl show "${path##*/}" -p DropInPaths --value 2>/dev/null)" || return 1
  [[ -z "$dropins" && ( -z "$fragment" || "$fragment" == "$path" ) ]] || {
    warn "服务存在其他来源或 drop-in 配置，保留原配置。"; return 1;
  }
}

forward_lock() {
  changes_storage_ready || return 1
  local path
  path="$(changes_root)/forwarding.lock"
  [[ ! -L "$path" ]] || return 1
  exec {FORWARD_LOCK_FD}>"$path" || return 1
  flock -n "$FORWARD_LOCK_FD" || { warn "另一个转发操作正在进行。"; return 1; }
}

forward_listeners() {
  local family=-4 option=-ltnp
  [[ "${FORWARD_RULE[listen]}" != *:* ]] || family=-6
  [[ "${FORWARD_RULE[protocol]}" != udp ]] || option=-lunp
  ss "$family" -H "$option" "sport = :${FORWARD_RULE[port]}"
}

forward_port_check() {
  local path="$1" output pid='' route
  if (( 10#${FORWARD_RULE[port]} == 10#${FORWARD_RULE[target_port]} )); then
    route="$(ip route get "${FORWARD_RULE[target]}" 2>/dev/null)" || route=''
    if [[ "${FORWARD_RULE[target]}" == *:* ]]; then route="$(ip -6 route get "${FORWARD_RULE[target]}" 2>/dev/null)" || route=''; fi
    [[ "$route" != local\ * ]] || { warn "目标指向本机同一端口，可能形成转发循环。"; return 1; }
  fi
  output="$(forward_listeners)" || return 1
  [[ -n "$output" ]] || return 0
  if [[ -f "$path" ]]; then pid="$(systemctl show "${path##*/}" -p MainPID --value)" || return 1; fi
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && ! grep -vF "pid=$pid," <<<"$output" | grep -q . && return 0
  warn "监听端口已被占用；不会停止其他服务或覆盖其他规则。"; return 1
}

forward_reserved_check() (
  local own="$1" path reserved_protocol="${FORWARD_RULE[protocol]}" reserved_port="${FORWARD_RULE[port]}" family=4 other_family
  [[ "${FORWARD_RULE[listen]}" != *:* ]] || family=6
  while IFS= read -r path; do
    [[ "$path" != "$own" ]] || continue
    forward_load "$path" || continue
    [[ "${FORWARD_RULE[active]}" == 1 || "${FORWARD_RULE[boot]}" == 1 ]] || continue
    other_family=4; [[ "${FORWARD_RULE[listen]}" != *:* ]] || other_family=6
    if [[ "$family" == "$other_family" && "$reserved_protocol" == "${FORWARD_RULE[protocol]}" ]] && (( 10#$reserved_port == 10#${FORWARD_RULE[port]} )); then
      warn "端口已被规则 ${FORWARD_RULE[id]} 预留，请先停用该规则及其开机启动。"; return 1
    fi
  done < <(forward_paths)
)

forward_verify_running() {
  local unit="$1" attempt pid output
  for ((attempt=0; attempt<15; attempt++)); do
    if systemctl is-active --quiet "$unit"; then
      pid="$(systemctl show "$unit" -p MainPID --value)" || return 1
      output="$(forward_listeners)" || return 1
      if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && grep -Fq "pid=$pid," <<<"$output"; then return 0; fi
    fi
    sleep 0.2
  done
  warn "转发服务未建立监听；请检查日志。"; return 1
}

forward_apply() {
  local unit="${FORWARD_APPLY_PATH##*/}"
  if [[ -f "$FORWARD_APPLY_PATH" ]]; then
    forward_load "$FORWARD_APPLY_PATH" || return 1
    runtime_with_timeout 15 systemd-analyze verify "$FORWARD_APPLY_PATH" || return 1
  fi
  if [[ ! -f "$FORWARD_APPLY_PATH" ]]; then
    systemctl daemon-reload || return 1
    ! systemctl is-active --quiet "$unit"
    return
  fi
  systemctl daemon-reload || return 1
  if [[ "${FORWARD_RULE[boot]}" == 1 ]]; then systemctl enable "$unit" || return 1
  else systemctl disable "$unit" || return 1; fi
  if [[ "${FORWARD_RULE[active]}" == 1 ]]; then
    if [[ "${FORWARD_RESTART:-1}" == 1 ]] || ! systemctl is-active --quiet "$unit"; then systemctl restart "$unit" || return 1; fi
    forward_verify_running "$unit"
  else
    systemctl stop "$unit" && ! systemctl is-active --quiet "$unit"
  fi
}

forward_rollback() {
  local unit="${FORWARD_APPLY_PATH##*/}" link
  if [[ ! -f "$FORWARD_APPLY_PATH" ]]; then
    if systemctl is-active --quiet "$unit"; then systemctl stop "$unit" || return 1; fi
    # Let systemd remove its enablement links even after the failed new file
    # has been rolled back; verify the only declared WantedBy link below.
    systemctl disable "$unit" >/dev/null 2>&1 || true
    link="$(forward_dir)/multi-user.target.wants/$unit"
    if [[ -L "$link" ]]; then
      [[ "$(readlink -m -- "$link")" == "$FORWARD_APPLY_PATH" ]] || return 1
      rm -f -- "$link" || return 1
    elif [[ -e "$link" ]]; then return 1; fi
    systemctl daemon-reload
    return
  fi
  systemctl daemon-reload || return 1
  if [[ "$FORWARD_WAS_BOOT" == 1 ]]; then systemctl enable "$unit" || return 1
  else systemctl disable "$unit" || return 1; fi
  if [[ "$FORWARD_WAS_ACTIVE" == 1 ]]; then
    forward_load "$FORWARD_APPLY_PATH" || return 1
    systemctl restart "$unit" && forward_verify_running "$unit"
  else systemctl stop "$unit"; fi
}

forward_save() (
  forward_values_valid || { warn "转发参数无效。"; return 1; }
  local path payload FORWARD_APPLY_PATH FORWARD_WAS_ACTIVE=0 FORWARD_WAS_BOOT=0 FORWARD_RESTART=1
  path="$(forward_path "${FORWARD_RULE[id]}")"; FORWARD_APPLY_PATH="$path"
  config_file_safe "$path" || return 1
  require_root
  forward_engine_available || { warn "请先安装 socat。"; return 1; }
  forward_native_guard "$path" || return 1
  (( DRY_RUN == 0 )) || { info "将保存规则并应用服务；不会修改 NAT 或防火墙。"; return 0; }
  forward_lock || return 1
  if [[ "${1:-edit}" == create && ( -e "$path" || -L "$path" ) ]]; then warn "同名规则已创建，请从列表进入管理。"; return 1; fi
  if [[ -e "$path" || -L "$path" ]]; then forward_owned "$path" || return 1; fi
  if [[ "${FORWARD_RULE[active]}" == 1 || "${FORWARD_RULE[boot]}" == 1 ]]; then
    forward_reserved_check "$path" && forward_port_check "$path" || return 1
  fi
  systemctl is-active --quiet "${path##*/}" && FORWARD_WAS_ACTIVE=1
  systemctl is-enabled --quiet "${path##*/}" && FORWARD_WAS_BOOT=1
  payload="$(forward_render)" || return 1
  if [[ -f "$path" && "$(sed -n '/^ExecStart=/p' "$path")" == "$(sed -n '/^ExecStart=/p' <<<"$payload")" ]]; then FORWARD_RESTART=0; fi
  config_file_write "$path" 0644 "$payload" forward_apply forward_rollback || return 1
  audit "action=forward-save id=${FORWARD_RULE[id]} protocol=${FORWARD_RULE[protocol]}"
  ui_success "转发配置已应用。"
)

forward_remove() (
  local path="$1" entry FORWARD_APPLY_PATH="$1" FORWARD_WAS_ACTIVE=0 FORWARD_WAS_BOOT=0
  require_root
  forward_recovery_handles "$path" && config_file_safe "$path" && forward_native_guard "$path" || return 1
  # A failed first deployment may leave an unchanged, absent-file baseline.
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    entry="$(changes_file_entry "$path")"
    [[ -f "$entry/before" && "$(<"$entry/before")" == absent && "$(changes_file_status "$entry")" == unchanged ]] || return 1
    (( DRY_RUN != 0 )) || forward_lock || return 1
    if systemctl is-active --quiet "${path##*/}" || systemctl is-enabled --quiet "${path##*/}"; then
      warn "配置文件缺失，但服务仍在运行或启用；请先人工检查。"; return 1
    fi
    config_file_restore "$path" forward_apply forward_rollback
    return
  fi
  forward_owned "$path" || return 1
  (( DRY_RUN == 0 )) || { info "将停用并移除此转发服务；保留 socat 和防火墙规则。"; return 0; }
  forward_lock && forward_owned "$path" || return 1
  systemctl is-active --quiet "${path##*/}" && FORWARD_WAS_ACTIVE=1
  systemctl is-enabled --quiet "${path##*/}" && FORWARD_WAS_BOOT=1
  # Disable before unlink so systemd can read [Install] and remove only its links.
  systemctl disable --now "${path##*/}" || { forward_rollback; return 1; }
  config_file_restore "$path" forward_apply forward_rollback || { forward_rollback; return 1; }
  audit "action=forward-remove unit=${path##*/}"
  ui_success "转发已移除；软件和防火墙规则保留。"
)

forward_recovery_handles() {
  local name="${1##*/}"
  [[ "$1" == "$(forward_dir)/$name" && "$name" == keine-forward-*.service ]] || return 1
  name="${name#keine-forward-}"; forward_id_valid "${name%.service}"
}
