#!/usr/bin/env bash

declare -Ag FRP_CONFIG
declare -ag FRP_MAPS

frp_sync_runtime() {
  local unit
  unit="$(frp_unit_path "${FRP_CONFIG[role]}")"; unit="${unit##*/}"
  FRP_CONFIG[active]=0; FRP_CONFIG[boot]=0
  if systemctl is-active --quiet "$unit"; then FRP_CONFIG[active]=1; fi
  if systemctl is-enabled --quiet "$unit"; then FRP_CONFIG[boot]=1; fi
}

frp_edit() {
  local role="$1" mode=edit value path
  path="$(frp_config_path "$role")" || return 1
  if [[ -e "$path" || -L "$path" ]]; then
    frp_owned "$role" && frp_load "$role" || return 1
    frp_sync_runtime
  else
    mode=create; FRP_CONFIG=([role]="$role" [port]=7000 [active]=1 [boot]=0); FRP_MAPS=()
  fi
  ui_page "FRP / $role 配置"
  if [[ "$role" == frps ]]; then
    FRP_CONFIG[addr]="$(read_input '控制连接监听 IP' "${FRP_CONFIG[addr]:-0.0.0.0}")"
    FRP_CONFIG[port]="$(read_input '控制端口' "${FRP_CONFIG[port]}")"
    ui_hint "映射监听 127.0.0.1 适合本机反代；0.0.0.0 或 :: 可对外提供访问。"
    FRP_CONFIG[proxy_addr]="$(read_input '映射监听 IP' "${FRP_CONFIG[proxy_addr]:-127.0.0.1}")"
    FRP_CONFIG[first]="$(read_input '允许的映射端口起点' "${FRP_CONFIG[first]:-10000}")"
    FRP_CONFIG[last]="$(read_input '允许的映射端口终点' "${FRP_CONFIG[last]:-20000}")"
    ui_hint "令牌留空：已有实例保留，新实例生成随机令牌；可从详情单独查看。"
  else
    FRP_CONFIG[addr]="$(read_input '服务端域名或 IP' "${FRP_CONFIG[addr]:-}")"
    FRP_CONFIG[port]="$(read_input '服务端控制端口' "${FRP_CONFIG[port]}")"
    FRP_CONFIG[user]="$(read_input '客户端标识（小写字母、数字、连字符）' "${FRP_CONFIG[user]:-node}")"
    ui_hint "同一服务端的客户端标识应唯一；已有令牌可留空保留。"
  fi
  value="$(read_secret '连接令牌（16–128 位字母、数字、下划线或连字符）')" || return 1
  if [[ -n "$value" ]]; then FRP_CONFIG[token]="$value"
  elif [[ -z "${FRP_CONFIG[token]:-}" && "$role" == frps ]]; then
    FRP_CONFIG[token]="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')" || return 1
  fi
  frp_values_valid || { warn "参数无效；端口为 1–65535，允许范围不能包含控制端口。"; return 1; }
  if [[ "$mode" == create ]]; then
    value="$(read_input '立即启动（y/n；未准备好对端可选 n）' y)"
    case "$value" in y|Y) FRP_CONFIG[active]=1 ;; n|N) FRP_CONFIG[active]=0 ;; *) return 1 ;; esac
  fi
  ui_kv "控制端点" "${FRP_CONFIG[addr]}:${FRP_CONFIG[port]}"
  if [[ "$role" == frps ]]; then
    ui_kv "映射范围" "${FRP_CONFIG[proxy_addr]} · ${FRP_CONFIG[first]}–${FRP_CONFIG[last]}"
    ui_note "仅持有令牌的客户端可申请范围内端口；公网访问还需主机防火墙和云端安全组放行。"
  fi
  ui_note "修改运行中的实例会中断现有隧道。新实例默认不开机启动。"
  confirm "保存并应用 FRP 配置？" || return 0
  frp_save "$mode"
}

