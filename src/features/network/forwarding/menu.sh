#!/usr/bin/env bash

declare -Ag FORWARD_RULE

forward_edit() {
  local path="${1:-}" id protocol listen port target target_port idle boot=0 active=1 mode=create
  if [[ -n "$path" ]]; then
    mode=edit
    forward_owned "$path" && forward_load "$path" || return 1
    id="${FORWARD_RULE[id]}"; boot="${FORWARD_RULE[boot]}"; active="${FORWARD_RULE[active]}"
    ui_page "修改转发 / $id"
    ui_note "修改运行中的规则会中断该规则的现有连接。"
  else
    FORWARD_RULE=()
    ui_page "新建 TCP / UDP 转发"
    id="$(read_input '规则名称（小写字母、数字、连字符；0 返回）')"
    [[ "$id" != 0 ]] || return 0
    forward_id_valid "$id" || { warn "名称以小写字母开头，最多 32 字符。"; return 1; }
    path="$(forward_path "$id")"
    [[ ! -e "$path" && ! -L "$path" ]] || { warn "同名规则已存在。"; return 1; }
  fi
  ui_section "转发端点" primary
  protocol="$(read_input '协议：tcp / udp' "${FORWARD_RULE[protocol]:-tcp}")"; protocol="${protocol,,}"
  listen="$(read_input '监听 IP（0.0.0.0 为全部 IPv4，:: 为全部 IPv6）' "${FORWARD_RULE[listen]:-127.0.0.1}")"
  port="$(read_input '监听端口' "${FORWARD_RULE[port]:-}")"
  target="$(read_input '目标 IP（IPv6 不加方括号）' "${FORWARD_RULE[target]:-}")"
  target_port="$(read_input '目标端口' "${FORWARD_RULE[target_port]:-}")"
  idle="${FORWARD_RULE[idle]:-120}"
  [[ "$protocol" != udp ]] || idle="$(read_input 'UDP 空闲回收（秒，1–3600）' "$idle")"
  if ! valid_port "$port" || ! valid_port "$target_port"; then warn "端口范围为 1–65535。"; return 1; fi
  FORWARD_RULE=([id]="$id" [protocol]="$protocol" [listen]="$listen" [port]="$((10#$port))"
    [target]="$target" [target_port]="$((10#$target_port))" [idle]="$idle" [active]="$active" [boot]="$boot")
  forward_values_valid || { warn "规则参数无效，请检查协议、IP 与端口。"; return 1; }
  ui_kv "规则" "$protocol · $listen:$port → $target:$target_port"
  ui_note "目标看到的是 VPS 出站地址；不自动放行防火墙。每条规则最多 128 个并发会话。"
  if [[ "$listen" == 0.0.0.0 || "$listen" == :: ]]; then ui_callout warn "监听全部地址" "公网放行后可被外部访问；请限制来源，不要暴露无认证服务。"; fi
  confirm "保存并应用转发规则？" || return 0
  forward_save "$mode"
}

