#!/usr/bin/env bash

security_fail2ban_jails() {
  fail2ban-client status 2>/dev/null |
    sed -n 's/.*Jail list:[[:space:]]*//p' |
    tr ',' '\n' |
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d'
}

security_fail2ban_total_banned() {
  local jails="${1:-}" jail count total=0
  while IFS= read -r jail; do
    [[ -n "$jail" ]] || continue
    count="$(fail2ban-client status "$jail" 2>/dev/null | awk -F: '/Currently banned/{gsub(/[[:space:]]/,"",$2);print $2;exit}')"
    [[ "$count" =~ ^[0-9]+$ ]] && total=$((total + count))
  done <<<"$jails"
  printf '%s' "$total"
}

security_fail2ban_jail_setting() {
  local jail="$1" setting="$2" value
  case "$setting" in
    bantime|findtime|maxretry|logpath|journalmatch|ignoreip) ;;
    *) return 1 ;;
  esac
  value="$(fail2ban-client get "$jail" "$setting" 2>/dev/null || true)"
  value="${value//$'\n'/, }"
  printf '%s' "${value:-—}"
}

security_fail2ban_seconds_label() {
  local value="${1:-}"
  [[ "$value" =~ ^-?[0-9]+$ ]] || { printf '%s' "$value"; return 0; }
  if (( value < 0 )); then
    printf '永久'
  elif (( value % 86400 == 0 && value >= 86400 )); then
    printf '%s 天' "$((value / 86400))"
  elif (( value % 3600 == 0 && value >= 3600 )); then
    printf '%s 小时' "$((value / 3600))"
  elif (( value % 60 == 0 && value >= 60 )); then
    printf '%s 分钟' "$((value / 60))"
  else
    printf '%s 秒' "$value"
  fi
}

