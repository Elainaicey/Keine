#!/usr/bin/env bash

security_firewall_expand_specs() {
  local raw="${1:-}" default_protocol="${2:-tcp}" clean token ports protocol
  local tokens=()
  local -A seen=()
  clean="${raw//[[:space:]]/}"
  [[ -n "$clean" && "$clean" != ,* && "$clean" != *, && "$clean" != *,,* ]] || return 1
  [[ "$default_protocol" == "tcp" || "$default_protocol" == "udp" || "$default_protocol" == "both" ]] || return 1
  IFS=',' read -r -a tokens <<<"$clean"
  ((${#tokens[@]} >= 1 && ${#tokens[@]} <= 20)) || return 1
  for token in "${tokens[@]}"; do
    if [[ "$token" == */* ]]; then
      valid_firewall_rule_spec "$token" || return 1
      [[ -n "${seen[$token]:-}" ]] || { printf '%s\n' "$token"; seen["$token"]=1; }
      continue
    fi
    valid_port_range "$token" || return 1
    ports="$token"
    if [[ "$default_protocol" == "both" ]]; then
      for protocol in tcp udp; do
        token="$ports/$protocol"
        [[ -n "${seen[$token]:-}" ]] || { printf '%s\n' "$token"; seen["$token"]=1; }
      done
    else
      token="$ports/$default_protocol"
      [[ -n "${seen[$token]:-}" ]] || { printf '%s\n' "$token"; seen["$token"]=1; }
    fi
  done
}

security_firewall_specs_need_protocol() {
  local clean token
  local tokens=()
  clean="${1//[[:space:]]/}"
  IFS=',' read -r -a tokens <<<"$clean"
  for token in "${tokens[@]}"; do [[ "$token" == */* ]] || return 0; done
  return 1
}

security_firewall_specs_label() {
  local specs=("$@") spec label=""
  for spec in "${specs[@]}"; do
    [[ -z "$label" ]] || label+=", "
    label+="$spec"
  done
  printf '%s' "$label"
}

security_enable_firewall() {
  local ssh_port raw spec
  local rules=()
  ssh_port="$(detect_ssh_port)"
  ui_page "启用基础防火墙" "保留当前 SSH 端口并应用默认入站策略"
  ui_panel_begin "变更摘要"
  ui_panel_kv "保留 SSH" "$ssh_port/tcp" "$GREEN"
  ui_panel_kv "默认入站" "拒绝"
  ui_panel_kv "默认出站" "允许"
  ui_panel_end
  ui_hint "格式：443/tcp, 80/tcp, 10000:10100/udp；最多 20 项。"
  raw="$(read_input "额外规则（逗号分隔，可留空）" "")"
  if [[ -n "$raw" ]]; then
    security_firewall_expand_specs "$raw" tcp >/dev/null || { warn "规则列表格式无效，请参考上方示例。"; return 1; }
    mapfile -t rules < <(security_firewall_expand_specs "$raw" tcp)
  fi
  confirm "安装并启用 UFW？" || return 0
  require_root
  package_install ufw || return 1
  run ufw allow "$ssh_port/tcp" || { warn "无法添加 SSH 保留规则。"; return 1; }
  for spec in "${rules[@]}"; do
    run ufw allow "$spec" || { warn "无法添加 UFW 规则：$spec"; return 1; }
  done
  run ufw default deny incoming || { warn "无法设置默认入站策略。"; return 1; }
  run ufw default allow outgoing || { warn "无法设置默认出站策略。"; return 1; }
  run ufw --force enable || { warn "UFW 启用失败。"; return 1; }
  if [[ "$DRY_RUN" -eq 0 ]]; then
    platform_firewall_active || { warn "UFW 命令完成后仍未处于启用状态。"; return 1; }
  fi
  audit "action=firewall-enable ssh_port=$ssh_port extra=${raw:-none}"
  ui_success "UFW 已启用，并保留 SSH 端口 $ssh_port/tcp"
}

security_firewall_rule() {
  local action="${1:-allow}" raw protocol_choice protocol_label source spec ports protocol ssh_port low high label=放行
  local rules=()
  [[ "$action" == allow || "$action" == deny ]] || return 1
  [[ "$action" != deny ]] || label=拒绝
  command_exists ufw || { warn "请先安装 UFW。"; return 1; }
  ui_page "添加 UFW $label 规则" "单条或批量端口，并可限制来源地址"
  ui_hint "格式：443/tcp, 80/tcp, 53/udp, 10000:10100/udp"
  raw="$(read_input "端口规则（逗号分隔）" "443/tcp")"
  security_firewall_expand_specs "$raw" tcp >/dev/null || { warn "端口规则格式无效，请参考上方示例。"; return 1; }
  if security_firewall_specs_need_protocol "$raw"; then
    ui_hint "未写 /tcp 或 /udp 的项目使用下面的公共协议。"
    ui_action 1 "TCP" "action"
    ui_action 2 "UDP" "action"
    ui_action 3 "TCP + UDP" "warning"
    ui_menu_footer "取消"
    ui_read_choice protocol_choice "公共协议" "1"
    case "$protocol_choice" in
      0) return 0 ;;
      1) protocol_label="TCP"; mapfile -t rules < <(security_firewall_expand_specs "$raw" tcp) ;;
      2) protocol_label="UDP"; mapfile -t rules < <(security_firewall_expand_specs "$raw" udp) ;;
      3) protocol_label="TCP + UDP"; mapfile -t rules < <(security_firewall_expand_specs "$raw" both) ;;
      *) warn "协议选项无效。"; return 1 ;;
    esac
  else
    protocol_label="由规则指定"
    mapfile -t rules < <(security_firewall_expand_specs "$raw" tcp)
  fi
  ui_hint "来源格式：any、203.0.113.10、10.0.0.0/8 或 IPv6 CIDR。"
  source="$(read_input "来源" "any")"
  valid_firewall_source "$source" || { warn "来源 IP 或 CIDR 格式无效。"; return 1; }
  if [[ "$action" == deny ]]; then
    ssh_port="$(detect_ssh_port)"
    for spec in "${rules[@]}"; do
      [[ "$spec" == */tcp ]] || continue
      ports="${spec%/*}"; low="${ports%%:*}"; high="${ports##*:}"
      if (( 10#$ssh_port >= 10#$low && 10#$ssh_port <= 10#$high )); then
        warn "拒绝规则覆盖当前 SSH 端口；请使用来源处置，不从此入口阻断管理端口。"; return 1
      fi
    done
    ui_danger "拒绝规则可能中断已有节点的入站访问；默认保留其他端口不变。"
  fi
  ui_section "规则预览" "accent"
  ui_kv "规则" "$(security_firewall_specs_label "${rules[@]}")"
  ui_kv "协议" "$protocol_label"
  ui_kv "来源" "$source"
  confirm "添加以上 $label 规则？" || return 0
  require_root
  for spec in "${rules[@]}"; do
    ports="${spec%/*}"
    protocol="${spec##*/}"
    if [[ "$source" == "any" ]]; then
      run ufw "$action" "$spec" || { warn "无法添加 UFW 规则：$spec"; return 1; }
    else
      run ufw "$action" from "$source" to any port "$ports" proto "$protocol" || {
        warn "无法添加 UFW 来源规则：$source → $spec"
        return 1
      }
    fi
  done
  audit "action=firewall-rule-add policy=$action rules=$(printf '%q' "$(security_firewall_specs_label "${rules[@]}")") source=$source"
  ui_success "已添加 ${#rules[@]} 条 UFW $label 规则；实际效果受规则顺序和 UFW 是否启用影响。"
}

security_firewall_limit() {
  local port source
  command_exists ufw || { warn "请先安装 UFW。"; return 1; }
  ui_page "UFW / TCP 连接限速" "优先规则，适用于 SSH；不建议限制节点业务端口"
  port="$(read_input "TCP 端口" "$(detect_ssh_port)")"
  source="$(read_input "来源 IP / CIDR / any" any)"
  if ! valid_port "$port" || ! valid_firewall_source "$source"; then warn "端口或来源格式无效。"; return 1; fi
  ui_kv "规则" "$source → $port/tcp"
  ui_hint "UFW 限制短时间内的新连接次数，不限制既有连接带宽。规则置于现有规则前，可按编号移除。"
  ui_danger "该规则也放行所选来源到该端口，可能扩大此前的来源限制；频繁重新连接 SSH 可能暂时被限速。"
  confirm "在规则首部添加以上 TCP 限速规则？" || return 0
  require_root
  if [[ "$source" == any ]]; then run ufw prepend limit "$port/tcp" || return 1
  else run ufw prepend limit from "$source" to any port "$port" proto tcp || return 1; fi
  audit "action=firewall-limit port=$port source=$source"
  ui_success "限速规则已保存；UFW 停用时不生效，请查看编号规则与完整状态。"
}

security_firewall_delete_rule() {
  local rules number
  command_exists ufw || { warn "请先安装 UFW。"; return 1; }
  ui_page "删除 UFW 规则" "按编号精确删除，避免协议或来源匹配歧义"
  rules="$(ufw status numbered 2>/dev/null || true)"
  printf '%s\n' "$rules"
  grep -q '^\[' <<<"$rules" || grep -q '^[[:space:]]*\[' <<<"$rules" || {
    ui_empty "当前没有可删除的编号规则"
    return 0
  }
  number="$(read_input "规则编号" "")"
  [[ "$number" =~ ^[0-9]+$ ]] || { warn "规则编号无效。"; return 1; }
  grep -Eq "^[[:space:]]*\\[[[:space:]]*$number\\]" <<<"$rules" || {
    warn "没有找到编号为 $number 的规则。"
    return 1
  }
  confirm "删除 UFW 规则 [$number]？" || return 0
  require_root
  run ufw --force delete "$number" || { warn "UFW 规则 [$number] 删除失败。"; return 1; }
  audit "action=firewall-rule-delete number=$number"
  ui_success "UFW 规则 [$number] 已删除"
}

security_firewall_disable() {
  ui_danger "禁用 UFW 会撤销主机层入站保护，但不会删除现有规则。"
  confirm "确认禁用 UFW？" || return 0
  require_root
  run ufw disable || { warn "UFW 禁用失败。"; return 1; }
  if [[ "$DRY_RUN" -eq 0 ]] && platform_firewall_active; then
    warn "UFW 命令完成后仍处于启用状态。"
    return 1
  fi
  audit "action=firewall-disable"
  ui_success "UFW 已禁用，现有规则仍被保留"
}

security_firewall_reload() {
  platform_firewall_active || { warn "UFW 当前未启用。"; return 1; }
  confirm "重新加载 UFW 规则？" || return 0
  require_root
  run ufw reload || { warn "UFW 规则重新加载失败。"; return 1; }
  audit "action=firewall-reload"
  ui_success "UFW 规则已重新加载"
}

security_firewall_logging() {
  local choice level
  command_exists ufw || { warn "请先安装 UFW。"; return 1; }
  ui_page "UFW 日志" "调整防火墙事件记录级别"
  ui_action 1 "关闭日志" "muted"
  ui_action 2 "低级别" "success" "适合日常运行"
  ui_action 3 "中级别" "warning"
  ui_menu_footer "取消"
  ui_read_choice choice "选择" "2"
  case "$choice" in
    0) return 0 ;;
    1) level=off ;;
    2) level=low ;;
    3) level=medium ;;
    *) warn "日志级别选项无效。"; return 1 ;;
  esac
  confirm "将 UFW 日志级别设置为 $level？" || return 0
  require_root
  run ufw logging "$level" || { warn "UFW 日志级别修改失败。"; return 1; }
  audit "action=firewall-logging level=$level"
  ui_success "UFW 日志级别已设置为 $level"
}

