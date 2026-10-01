#!/usr/bin/env bash

NETWORK_BBR_FILE="${KEINE_BBR_FILE:-/etc/sysctl.d/98-keine-bbr.conf}"

network_bbr_apply_file() {
  [[ -f "$NETWORK_BBR_FILE" ]] || return 0
  if ! grep -Eq '^net.core.default_qdisc[[:space:]]*=[[:space:]]*fq$' "$NETWORK_BBR_FILE" ||
    ! grep -Eq '^net.ipv4.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr$' "$NETWORK_BBR_FILE"; then return 1; fi
  network_sysctl_apply_values net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr
}

network_enable_bbr() {
  local available current payload
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '未知')"
  ui_page "启用 BBR" "原生内核能力、独立持久配置与完整基线恢复"
  if [[ -e "$NETWORK_BBR_FILE" ]] && ! config_project_marker "$NETWORK_BBR_FILE"; then
    warn "目标文件不属于项目，拒绝覆盖。"; return 1
  fi
  ui_hint "只设置拥塞算法与默认队列；不更换内核、不重建当前网卡队列，也不加载第三方 sysctl 文件。"
  confirm "启用 BBR，并记录当前拥塞算法与默认队列？" || return 0
  require_root
  if [[ " $available " != *" bbr "* ]] && command_exists modprobe; then
    run modprobe tcp_bbr || true
    (( DRY_RUN == 1 )) || available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  fi
  [[ "$DRY_RUN" == 1 || " $available " == *" bbr "* ]] || { warn "当前内核不支持 BBR。"; return 1; }
  payload="$(printf '# Managed by keine\n# Previous: %s\nnet.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' "$current")"
  config_file_write "$NETWORK_BBR_FILE" 0644 "$payload" network_bbr_apply_file || return 1
  audit "action=enable-bbr previous=$current"
  ui_success "BBR 配置操作完成。"
}

network_restore_bbr() {
  if [[ ! -d "$(changes_file_entry "$NETWORK_BBR_FILE")" ||
    ! -d "$(changes_root)/settings/bbr" || ! -d "$(changes_root)/settings/qdisc" ]]; then
    warn "此 BBR 配置没有完整的初始基线，不能猜测原始算法与队列；请先核实历史快照。"; return 1
  fi
  network_sysctl_restore_group "$NETWORK_BBR_FILE" net.core.default_qdisc net.ipv4.tcp_congestion_control
}

network_bbr_manage() {
  local current available managed="否" action
  current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '未知')"
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || printf '未知')"
  if [[ -f "$NETWORK_BBR_FILE" ]] &&
    config_project_marker "$NETWORK_BBR_FILE"; then
    managed="是"
  fi
  ui_page "BBR 拥塞控制" "查看内核能力、启用 BBR 或恢复托管配置"
  ui_panel_begin "当前状态"
  if [[ "$current" == "bbr" ]]; then ui_panel_kv "当前算法" "● bbr" "$GREEN"; else ui_panel_kv "当前算法" "● $current" "$YELLOW"; fi
  ui_panel_kv "可用算法" "$available"
  ui_panel_kv "工具托管" "$managed"
  ui_panel_end
  ui_section "操作" "accent"
  ui_action 1 "启用 BBR" "success"
  if [[ "$managed" == "是" ]]; then
    ui_action 2 "恢复系统设置" "warning" "移除工具管理的持久化配置"
  else
    ui_action 2 "恢复系统设置" "muted" "没有工具管理的配置"
  fi
  ui_action 0 "返回" "muted"
  action="$(read_input "请选择" "0")"
  case "$action" in
    1) network_enable_bbr ;;
    2) network_restore_bbr ;;
    0) return 0 ;;
    *) warn "未知选项"; return 1 ;;
  esac
}

network_set_address_preference() {
  ui_page "IP 地址优先级" "设置 IPv4 优先或恢复系统默认地址选择"
  ui_action 1 "IPv4 优先" "action"
  ui_action 2 "恢复系统默认" "warning"
  ui_action 0 "取消" "muted"
  local choice action="恢复系统默认地址选择"
  choice="$(read_input "请选择" "0")"
  [[ "$choice" == "1" || "$choice" == "2" ]] || return 0
  if [[ "$choice" == "1" ]]; then
    action="设置 IPv4 优先"
  fi
  confirm "$action？" || return 0
  require_root
  local config=/etc/gai.conf temporary=""
  changes_prepare_file "$config" || { warn "无法登记 $config 的初始状态。"; return 1; }
  if [[ "$DRY_RUN" -eq 1 ]]; then info "将更新 $config。"; return 0; fi
  temporary="$(mktemp)" || { warn "无法创建地址优先级临时文件。"; return 1; }
  if [[ -f "$config" ]]; then
    awk '
      $0 == "# BEGIN keine" {managed=1; next}
      $0 == "# END keine" && managed {managed=0; next}
      !managed {print}
    ' "$config" >"$temporary" || { rm -f "$temporary"; warn "无法读取 $config。"; return 1; }
  fi
  if [[ "$choice" == "1" ]]; then
    cat >>"$temporary" <<'EOF'

# BEGIN keine
precedence ::ffff:0:0/96 100
# END keine
EOF
  fi
  install -m 0644 "$temporary" "$config" || { rm -f "$temporary"; warn "无法更新 $config。"; return 1; }
  rm -f "$temporary"
  if [[ "$choice" == "1" ]]; then
    grep -Fqx 'precedence ::ffff:0:0/96 100' "$config" || { warn "IPv4 优先级写入后验证失败。"; return 1; }
  elif grep -Fq '# BEGIN keine' "$config"; then
    warn "托管的地址优先级配置未完全移除。"
    return 1
  fi
  audit "action=set-address-preference mode=$choice"
  ui_success "$action 完成"
}