security_fail2ban_jail_manage() {
  local jails jail action banned address bantime findtime maxretry logpath
  jails="$(security_fail2ban_jails || true)"
  [[ -n "$jails" ]] || { warn "当前没有启用的 Jail。"; return 1; }
  ui_page "Fail2ban / Jail" "选择 Jail 查看封禁状态与解除误封"
  while IFS= read -r jail; do
    printf '  %b•%b %s\n' "$CYAN" "$NC" "$jail"
  done <<<"$jails"
  jail="$(read_input "Jail 名称" "")"
  grep -Fxq "$jail" <<<"$jails" || { warn "Jail 不存在或当前未启用：$jail"; return 1; }
  while true; do
    bantime="$(security_fail2ban_jail_setting "$jail" bantime)"
    findtime="$(security_fail2ban_jail_setting "$jail" findtime)"
    maxretry="$(security_fail2ban_jail_setting "$jail" maxretry)"
    logpath="$(security_fail2ban_jail_setting "$jail" logpath)"
    ui_page "Fail2ban / $jail" "实时封禁、有效参数、手动处置与单 Jail 重载"
    fail2ban-client status "$jail" 2>/dev/null | sed -n '1,16p'
    banned="$(fail2ban-client status "$jail" 2>/dev/null | sed -n 's/.*Banned IP list:[[:space:]]*//p')"
    ui_panel_begin "有效参数"
    ui_panel_kv "封禁时间" "$(security_fail2ban_seconds_label "$bantime")"
    ui_panel_kv "观察窗口" "$(security_fail2ban_seconds_label "$findtime")"
    ui_panel_kv "最大重试" "$maxretry 次"
    ui_panel_kv "日志来源" "$logpath"
    ui_panel_end
    ui_section "操作" "accent"
    ui_action 1 "解除一个 IP 的封禁" "warning"
    ui_action 2 "手动封禁一个 IP" "danger" "立即加入当前 Jail 的封禁集合"
    ui_action 3 "重新加载当前 Jail" "warning" "应用该 Jail 的磁盘配置"
    ui_menu_footer "返回"
    ui_read_choice action
    case "$action" in
      1)
        [[ -n "$banned" ]] || { warn "当前 Jail 没有封禁 IP。"; pause; continue; }
        address="$(read_input "待解除的 IP" "")"
        if ! valid_firewall_source "$address" || [[ "$address" == "any" || "$address" == */* ]]; then
          warn "IP 地址格式无效。"
          pause
          continue
        fi
        tr ' ' '\n' <<<"$banned" | grep -Fxq "$address" || {
          warn "$address 不在当前封禁清单中。"
          pause
          continue
        }
        confirm "从 $jail 解除 $address 的封禁？" || continue
        require_root
        run fail2ban-client set "$jail" unbanip "$address" || { warn "Fail2ban 解除封禁命令失败。"; pause; continue; }
        if [[ "$DRY_RUN" -eq 0 ]]; then
          banned="$(fail2ban-client status "$jail" 2>/dev/null | sed -n 's/.*Banned IP list:[[:space:]]*//p')"
          tr ' ' '\n' <<<"$banned" | grep -Fxq "$address" && { warn "$address 仍在封禁清单中。"; pause; continue; }
        fi
        audit "action=fail2ban-unban jail=$jail address=$address"
        ui_success "$address 已从 $jail 解除封禁"
        pause
        ;;
      2)
        address="$(read_input "待封禁的 IP" "")"
        if ! valid_firewall_source "$address" || [[ "$address" == "any" || "$address" == */* ]]; then
          warn "IP 地址格式无效。"
          pause
          continue
        fi
        if security_source_is_current "$address"; then
          warn "拒绝封禁当前 SSH 会话来源。"; pause; continue
        fi
        if tr ' ' '\n' <<<"$banned" | grep -Fxq "$address"; then
          info "$address 已在当前封禁清单中。"
          pause
          continue
        fi
        ui_danger "手动封禁会立即阻止该地址匹配 $jail 的受保护服务。"
        confirm "在 $jail 中封禁 $address？" || continue
        require_root
        run fail2ban-client set "$jail" banip "$address" || { warn "Fail2ban 手动封禁命令失败。"; pause; continue; }
        if [[ "$DRY_RUN" -eq 0 ]]; then
          banned="$(fail2ban-client status "$jail" 2>/dev/null | sed -n 's/.*Banned IP list:[[:space:]]*//p')"
          tr ' ' '\n' <<<"$banned" | grep -Fxq "$address" || { warn "$address 没有进入封禁清单。"; pause; continue; }
        fi
        audit "action=fail2ban-ban jail=$jail address=$address"
        ui_success "$address 已加入 $jail 的封禁集合"
        pause
        ;;
      3)
        confirm "重新加载 $jail 的配置？" || continue
        require_root
        run fail2ban-client reload "$jail" || { warn "$jail 重新加载失败。"; pause; continue; }
        if [[ "$DRY_RUN" -eq 0 ]]; then
          security_fail2ban_jails | grep -Fxq "$jail" || { warn "重新加载后 $jail 未处于启用状态。"; pause; continue; }
        fi
        audit "action=fail2ban-jail-reload jail=$jail"
        ui_success "$jail 已重新加载"
        pause
        ;;
      0) return 0 ;;
      *) warn "未知选项" ;;
    esac
  done
}

security_fail2ban_reload() {
  confirm "重新加载 Fail2ban 配置？" || return 0
  require_root
  fail2ban-client -t >/dev/null 2>&1 || { warn "配置检查失败，未执行重载。"; return 1; }
  run fail2ban-client reload || { warn "Fail2ban 配置重新加载失败。"; return 1; }
  if [[ "$DRY_RUN" -eq 0 ]]; then
    fail2ban-client ping >/dev/null 2>&1 || { warn "重新加载后 Fail2ban 无法响应。"; return 1; }
  fi
  audit "action=fail2ban-reload"
  ui_success "Fail2ban 配置已重新加载"
}