security_firewall_block_source() {
  local source="${1:-}" current_source
  command_exists ufw || { warn "请先安装 UFW。"; return 1; }
  platform_firewall_active || { warn "UFW 当前未启用，拒绝创建容易被误解为已生效的阻止规则。"; return 1; }
  if [[ -z "$source" ]]; then
    ui_hint "只接受明确的单个 IPv4 或 IPv6；需要网段策略时请使用专业防火墙规则管理。"
    source="$(read_input "待阻止来源 IP" "")"
  fi
  security_exact_ip_valid "$source" || { warn "来源必须是明确的 IPv4 或 IPv6 地址。"; return 1; }
  current_source="${SSH_CONNECTION:-}"
  current_source="${current_source%% *}"
  if [[ -n "$current_source" && "$source" == "$current_source" ]]; then
    warn "拒绝阻止当前 SSH 会话来源：$source"
    return 1
  fi
  ui_page "阻止来源地址" "$source · UFW 入站拒绝"
  ui_danger "该规则会阻止此地址访问本机所有入站端口；可稍后按编号删除。"
  confirm "添加 UFW 拒绝规则？" || return 0
  require_root
  run ufw deny from "$source" || { warn "UFW 来源拒绝规则添加失败。"; return 1; }
  if [[ "$DRY_RUN" -eq 0 ]]; then
    if ! ufw show added 2>/dev/null | grep -F -- "$source" | grep -Eq '(^|[[:space:]])deny([[:space:]]|$)'; then
      warn "规则执行后未能在 UFW 持久规则中确认来源拒绝。"
      return 1
    fi
  fi
  audit "action=firewall-source-deny source=$source"
  ui_success "UFW 已阻止来源 $source"
}

