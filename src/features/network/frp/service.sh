#!/usr/bin/env bash

declare -Ag FRP_CONFIG
declare -ag FRP_MAPS

frp_release_operation() (
  local operation="$1" role="$2" result=0
  shift 2
  require_root || return 1
  if (( DRY_RUN == 0 )); then frp_lock || return 1; fi
  frp_release_guard "$role" "$operation" || return 1
  if [[ "$operation" == remove ]]; then software_remove_release_payload "$role" || result=$?
  else software_install_release_payload "$role" "$@" || result=$?; fi
  changes_commit_pending || return 1
  return "$result"
)

frp_lock() {
  local path
  command_exists flock && changes_storage_ready || return 1
  path="$(changes_root)/frp.lock"
  [[ ! -L "$path" ]] || return 1
  exec {FRP_LOCK_FD}>"$path" || return 1
  flock -n "$FRP_LOCK_FD" || { warn "另一个 FRP 操作正在进行。"; return 1; }
}

frp_native_guard() {
  local role="$1" path unit fragment dropins enabled directory
  frp_role_valid "$role" || return 1
  for directory in "$(frp_config_dir)" "$(frp_unit_dir)"; do
    safe_managed_path "$directory" && [[ "$(readlink -m -- "$directory")" == "$directory" ]] || return 1
  done
  for path in "$(frp_config_path "$role")" "$(frp_unit_path "$role")"; do config_file_safe "$path" || return 1; done
  for unit in systemctl systemd-analyze ss journalctl flock; do command_exists "$unit" || { warn "缺少 $unit。"; return 1; }; done
  path="$(frp_unit_path "$role")"; unit="${path##*/}"
  fragment="$(systemctl show "$unit" -p FragmentPath --value 2>/dev/null)" || return 1
  dropins="$(systemctl show "$unit" -p DropInPaths --value 2>/dev/null)" || return 1
  enabled="$(systemctl is-enabled "$unit" 2>/dev/null)" || true
  [[ -z "$dropins" && ( -z "$fragment" || "$fragment" == "$path" ) ]] || {
    warn "FRP 服务存在其他来源或 drop-in，停止覆盖。"; return 1;
  }
  case "$enabled" in enabled|disabled|not-found|'') ;; *) warn "FRP 服务启用方式异常：$enabled"; return 1 ;; esac
}

frp_verify_config() {
  local role="$1" path="$2"
  # Native errors may contain config values. Keep credentials out of ordinary output.
  runtime_with_timeout 10 "$(frp_binary "$role")" verify -c "$path" >/dev/null 2>&1 || {
    warn "FRP 原生配置验证失败；未加载候选配置。"; return 1;
  }
}

frp_port_check() {
  local role="$1" output pid unit
  [[ "$role" == frps ]] || return 0
  unit="$(frp_unit_path "$role")"; unit="${unit##*/}"
  output="$(ss -H -ltnp "sport = :${FRP_CONFIG[port]}")" || return 1
  [[ -n "$output" ]] || return 0
  pid="$(systemctl show "$unit" -p MainPID --value)" || return 1
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && ! grep -vF "pid=$pid," <<<"$output" | grep -q . && return 0
  warn "FRP 控制端口已被其他服务占用。"; return 1
}

frp_current_log() {
  local unit="$1" invocation
  invocation="$(systemctl show "$unit" -p InvocationID --value)" || return 1
  [[ "$invocation" =~ ^[a-fA-F0-9]{32}$ ]] || return 1
  runtime_with_timeout 3 journalctl --quiet -u "$unit" "_SYSTEMD_INVOCATION_ID=$invocation" -n 200 --no-pager -o cat
}

frp_verify_running() {
  local role="$1" unit pid output attempt row name type host port remote enabled good
  unit="$(frp_unit_path "$role")"; unit="${unit##*/}"
  for ((attempt=0; attempt<12; attempt++)); do
    if systemctl is-active --quiet "$unit"; then
      if [[ "$role" == frps ]]; then
        pid="$(systemctl show "$unit" -p MainPID --value)" || return 1
        output="$(ss -H -ltnp "sport = :${FRP_CONFIG[port]}")" || return 1
        if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && grep -Fq "pid=$pid," <<<"$output"; then return 0; fi
      else
        output="$(frp_current_log "$unit")" || output=''
        good=1
        [[ "$output" == *'login to server success'* ]] || good=0
        for row in "${FRP_MAPS[@]}"; do
          IFS='|' read -r name type host port remote enabled <<<"$row"
          # Newer FRP strips the user prefix from the local log name.
          [[ "$enabled" != 1 ]] || [[ "$output" == *"[$name] start proxy success"* || "$output" == *"[${FRP_CONFIG[user]}.$name] start proxy success"* ]] || good=0
        done
        (( good == 0 )) || return 0
      fi
    fi
    sleep 0.5
  done
  warn "FRP 运行验证未通过；服务端需建立监听，客户端需登录并注册全部启用映射。"
  return 1
}

