#!/usr/bin/env bash

services_journal_kernel_warnings() {
  ui_page "内核警告" "本次启动最近 120 条 warning 及以上日志"
  journalctl -k -b -p warning --no-pager -n 120 2>/dev/null || ui_empty "没有可显示的内核警告"
}

services_journal_query() {
  local time_choice priority_choice unit keyword output line count=0
  local -a arguments=(--no-pager -n 300 -o short-iso)
  ui_page "Journal 条件查询"
  ui_section "时间范围" "primary"
  ui_action_pair 1 "本次启动" "action" 2 "最近 1 小时" "action"
  ui_action_pair 3 "最近 24 小时" "action" 4 "最近 7 天" "action"
  ui_menu_footer "取消"
  ui_read_choice time_choice "时间范围" "3"
  case "$time_choice" in
    0) return 0 ;;
    1) arguments+=(-b) ;;
    2) arguments+=(--since "-1 hour") ;;
    3) arguments+=(--since "-24 hours") ;;
    4) arguments+=(--since "-7 days") ;;
    *) warn "未知时间范围：$time_choice"; return 1 ;;
  esac
  ui_section "最低优先级" "accent"
  ui_action_pair 1 "错误 err" "danger" 2 "警告 warning" "warning"
  ui_action_pair 3 "通知 notice" "action" 4 "全部级别" "action"
  ui_menu_footer "取消"
  ui_read_choice priority_choice "优先级" "2"
  case "$priority_choice" in
    0) return 0 ;;
    1) arguments+=(-p err) ;;
    2) arguments+=(-p warning) ;;
    3) arguments+=(-p notice) ;;
    4) ;;
    *) warn "未知优先级：$priority_choice"; return 1 ;;
  esac
  ui_hint "单元留空表示全部，如 nginx.service。"
  unit="$(read_input "systemd 单元" "")"
  if [[ -n "$unit" ]]; then
    valid_service_name "$unit" || { warn "systemd 单元名格式无效。"; return 1; }
    unit_exists "$unit" || { warn "没有找到 systemd 单元：$unit"; return 1; }
    arguments+=(-u "$unit")
  fi
  ui_hint "关键词可留空，最多 80 字符。"
  keyword="$(read_input "关键词" "")"
  if [[ "${#keyword}" -gt 80 || "$keyword" == *[[:cntrl:]]* ]]; then
    warn "关键词格式无效。"
    return 1
  fi
  ui_page "Journal 查询结果" "${unit:-全部单元} · 最多显示最近 300 条"
  output="$(journalctl "${arguments[@]}" 2>/dev/null || true)"
  if [[ -n "$keyword" ]]; then
    output="$(grep -Fi -- "$keyword" <<<"$output" || true)"
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '  %s\n' "$(terminal_safe_text "$line")"
    count=$((count + 1))
  done <<<"$output"
  (( count > 0 )) || ui_empty "没有匹配当前条件的 Journal"
  ui_context "$count 条结果"
}

services_journal_vacuum() {
  local mode="$1" value option description
  case "$mode" in
    time)
      value="$(read_input "保留最近多少天" "14")"
      if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < 1 || value > 3650 )); then
        warn "天数必须在 1-3650 之间。"
        return 1
      fi
      option="--vacuum-time=${value}d"
      description="删除早于 $value 天的归档 Journal"
      ;;
    size)
      value="$(read_input "Journal 最大占用（MiB）" "500")"
      if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < 32 || value > 10240 )); then
        warn "容量必须在 32-10240 MiB 之间。"
        return 1
      fi
      option="--vacuum-size=${value}M"
      description="把归档 Journal 压缩到 $value MiB 以内"
      ;;
    *) warn "未知 Journal 清理模式：$mode"; return 1 ;;
  esac
  ui_danger "$description；被清理的历史日志无法恢复。"
  confirm "确认执行 Journal 清理？" || return 0
  require_root
  run journalctl --rotate || { warn "无法轮转当前 Journal。"; return 1; }
  run journalctl "$option" || { warn "Journal 清理失败。"; return 1; }
  audit "action=journal-vacuum mode=$mode value=$value"
  ui_success "Journal 清理完成"
}

services_journal_info() {
  local action usage storage boots
  while true; do
    usage="$(journalctl --disk-usage 2>/dev/null | sed 's/^Archived and active journals take up //;s/\.$//' || printf '未知')"
    if [[ -d /var/log/journal ]]; then storage="持久化"; else storage="易失（随重启清理）"; fi
    boots="$(journalctl --list-boots --no-pager 2>/dev/null | grep -c . || true)"
    ui_page "Journal 管理" "磁盘占用、完整性验证、内核警告与历史清理"
    ui_panel_begin "日志存储"
    ui_panel_kv "磁盘占用" "${usage:-未知}"
    ui_panel_kv "存储模式" "$storage"
    ui_panel_kv "可查询启动" "$boots"
    ui_panel_end
    ui_section "查看与验证" "primary"
    ui_action_pair 1 "查看内核警告" "action" 2 "验证 Journal 文件" "action"
    ui_action 3 "查看磁盘占用详情" "action"
    ui_action 6 "条件查询" "action" "按时间、优先级、单元和关键词筛选"
    ui_section "空间维护" "accent"
    ui_action_pair 4 "按时间清理" "warning" 5 "按容量清理" "warning"
    ui_menu_footer "返回"
    ui_read_choice action
    case "$action" in
      1) services_journal_kernel_warnings; pause ;;
      2)
        ui_page "验证 Journal" "读取所有 Journal 文件并检查一致性"
        if journalctl --verify 2>&1 | sed -n '1,160p'; then
          ui_success "Journal 文件验证通过"
        else
          warn "Journal 验证发现异常，请检查上方输出。"
        fi
        pause
        ;;
      3) journalctl --disk-usage 2>/dev/null || true; pause ;;
      4) services_journal_vacuum time || true; pause ;;
      5) services_journal_vacuum size || true; pause ;;
      6) services_journal_query || true; pause ;;
      0) return 0 ;;
      *) warn "未知选项" ;;
    esac
  done
}
