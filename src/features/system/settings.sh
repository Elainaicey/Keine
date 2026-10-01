#!/usr/bin/env bash

system_hostname_apply() {
  run hostnamectl set-hostname "$name" || return 1
  [[ "$(hostname -s 2>/dev/null || true)" == "$name" ]]
}

system_hostname_rollback() { run hostnamectl set-hostname "$current"; }

system_set_hostname() {
  local current name payload
  ui_page "修改主机名" "同步 hosts 与 hostnamectl；应用失败时回退本次修改"
  ui_hint "例如 web-01；仅使用字母、数字和中间短横线，最长 63 字符。"
  current="$(hostname -s 2>/dev/null || hostname)"; name="$(read_input "新主机名" "$current")"
  [[ "$name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || { warn "主机名格式无效。"; return 1; }
  [[ "$name" != "$current" ]] || { info "主机名未变化。"; return 0; }
  confirm "将主机名从 $current 修改为 $name？" || return 0; require_root
  changes_prepare_file /etc/hostname || return 1
  payload="$(awk -v name="$name" 'BEGIN{changed=0}$1=="127.0.1.1"{print "127.0.1.1 "name;changed=1;next}{print}END{if(!changed)print "127.0.1.1 "name}' /etc/hosts)" || {
    warn "无法生成新的 /etc/hosts。"; return 1;
  }
  config_file_write /etc/hosts 0644 "$payload" system_hostname_apply system_hostname_rollback || return 1
  audit "action=set-hostname value=$name"
  ui_success "主机名已修改为 $name"
}

system_set_timezone() {
  local current timezone
  ui_page "修改时区" "使用系统 zoneinfo 数据库配置时区"
  ui_hint "例如 Asia/Shanghai、Etc/UTC，可用 timedatectl list-timezones 查询。"
  current="$(timedatectl show -p Timezone --value 2>/dev/null || printf 'Etc/UTC')"; timezone="$(read_input "时区" "$current")"
  [[ -f "/usr/share/zoneinfo/$timezone" ]] || { warn "不存在的时区：$timezone"; return 1; }
  [[ "$timezone" != "$current" ]] || { info "时区未变化。"; return 0; }
  confirm "将时区修改为 $timezone？" || return 0
  require_root
  changes_prepare_file /etc/timezone || return 1
  run timedatectl set-timezone "$timezone" || { warn "时区修改失败。"; return 1; }
  if [[ "$DRY_RUN" -eq 0 && "$(timedatectl show -p Timezone --value 2>/dev/null || true)" != "$timezone" ]]; then
    warn "系统没有确认新的时区。"
    return 1
  fi
  audit "action=set-timezone value=$timezone"
  ui_success "系统时区已修改为 $timezone"
}

system_swap_marker() {
  printf '%s/swapfile.managed' "$STATE_ROOT"
}

system_owned_file_matches() {
  local marker="$1" expected_path="$2" recorded_identity current_identity
  [[ -r "$marker" && -f "$expected_path" && ! -L "$expected_path" ]] || return 1
  grep -Fqx "path=$expected_path" "$marker" || return 1
  recorded_identity="$(sed -n 's/^identity=//p' "$marker" | head -n 1)"
  current_identity="$(stat -c '%d:%i' "$expected_path" 2>/dev/null || true)"
  [[ "$recorded_identity" =~ ^[0-9]+:[0-9]+$ && "$recorded_identity" == "$current_identity" ]]
}

system_swap_managed() {
  system_owned_file_matches "$(system_swap_marker)" /swapfile
}

system_swap_active() {
  swapon --show=NAME --noheadings 2>/dev/null | awk '{$1=$1;print}' | grep -Fxq /swapfile
}

system_swap_creation_rollback() {
  local marker="$1" fstab_existed="$2" previous_fstab="$3"
  [[ "$DRY_RUN" -eq 0 ]] || return 0
  if system_swap_active && ! swapoff /swapfile; then
    warn "Swap 已启用但无法回滚停用；为避免损坏，已保留 /swapfile 和状态记录。"
    return 1
  fi
  rm -f -- /swapfile "$marker" || return 1
  if [[ "$fstab_existed" -eq 1 ]]; then
    [[ -n "$previous_fstab" && -f "$previous_fstab" ]] || return 1
    cp -p "$previous_fstab" /etc/fstab || return 1
  else
    rm -f -- /etc/fstab || return 1
  fi
}

system_create_swap() (
  local size_mb marker identity fstab_existed=0 previous_fstab=""
  trap '[[ -z "$previous_fstab" ]] || rm -f -- "$previous_fstab"' EXIT
  ui_page "创建 Swap" "为低内存 VPS 创建受保护、可追踪的交换文件"
  swapon --show --noheadings 2>/dev/null | grep -q . && { warn "系统已经启用 Swap，无需再创建。"; return 0; }
  [[ ! -e /swapfile ]] || { warn "/swapfile 已存在且所有权未知，拒绝覆盖。"; return 1; }
  ui_hint "允许 128-32768 MB；低内存 VPS 通常可从 1024 MB 开始。"
  size_mb="$(read_input "Swap 大小（MB）" "1024")"
  if [[ ! "$size_mb" =~ ^[0-9]+$ ]] || (( size_mb < 128 || size_mb > 32768 )); then
    warn "大小必须在 128-32768 MB。"
    return 1
  fi
  marker="$(system_swap_marker)"
  safe_toolkit_path "$STATE_ROOT" || { warn "项目状态目录不安全：$STATE_ROOT"; return 1; }
  ui_panel_begin "创建计划"
  ui_panel_kv "路径" "/swapfile"
  ui_panel_kv "容量" "$size_mb MiB"
  ui_panel_kv "开机启用" "是"
  ui_panel_kv "状态记录" "$marker"
  ui_panel_end
  confirm "创建 ${size_mb} MB 的 /swapfile？" || return 0
  require_root
  [[ -e /etc/fstab ]] && fstab_existed=1
  changes_prepare_file /etc/fstab || return 1
  if (( DRY_RUN == 0 && fstab_existed == 1 )); then
    previous_fstab="$(mktemp)" || return 1
    cp -p /etc/fstab "$previous_fstab" || return 1
  fi
  if command_exists fallocate; then
    if ! run fallocate -l "${size_mb}M" /swapfile; then
      run dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=progress || {
        system_swap_creation_rollback "$marker" "$fstab_existed" "$previous_fstab" || warn "Swap 失败清理未完全完成，请检查 /swapfile。"
        warn "Swap 文件创建失败."
        return 1
      }
    fi
  else
    run dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=progress || {
      system_swap_creation_rollback "$marker" "$fstab_existed" "$previous_fstab" || warn "Swap 失败清理未完全完成，请检查 /swapfile。"
      warn "Swap 文件创建失败。"
      return 1
    }
  fi
  run chmod 600 /swapfile || {
    system_swap_creation_rollback "$marker" "$fstab_existed" "$previous_fstab" || warn "Swap 失败清理未完全完成，请检查 /swapfile。"
    warn "无法设置 Swap 文件权限。"
    return 1
  }
  run mkswap /swapfile || {
    system_swap_creation_rollback "$marker" "$fstab_existed" "$previous_fstab" || warn "Swap 失败清理未完全完成，请检查 /swapfile。"
    warn "无法初始化 Swap 文件。"
    return 1
  }
  if [[ "$DRY_RUN" -eq 1 ]]; then
    run swapon /swapfile
    info "将更新 /etc/fstab 并记录托管状态。"
    return 0
  fi
  mkdir -p "$STATE_ROOT" || {
    system_swap_creation_rollback "$marker" "$fstab_existed" "$previous_fstab" || warn "Swap 失败清理未完全完成，请检查 /swapfile。"
    warn "无法创建项目状态目录。"
    return 1
  }
  identity="$(stat -c '%d:%i' /swapfile 2>/dev/null || true)"
  if [[ ! "$identity" =~ ^[0-9]+:[0-9]+$ ]]; then
    system_swap_creation_rollback "$marker" "$fstab_existed" "$previous_fstab" || warn "Swap 失败清理未完全完成，请检查 /swapfile。"
    warn "无法记录 Swap 文件身份。"
    return 1
  fi
  if ! {
    printf 'path=/swapfile\n'
    printf 'size_mb=%s\n' "$size_mb"
    printf 'identity=%s\n' "$identity"
    printf 'created_at=%s\n' "$(date -Is)"
  } >"$marker" || ! chmod 0600 "$marker"; then
    system_swap_creation_rollback "$marker" "$fstab_existed" "$previous_fstab" || warn "Swap 失败清理未完全完成，请检查 /swapfile。"
    warn "无法写入或保护 Swap 所有权记录。"
    return 1
  fi
  if ! swapon /swapfile; then
    system_swap_creation_rollback "$marker" "$fstab_existed" "$previous_fstab" || warn "Swap 失败清理未完全完成，请检查 /swapfile。"
    warn "无法启用 Swap 文件。"
    return 1
  fi
  changes_prepare_file /etc/fstab || {
    system_swap_creation_rollback "$marker" "$fstab_existed" "$previous_fstab" || warn "Swap 失败清理未完全完成，请检查 /swapfile。"
    return 1
  }
  if ! grep -Fqx '/swapfile none swap sw 0 0' /etc/fstab &&
    ! printf '/swapfile none swap sw 0 0\n' >>/etc/fstab; then
    system_swap_creation_rollback "$marker" "$fstab_existed" "$previous_fstab" || warn "Swap 失败清理未完全完成，请检查 /swapfile。"
    warn "无法更新 /etc/fstab，已尝试回滚本次创建。"
    return 1
  fi
  if ! system_swap_active; then
    system_swap_creation_rollback "$marker" "$fstab_existed" "$previous_fstab" || warn "Swap 失败清理未完全完成，请检查 /swapfile。"
    warn "Swap 创建完成但未处于启用状态。"
    return 1
  fi
  audit "action=create-swap size_mb=$size_mb"
  ui_success "Swap 已创建并设置为开机启用"
)

system_swap_toggle() {
  local mode="$1"
  system_swap_managed || { warn "只允许控制由 keine 创建的 /swapfile。"; return 1; }
  case "$mode" in
    enable)
      system_swap_active && { info "/swapfile 已经启用。"; return 0; }
      confirm "立即启用 /swapfile？" || return 0
      require_root
      run swapon /swapfile || { warn "无法启用 /swapfile。"; return 1; }
      ;;
    disable)
      system_swap_active || { info "/swapfile 当前未启用。"; return 0; }
      ui_note "这里只停用当前会话；由于 fstab 仍保留配置，下次开机会重新启用。"
      confirm "立即停用 /swapfile？" || return 0
      require_root
      run swapoff /swapfile || { warn "Swap 正在使用且无法安全停用。"; return 1; }
      ;;
    *) warn "未知 Swap 操作：$mode"; return 1 ;;
  esac
  audit "action=swap-$mode path=/swapfile"
  ui_success "/swapfile 状态已更新"
}

