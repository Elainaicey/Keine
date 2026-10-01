#!/usr/bin/env bash

declare -Ag SECURITY_EXPOSURE_DOCKER_OWNERS=()
SECURITY_EXPOSURE_UFW_STATUS=""

security_exposure_parse_ss() {
  awk '
    {
      protocol=tolower($1)
      local_address=$5
      port=local_address
      sub(/^.*:/, "", port)
      address=substr(local_address, 1, length(local_address)-length(port)-1)
      gsub(/^\[/, "", address)
      gsub(/\]$/, "", address)
      if (address != "0.0.0.0" && address != "::" && address != "*") next
      if (port !~ /^[0-9]+$/ || port < 1 || port > 65535) next

      process="—"
      pid="—"
      raw=$0
      if (raw ~ /users:\(\("/) {
        process=raw
        sub(/^.*users:\(\("/, "", process)
        sub(/".*$/, "", process)
      }
      if (raw ~ /pid=[0-9]+/) {
        pid=raw
        sub(/^.*pid=/, "", pid)
        sub(/[^0-9].*$/, "", pid)
      }
      gsub(/\|/, "/", process)
      print protocol "|" address "|" port "|" process "|" pid
    }
  '
}

security_exposure_listener_rows() {
  command_exists ss || return 1
  ss -H -lntup 2>/dev/null | security_exposure_parse_ss |
    sort -t '|' -k3,3n -k1,1 -u
}

security_exposure_parse_docker_ports() {
  local line name ports binding host host_address container protocol port
  while IFS= read -r line; do
    name="${line%%|*}"
    ports="${line#*|}"
    [[ "$line" == *'|'* && "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || continue
    while IFS= read -r binding; do
      binding="${binding#"${binding%%[![:space:]]*}"}"
      binding="${binding%"${binding##*[![:space:]]}"}"
      [[ "$binding" == *'->'* ]] || continue
      host="${binding%%->*}"
      container="${binding#*->}"
      protocol="${container##*/}"
      port="${host##*:}"
      host_address="${host%:*}"
      host_address="${host_address#[}"
      host_address="${host_address%]}"
      [[ "$protocol" == "tcp" || "$protocol" == "udp" ]] || continue
      [[ "$host_address" == "0.0.0.0" || "$host_address" == "::" || "$host_address" == "*" ]] || continue
      valid_port "$port" || continue
      printf '%s|%s|%s\n' "$protocol" "$port" "$name"
    done < <(tr ',' '\n' <<<"$ports")
  done
}

security_exposure_load_docker() {
  local protocol port container key current
  SECURITY_EXPOSURE_DOCKER_OWNERS=()
  command_exists docker || return 0
  while IFS='|' read -r protocol port container; do
    [[ -n "$protocol" && -n "$port" && -n "$container" ]] || continue
    key="$protocol/$port"
    current="${SECURITY_EXPOSURE_DOCKER_OWNERS[$key]:-}"
    case ",$current," in
      *",$container,"*) ;;
      *) SECURITY_EXPOSURE_DOCKER_OWNERS["$key"]="${current:+$current,}$container" ;;
    esac
  done < <(docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null | security_exposure_parse_docker_ports)
}

security_exposure_unit_for_pid() {
  local pid="${1:-}" cgroup_root="${KEINE_PROC_ROOT:-/proc}"
  [[ "$pid" =~ ^[0-9]+$ ]] && (( 10#$pid >= 1 && 10#$pid <= 4194304 )) || return 1
  [[ -r "$cgroup_root/$pid/cgroup" ]] || return 1
  awk -F/ '
    {
      for (field=NF; field>=1; field--) {
        if ($field ~ /^[a-zA-Z0-9@_.:-]+[.]service$/) {
          print $field
          exit
        }
      }
    }
  ' "$cgroup_root/$pid/cgroup"
}

security_exposure_load_ufw() {
  SECURITY_EXPOSURE_UFW_STATUS=""
  command_exists ufw || return 0
  SECURITY_EXPOSURE_UFW_STATUS="$(ufw status 2>/dev/null || true)"
}

security_exposure_ufw_rule_state() {
  local port="$1" protocol="$2" status="${3:-$SECURITY_EXPOSURE_UFW_STATUS}"
  if [[ -z "$status" ]]; then
    printf 'unavailable'
    return 0
  fi
  if ! grep -q '^Status: active' <<<"$status"; then
    printf 'inactive'
    return 0
  fi
  awk -v target="$port/$protocol" -v bare="$port" '
    {
      line=$0
      sub(/^[[:space:]]*\[[[:space:]]*[0-9]+\][[:space:]]*/, "", line)
      count=split(line, fields, /[[:space:]]+/)
      if (fields[1] != target && fields[1] != bare) next
      for (field=2; field<=count; field++) {
        if (fields[field] ~ /^ALLOW/) {print "allow"; exit}
        if (fields[field] ~ /^(DENY|REJECT)/) {print "deny"; exit}
      }
    }
  ' <<<"$status" | {
    read -r state || true
    printf '%s' "${state:-review}"
  }
}

security_exposure_firewall_label() {
  case "$1" in
    allow) printf 'UFW 已显式放行' ;;
    deny) printf 'UFW 已显式拒绝' ;;
    inactive) printf 'UFW 未启用' ;;
    unavailable) printf 'UFW 未安装' ;;
    *) printf '未发现精确规则，需核对' ;;
  esac
}

security_exposure_owner() {
  local protocol="$1" port="$2" process="$3" pid="$4" key unit docker_owner
  key="$protocol/$port"
  docker_owner="${SECURITY_EXPOSURE_DOCKER_OWNERS[$key]:-}"
  if [[ -n "$docker_owner" ]]; then
    printf 'Docker 容器 · %s' "${docker_owner//,/, }"
    return 0
  fi
  unit="$(security_exposure_unit_for_pid "$pid" 2>/dev/null || true)"
  if [[ -n "$unit" ]]; then
    printf 'systemd · %s' "$unit"
  elif [[ "$process" != "—" ]]; then
    printf '进程 · %s%s' "$process" "$([[ "$pid" == "—" ]] || printf ' · PID %s' "$pid")"
  else
    printf '归属未知'
  fi
}

security_exposure_analysis() {
  local interactive="${1:-1}" protocol address port process pid owner firewall_state
  local count=0 allowed=0 denied=0 review=0 docker_count=0 input
  command_exists ss || { warn "缺少 ss 命令，无法分析监听端口。"; return 1; }
  while true; do
    count=0; allowed=0; denied=0; review=0; docker_count=0
    security_exposure_load_docker
    security_exposure_load_ufw
    ui_page "公网暴露分析" "关联监听地址、进程、systemd、Docker 与 UFW 精确规则"
    ui_note "这里只识别监听所有本机地址的套接字；云防火墙、NAT 和上游网络策略仍需单独核对。"
    while IFS='|' read -r protocol address port process pid; do
      [[ -n "$protocol" ]] || continue
      process="$(terminal_safe_text "$process")"
      count=$((count + 1))
      owner="$(security_exposure_owner "$protocol" "$port" "$process" "$pid")"
      firewall_state="$(security_exposure_ufw_rule_state "$port" "$protocol")"
      case "$firewall_state" in
        allow) allowed=$((allowed + 1)) ;;
        deny) denied=$((denied + 1)) ;;
        *) review=$((review + 1)) ;;
      esac
      [[ "$owner" == Docker* ]] && docker_count=$((docker_count + 1))
      printf '\n  %b◆%b %b%s/%s%b  %b%s:%s%b\n' \
        "$MAGENTA" "$NC" "$CYAN$BOLD" "${protocol^^}" "$port" "$NC" "$WHITE" "$address" "$port" "$NC"
      printf '    %b归属%b      %s\n' "$BLUE" "$NC" "$owner"
      printf '    %b监听进程%b  %s%s\n' "$BLUE" "$NC" "$process" "$([[ "$pid" == "—" ]] || printf ' · PID %s' "$pid")"
      printf '    %b防火墙%b    %s\n' "$BLUE" "$NC" "$(security_exposure_firewall_label "$firewall_state")"
    done < <(security_exposure_listener_rows)
    if (( count == 0 )); then
      ui_empty "没有检测到监听所有 IPv4/IPv6 地址的端口"
    fi
    ui_stats "公网监听" "$count" "显式放行" "$allowed" "需核对" "$review"
    ui_context "显式拒绝 $denied 项 · Docker 发布 $docker_count 项"
    [[ "$interactive" -eq 1 ]] || return 0
    ui_section "后续操作" "accent"
    ui_action F "打开 UFW 管理" "action" "查看、添加或删除主机防火墙规则"
    ui_action R "重新扫描" "success" "重新读取监听端口、容器和规则"
    ui_action 0 "返回安全中心" "muted"
    input="$(read_input "请选择" "0")"
    case "$input" in
      F|f) security_firewall_manage ;;
      R|r) continue ;;
      0) return 0 ;;
      *) warn "未知选项：$input" ;;
    esac
  done
}
