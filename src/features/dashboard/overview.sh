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

  if command_exists ufw; then
    firewall_state="inactive"
    firewall_display="未启用"
  fi
  if platform_firewall_active; then
    firewall_state="active"
    firewall_display="已启用"
    firewall_style="good"
  fi

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
    "UFW" "$firewall_display" "$firewall_style" \
    "Fail2ban" "$fail2ban_display" "$fail2ban_style" \
    "系统时间" "$time_sync" "$time_style"

  ui_section "需要关注" "warning"
  if [[ "$failed_units" =~ ^[0-9]+$ ]] && (( failed_units > 0 )); then
    ui_callout "bad" "$failed_units 个服务失败" "进入失败服务清单查看退出原因、日志和生命周期操作。"
    attention=$((attention + 1))
  fi
  if (( root_percent >= 90 )); then
    ui_callout "bad" "根分区使用率 ${root_percent}%" "进入存储中心定位大目录、已删除占用和 APT 缓存。"
    attention=$((attention + 1))
  elif (( root_percent >= 75 )); then
    ui_callout "warn" "根分区使用率 ${root_percent}%" "空间已进入关注区间，可按需运行一次存储分析。"
    attention=$((attention + 1))
  fi
  if (( memory_percent >= 90 )); then
    ui_callout "bad" "内存使用率 ${memory_percent}%" "进入进程与资源页定位高占用进程，避免直接猜测性终止。"
    attention=$((attention + 1))
  elif (( memory_percent >= 75 )); then
    ui_callout "warn" "内存使用率 ${memory_percent}%" "建议查看进程排行与 OOM 记录。"
    attention=$((attention + 1))
  fi
  if [[ "$upgrades" =~ ^[0-9]+$ ]] && (( upgrades > 0 )); then
    ui_callout "warn" "$upgrades 个系统软件包可更新" "软件包健康中心会列出版本与安全更新；不会自动全量升级。"
    attention=$((attention + 1))
  fi
  if [[ "$firewall_state" != "active" ]]; then
    ui_callout "warn" "UFW 防火墙未启用" "启用前先确认当前 SSH 端口和业务端口，避免中断远程访问。"
    attention=$((attention + 1))
  fi
  if [[ "$time_sync" != "已同步" ]]; then
    ui_callout "warn" "系统时间尚未同步" "时间偏差会影响 TLS、日志定位和软件仓库验证。"
    attention=$((attention + 1))
  fi
  if command_exists docker && (( docker_ready == 0 )); then
    ui_callout "warn" "Docker 已安装但当前不可用" "进入应用与容器中心检查服务状态、配置和最近日志。"
    attention=$((attention + 1))
  elif (( docker_issues > 0 )); then
    ui_callout "bad" "Docker 有 $docker_issues 个异常容器状态" "包含 $docker_unhealthy 个 unhealthy、$docker_restarting 个 restarting。"
    attention=$((attention + 1))
  fi
  if [[ "$MEMORY_MB" =~ ^[0-9]+$ && "$SWAP_MB" =~ ^[0-9]+$ ]] &&
    (( MEMORY_MB < 1024 && SWAP_MB == 0 )); then
    ui_callout "warn" "低内存主机尚未配置 Swap" "可在系统管理中创建带所有权记录、可安全移除的 Swap 文件。"
    attention=$((attention + 1))
  fi
  if dashboard_reboot_required; then
    ui_callout "warn" "系统提示需要重启" "先确认业务状态与服务商控制台，再安排维护窗口。"
    attention=$((attention + 1))
  fi
  if (( attention == 0 )); then
    ui_callout "good" "当前总览没有发现明确异常" "仍可运行故障快速排查获取更深入的一次性诊断。"
  else
    ui_hint "共 $attention 项需要核实；总览只读取状态，不会自动修复或启动后台监控。"
  fi
}
