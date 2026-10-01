#!/usr/bin/env bash

services_format_bytes() {
  local value="${1:-}"
  [[ "$value" =~ ^[0-9]+$ && "$value" != "18446744073709551615" ]] || { printf '—'; return 0; }
  if command_exists numfmt; then
    numfmt --to=iec-i --suffix=B "$value" 2>/dev/null || printf '%s B' "$value"
  else
    printf '%s B' "$value"
  fi
}

services_format_cpu_time() {
  local value="${1:-}"
  [[ "$value" =~ ^[0-9]+$ ]] || { printf '—'; return 0; }
  awk -v nanoseconds="$value" 'BEGIN {
    seconds=nanoseconds/1000000000
    if (seconds < 60) printf "%.2f 秒", seconds
    else if (seconds < 3600) printf "%.1f 分钟", seconds/60
    else printf "%.1f 小时", seconds/3600
  }'
}

services_path_summary() {
  local value="${1:-}" first
  local paths=()
  [[ -n "$value" ]] || { printf '无'; return 0; }
  IFS=' ' read -r -a paths <<<"$value"
  first="${paths[0]:-}"
  if ((${#paths[@]} <= 1)); then
    printf '%s' "$first"
  else
    printf '%s 个 · %s …' "${#paths[@]}" "$first"
  fi
}

services_logs() {
  local service="$1"
  ui_page "$service 日志" "最近 100 条 Journal"
  journalctl -u "$service" -n 100 --no-pager 2>/dev/null || warn "无法读取日志。"
}

services_search() {
  local query service
  ui_hint "关键词仅使用字母、数字、点、短横线、下划线、@、冒号。"
  query="$(read_input "服务关键词" "")"; [[ -n "$query" ]] || return 0
  [[ "$query" =~ ^[a-zA-Z0-9@_.:-]+$ ]] || { warn "关键词格式无效。"; return 1; }
  ui_page "查找 systemd 服务" "$query · 匹配单元名或描述"
  systemctl list-units --all --type=service --no-legend --no-pager 2>/dev/null |
    awk -v query="$query" 'BEGIN{query=tolower(query)} index(tolower($0),query){print "  "$0; found=1} END{if(!found)print "  — 没有匹配的服务"}' |
    sed -n '1,80p'
  ui_menu_footer "返回"
  ui_read_choice service "服务名"
  [[ "$service" == "0" ]] && return 0
  valid_service_name "$service" || { warn "服务名格式无效。"; return 1; }
  services_select "$service"
}

services_apply_action() {
  local unit="$1" verb="$2" label unit_type result snapshot
  valid_service_name "$unit" || { warn "systemd 服务名格式无效。"; return 1; }
  service_exists "$unit" || { warn "没有找到 systemd 服务：$unit"; return 1; }
  case "$verb" in
    start) label="启动" ;;
    stop) label="停止" ;;
    restart) label="重启" ;;
    enable) label="启用开机启动" ;;
    disable) label="禁用开机启动" ;;
    *) warn "不支持的 systemd 操作：$verb"; return 1 ;;
  esac
  confirm "对 $unit 执行「$label」？" || return 0
  require_root
  run systemctl "$verb" "$unit" || { warn "$unit：$label命令执行失败。"; return 1; }
  if [[ "$DRY_RUN" -eq 0 ]]; then
    case "$verb" in
      start|restart)
        snapshot="$(unit_properties_snapshot "$unit" Type Result || true)"
        unit_type="$(unit_snapshot_value "$snapshot" Type 2>/dev/null || true)"
        if [[ "$unit_type" == "oneshot" ]]; then
          result="$(unit_snapshot_value "$snapshot" Result 2>/dev/null || true)"
          [[ "$result" == "success" ]] || { warn "$unit 执行结果不是 success。"; return 1; }
        else
          systemctl is-active --quiet "$unit" || { warn "$unit 操作后仍未运行。"; return 1; }
        fi
        ;;
      stop)
        if systemctl is-active --quiet "$unit"; then warn "$unit 操作后仍在运行。"; return 1; fi
        ;;
      enable)
        systemctl is-enabled --quiet "$unit" || { warn "$unit 尚未启用开机启动。"; return 1; }
        ;;
      disable)
        if systemctl is-enabled --quiet "$unit"; then warn "$unit 仍处于开机启动状态。"; return 1; fi
        ;;
    esac
  fi
  audit "action=systemd-$verb unit=$unit"
  ui_success "$unit：$label已完成"
}