frp_mapping_edit() {
  local index="${1:--1}" name='' type=tcp host=127.0.0.1 port='' remote='' enabled=1
  frp_owned frpc && frp_load frpc || return 1
  frp_sync_runtime
  if (( index >= 0 )); then IFS='|' read -r name type host port remote enabled <<<"${FRP_MAPS[$index]}"; fi
  ui_page "FRP / TCP 与 UDP 映射"
  name="$(read_input '映射名称（小写字母、数字、连字符）' "$name")"
  type="$(read_input '协议 tcp / udp' "$type")"
  host="$(read_input '客户端可访问的目标 IP 或域名' "$host")"
  port="$(read_input '目标端口' "$port")"
  remote="$(read_input '服务端映射端口' "$remote")"
  if (( index < 0 )); then FRP_MAPS+=("$name|$type|$host|$port|$remote|$enabled")
  else FRP_MAPS[index]="$name|$type|$host|$port|$remote|$enabled"; fi
  frp_values_valid || { warn "映射参数无效、名称重复或启用映射的远端端口冲突。"; return 1; }
  ui_kv "映射" "$type · 服务端 $remote → $host:$port"
  ui_note "映射端口须处于服务端允许范围。应用时会重启客户端，中断该客户端全部现有隧道。"
  confirm "保存映射并应用？" || return 0
  frp_save
}

frp_mapping_detail() {
  local index="$1" choice name type host port remote enabled
  while true; do
    frp_owned frpc && frp_load frpc || return 1
    [[ -v 'FRP_MAPS[$index]' ]] || return 0
    IFS='|' read -r name type host port remote enabled <<<"${FRP_MAPS[$index]}"
    ui_page "FRP / 映射 $name"
    ui_kv "协议与端点" "$type · 服务端 $remote → $host:$port"
    ui_kv "配置状态" "$([[ "$enabled" == 1 ]] && printf 启用 || printf 停用)"
    ui_action 1 "修改映射" action
    ui_action 2 "切换启用状态" warning
    ui_action D "删除映射" danger
    ui_menu_footer "返回"; ui_read_choice choice
    case "$choice" in
      0) return 0 ;;
      1) frp_mapping_edit "$index" || true ;;
      2|D|d)
        ui_note "会重新应用客户端配置，中断其全部现有隧道。"
        confirm "确认修改此映射？" || continue
        frp_sync_runtime
        if [[ "$choice" == 2 ]]; then FRP_MAPS[index]="$name|$type|$host|$port|$remote|$((1-enabled))"
        else unset 'FRP_MAPS[$index]'; FRP_MAPS=("${FRP_MAPS[@]}"); fi
        frp_save || { pause; continue; }
        [[ "$choice" == 2 ]] || return 0 ;;
      *) warn "未知选项" ;;
    esac
    pause
  done
}