system_remove_swap() {
  local marker temporary
  marker="$(system_swap_marker)"
  system_swap_managed || { warn "没有检测到由 keine 创建的 /swapfile。"; return 1; }
  [[ -f /swapfile && ! -L /swapfile ]] || { warn "/swapfile 不存在或文件类型异常。"; return 1; }
  ui_page "删除托管 Swap" "停用交换文件、移除开机配置并删除项目状态记录"
  ui_danger "该操作会永久删除 /swapfile；内存不足时停用 Swap 可能失败。"
  confirm "确认删除由 keine 管理的 /swapfile？" || return 0
  require_root
  changes_prepare_file /etc/fstab || return 1
  if system_swap_active; then
    run swapoff /swapfile || { warn "无法安全停用 Swap，已取消删除。"; return 1; }
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "将从 /etc/fstab 移除 /swapfile，并删除 $marker。"
  else
    changes_prepare_file /etc/fstab || return 1
    temporary="$(mktemp)" || { warn "无法创建 fstab 临时文件。"; return 1; }
    awk '$0 != "/swapfile none swap sw 0 0"' /etc/fstab >"$temporary" || {
      rm -f -- "$temporary"
      warn "无法生成新的 /etc/fstab。"
      return 1
    }
    install -m 0644 "$temporary" /etc/fstab || { rm -f -- "$temporary"; warn "无法更新 /etc/fstab。"; return 1; }
    rm -f -- "$temporary"
    rm -f -- /swapfile "$marker" || { warn "无法删除 Swap 文件或状态记录。"; return 1; }
  fi
  audit "action=remove-swap path=/swapfile"
  ui_success "托管 Swap 已删除"
}