services_dependencies_view() {
  local service="$1"
  ui_page "服务依赖 / $service" "正向依赖、反向依赖与关键启动链"
  ui_section "该服务依赖" "primary"
  systemctl list-dependencies "$service" --no-pager 2>/dev/null | sed -n '1,100p' || ui_empty "无法读取正向依赖"
  ui_section "依赖该服务" "accent"
  systemctl list-dependencies --reverse "$service" --no-pager 2>/dev/null | sed -n '1,100p' || ui_empty "无法读取反向依赖"
  ui_section "关键启动链" "primary"
  if command_exists systemd-analyze; then
    systemd-analyze critical-chain "$service" --no-pager 2>/dev/null | sed -n '1,80p' || ui_empty "无法读取启动关键链"
  else
    ui_empty "缺少 systemd-analyze"
  fi
}

services_failure_diagnostics() {
  local service="$1" result exit_code exit_status snapshot
  snapshot="$(unit_properties_snapshot "$service" Result ExecMainCode ExecMainStatus || true)"
  result="$(unit_snapshot_value "$snapshot" Result 2>/dev/null || true)"
  exit_code="$(unit_snapshot_value "$snapshot" ExecMainCode 2>/dev/null || true)"
  exit_status="$(unit_snapshot_value "$snapshot" ExecMainStatus 2>/dev/null || true)"
  ui_page "服务诊断 / $service" "退出结果、状态码与本次启动的 warning 以上日志"
  ui_panel_begin "退出信息"
  ui_panel_kv "Result" "${result:-—}" "$([[ "$result" == "success" ]] && printf '%s' "$GREEN" || printf '%s' "$RED")"
  ui_panel_kv "ExecMainCode" "${exit_code:-—}"
  ui_panel_kv "ExecMainStatus" "${exit_status:-—}"
  ui_panel_end
  ui_section "本次启动相关日志" "accent"
  journalctl -u "$service" -b -p warning --no-pager -n 100 2>/dev/null || ui_empty "没有可显示的警告日志"
}

