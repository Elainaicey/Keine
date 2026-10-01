#!/usr/bin/env bash

process_exists() {
  valid_pid "${1:-}" && [[ -d "/proc/$1" ]]
}

process_is_protected() {
  local pid="$1"
  [[ "$pid" == "1" || "$pid" == "$$" || "$pid" == "$PPID" ]]
}

process_command_line() {
  local pid="$1" command
  command="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
  if [[ -n "$command" ]]; then
    terminal_safe_text "${command% }"
  else
    command="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    terminal_safe_text "${command:-—}"
  fi
}

process_service_unit() {
  local pid="$1"
  awk -F/ '
    {
      for (field=NF; field>=1; field--) {
        if ($field ~ /\.service$/) {print $field; exit}
      }
    }' "/proc/$pid/cgroup" 2>/dev/null | head -n 1
}

process_open_fd_count() {
  find "/proc/$1/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d '[:space:]'
}

process_socket_summary() {
  local pid="$1" sockets
  command_exists ss || { ui_empty "未安装 iproute2，无法读取套接字"; return 0; }
  sockets="$(ss -tunap 2>/dev/null | grep -F "pid=$pid," | sed -n '1,40p' || true)"
  if [[ -n "$sockets" ]]; then printf '%s\n' "$sockets"; else ui_empty "没有检测到该进程持有的 TCP/UDP 套接字"; fi
}

process_files_summary() {
  local pid="$1"
  ui_page "进程资源 / PID $pid" "打开文件、网络套接字与 cgroup"
  ui_section "打开文件描述符" "primary"
  if command_exists lsof; then
    lsof -nP -p "$pid" 2>/dev/null | sed -n '1,50p' || ui_empty "无法读取打开文件"
  else
    find "/proc/$pid/fd" -mindepth 1 -maxdepth 1 -printf '  %f -> %l\n' 2>/dev/null | sed -n '1,50p' || ui_empty "无法读取文件描述符"
  fi
  ui_section "网络套接字" "accent"
  process_socket_summary "$pid"
  ui_section "cgroup" "primary"
  sed -n '1,30p' "/proc/$pid/cgroup" 2>/dev/null || ui_empty "无法读取 cgroup"
}

process_signal() {
  local pid="$1" signal="$2" label command _attempt
  process_exists "$pid" || { warn "进程不存在：$pid"; return 1; }
  process_is_protected "$pid" && { warn "拒绝向 PID 1、工具自身或其父进程发送信号。"; return 1; }
  command="$(process_command_line "$pid")"
  case "$signal" in
    TERM) label="SIGTERM（请求优雅退出）" ;;
    KILL) label="SIGKILL（立即终止）" ;;
    *) warn "不支持的信号：$signal"; return 1 ;;
  esac
  ui_panel_begin "信号计划"
  ui_panel_kv "PID" "$pid"
  ui_panel_kv "进程" "$command"
  ui_panel_kv "信号" "$label"
  ui_panel_end
  [[ "$signal" != "KILL" ]] || ui_danger "SIGKILL 不允许进程保存状态或清理资源，只应在 SIGTERM 无效时使用。"
  confirm "向 PID $pid 发送 $label？" || return 0
  require_root
  run kill "-$signal" "$pid" || { warn "信号发送失败。"; return 1; }
  audit "action=process-signal pid=$pid signal=$signal"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    for _attempt in 1 2 3 4 5; do
      [[ -d "/proc/$pid" ]] || break
      sleep 0.2
    done
  fi
  if [[ "$DRY_RUN" -eq 0 && -d "/proc/$pid" ]]; then
    warn "信号已发送，但进程目前仍存在；它可能正在退出、成为僵尸进程或由服务管理器重新拉起。"
  else
    ui_success "信号已发送"
  fi
}

process_set_nice() {
  local pid="$1" value current
  process_exists "$pid" || { warn "进程不存在：$pid"; return 1; }
  process_is_protected "$pid" && { warn "拒绝调整 PID 1、工具自身或其父进程的优先级。"; return 1; }
  current="$(ps -o ni= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  value="$(read_input "新的 nice 值（-20 最高，19 最低）" "${current:-0}")"
  valid_nice_value "$value" || { warn "nice 值必须在 -20 到 19 之间。"; return 1; }
  [[ "$value" != "$current" ]] || { warn "进程已经使用 nice=$value。"; return 0; }
  confirm "将 PID $pid 的 nice 从 ${current:-未知} 调整为 $value？" || return 0
  require_root
  run renice -n "$value" -p "$pid" || { warn "进程优先级调整失败。"; return 1; }
  if [[ "$DRY_RUN" -eq 0 ]]; then
    current="$(ps -o ni= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    [[ "$current" == "$value" ]] || { warn "nice 值验证失败，当前为 ${current:-未知}。"; return 1; }
  fi
  audit "action=process-renice pid=$pid nice=$value"
  ui_success "进程优先级已更新"
}