frp_apply_service() {
  local role="$1" unit
  unit="$(frp_unit_path "$role")"; unit="${unit##*/}"
  systemctl daemon-reload || return 1
  if [[ "${FRP_CONFIG[boot]}" == 1 ]]; then systemctl enable "$unit" || return 1
  else systemctl disable "$unit" || return 1; fi
  frp_verify_boot "$unit" "${FRP_CONFIG[boot]}" || return 1
  if [[ "${FRP_CONFIG[active]}" == 1 ]]; then
    if [[ "${FRP_TX_RESTART:-1}" == 1 ]] || ! systemctl is-active --quiet "$unit"; then systemctl restart "$unit" || return 1; fi
    frp_verify_running "$role"
  else systemctl stop "$unit" && ! systemctl is-active --quiet "$unit"; fi
}

frp_verify_boot() {
  local unit="$1" expected="$2" actual
  actual="$(systemctl is-enabled "$unit" 2>/dev/null)" || true
  if [[ "$expected" == 1 ]]; then [[ "$actual" == enabled ]]
  else [[ "$actual" == disabled || "$actual" == not-found ]]; fi
}

frp_release_guard() {
  local role="$1" operation="$2" path unit
  frp_role_valid "$role" || return 0
  path="$(frp_config_path "$role")"; unit="$(frp_unit_path "$role")"
  if [[ -e "$path" || -L "$path" || -e "$unit" || -L "$unit" ]] || frp_role_recorded "$role"; then
    if [[ "$operation" == remove ]]; then warn "请先在 FRP 管理中移除 $role 实例，再删除软件。"; return 1; fi
    frp_owned "$role" && frp_native_guard "$role" || return 1
    if systemctl is-active --quiet "${unit##*/}"; then warn "请先停止 $role，再更新二进制；更新后从 FRP 管理启动并验证。"; return 1; fi
  fi
  if command_exists systemctl && systemctl is-active --quiet "$role.service"; then
    warn "检测到运行中的外部 $role.service，请先核实其二进制来源。"; return 1
  fi
}

frp_logs() (
  local role="$1" unit output line
  frp_owned "$role" && frp_load "$role" || return 1
  unit="$(frp_unit_path "$role")"; unit="${unit##*/}"
  output="$(runtime_with_timeout 5 journalctl --quiet -u "$unit" -n 100 --no-pager -o cat)" || return 1
  output="${output//${FRP_CONFIG[token]}/[已隐藏]}"
  while IFS= read -r line; do terminal_safe_text "$line"; printf '\n'; done <<<"$output"
)

frp_diagnose() (
  local role="$1" unit row name type host port remote enabled
  frp_owned "$role" && frp_load "$role" || return 1
  unit="$(frp_unit_path "$role")"; unit="${unit##*/}"
  ui_page "FRP / 连接检查"
  frp_native_guard "$role" && frp_verify_config "$role" "$(frp_config_path "$role")" || return 1
  ui_check pass "配置与资源归属检查通过"
  if frp_verify_running "$role"; then
    if [[ "$role" == frpc ]]; then ui_check pass "本次进程已登录并注册映射；当前端到端流量仍需验证"
    else ui_check pass "服务端控制端口已监听"; fi
  else ui_check warn "运行或映射注册未确认，请查看日志"; fi
  if [[ "$role" == frpc ]]; then
    network_endpoint_probe "${FRP_CONFIG[addr]}" "${FRP_CONFIG[port]}" || true
    for row in "${FRP_MAPS[@]}"; do
      IFS='|' read -r name type host port remote enabled <<<"$row"
      [[ "$enabled" == 1 ]] || continue
      ui_section "映射 / $name" primary
      if [[ "$type" == tcp ]]; then network_endpoint_probe "$host" "$port" || true
      else ui_note "UDP $host:$port → 服务端 $remote；请发送实际业务报文检查。"; fi
    done
  fi
  ui_note "控制连接、映射注册与业务响应是不同检查；远端端口冲突、允许范围及云端安全组需在服务端核对。"
)

frp_existing_view() {
  local role path unit fragment state output line found=0
  ui_page "FRP / 已有实例"
  for role in frps frpc; do
    path="$(command -v "$role" 2>/dev/null || true)"
    if [[ -n "$path" ]]; then ui_kv "$role 命令" "$(terminal_safe_text "$path")"; found=1; fi
    for unit in "$role.service" "keine-$role.service"; do
      fragment="$(systemctl show "$unit" -p FragmentPath --value 2>/dev/null)" || continue
      [[ -n "$fragment" ]] || continue
      state="$(service_state "$unit")"
      ui_kv "$unit" "$state · $(terminal_safe_text "$fragment")"; found=1
    done
    for path in "/etc/frp/$role.toml" "/etc/frp/$role.ini" "/home/frp/$role.toml" "$(frp_config_path "$role")"; do
      [[ ! -f "$path" ]] || { ui_kv "配置路径" "$path"; found=1; }
    done
  done
  if command_exists docker; then
    output="$(runtime_with_timeout 5 docker ps -a --filter name=frp --format '{{.Names}} · {{.Image}} · {{.Status}}' 2>/dev/null)" || output=''
    while IFS= read -r line; do
      [[ -z "$line" ]] || { ui_kv "容器" "$(terminal_safe_text "$line")"; found=1; }
    done <<<"$output"
  fi
  (( found != 0 )) || ui_note "未发现常见原生实例；自定义名称、目录或容器请从原生管理入口核对。"
  ui_note "只读取命令、服务与常见路径；不读取配置内容，不接管外部实例。"
}