security_firewall_manage() {
  local action state defaults logging state_style
  while true; do
    if command_exists ufw; then
      if platform_firewall_active; then state="active"; state_style="$GREEN"; else state="inactive"; state_style="$YELLOW"; fi
      defaults="$(ufw status verbose 2>/dev/null | awk -F': ' '/^Default:/{print $2;exit}')"
      logging="$(ufw status verbose 2>/dev/null | awk -F': ' '/^Logging:/{print $2;exit}')"
    else
      state="未安装"
      state_style="$YELLOW"
      defaults="—"
      logging="—"
    fi
    ui_page "UFW 防火墙"
    ui_panel_begin "防火墙状态"
    ui_panel_kv "状态" "● $state" "$state_style"
    ui_panel_kv "默认策略" "${defaults:-未知}"
    ui_panel_kv "日志" "${logging:-未知}"
    ui_panel_kv "SSH 端口" "$(detect_ssh_port)/tcp"
    ui_panel_end
    ui_section "规则" "primary"
    ui_action 1 "查看完整状态" "action"
    ui_action 2 "添加放行规则" "success"
    ui_action 3 "删除编号规则" "danger"
    ui_section "运行控制" "accent"
    if [[ "$state" == "active" ]]; then
      ui_action 5 "禁用防火墙" "danger"
      ui_action 6 "重新加载规则" "warning"
    else
      ui_action 4 "启用基础防火墙" "success"
    fi
    ui_action 7 "调整日志级别" "action"
    ui_action 8 "阻止来源 IP" "danger"
    ui_action 9 "添加拒绝规则" "danger"
    ui_action 10 "TCP 连接限速" "warning"
    ui_menu_footer "返回"
    ui_read_choice action
    case "$action" in
      1) security_firewall_status || true; pause ;;
      2) security_firewall_rule allow || true; pause ;;
      3) security_firewall_delete_rule || true; pause ;;
      4) security_enable_firewall || true; pause ;;
      5)
        if [[ "$state" == "active" ]]; then security_firewall_disable || true; else warn "UFW 当前未启用。"; fi
        pause
        ;;
      6) security_firewall_reload || true; pause ;;
      7) security_firewall_logging || true; pause ;;
      8) security_firewall_block_source "" || true; pause ;;
      9) security_firewall_rule deny || true; pause ;;
      10) security_firewall_limit || true; pause ;;
      0) return 0 ;;
      *) warn "未知选项" ;;
    esac
  done
}
