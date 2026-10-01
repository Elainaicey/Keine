#!/usr/bin/env bash

valid_port() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 ))
}

valid_port_range() {
  local value="${1:-}" start end
  if [[ "$value" =~ ^([0-9]+):([0-9]+)$ ]]; then
    start="${BASH_REMATCH[1]}"
    end="${BASH_REMATCH[2]}"
    valid_port "$start" && valid_port "$end" && (( 10#$start <= 10#$end ))
  else
    valid_port "$value"
  fi
}

valid_firewall_rule_spec() {
  local value="${1:-}" ports protocol="tcp"
  ports="$value"
  if [[ "$value" == */* ]]; then
    ports="${value%/*}"
    protocol="${value##*/}"
  fi
  valid_port_range "$ports" && [[ "$protocol" == "tcp" || "$protocol" == "udp" ]]
}

valid_ipv4_address() {
  local value="${1:-}" part
  local parts=()
  IFS='.' read -r -a parts <<<"$value"
  ((${#parts[@]} == 4)) || return 1
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9]{1,3}$ ]] && (( 10#$part <= 255 )) || return 1
  done
}

valid_ipv6_address() {
  local value="${1:-}" left right part
  local left_parts=() right_parts=() parts=()
  [[ -n "$value" && "$value" =~ ^[0-9a-fA-F:]+$ ]] || return 1
  if [[ "$value" == *::* ]]; then
    right="${value#*::}"
    [[ "$right" != *::* ]] || return 1
    left="${value%%::*}"
    if [[ -n "$left" ]]; then IFS=':' read -r -a left_parts <<<"$left"; fi
    if [[ -n "$right" ]]; then IFS=':' read -r -a right_parts <<<"$right"; fi
    ((${#left_parts[@]} + ${#right_parts[@]} < 8)) || return 1
    parts=("${left_parts[@]}" "${right_parts[@]}")
  else
    IFS=':' read -r -a parts <<<"$value"
    ((${#parts[@]} == 8)) || return 1
  fi
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
  done
}

valid_firewall_source() {
  local value="${1:-}" address prefix=""
  [[ "$value" == "any" ]] && return 0
  address="$value"
  if [[ "$value" == */* ]]; then
    address="${value%/*}"
    prefix="${value##*/}"
    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  fi
  if valid_ipv4_address "$address"; then
    [[ -z "$prefix" ]] || (( 10#$prefix <= 32 ))
    return
  fi
  valid_ipv6_address "$address" || return 1
  [[ -z "$prefix" ]] || (( 10#$prefix <= 128 ))
}

valid_service_name() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9@_.:-]*$ ]]
}

valid_package_name() {
  [[ "${1:-}" =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9][a-z0-9-]*)?$ ]]
}

valid_pid() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] && (( 10#$pid >= 2 && 10#$pid <= 4194304 ))
}

valid_nice_value() {
  local value="${1:-}" magnitude numeric
  [[ "$value" =~ ^-?[0-9]+$ ]] || return 1
  if [[ "$value" == -* ]]; then
    magnitude="${value#-}"
    numeric=$((-10#$magnitude))
  else
    numeric=$((10#$value))
  fi
  (( numeric >= -20 && numeric <= 19 ))
}

valid_network_target() {
  local target="${1:-}"
  [[ "$target" =~ ^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,252}$ || "$target" =~ ^[a-fA-F0-9:]+$ ]]
}

valid_http_url() {
  local value="${1:-}" authority
  [[ "${#value}" -le 2048 && "$value" != *[[:space:]]* && "$value" != *[[:cntrl:]]* ]] || return 1
  [[ "$value" == http://* || "$value" == https://* ]] || return 1
  authority="${value#*://}"
  authority="${authority%%/*}"
  authority="${authority%%\?*}"
  authority="${authority%%\#*}"
  [[ -n "$authority" && "$authority" != *@* && "$authority" != -* ]]
}

valid_network_interface() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,14}$ ]]
}

valid_backup_label() {
  local value="${1:-}"
  [[ "${#value}" -le 60 && "$value" != *[[:cntrl:]]* ]]
}

valid_docker_volume_name() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$ ]]
}

safe_managed_path() {
  local path="${1:-}"
  [[ "$path" == /* ]] || return 1
  [[ "$path" != */ && "$path" != *//* && "$path" != *[[:cntrl:]]* ]] || return 1
  [[ "$path" != *'/../'* && "$path" != */.. && "$path" != *'/./'* && "$path" != */. ]] || return 1
  case "$path" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var) return 1 ;;
  esac
  [[ "${path#/}" == */* ]]
}

safe_toolkit_path() {
  local path="${1:-}" component
  local components=()
  safe_managed_path "$path" || return 1
  IFS='/' read -r -a components <<<"${path#/}"
  for component in "${components[@]}"; do
    case "$component" in
      server-toolkit|server-toolkit-*) return 0 ;;
    esac
  done
  return 1
}