services_select() {
  local service="${1:-}" action state enabled description substate main_pid restarts started
  local memory tasks cpu_time result exit_status fragment dropins state_color snapshot
  if [[ -z "$service" ]]; then
    ui_hint "输入完整 systemd 服务名，例如 nginx.service 或 ssh.service。"
    service="$(read_input "服务名" "")"
  fi
  [[ -n "$service" ]] || return 0
  valid_service_name "$service" || { warn "服务名格式无效。"; return 1; }
  service_exists "$service" || { warn "没有找到服务：$service"; return 1; }
  while true; do
    state="$(service_state "$service")"
    enabled="$(systemctl is-enabled "$service" 2>/dev/null || true)"
    enabled="${enabled:-disabled}"
    snapshot="$(unit_properties_snapshot "$service" Description SubState MainPID NRestarts \
      ActiveEnterTimestamp MemoryCurrent TasksCurrent CPUUsageNSec Result ExecMainStatus \
      FragmentPath DropInPaths || true)"
    description="$(unit_snapshot_value "$snapshot" Description 2>/dev/null || true)"
    substate="$(unit_snapshot_value "$snapshot" SubState 2>/dev/null || true)"
    main_pid="$(unit_snapshot_value "$snapshot" MainPID 2>/dev/null || true)"
    restarts="$(unit_snapshot_value "$snapshot" NRestarts 2>/dev/null || true)"
    started="$(unit_snapshot_value "$snapshot" ActiveEnterTimestamp 2>/dev/null || true)"
    memory="$(unit_snapshot_value "$snapshot" MemoryCurrent 2>/dev/null || true)"
    tasks="$(unit_snapshot_value "$snapshot" TasksCurrent 2>/dev/null || true)"
    cpu_time="$(unit_snapshot_value "$snapshot" CPUUsageNSec 2>/dev/null || true)"
    result="$(unit_snapshot_value "$snapshot" Result 2>/dev/null || true)"
    exit_status="$(unit_snapshot_value "$snapshot" ExecMainStatus 2>/dev/null || true)"
    fragment="$(unit_snapshot_value "$snapshot" FragmentPath 2>/dev/null || true)"
    dropins="$(unit_snapshot_value "$snapshot" DropInPaths 2>/dev/null || true)"
    case "$state" in active) state_color="$GREEN" ;; failed) state_color="$RED" ;; *) state_color="$YELLOW" ;; esac
    ui_page "服务 / $service"
    ui_panel_begin "服务信息"
    ui_panel_kv "说明" "$(terminal_safe_text "${description:-—}")"
    ui_panel_kv "状态" "● $state" "$state_color"
    ui_panel_kv "子状态" "${substate:-—}"
    ui_panel_kv "开机启动" "$enabled"
    ui_panel_kv "主进程 PID" "${main_pid:-0}"
    ui_panel_kv "重启次数" "${restarts:-0}"
    ui_panel_kv "进入状态时间" "${started:-—}"
    ui_panel_end
    ui_panel_begin "资源与结果"
    ui_panel_kv "当前内存" "$(services_format_bytes "$memory")"
    ui_panel_kv "累计 CPU" "$(services_format_cpu_time "$cpu_time")"
    ui_panel_kv "任务数量" "${tasks:-—}"
    ui_panel_kv "执行结果" "${result:-—}" "$([[ "$result" == "success" ]] && printf '%s' "$GREEN" || printf '%s' "$YELLOW")"
    ui_panel_kv "退出状态" "${exit_status:-—}"
    ui_panel_kv "Unit 文件" "$(terminal_safe_text "${fragment:-—}")"
    ui_panel_kv "Drop-in" "$(terminal_safe_text "$(services_path_summary "$dropins")")"
    ui_panel_end
    ui_section "查看" "primary"
    ui_action 1 "查看状态" "action"
    ui_action 2 "查看日志" "action"
    ui_action 3 "依赖与启动链" "action"
    ui_action 4 "失败诊断" "$([[ "$state" == "failed" ]] && printf 'danger' || printf 'action')"
    ui_section "生命周期" "accent"
    if [[ "$state" == "active" ]]; then
      ui_action 6 "停止" "danger"
      ui_action 7 "重启" "warning"
    else
      ui_action 5 "启动" "success"
      ui_action 7 "重启" "warning"
    fi
    if [[ "$enabled" == "enabled" ]]; then
      ui_action 9 "禁用开机启动" "danger"
    else
      ui_action 8 "启用开机启动" "success"
    fi
    ui_menu_footer "返回"
    ui_read_choice action
    case "$action" in
      1) systemctl status "$service" --no-pager || true; pause ;;
      2) services_logs "$service"; pause ;;
      3) services_dependencies_view "$service"; pause ;;
      4) services_failure_diagnostics "$service"; pause ;;
      5|6|7|8|9)
        local verb=""
        case "$action" in
          5) verb=start ;;
          6) verb=stop ;;
          7) verb=restart ;;
          8) verb=enable ;;
          9) verb=disable ;;
        esac
        services_apply_action "$service" "$verb" || true
        pause
        ;;
      0) return 0 ;;
      *) warn "未知选项" ;;
    esac
  done
}