system_swap_manage() {
  local action total_kb used_kb total_mb used_mb managed="否" state="未配置" swapfile_active=0
  while true; do
    total_kb="$(awk '/SwapTotal/{print $2}' /proc/meminfo 2>/dev/null || printf '0')"
    used_kb="$(awk '/SwapTotal/{total=$2}/SwapFree/{free=$2}END{print total-free}' /proc/meminfo 2>/dev/null || printf '0')"
    total_mb="$(( ${total_kb:-0} / 1024 ))"
    used_mb="$(( ${used_kb:-0} / 1024 ))"
    managed="否"
    state="未配置"
    swapfile_active=0
    system_swap_managed && managed="是"
    (( total_mb > 0 )) && state="已启用"
    system_swap_active && swapfile_active=1
    ui_page "Swap 管理" "交换空间状态、创建、即时启停与安全删除"
    ui_panel_begin "交换空间"
    if (( total_mb > 0 )); then ui_panel_kv "状态" "● $state" "$GREEN"; else ui_panel_kv "状态" "● 未配置" "$YELLOW"; fi
    ui_panel_kv "已用 / 总量" "$used_mb / $total_mb MiB"
    ui_panel_kv "工具托管" "$managed"
    ui_panel_end
    ui_section "当前设备" "primary"
    swapon --show 2>/dev/null || ui_empty "没有启用的 Swap 设备"
    ui_section "操作" "accent"
    if (( total_mb == 0 )); then ui_action 1 "创建 /swapfile" "success"; else ui_action 1 "创建 /swapfile" "muted" "系统已有 Swap"; fi
    if [[ "$managed" == "是" && "$swapfile_active" -eq 1 ]]; then
      ui_action 2 "立即启用" "muted" "当前已经启用"
      ui_action 3 "临时停用" "warning" "下次开机仍会启用"
    elif [[ "$managed" == "是" ]]; then
      ui_action 2 "立即启用" "success"
      ui_action 3 "临时停用" "muted" "当前未启用"
    else
      ui_action 2 "立即启用" "muted" "仅控制工具创建的 Swap"
      ui_action 3 "临时停用" "muted" "仅控制工具创建的 Swap"
    fi
    ui_action 4 "删除托管 Swap" "danger" "同时移除 fstab 配置"
    ui_menu_footer "返回"
    ui_read_choice action
    case "$action" in
      1) system_create_swap || true; pause ;;
      2) system_swap_toggle enable || true; pause ;;
      3) system_swap_toggle disable || true; pause ;;
      4) system_remove_swap || true; pause ;;
      0) return 0 ;;
      *) warn "未知选项" ;;
    esac
  done
}