forward_detail() {
  local path="$1" choice state boot
  while [[ -f "$path" ]]; do
    forward_load "$path" || { warn "规则无法解析，保留原文件：$path"; return 1; }
    ui_page "端口转发 / ${FORWARD_RULE[id]}"
    state="$(service_state "${path##*/}")"; boot=关闭
    systemctl is-enabled --quiet "${path##*/}" && boot=开启
    ui_panel_begin "规则"
    ui_panel_kv "协议" "${FORWARD_RULE[protocol]}"
    ui_panel_kv "监听" "${FORWARD_RULE[listen]}:${FORWARD_RULE[port]}"
    ui_panel_kv "目标" "${FORWARD_RULE[target]}:${FORWARD_RULE[target_port]}"
    ui_panel_kv "运行" "$state"
    ui_panel_kv "开机启动" "$boot"
    [[ "${FORWARD_RULE[protocol]}" != udp ]] || ui_panel_kv "空闲回收" "${FORWARD_RULE[idle]} 秒"
    ui_panel_end
    ui_section "规则管理" primary
    ui_action 1 "修改规则" action
    if [[ "$state" == active ]]; then ui_action 2 "停止转发" warning
    else ui_action 2 "启动转发" success; fi
    ui_action 3 "切换开机启动" warning
    ui_section "诊断与访问" primary
    ui_action 4 "查看日志" action
    ui_action 5 "检查目标" action
    ui_action 6 "主机防火墙" action
    ui_section "操作" primary
    ui_action R "刷新状态" accent
    ui_action D "删除规则" danger
    ui_menu_footer "返回"; ui_read_choice choice
    case "$choice" in
      0) return 0 ;;
      1) forward_edit "$path" || true ;;
      2)
        [[ "$state" != active ]] && FORWARD_RULE[active]=1 || FORWARD_RULE[active]=0
        if confirm "应用转发运行状态？"; then forward_save || true; fi ;;
      3)
        if [[ "$boot" == 开启 ]]; then FORWARD_RULE[boot]=0; else FORWARD_RULE[boot]=1; fi
        if [[ "$state" == active ]]; then FORWARD_RULE[active]=1; else FORWARD_RULE[active]=0; fi
        if confirm "修改此转发服务的开机策略？"; then forward_save || true; fi ;;
      4) services_logs "${path##*/}" || true ;;
      5)
        if [[ "${FORWARD_RULE[protocol]}" == tcp ]]; then network_endpoint_probe "${FORWARD_RULE[target]}" "${FORWARD_RULE[target_port]}" || true
        else ui_note "UDP 无握手；请从客户端发送实际业务流量，结合服务日志确认。"; fi ;;
      6) security_firewall_manage; continue ;;
      R|r) continue ;;
      D|d) if confirm "停止并删除该转发？不移除 socat 或防火墙规则。"; then forward_remove "$path" || true; fi ;;
      *) warn "未知选项" ;;
    esac
    pause
  done
}

forward_menu() {
  local choice index start page=0 paths=()
  while true; do
    mapfile -t paths < <(forward_paths)
    (( page*6 < ${#paths[@]} )) || page=0
    start=$((page*6))
    ui_page "TCP / UDP 转发"
    ui_section "转发规则" primary
    for ((index=start; index<start+6 && index<${#paths[@]}; index++)); do
      if forward_load "${paths[$index]}"; then
        ui_action "$((index-start+1))" "${FORWARD_RULE[id]}" action "${FORWARD_RULE[protocol]} · ${FORWARD_RULE[port]} → ${FORWARD_RULE[target]}:${FORWARD_RULE[target_port]}"
      else ui_action "$((index-start+1))" "${paths[$index]##*/}" warning "配置需人工检查"; fi
    done
    (( ${#paths[@]} > 0 )) || ui_empty "尚无转发规则"
    (( page == 0 )) || ui_action P "上一页" action
    (( start+6 >= ${#paths[@]} )) || ui_action N "下一页" action
    ui_section "操作" primary
    ui_action A "新建转发" success
    ui_action I "安装 / 更新 socat" action
    ui_action R "刷新列表" accent
    ui_menu_footer "返回"; ui_read_choice choice
    case "$choice" in
      0) return 0 ;;
      A|a) forward_edit || true ;;
      I|i) catalog_item_menu socat; continue ;;
      R|r) continue ;;
      P|p) (( page == 0 )) || page=$((page-1)); continue ;;
      N|n) (( start+6 >= ${#paths[@]} )) || page=$((page+1)); continue ;;
      *)
        if [[ "$choice" =~ ^[1-6]$ ]] && (( start+choice <= ${#paths[@]} )); then forward_detail "${paths[$((start+choice-1))]}" || true
        else warn "未知选项"; fi ;;
    esac
    pause
  done
}
