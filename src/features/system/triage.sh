#!/usr/bin/env bash

TRIAGE_PASS=0
TRIAGE_WARN=0
TRIAGE_FAIL=0

system_triage_result() {
  local state="$1" message="$2" hint="${3:-}"
  case "$state" in
    pass) TRIAGE_PASS=$((TRIAGE_PASS + 1)) ;;
    warn) TRIAGE_WARN=$((TRIAGE_WARN + 1)) ;;
    fail) TRIAGE_FAIL=$((TRIAGE_FAIL + 1)) ;;
    *) return 1 ;;
  esac
  ui_check "$state" "$message"
  [[ -z "$hint" ]] || printf '    %b↳ %s%b\n' "$MUTED" "$hint" "$NC"
}

system_triage_report() {
  local failed_units updates recent_errors oom_count root_free inode_percent memory_percent
  local listeners=0 docker_installed=0 docker_ready=0 docker_unhealthy=0 docker_restarting=0
  local snapshots=() protected=0 snapshot
  TRIAGE_PASS=0; TRIAGE_WARN=0; TRIAGE_FAIL=0
  platform_detect
  failed_units="$(systemctl --failed --no-legend 2>/dev/null | grep -c . || true)"
  updates="$(package_upgradable_count)"
  recent_errors="$(journalctl -p err --since "-1 hour" --no-pager 2>/dev/null | grep -c . || true)"
  oom_count="$(journalctl -k -b --no-pager 2>/dev/null | grep -Eic 'out of memory|oom-killer|killed process' || true)"
  root_free="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
  inode_percent="$(df -Pi / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5);print $5}')"
  memory_percent=0
  if [[ "$MEMORY_USED_MB" =~ ^[0-9]+$ && "$MEMORY_MB" =~ ^[0-9]+$ ]] && (( MEMORY_MB > 0 )); then
    memory_percent=$((MEMORY_USED_MB * 100 / MEMORY_MB))
  fi
  if declare -F security_exposure_listener_rows >/dev/null; then
    listeners="$(security_exposure_listener_rows 2>/dev/null | grep -c . || true)"
  fi
  if command_exists docker; then
    docker_installed=1
    if runtime_with_timeout 5 docker info >/dev/null 2>&1; then
      docker_ready=1
      docker_unhealthy="$(docker ps -q --filter health=unhealthy 2>/dev/null | grep -c . || true)"
      docker_restarting="$(docker ps -q --filter status=restarting 2>/dev/null | grep -c . || true)"
    fi
  fi
  mapfile -t snapshots < <(backup_snapshots)
  for snapshot in "${snapshots[@]}"; do
    backup_snapshot_protected "$snapshot" && protected=$((protected + 1))
  done

  ui_page "故障快速排查" "资源、服务、日志、网络、容器与恢复能力的当前快照"
  ui_context "$(date '+%F %T %Z') · $OS_NAME · $ARCH · $VIRTUALIZATION"
  ui_section "资源" "primary"
  ui_progress "内存" "$MEMORY_USED_MB" "$MEMORY_MB" "MiB"
  ui_kv "负载" "$LOAD_AVERAGE / $CPU_CORES vCPU"
  ui_kv "根分区" "使用 ${ROOT_USED_PERCENT:-未知}% · 可用 ${root_free:-未知} MiB"
  ui_kv "inode" "使用 ${inode_percent:-未知}%"
  if (( memory_percent >= 95 )); then
    system_triage_result fail "内存使用率 ${memory_percent}%"
  elif (( memory_percent >= 80 )); then
    system_triage_result warn "内存使用率 ${memory_percent}%"
  else
    system_triage_result pass "内存余量正常"
  fi
  if [[ "$ROOT_USED_PERCENT" =~ ^[0-9]+$ ]] && (( ROOT_USED_PERCENT >= 95 )); then
    system_triage_result fail "根分区使用率 ${ROOT_USED_PERCENT}%"
  elif [[ "$ROOT_USED_PERCENT" =~ ^[0-9]+$ ]] && (( ROOT_USED_PERCENT >= 85 )); then
    system_triage_result warn "根分区使用率 ${ROOT_USED_PERCENT}%"
  else
    system_triage_result pass "根分区空间未达到关注阈值"
  fi
  if [[ "$inode_percent" =~ ^[0-9]+$ ]] && (( inode_percent >= 90 )); then
    system_triage_result warn "inode 使用率 ${inode_percent}%"
  else
    system_triage_result pass "inode 余量正常"
  fi

  ui_section "服务与日志" "accent"
  if (( failed_units > 0 )); then
    system_triage_result fail "$failed_units 个 systemd 单元失败" "进入服务中心查看失败诊断"
  else
    system_triage_result pass "没有失败的 systemd 单元"
  fi
  if (( recent_errors >= 20 )); then
    system_triage_result warn "最近 1 小时有 $recent_errors 条 err 级 Journal"
  else
    system_triage_result pass "最近 1 小时 err 级 Journal：$recent_errors 条"
  fi
  if (( oom_count > 0 )); then
    system_triage_result warn "本次启动检测到 $oom_count 条 OOM 相关日志"
  else
    system_triage_result pass "本次启动未检测到 OOM"
  fi

  ui_section "维护与暴露" "primary"
  ui_kv "公网监听" "$listeners 个"
  ui_kv "可更新软件包" "$updates 个"
  ui_kv "配置快照" "${#snapshots[@]} 份 · $protected 份受保护"
  if [[ -f /var/run/reboot-required ]]; then
    system_triage_result warn "系统提示需要重启"
  else
    system_triage_result pass "没有待处理的重启提示"
  fi
  if [[ "$updates" =~ ^[0-9]+$ ]] && (( updates >= 50 )); then
    system_triage_result warn "$updates 个软件包可更新"
  else
    system_triage_result pass "软件包更新积压未达到 50 个"
  fi
  if ((${#snapshots[@]} > 0)); then
    system_triage_result pass "存在可用的配置快照 · 最新 ${snapshots[0]}"
  else
    system_triage_result warn "还没有配置快照" "只有发生配置修改或手动备份后才会创建"
  fi
  if (( docker_unhealthy + docker_restarting > 0 )); then
    system_triage_result fail "Docker：$docker_unhealthy 个 unhealthy，$docker_restarting 个 restarting"
  elif (( docker_ready == 1 )); then
    system_triage_result pass "Docker 未检测到 unhealthy 或 restarting 容器"
  elif (( docker_installed == 1 )); then
    system_triage_result warn "Docker Daemon 在 5 秒内不可用" "检查 docker.service 状态或 Socket 权限"
  fi

  ui_section "排查结论" "accent"
  ui_health_summary "$TRIAGE_PASS" "$TRIAGE_WARN" "$TRIAGE_FAIL"
  if (( TRIAGE_FAIL > 0 )); then
    ui_danger "检测到 $TRIAGE_FAIL 项明确异常，建议从失败服务、资源和近期日志开始。"
  elif (( TRIAGE_WARN > 0 )); then
    ui_note "当前没有明确故障，但有 $TRIAGE_WARN 项值得继续核实。"
  else
    ui_success "当前快速排查项没有发现异常"
  fi
  ui_note "该报告只读取当前状态，不会自动修复、重启或清理系统。"
}

system_triage() {
  local interactive="${1:-1}" choice
  while true; do
    system_triage_report
    [[ "$interactive" -eq 1 ]] || return 0
    ui_section "继续定位" "primary"
    ui_action_pair 1 "失败服务" "danger" 2 "Journal 查询" "action"
    ui_action_pair 3 "进程与资源" "action" 4 "存储中心" "action"
    ui_action_pair 5 "网络诊断" "action" 6 "安全基线" "action"
    if command_exists docker; then ui_action 7 "Docker 健康" "action"; else ui_action 7 "Docker 健康" "disabled" "Docker 未安装"; fi
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      1) services_failed ;;
      2) services_journal_query || true ;;
      3) system_processes; continue ;;
      4) system_disk_usage; continue ;;
      5) network_menu; continue ;;
      6) security_audit ;;
      7) if command_exists docker; then docker_health; else warn "Docker 未安装。"; fi ;;
      0) return 0 ;;
      *) warn "未知选项：$choice"; continue ;;
    esac
    pause
  done
}