security_fail2ban() {
  local action state enabled version jails jail_count banned style client_ready
  while true; do
    if ! command_exists fail2ban-client; then
      ui_page "Fail2ban 管理" "安装登录防护并管理服务生命周期"
      ui_panel_begin "组件状态"
      ui_panel_kv "安装状态" "未安装" "$YELLOW"
      ui_panel_end
      ui_section "操作" "accent"
      ui_action 1 "安装 Fail2ban" "success" "通过软件目录安装单个系统包"
      ui_menu_footer "返回"
      ui_read_choice action
      case "$action" in
        1) catalog_install fail2ban || true; pause ;;
        0) return 0 ;;
        *) warn "未知选项" ;;
      esac
      continue
    fi

    state="$(service_state fail2ban.service)"
    enabled="$(systemctl is-enabled fail2ban.service 2>/dev/null || true)"
    enabled="${enabled:-disabled}"
    version="$(fail2ban-client --version 2>/dev/null | head -n 1 || true)"
    jails=""
    jail_count=0
    banned=0
    client_ready=0
    if [[ "$state" == "active" ]]; then
      style="$GREEN"
      if fail2ban-client ping >/dev/null 2>&1; then
        client_ready=1
        jails="$(security_fail2ban_jails || true)"
        jail_count="$(grep -c . <<<"$jails" || true)"
        banned="$(security_fail2ban_total_banned "$jails")"
      else
        jail_count="不可读取"
        banned="不可读取"
      fi
    else
      style="$YELLOW"
    fi

    ui_page "Fail2ban 管理"
    ui_panel_begin "运行状态"
    ui_panel_kv "状态" "● $state" "$style"
    ui_panel_kv "开机启动" "$enabled"
    ui_panel_kv "版本" "${version:-未知}"
    ui_panel_kv "启用 Jail" "$jail_count"
    ui_panel_kv "当前封禁" "$banned"
    ui_panel_end
    if [[ "$state" == "active" && "$client_ready" -eq 0 ]]; then
      ui_note "服务正在运行，但当前用户无法读取 Fail2ban Socket；请使用 sudo keine。"
    fi
    ui_section "观察与处置" "primary"
    ui_action 1 "查看全部 Jail" "action"
    ui_action 2 "管理一个 Jail" "action"
    ui_action 3 "查看服务日志" "action"
    ui_action 4 "重新加载配置" "warning"
    ui_action C "配置 SSH Jail 策略" "action"
    ui_action R "撤销项目 Jail 策略" "warning"
    ui_section "服务生命周期" "accent"
    if [[ "$state" == "active" ]]; then
      ui_action 6 "停止服务" "danger"
      ui_action 7 "重启服务" "warning"
    else
      ui_action 5 "启动服务" "success"
      ui_action 7 "重启服务" "warning"
    fi
    if [[ "$enabled" == "enabled" ]]; then
      ui_action 9 "禁用开机启动" "danger"
    else
      ui_action 8 "启用开机启动" "success"
    fi
    ui_menu_footer "返回"
    ui_read_choice action
    case "$action" in
      1)
        ui_page "Fail2ban Jail" "全部已启用 Jail 的封禁统计"
        if [[ "$client_ready" -eq 1 && -n "$jails" ]]; then
          local jail
          while IFS= read -r jail; do
            fail2ban-client status "$jail" 2>/dev/null | sed -n '1,12p'
            printf '\n'
          done <<<"$jails"
        else
          ui_empty "服务未运行或没有启用的 Jail"
        fi
        pause
        ;;
      2)
        if [[ "$client_ready" -eq 1 ]]; then security_fail2ban_jail_manage || true; else warn "Fail2ban 未运行或当前用户无权读取。"; fi
        pause
        ;;
      3) services_logs fail2ban.service; pause ;;
      4)
        if [[ "$state" == "active" ]]; then security_fail2ban_reload || true; else warn "请先启动 Fail2ban。"; fi
        pause
        ;;
      5) services_apply_action fail2ban.service start || true; pause ;;
      6) services_apply_action fail2ban.service stop || true; pause ;;
      7) services_apply_action fail2ban.service restart || true; pause ;;
      8) services_apply_action fail2ban.service enable || true; pause ;;
      9) services_apply_action fail2ban.service disable || true; pause ;;
      C|c) security_fail2ban_policy_configure || true; pause ;;
      R|r) security_fail2ban_policy_restore || true; pause ;;
      0) return 0 ;;
      *) warn "未知选项" ;;
    esac
  done
}
