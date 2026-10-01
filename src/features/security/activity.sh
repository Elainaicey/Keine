#!/usr/bin/env bash

security_exact_ip_valid() {
  local address="${1:-}"
  valid_firewall_source "$address" && [[ "$address" != "any" && "$address" != */* ]]
}

security_source_is_current() {
  local source="${SSH_CONNECTION:-}"
  source="${source%% *}"
  [[ -n "$source" && "$1" == "$source" ]]
}

security_auth_event_rows() {
  local line event user address
  while IFS= read -r line || [[ -n "$line" ]]; do
    event=""
    user=""
    address=""
    if [[ "$line" =~ Accepted[[:space:]]+[^[:space:]]+[[:space:]]+for[[:space:]]+([^[:space:]]+)[[:space:]]+from[[:space:]]+([^[:space:]]+) ]]; then
      event="accepted"; user="${BASH_REMATCH[1]}"; address="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ Failed[[:space:]]+password[[:space:]]+for[[:space:]]+invalid[[:space:]]+user[[:space:]]+([^[:space:]]+)[[:space:]]+from[[:space:]]+([^[:space:]]+) ]]; then
      event="failed"; user="${BASH_REMATCH[1]}"; address="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ Failed[[:space:]]+password[[:space:]]+for[[:space:]]+([^[:space:]]+)[[:space:]]+from[[:space:]]+([^[:space:]]+) ]]; then
      event="failed"; user="${BASH_REMATCH[1]}"; address="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ Invalid[[:space:]]+user[[:space:]]+([^[:space:]]+)[[:space:]]+from[[:space:]]+([^[:space:]]+) ]]; then
      event="failed"; user="${BASH_REMATCH[1]}"; address="${BASH_REMATCH[2]}"
    fi
    [[ -n "$event" ]] || continue
    security_exact_ip_valid "$address" || continue
    [[ "$user" =~ ^[a-zA-Z0-9_.@-]{1,64}$ ]] || user="未知"
    printf '%s|%s|%s\n' "$event" "$user" "$address"
  done
}

security_auth_activity_data() {
  local hours="${1:-24}"
  [[ "$hours" =~ ^[0-9]+$ ]] && (( hours >= 1 && hours <= 168 )) || return 1
  if command_exists journalctl; then
    journalctl -u ssh.service -u sshd.service --since "-$hours hours" --no-pager -n 5000 2>/dev/null || true
  elif [[ -r /var/log/auth.log ]]; then
    tail -n 5000 /var/log/auth.log 2>/dev/null || true
  fi
}

security_auth_failed_sources() {
  awk -F '|' '
    $1 == "failed" {count[$3]++}
    END {for (address in count) print count[address] "|" address}
  ' | sort -t '|' -k1,1nr -k2,2 | sed -n '1,20p'
}

security_auth_activity() {
  local hours="${1:-24}" raw events accepted failed unique top count address user
  raw="$(security_auth_activity_data "$hours")"
  events="$(security_auth_event_rows <<<"$raw")"
  accepted="$(awk -F '|' '$1=="accepted"{count++}END{print count+0}' <<<"$events")"
  failed="$(awk -F '|' '$1=="failed"{count++}END{print count+0}' <<<"$events")"
  unique="$(awk -F '|' '$1=="failed"{seen[$3]=1}END{for (item in seen) count++;print count+0}' <<<"$events")"
  ui_page "SSH 登录活动" "最近 $hours 小时成功、失败与高频来源聚合"
  ui_stats "成功" "$accepted" "失败" "$failed" "失败来源" "$unique"
  ui_section "失败来源排行" "accent"
  top="$(security_auth_failed_sources <<<"$events")"
  if [[ -n "$top" ]]; then
    while IFS='|' read -r count address; do
      printf '  %8s  %s\n' "$count" "$address"
    done <<<"$top"
  else
    ui_empty "没有解析到失败登录来源"
  fi
  ui_section "成功登录" "primary"
  if grep -q '^accepted|' <<<"$events"; then
    awk -F '|' '$1=="accepted"{key=$2"|"$3;count[key]++}END{for(key in count)print count[key]"|"key}' <<<"$events" |
      sort -t '|' -k1,1nr | sed -n '1,20p' |
      while IFS='|' read -r count user address; do
        printf '  %8s  %-20s %s\n' "$count" "$user" "$address"
      done
  else
    ui_empty "没有解析到成功登录事件"
  fi
  if (( failed >= 100 )); then
    ui_check fail "失败登录达到 $failed 次，建议检查高频来源和账户策略"
  elif (( failed >= 20 )); then
    ui_check warn "失败登录达到 $failed 次，建议持续观察"
  else
    ui_check pass "失败登录数量未达到内置关注阈值"
  fi
  ui_note "统计仅覆盖 OpenSSH 常见日志格式；日志轮转、语言或自定义格式可能影响计数。"
}

security_auth_center() {
  local choice
  while true; do
    security_auth_activity 24
    ui_section "明确操作" "accent"
    ui_action 1 "处置一个失败来源" "warning" "只允许选择当前清单中的明确 IP"
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      1) security_auth_source_response || true; pause ;;
      0) return 0 ;;
      *) warn "未知选项：$choice" ;;
    esac
  done
}

security_auth_source_response() {
  local raw events sources address count action jails jail current_source banned
  raw="$(security_auth_activity_data 24)"
  events="$(security_auth_event_rows <<<"$raw")"
  sources="$(security_auth_failed_sources <<<"$events")"
  [[ -n "$sources" ]] || { warn "最近 24 小时没有可处置的失败登录来源。"; return 1; }
  ui_page "失败来源处置" "只允许选择最近 24 小时 SSH 失败日志中的明确 IP"
  while IFS='|' read -r count address; do printf '  %8s  %s\n' "$count" "$address"; done <<<"$sources"
  address="$(read_input "来源 IP" "")"; [[ -n "$address" ]] || return 0
  security_exact_ip_valid "$address" || { warn "来源必须是明确的 IPv4 或 IPv6 地址。"; return 1; }
  awk -F '|' -v wanted="$address" '$2==wanted{found=1}END{exit !found}' <<<"$sources" || {
    warn "该地址不在当前失败来源清单中。"
    return 1
  }
  current_source="${SSH_CONNECTION:-}"
  current_source="${current_source%% *}"
  if [[ -n "$current_source" && "$address" == "$current_source" ]]; then
    warn "拒绝阻止当前 SSH 会话来源：$address"
    return 1
  fi
  ui_section "处置方式" "accent"
  ui_action 1 "加入 Fail2ban Jail" "warning" "临时封禁，时长由 Jail 配置决定"
  ui_action 2 "添加 UFW 来源拒绝" "danger" "持续阻止该来源访问本机"
  ui_menu_footer "取消"
  ui_read_choice action
  case "$action" in
    1)
      if ! command_exists fail2ban-client || ! fail2ban-client ping >/dev/null 2>&1; then
        warn "Fail2ban 未运行或当前用户无法访问。"
        return 1
      fi
      jails="$(security_fail2ban_jails || true)"
      [[ -n "$jails" ]] || { warn "没有启用的 Fail2ban Jail。"; return 1; }
      printf '%s\n' "$jails" | sed 's/^/  • /'
      if grep -Fxq sshd <<<"$jails"; then jail=sshd; else jail="$(head -n 1 <<<"$jails")"; fi
      jail="$(read_input "Jail 名称" "$jail")"
      grep -Fxq "$jail" <<<"$jails" || { warn "Jail 不存在：$jail"; return 1; }
      confirm "在 $jail 中封禁 $address？" || return 0
      require_root
      run fail2ban-client set "$jail" banip "$address" || { warn "Fail2ban 封禁失败。"; return 1; }
      if [[ "$DRY_RUN" -eq 0 ]]; then
        banned="$(fail2ban-client status "$jail" 2>/dev/null | sed -n 's/.*Banned IP list:[[:space:]]*//p')"
        tr ' ' '\n' <<<"$banned" | grep -Fxq "$address" || { warn "封禁后未在 Jail 中找到该地址。"; return 1; }
      fi
      audit "action=auth-source-ban method=fail2ban jail=$jail address=$address"
      ui_success "$address 已加入 Fail2ban Jail $jail"
      ;;
    2) security_firewall_block_source "$address" ;;
    0) return 0 ;;
    *) warn "未知选项"; return 1 ;;
  esac
}
