#!/usr/bin/env bash

# 原生探测不依赖 keine 安装标记，不读取或展示私钥。
warp_wireguard_directory() { printf '%s' "${KEINE_WIREGUARD_DIR:-/etc/wireguard}"; }

warp_wireguard_profiles() {
  local directory file name
  directory="$(warp_wireguard_directory)"
  [[ -d "$directory" && ! -L "$directory" ]] || return 0
  for file in "$directory"/*.conf; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    name="${file##*/}"; name="${name%.conf}"
    [[ "$name" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || continue
    if [[ "$name" == wgcf || "$name" == warp* ]] ||
      grep -Eiq '^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*([^#]*engage[.]cloudflareclient[.]com|162[.]159[.]19[23][.])' "$file"; then
      printf '%s\n' "$name"
    fi
  done
}

warp_connection_value() {
  local output
  command_exists warp-cli || return 1
  output="$(LC_ALL=C runtime_with_timeout 8 warp-cli status 2>/dev/null)" || return 1
  if grep -Eq '(^|[[:space:]])Disconnected([[:space:]]|$)' <<<"$output"; then printf disconnected
  elif grep -Eq '(^|[[:space:]])Connected([[:space:]]|$)' <<<"$output"; then printf connected
  else return 1; fi
}

warp_client_action() {
  local action="$1"
  [[ "$action" == connect || "$action" == disconnect ]] || return 1
  require_root
  ui_callout warn "连接变化可能改变 VPS 出站路由或影响当前 SSH 会话。" "建议保留 VPS 网页控制台；不创建注册、不修改模式、不删除外部配置。"
  confirm "执行 WARP $action？" || return 0
  # 未能可靠识别原状态时不写连接设置，避免虚假的恢复能力。
  if declare -F changes_setting_prepare >/dev/null; then changes_setting_prepare warp || return 1; fi
  local result=0
  run warp-cli "$action" || result=$?
  # 客户端返回后连接是异步的；短时验证，失败也记下当前已发生的改变。
  if (( DRY_RUN == 0 )); then
    local expected=connected current="" attempt
    [[ "$action" != disconnect ]] || expected=disconnected
    for (( attempt=0; attempt<3; attempt++ )); do
      current="$(warp_connection_value || true)"
      [[ "$current" != "$expected" ]] || break
      sleep 1
    done
    changes_setting_commit warp || result=1
    [[ "$current" == "$expected" ]] || { warn "连接尚未达到目标状态；请检查客户端日志。"; result=1; }
  fi
  audit "action=warp-client verb=$action result=$result"
  return "$result"
}

warp_menu() {
  local profiles=() choice profile unit index
  while true; do
    ui_page "WARP 与 WireGuard" "原生识别与控制 · 无需由本项目安装"
    ui_panel_begin "官方客户端"
    if command_exists warp-cli; then
      ui_panel_kv "版本" "$(runtime_with_timeout 8 warp-cli --version 2>/dev/null || true)" "$CYAN"
      ui_panel_kv "连接" "$(warp_connection_value || printf '未连接 / 未注册 / 服务不可用')"
      ui_panel_kv "服务" "$(systemctl is-active warp-svc.service 2>/dev/null || true)"
    else ui_panel_kv "安装" "未检测到 warp-cli"; fi
    ui_panel_end
    ui_action 1 "连接官方 WARP" "success"
    ui_action 2 "断开官方 WARP" "warning"
    ui_action 3 "客户端服务" "action" "启动、关停、自启与日志"
    mapfile -t profiles < <(warp_wireguard_profiles)
    ui_section "已有 WireGuard / wgcf 隧道" "accent"
    if ((${#profiles[@]} == 0)); then ui_note "未发现 WARP 配置；不安装或接管外部脚本。"; fi
    for index in "${!profiles[@]}"; do
      profile="${profiles[$index]}"; unit="wg-quick@$profile.service"
      ui_item "$((index + 4))" "$profile" "$(systemctl is-active "$unit" 2>/dev/null || true) · 原生 systemd 管理"
    done
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      0) return 0 ;;
      1|2)
        if command_exists warp-cli; then
          if [[ "$choice" == 1 ]]; then warp_client_action connect || true; else warp_client_action disconnect || true; fi
        else warn "未检测到官方客户端；wgcf 安装请选择下方隧道。"; fi
        pause
        ;;
      3)
        if service_exists warp-svc.service; then services_select warp-svc.service; else warn "没有官方 WARP 服务。"; pause; fi
        ;;
      *)
        if [[ "$choice" =~ ^[1-9][0-9]{0,2}$ ]] && (( choice >= 4 && choice < ${#profiles[@]} + 4 )); then
          unit="wg-quick@${profiles[$((choice - 4))]}.service"
          if service_exists "$unit"; then services_select "$unit"; else warn "未找到 wg-quick 单元，请检查原安装。"; pause; fi
        else warn "编号无效。"; pause; fi
        ;;
    esac
  done
}