system_process_select() {
  local pid="$1" action user state cpu memory rss elapsed nice threads fds command exe service
  process_exists "$pid" || { warn "进程不存在：$pid"; return 1; }
  while process_exists "$pid"; do
    user="$(ps -o user= -p "$pid" 2>/dev/null | awk '{$1=$1;print}')"
    state="$(ps -o stat= -p "$pid" 2>/dev/null | awk '{$1=$1;print}')"
    cpu="$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    memory="$(ps -o %mem= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    rss="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    elapsed="$(ps -o etime= -p "$pid" 2>/dev/null | awk '{$1=$1;print}')"
    nice="$(ps -o ni= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    threads="$(awk '/^Threads:/{print $2}' "/proc/$pid/status" 2>/dev/null || true)"
    fds="$(process_open_fd_count "$pid")"
    command="$(process_command_line "$pid")"
    exe="$(terminal_safe_text "$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)")"
    service="$(process_service_unit "$pid")"
    ui_page "进程详情 / PID $pid" "资源、归属、文件与安全控制"
    ui_panel_begin "运行信息"
    ui_panel_kv "用户 / 状态" "${user:-—} / ${state:-—}"
    ui_panel_kv "CPU / 内存" "${cpu:-0}% / ${memory:-0}%"
    ui_panel_kv "常驻内存" "${rss:-0} KiB"
    ui_panel_kv "运行时间" "${elapsed:-—}"
    ui_panel_kv "nice / 线程" "${nice:-—} / ${threads:-—}"
    ui_panel_kv "打开 FD" "${fds:-0}"
    ui_panel_kv "systemd 单元" "${service:-—}"
    ui_panel_kv "可执行文件" "${exe:-—}"
    ui_panel_kv "命令" "$command"
    ui_panel_end
    ui_section "诊断" "primary"
    ui_action_pair 1 "文件、套接字与 cgroup" "action" 2 "查看进程树" "action"
    ui_section "控制" "accent"
    ui_action_pair 3 "调整 nice 优先级" "warning" 4 "发送 SIGTERM" "warning"
    ui_action 5 "发送 SIGKILL" "danger" "仅在无法优雅退出时使用"
    process_is_protected "$pid" && ui_note "PID 1、工具自身和父进程受保护，控制操作不可用。"
    ui_menu_footer "返回"
    ui_read_choice action
    case "$action" in
      1) process_files_summary "$pid"; pause ;;
      2)
        if command_exists pstree; then pstree -aps "$pid" 2>/dev/null || true; else ps -o pid,ppid,user,stat,etime,cmd -p "$pid" 2>/dev/null || true; fi
        pause
        ;;
      3) process_set_nice "$pid" || true; pause ;;
      4) process_signal "$pid" TERM || true; pause ;;
      5) process_signal "$pid" KILL || true; pause ;;
      0) return 0 ;;
      *) warn "未知选项" ;;
    esac
  done
  ui_success "PID $pid 已经退出"
}

system_processes() {
  local action pid
  while true; do
    ui_page "进程与资源" "高占用排行、进程下钻与受控处置"
    ui_section "内存占用最高" "primary"
    ps -eo pid,user,%cpu,%mem,rss,stat,comm --sort=-%mem 2>/dev/null | sed -n '1,16p'
    ui_section "CPU 占用最高" "accent"
    ps -eo pid,user,%cpu,%mem,etime,stat,comm --sort=-%cpu 2>/dev/null | sed -n '1,16p'
    ui_section "操作" "primary"
    ui_action 1 "按 PID 查看进程详情" "action" "资源、文件、套接字、优先级与终止信号"
    ui_menu_footer "返回"
    ui_read_choice action
    case "$action" in
      1)
        ui_hint "输入排行榜或 ps 输出中的数字 PID。"
        pid="$(read_input "PID" "")"
        valid_pid "$pid" || { warn "PID 格式无效。"; pause; continue; }
        system_process_select "$pid" || true
        ;;
      0) return 0 ;;
      *) warn "未知选项" ;;
    esac
  done
}
