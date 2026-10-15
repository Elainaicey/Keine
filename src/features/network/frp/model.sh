#!/usr/bin/env bash

declare -Ag FRP_CONFIG=()
declare -ag FRP_MAPS=()
frp_role_valid() { [[ "${1:-}" == frps || "${1:-}" == frpc ]]; }
frp_name_valid() { [[ "${1:-}" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; }
frp_config_dir() { printf '%s' "${KEINE_FRP_CONFIG_DIR:-/etc/keine-frp}"; }
frp_unit_dir() { printf '%s' "${KEINE_FRP_UNIT_DIR:-/etc/systemd/system}"; }
frp_config_path() { frp_role_valid "$1" && printf '%s/%s.toml' "$(frp_config_dir)" "$1"; }
frp_unit_path() { frp_role_valid "$1" && printf '%s/keine-%s.service' "$(frp_unit_dir)" "$1"; }
frp_binary() { frp_role_valid "$1" && software_release_target "$1"; }
frp_ip_valid() { valid_ipv4_address "$1" || valid_ipv6_address "$1"; }
frp_port_valid() { valid_port "$1" && [[ "$1" == "$((10#$1))" ]]; }

frp_values_valid() {
  local row name type host port remote enabled extra key
  local -A names=() ports=()
  frp_role_valid "${FRP_CONFIG[role]:-}" || return 1
  for key in addr port token active boot; do [[ -n "${FRP_CONFIG[$key]:-}" ]] || return 1; done
  [[ "${FRP_CONFIG[token]}" =~ ^[a-zA-Z0-9_-]{16,128}$ ]] || return 1
  [[ "${FRP_CONFIG[active]}" =~ ^[01]$ && "${FRP_CONFIG[boot]}" =~ ^[01]$ ]] || return 1
  frp_port_valid "${FRP_CONFIG[port]}" || return 1
  if [[ "${FRP_CONFIG[role]}" == frps ]]; then
    frp_ip_valid "${FRP_CONFIG[addr]}" && frp_ip_valid "${FRP_CONFIG[proxy_addr]:-}" || return 1
    frp_port_valid "${FRP_CONFIG[first]:-}" && frp_port_valid "${FRP_CONFIG[last]:-}" || return 1
    (( FRP_CONFIG[first] <= FRP_CONFIG[last] )) || return 1
    (( FRP_CONFIG[port] < FRP_CONFIG[first] || FRP_CONFIG[port] > FRP_CONFIG[last] )) || return 1
    (( ${#FRP_MAPS[@]} == 0 )) || return 1
  else
    valid_network_target "${FRP_CONFIG[addr]}" && frp_name_valid "${FRP_CONFIG[user]:-}" || return 1
    [[ "${FRP_CONFIG[addr]}" != 0.0.0.0 && "${FRP_CONFIG[addr]}" != :: ]] || return 1
  fi
  (( ${#FRP_MAPS[@]} <= 64 )) || return 1
  for row in "${FRP_MAPS[@]}"; do
    IFS='|' read -r name type host port remote enabled extra <<<"$row"
    [[ "$row" == "$name|$type|$host|$port|$remote|$enabled" && -z "$extra" ]] || return 1
    frp_name_valid "$name" && [[ "$type" == tcp || "$type" == udp ]] || return 1
    valid_network_target "$host" && [[ "$host" != 0.0.0.0 && "$host" != :: ]] || return 1
    frp_port_valid "$port" && frp_port_valid "$remote" && [[ "$enabled" =~ ^[01]$ ]] || return 1
    [[ ! -v 'names[$name]' ]] || return 1; names[$name]=1
    if [[ "$enabled" == 1 ]]; then
      key="$type:$remote"; [[ ! -v 'ports[$key]' ]] || return 1; ports[$key]=1
      [[ "$type" != tcp || "$remote" != "${FRP_CONFIG[port]}" ]] || return 1
    fi
  done
}

frp_render_config() {
  frp_values_valid || return 1
  local field row name type host port remote enabled
  printf '# Managed by keine\n# keine-frp-v1\n'
  for field in role addr port proxy_addr first last user active boot; do
    [[ ! -v 'FRP_CONFIG[$field]' ]] || printf '# frp.%s=%s\n' "$field" "${FRP_CONFIG[$field]}"
  done
  for row in "${FRP_MAPS[@]}"; do printf '# frp.map=%s\n' "$row"; done
  printf 'auth.method = "token"\nauth.token = "%s"\n' "${FRP_CONFIG[token]}"
  printf 'auth.additionalScopes = ["HeartBeats", "NewWorkConns"]\n'
  printf 'log.to = "console"\nlog.level = "info"\nlog.disablePrintColor = true\n'
  if [[ "${FRP_CONFIG[role]}" == frps ]]; then
    printf 'bindAddr = "%s"\nbindPort = %s\nproxyBindAddr = "%s"\n' "${FRP_CONFIG[addr]}" "${FRP_CONFIG[port]}" "${FRP_CONFIG[proxy_addr]}"
    printf 'allowPorts = [{start = %s, end = %s}]\nmaxPortsPerClient = 64\ntransport.tls.force = true\ndetailedErrorsToClient = false\n' "${FRP_CONFIG[first]}" "${FRP_CONFIG[last]}"
  else
    printf 'serverAddr = "%s"\nserverPort = %s\nuser = "%s"\nloginFailExit = true\ntransport.protocol = "tcp"\ntransport.tls.enable = true\n' "${FRP_CONFIG[addr]}" "${FRP_CONFIG[port]}" "${FRP_CONFIG[user]}"
    for row in "${FRP_MAPS[@]}"; do
      IFS='|' read -r name type host port remote enabled <<<"$row"
      [[ "$enabled" == 1 ]] || continue
      printf '\n[[proxies]]\nname = "%s"\ntype = "%s"\nlocalIP = "%s"\nlocalPort = %s\nremotePort = %s\n' "$name" "$type" "$host" "$port" "$remote"
    done
  fi
}

frp_load() {
  local role="$1" path line field value
  path="$(frp_config_path "$role")" || return 1
  config_file_safe "$path" && [[ -f "$path" ]] || return 1
  FRP_CONFIG=(); FRP_MAPS=()
  while IFS= read -r line; do
    case "$line" in
      '# frp.map='*) FRP_MAPS+=("${line#*=}") ;;
      '# frp.'*)
        field="${line#\# frp.}"; value="${field#*=}"; field="${field%%=*}"
        case "$field" in role|addr|port|proxy_addr|first|last|user|active|boot) ;; *) return 1 ;; esac
        [[ ! -v 'FRP_CONFIG[$field]' ]] || return 1; FRP_CONFIG[$field]="$value" ;;
      'auth.token = "'*'"')
        [[ ! -v 'FRP_CONFIG[token]' ]] || return 1
        value="${line#auth.token = \"}"; FRP_CONFIG[token]="${value%\"}" ;;
    esac
  done <"$path"
  [[ "${FRP_CONFIG[role]:-}" == "$role" ]] && frp_values_valid
}

frp_render_unit() {
  local role="$1" binary config
  binary="$(frp_binary "$role")" && config="$(frp_config_path "$role")" || return 1
  # Paths also appear in systemd syntax; reject specifiers, whitespace and escapes.
  [[ "$binary" =~ ^/[a-zA-Z0-9_./-]+$ && "$config" =~ ^/[a-zA-Z0-9_./-]+$ ]] || return 1
  cat <<EOF
# Managed by keine
[Unit]
Description=keine FRP / $role
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart=$binary -c $config
Restart=on-failure
RestartSec=5
TimeoutStopSec=15
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
}

frp_owned() (
  local role="$1" path entry
  frp_load "$role" || { warn "FRP 配置不完整或无法识别。"; return 1; }
  path="$(frp_config_path "$role")"
  [[ "$(<"$path")" == "$(frp_render_config)" ]] || { warn "FRP 配置已被外部修改。"; return 1; }
  path="$(frp_unit_path "$role")"
  config_file_safe "$path" && [[ -f "$path" && "$(<"$path")" == "$(frp_render_unit "$role")" ]] || return 1
  for path in "$(frp_config_path "$role")" "$(frp_unit_path "$role")"; do
    entry="$(changes_file_entry "$path")"
    [[ -f "$entry/before" && "$(<"$entry/before")" == absent ]] || { warn "FRP 资源缺少项目创建记录。"; return 1; }
    case "$(changes_file_status "$entry")" in ready|unchanged) ;; *) warn "FRP 资源存在外部修改冲突。"; return 1 ;; esac
  done
)

frp_role_recorded() {
  local role="$1"
  [[ -d "$(changes_file_entry "$(frp_config_path "$role")")" || -d "$(changes_file_entry "$(frp_unit_path "$role")")" ]]
}

frp_recovery_role() {
  local path="$1" role
  for role in frps frpc; do
    if [[ "$path" == "$(frp_config_path "$role")" || "$path" == "$(frp_unit_path "$role")" ]]; then printf '%s' "$role"; return 0; fi
  done
  return 1
}
