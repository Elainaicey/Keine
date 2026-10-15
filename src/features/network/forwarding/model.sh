#!/usr/bin/env bash

declare -Ag FORWARD_RULE=()
forward_dir() { printf '%s' "${KEINE_FORWARD_UNITS:-/etc/systemd/system}"; }
forward_id_valid() { [[ "${1:-}" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; }
forward_path() { forward_id_valid "$1" && printf '%s/keine-forward-%s.service' "$(forward_dir)" "$1"; }
forward_address_valid() {
  local part parts=()
  if valid_ipv4_address "$1"; then
    IFS='.' read -r -a parts <<<"$1"
    for part in "${parts[@]}"; do [[ "$part" == "$((10#$part))" ]] || return 1; done
  else valid_ipv6_address "$1"; fi
}

forward_values_valid() {
  forward_id_valid "${FORWARD_RULE[id]:-}" || return 1
  [[ "${FORWARD_RULE[protocol]:-}" == tcp || "${FORWARD_RULE[protocol]:-}" == udp ]] || return 1
  forward_address_valid "${FORWARD_RULE[listen]:-}" && forward_address_valid "${FORWARD_RULE[target]:-}" || return 1
  valid_port "${FORWARD_RULE[port]:-}" && valid_port "${FORWARD_RULE[target_port]:-}" || return 1
  [[ "${FORWARD_RULE[active]:-}" =~ ^[01]$ && "${FORWARD_RULE[boot]:-}" =~ ^[01]$ ]] || return 1
  [[ "${FORWARD_RULE[idle]:-}" =~ ^[1-9][0-9]{0,3}$ ]] && (( FORWARD_RULE[idle] <= 3600 )) || return 1
  [[ "${FORWARD_RULE[target]}" != 0.0.0.0 && "${FORWARD_RULE[target]}" != :: ]] || return 1
  [[ "${FORWARD_RULE[listen]}:${FORWARD_RULE[port]}" != "${FORWARD_RULE[target]}:${FORWARD_RULE[target_port]}" ]]
}

forward_render() {
  forward_values_valid || return 1
  local field listen target proto="${FORWARD_RULE[protocol]^^}" family=4 target_family=4 timeout=''
  [[ "${FORWARD_RULE[listen]}" != *:* ]] || family=6
  [[ "${FORWARD_RULE[target]}" != *:* ]] || target_family=6
  listen="${FORWARD_RULE[listen]}"; target="${FORWARD_RULE[target]}"
  [[ "$family" != 6 ]] || listen="[$listen]"
  [[ "$target_family" != 6 ]] || target="[$target]"
  listen="$proto$family-LISTEN:${FORWARD_RULE[port]},bind=$listen,reuseaddr,fork,max-children=128"
  [[ "$family" != 6 ]] || listen+=",ipv6only=1"
  target="$proto$target_family:$target:${FORWARD_RULE[target_port]}"
  if [[ "$proto" == UDP ]]; then timeout=" -T${FORWARD_RULE[idle]}"
  else target+=",connect-timeout=10"; fi
  printf '# Managed by keine\n# keine-forward-v1\n'
  for field in id protocol listen port target target_port active boot idle; do
    printf '# forward.%s=%s\n' "$field" "${FORWARD_RULE[$field]}"
  done
  cat <<EOF
[Unit]
Description=keine ${FORWARD_RULE[protocol]} forwarding / ${FORWARD_RULE[id]}
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
ExecStart=/usr/bin/socat -d -d -b65535$timeout $listen $target
Restart=on-failure
RestartSec=3
KillMode=control-group
TimeoutStopSec=10
DynamicUser=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
TasksMax=160
LimitNOFILE=1024

[Install]
WantedBy=multi-user.target
EOF
}

forward_load() {
  local path="$1" line field value
  [[ -f "$path" && ! -L "$path" ]] || return 1
  FORWARD_RULE=()
  while IFS= read -r line; do
    [[ "$line" == '# forward.'* ]] || continue
    field="${line#\# forward.}"; value="${field#*=}"; field="${field%%=*}"
    case "$field" in id|protocol|listen|port|target|target_port|active|boot|idle) ;; *) return 1 ;; esac
    [[ ! -v 'FORWARD_RULE[$field]' ]] || return 1
    FORWARD_RULE[$field]="$value"
  done <"$path"
  forward_values_valid && [[ "$path" == "$(forward_path "${FORWARD_RULE[id]}")" ]]
}

forward_paths() {
  local path
  for path in "$(forward_dir)"/keine-forward-*.service; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    printf '%s\n' "$path"
  done
}

forward_owned() (
  local path="$1" entry
  if ! config_file_safe "$path" || ! forward_load "$path"; then warn "规则路径或元数据无效。"; return 1; fi
  [[ "$(<"$path")" == "$(forward_render)" ]] || { warn "规则已被外部修改，拒绝覆盖。"; return 1; }
  entry="$(changes_file_entry "$path")"
  [[ -f "$entry/before" && "$(<"$entry/before")" == absent ]] || { warn "规则缺少项目创建记录。"; return 1; }
  case "$(changes_file_status "$entry")" in ready|unchanged) ;; *) warn "规则存在外部修改冲突。"; return 1 ;; esac
)
