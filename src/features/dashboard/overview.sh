#!/usr/bin/env bash

dashboard_percent() {
  local current="${1:-0}" total="${2:-0}"
  if [[ "$current" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]] && (( total > 0 )); then
    printf '%s' "$((current * 100 / total))"
  else
    printf '0'
  fi
}

dashboard_resource_state() {
  local percent="${1:-0}"
  if [[ "$percent" =~ ^[0-9]+$ ]] && (( percent >= 90 )); then
    printf 'bad'
  elif [[ "$percent" =~ ^[0-9]+$ ]] && (( percent >= 75 )); then
    printf 'warn'
  else
    printf 'good'
  fi
}

dashboard_reboot_required() {
  [[ -f /var/run/reboot-required ]]
}

dashboard_show() {
  platform_detect
  local failed_units running_services listeners upgrades
  local docker_state="未安装" docker_display="未安装" docker_ready=0
  local containers=0 docker_unhealthy=0 docker_restarting=0 docker_issues=0
  local firewall_state="未安装" firewall_display="未安装" firewall_style="warn"
  local fail2ban_state="未安装" fail2ban_display="未安装" fail2ban_style="warn"
  local time_sync="未同步" time_style="warn"
  local root_total root_used root_percent memory_percent memory_style root_style
  local failed_style="good" upgrades_style="good" swap_style="muted"
  local docker_style="muted" backup_style="muted"
  local load_one snapshots=() latest_backup="无" attention=0

  failed_units="$(systemctl --failed --type=service --no-legend 2>/dev/null | grep -c . || true)"
  running_services="$(systemctl --type=service --state=running --no-legend 2>/dev/null | grep -c . || true)"
  listeners=0
  if command_exists ss; then
    listeners="$(ss -H -ltn 2>/dev/null | wc -l | tr -d ' ' || true)"
  fi
  upgrades="$(package_upgradable_count)"

  if command_exists docker; then
    docker_state="$(service_state docker.service)"
    if [[ "$docker_state" == "active" ]] && runtime_with_timeout 5 docker info >/dev/null 2>&1; then
      docker_ready=1
      containers="$(docker ps -q 2>/dev/null | wc -l | tr -d ' ' || true)"
      docker_unhealthy="$(docker ps -q --filter health=unhealthy 2>/dev/null | grep -c . || true)"
      docker_restarting="$(docker ps -q --filter status=restarting 2>/dev/null | grep -c . || true)"
      docker_issues=$((docker_unhealthy + docker_restarting))
      if (( docker_issues > 0 )); then
        docker_display="$containers 运行 · $docker_issues 异常"
      else
        docker_display="$containers 运行中"
      fi
      docker_style="good"
    else
      docker_display="$docker_state"
      docker_style="warn"
    fi
  fi

  firewall_state="$(platform_firewall_backend)"
  firewall_display="$(platform_firewall_label "$firewall_state")"
  case "$firewall_state" in ufw) firewall_style=good ;; iptables|nftables|firewalld) firewall_style=primary ;; esac

  if service_exists fail2ban.service; then
    fail2ban_state="$(service_state fail2ban.service)"
    fail2ban_display="$fail2ban_state"
    if [[ "$fail2ban_state" == "active" ]]; then
      fail2ban_display="运行中"
      fail2ban_style="good"
    fi
  fi

  if command_exists timedatectl &&
    [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == "yes" ]]; then
    time_sync="已同步"
    time_style="good"
  fi

  root_total="$(df -Pm / 2>/dev/null | awk 'NR==2{print $2}')"
  root_used="$(df -Pm / 2>/dev/null | awk 'NR==2{print $3}')"
  root_percent="$(dashboard_percent "${root_used:-0}" "${root_total:-0}")"
  memory_percent="$(dashboard_percent "$MEMORY_USED_MB" "$MEMORY_MB")"
  memory_style="$(dashboard_resource_state "$memory_percent")"
  root_style="$(dashboard_resource_state "$root_percent")"
  load_one="${LOAD_AVERAGE%% *}"
  if [[ "$failed_units" =~ ^[0-9]+$ ]] && (( failed_units > 0 )); then failed_style="bad"; fi
  if [[ "$upgrades" =~ ^[0-9]+$ ]] && (( upgrades > 0 )); then upgrades_style="warn"; fi
  if [[ "$MEMORY_MB" =~ ^[0-9]+$ ]] && (( MEMORY_MB < 1024 )); then swap_style="warn"; fi
  if (( docker_issues > 0 )); then docker_style="bad"; fi

  if declare -F backup_snapshots >/dev/null; then
    mapfile -t snapshots < <(backup_snapshots)
    latest_backup="${snapshots[0]:-无}"
  fi
  if ((${#snapshots[@]} > 0)); then backup_style="good"; fi

  ui_page "运维总览" "按需采集 · $(date '+%Y-%m-%d %H:%M:%S')"
  ui_context "$OS_NAME · $ARCH · $VIRTUALIZATION · $CPU_CORES vCPU · 已运行 $UPTIME_TEXT"

  ui_section "关键指标" "primary"
  ui_metric_row \
    "内存" "${memory_percent}%" "$memory_style" \
    "根分区" "${root_percent}%" "$root_style" \
    "1m 负载" "$load_one" "primary"
  ui_metric_row \
    "运行服务" "$running_services" "good" \
    "失败服务" "$failed_units" "$failed_style" \
    "可更新" "$upgrades" "$upgrades_style"

  ui_section "资源使用" "accent"
  ui_progress "内存" "$MEMORY_USED_MB" "$MEMORY_MB" "MiB"
  if [[ "$SWAP_MB" =~ ^[0-9]+$ ]] && (( SWAP_MB > 0 )); then
    ui_progress "Swap" "$SWAP_USED_MB" "$SWAP_MB" "MiB"
  else
    ui_status "Swap" "未配置" "$swap_style"
  fi
  ui_progress "根分区" "${root_used:-0}" "${root_total:-0}" "MiB"

  ui_section "服务与边界" "primary"
  ui_metric_row \
    "TCP 监听" "$listeners" "primary" \
    "Docker" "$docker_display" "$docker_style" \
    "配置快照" "${#snapshots[@]} 份" "$backup_style"
  ui_hint "最新配置快照：$latest_backup"

  ui_section "基础防护" "accent"
  ui_metric_row \
    "防火墙" "$firewall_display" "$firewall_style" \
    "Fail2ban" "$fail2ban_display" "$fail2ban_style" \
    "系统时间" "$time_sync" "$time_style"

  ui_section "需要关注" "warning"
  if [[ "$failed_units" =~ ^[0-9]+$ ]] && (( failed_units > 0 )); then
    ui_callout "bad" "$failed_units 个服务失败"
    attention=$((attention + 1))
  fi
  if (( root_percent >= 90 )); then
    ui_callout "bad" "根分区使用率 ${root_percent}%"
    attention=$((attention + 1))
  elif (( root_percent >= 75 )); then
    ui_callout "warn" "根分区使用率 ${root_percent}%"
    attention=$((attention + 1))
  fi
  if (( memory_percent >= 90 )); then
    ui_callout "bad" "内存使用率 ${memory_percent}%"
    attention=$((attention + 1))
  elif (( memory_percent >= 75 )); then
    ui_callout "warn" "内存使用率 ${memory_percent}%"
    attention=$((attention + 1))
  fi
  if [[ "$upgrades" =~ ^[0-9]+$ ]] && (( upgrades > 0 )); then
    ui_callout "warn" "$upgrades 个系统软件包可更新"
    attention=$((attention + 1))
  fi
  if [[ "$firewall_state" == unknown || "$firewall_state" == ufw-inactive ]]; then
    ui_callout "warn" "未确认生效的主机防火墙" "检查原生规则与云端访问策略。"
    attention=$((attention + 1))
  fi
  if [[ "$time_sync" != "已同步" ]]; then
    ui_callout "warn" "系统时间尚未同步"
    attention=$((attention + 1))
  fi
  if command_exists docker && (( docker_ready == 0 )); then
    ui_callout "warn" "Docker 已安装但当前不可用"
    attention=$((attention + 1))
  elif (( docker_issues > 0 )); then
    ui_callout "bad" "Docker 有 $docker_issues 个异常容器状态" "包含 $docker_unhealthy 个 unhealthy、$docker_restarting 个 restarting。"
    attention=$((attention + 1))
  fi
  if [[ "$MEMORY_MB" =~ ^[0-9]+$ && "$SWAP_MB" =~ ^[0-9]+$ ]] &&
    (( MEMORY_MB < 1024 && SWAP_MB == 0 )); then
    ui_callout "warn" "低内存主机尚未配置 Swap"
    attention=$((attention + 1))
  fi
  if dashboard_reboot_required; then
    ui_callout "warn" "系统提示需要重启" "先确认业务状态与服务商控制台，再安排维护窗口。"
    attention=$((attention + 1))
  fi
  if (( attention == 0 )); then
    ui_callout "good" "当前未发现明确异常"
  else
    ui_context "$attention 项需要关注"
  fi
}