frp_mappings_menu() {
  local page=0 start index choice name type host port remote enabled
  while true; do
    frp_owned frpc && frp_load frpc || return 1
    (( page*6 < ${#FRP_MAPS[@]} )) || page=0; start=$((page*6))
    ui_page "FRP / 客户端映射"
    for ((index=start; index<start+6 && index<${#FRP_MAPS[@]}; index++)); do
      IFS='|' read -r name type host port remote enabled <<<"${FRP_MAPS[$index]}"
      ui_item "$((index-start+1))" "$name" "$type · $remote → $host:$port · $([[ "$enabled" == 1 ]] && printf 启用 || printf 停用)"
    done
    (( ${#FRP_MAPS[@]} > 0 )) || ui_empty "尚无映射"
    ui_action A "添加映射" success
    (( page == 0 )) || ui_action P "上一页" action
    (( start+6 >= ${#FRP_MAPS[@]} )) || ui_action N "下一页" action
    ui_menu_footer "返回"; ui_read_choice choice
    case "$choice" in
      0) return 0 ;;
      A|a) frp_mapping_edit || true ;;
      P|p) (( page == 0 )) || page=$((page-1)); continue ;;
      N|n) (( start+6 >= ${#FRP_MAPS[@]} )) || page=$((page+1)); continue ;;
      *)
        if [[ "$choice" =~ ^[1-6]$ ]] && (( start+choice <= ${#FRP_MAPS[@]} )); then frp_mapping_detail "$((start+choice-1))" || true
        else warn "未知选项"; fi ;;
    esac
    pause
  done
}

frp_role_menu() {
  local role="$1" choice path unit state boot
  frp_role_valid "$role" || return 1
  path="$(frp_config_path "$role")"; unit="$(frp_unit_path "$role")"; unit="${unit##*/}"
  while true; do
    ui_page "FRP / $([[ "$role" == frps ]] && printf 服务端 || printf 客户端)"
    if [[ -f "$path" ]] && frp_load "$role"; then
      state="$(service_state "$unit")"; boot="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
      ui_kv "服务" "$state · 开机 ${boot:-未知}"
      ui_kv "控制端点" "${FRP_CONFIG[addr]}:${FRP_CONFIG[port]}"
      if [[ "$role" == frps ]]; then ui_kv "映射范围" "${FRP_CONFIG[proxy_addr]} · ${FRP_CONFIG[first]}–${FRP_CONFIG[last]}"
      else ui_kv "客户端" "${FRP_CONFIG[user]} · ${#FRP_MAPS[@]} 条映射"; fi
    else ui_note "尚无可读取的托管实例。"; fi
    ui_section "配置与连接" primary
    ui_action 1 "创建 / 修改配置" action
    [[ "$role" != frpc ]] || ui_action 2 "TCP / UDP 映射" action
    ui_action 3 "连接与配置检查" action
    ui_action 4 "最近日志" action
    ui_section "服务" primary
    ui_action 5 "启动 / 停止" action
    ui_action 6 "重启并验证" warning
    ui_action 7 "切换开机启动" warning
    ui_section "关联操作" primary
    ui_action I "安装 / 更新软件" action
    ui_action F "主机防火墙" action
    [[ "$role" != frps ]] || ui_action W "反向代理与 HTTPS" action
    ui_action K "查看连接令牌" warning
    ui_action D "移除托管实例" danger "保留软件"
    ui_action R "刷新状态" accent
    ui_menu_footer "返回"; ui_read_choice choice
    case "$choice" in
      0) return 0 ;;
      1) frp_edit "$role" || true ;;
      2) if [[ "$role" == frpc ]]; then frp_mappings_menu || true; fi ;;
      3) frp_diagnose "$role" || true ;;
      4) frp_logs "$role" || true ;;
      5|6|7)
        if ! frp_owned "$role" || ! frp_load "$role"; then warn "请先创建完整的托管实例。"; pause; continue; fi
        frp_sync_runtime
        case "$choice" in
          5) FRP_CONFIG[active]="$((1-FRP_CONFIG[active]))" ;;
          6) FRP_CONFIG[active]=1 ;;
          7) FRP_CONFIG[boot]="$((1-FRP_CONFIG[boot]))" ;;
        esac
        if [[ "$choice" == 7 ]]; then ui_note "只修改开机策略，保持当前运行状态。"
        else ui_note "启停或重启会中断当前隧道。"; fi
        if confirm "应用 FRP 服务状态？"; then
          if [[ "$choice" == 6 ]]; then frp_save restart || true; else frp_save || true; fi
        fi ;;
      I|i) catalog_item_menu "$role"; continue ;;
      F|f) security_firewall_manage; continue ;;
      W|w) if [[ "$role" == frps ]]; then web_menu; fi; continue ;;
      K|k)
        require_root
        if (( DRY_RUN == 0 )) && frp_owned "$role" && frp_load "$role" && confirm "在当前终端显示连接令牌？请避免录屏或共享终端。"; then
          printf '连接令牌：%s\n' "${FRP_CONFIG[token]}"
        fi ;;
      D|d)
        if confirm "停止并移除 $role 托管配置和服务？客户端映射将一并移除。"; then frp_remove "$role" || true; fi ;;
      R|r) continue ;;
      *) warn "未知选项" ;;
    esac
    pause
  done
}

frp_menu() {
  local choice
  while true; do
    ui_page "FRP 隧道管理"
    ui_section "实例" primary
    ui_action 1 "服务端 frps" action "部署在可被客户端访问的 VPS"
    ui_action 2 "客户端 frpc" action "部署在能访问目标服务的主机"
    ui_section "检查" primary
    ui_action 3 "识别已有实例" action
    ui_menu_footer "返回"; ui_read_choice choice
    case "$choice" in
      0) return 0 ;;
      1) frp_role_menu frps ;;
      2) frp_role_menu frpc ;;
      3) frp_existing_view || true; pause ;;
      *) warn "未知选项"; pause ;;
    esac
  done
}