system_time_sync() {
  local timezone ntp synchronized local_time utc_time provider="" provider_state="未检测" action target
  timezone="$(timedatectl show -p Timezone --value 2>/dev/null || printf '未知')"
  ntp="$(timedatectl show -p NTP --value 2>/dev/null || printf 'no')"
  synchronized="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || printf 'no')"
  local_time="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  utc_time="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  for target in systemd-timesyncd.service chrony.service ntpsec.service ntp.service; do
    if service_exists "$target"; then
      provider="$target"
      provider_state="$(service_state "$target")"
      break
    fi
  done
  ui_page "时间同步管理" "本地时间、NTP 状态与同步服务控制"
  ui_panel_begin "时间状态"
  ui_panel_kv "本地时间" "$local_time"
  ui_panel_kv "UTC 时间" "$utc_time"
  ui_panel_kv "时区" "$timezone"
  if [[ "$ntp" == "yes" ]]; then ui_panel_kv "NTP" "● 已启用" "$GREEN"; else ui_panel_kv "NTP" "● 未启用" "$YELLOW"; fi
  if [[ "$synchronized" == "yes" ]]; then ui_panel_kv "时钟同步" "● 已同步" "$GREEN"; else ui_panel_kv "时钟同步" "● 尚未同步" "$YELLOW"; fi
  ui_panel_kv "同步服务" "${provider:-未检测到}"
  ui_panel_kv "服务状态" "$provider_state"
  ui_panel_end
  ui_section "操作" "accent"
  ui_action 1 "启用 NTP 时间同步" "success"
  ui_action 2 "禁用 NTP 时间同步" "danger"
  ui_action 3 "管理同步服务" "action" "查看日志、启停、重启与开机策略"
  ui_menu_footer "返回"
  ui_read_choice action
  case "$action" in
    1|2)
      if [[ "$action" == "1" ]]; then target=true; else target=false; fi
      confirm "将系统 NTP 设置为 $target？" || return 0
      require_root
      run timedatectl set-ntp "$target" || { warn "NTP 设置修改失败。"; return 1; }
      if [[ "$DRY_RUN" -eq 0 ]]; then
        ntp="$(timedatectl show -p NTP --value 2>/dev/null || true)"
        if [[ "$target" == "true" && "$ntp" != "yes" ]]; then warn "系统没有确认 NTP 已启用。"; return 1; fi
        if [[ "$target" == "false" && "$ntp" == "yes" ]]; then warn "系统仍报告 NTP 已启用。"; return 1; fi
      fi
      audit "action=set-time-sync enabled=$target"
      ui_success "NTP 时间同步设置已更新"
      ;;
    3)
      if [[ -n "$provider" ]]; then services_select "$provider"; else warn "没有检测到可管理的时间同步服务。"; fi
      ;;
    0) return 0 ;;
    *) warn "未知选项"; return 1 ;;
  esac
}
