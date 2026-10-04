#!/usr/bin/env bash

tuning_strategy_preview() {
  local payload="$1" key value current state skipped
  # Used by ui_kv; keep long sysctl names aligned without changing other pages.
  # shellcheck disable=SC2034
  local UI_LABEL_WIDTH=42
  ui_section "参数预览" "accent"
  while IFS='=' read -r key value; do
    current="$(changes_sysctl_read "$key" || printf '不可读')"
    if [[ "$current" == "$value" ]]; then state="保持 $value"; else state="$current → $value"; fi
    ui_kv "$key" "$state"
  done < <(tuning_strategy_values <<<"$payload")
  skipped="$(sed -n 's/^# Unsupported: //p' <<<"$payload")"
  [[ -z "$skipped" ]] || ui_hint "内核不提供，跳过：${skipped//$'\n'/、}"
}

tuning_strategy_configure() {
  local engine="$1" bandwidth selector rtt=150 payload raw choice active
  ui_page "调优方案 / $engine"
  case "$engine" in
    tcpfit)
      ui_kv "上游版本" "0.5.9 · 38fbf5a"
      ui_hint "RTT 取主要用户到 VPS 的典型值；不是测速服务器延迟。"
      ui_action 1 "代理业务" "action"; ui_action 2 "大文件传输" "action"; ui_action 3 "混合业务" "action"
      ui_menu_footer "返回"; ui_read_choice choice
      case "$choice" in 1) selector=proxy ;; 2) selector=bulk ;; 3) selector=mixed ;; 0) return 0 ;; *) warn "未知选项"; return 1 ;; esac
      rtt="$(read_input '业务 RTT（ms，1–2000）' 150)"
      tuning_strategy_integer "$rtt" 2000 || { warn "RTT 应为 1–2000 的整数。"; return 1; }
      ;;
    vps-tcp-tune)
      ui_kv "上游版本" "5.4.11 · 2dbe1c8"
      ui_hint "按带宽与地区档位计算；还包含内存与调度参数。"
      ui_action 1 "亚太 / 短距离" "action"; ui_action 2 "美欧 / 长距离" "action"
      ui_menu_footer "返回"; ui_read_choice choice
      case "$choice" in 1) selector=asia ;; 2) selector=overseas ;; 0) return 0 ;; *) warn "未知选项"; return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
  bandwidth="$(read_input '可用带宽（Mbps，0 返回）' 100)"
  [[ "$bandwidth" != 0 ]] || return 0
  tuning_strategy_integer "$bandwidth" 100000 || { warn "带宽应为 1–100000 的整数，不是网卡标称速率。"; return 1; }
  raw="$(tuning_strategy_plan "$engine" "$bandwidth" "$selector" "$rtt")" || return 1
  payload="$(tuning_strategy_supported <<<"$raw")" || { warn "当前内核缺少必要参数。"; return 1; }
  tuning_strategy_validate <<<"$payload" || return 1
  tuning_strategy_preview "$payload"
  active="$(tuning_strategy_id || true)"
  if [[ -n "$active" && "$active" != "$engine" ]]; then ui_note "切换 $active → $engine；上一方案独有参数恢复初始值。"; fi
  ui_hint "此步只应用参数；测速、队列和初始窗口从方案菜单单独配置。"
  tuning_strategy_preflight && tuning_strategy_conflicts "$payload" || return 1
  confirm "应用 $engine 方案？" || return 0
  tuning_strategy_apply "$payload"
}

tuning_strategy_status() {
  local line
  ui_page "网络调优 / 当前方案"
  if tuning_strategy_id >/dev/null; then
    ui_kv "提供方" "$(tuning_strategy_id)"
    ui_kv "输入" "$(sed -n 's/^# Input: //p' "$TUNING_STRATEGY_FILE")"
    tuning_strategy_preview "$(<"$TUNING_STRATEGY_FILE")"
    tuning_strategy_preflight || return 1
    ui_success "文件与运行值的恢复记录可验证。"
  else ui_empty "没有启用托管方案"; fi
  if command_exists tc; then
    ui_section "实际网卡队列" "primary"
    tc qdisc show 2>/dev/null | while IFS= read -r line; do printf '  %s\n' "$(terminal_safe_text "$line")"; done
  fi
  ui_note "default_qdisc 仅设置默认值，不代表已有队列已替换。"
}

tuning_strategy_load_bbr() {
  require_root
  command_exists modprobe || { warn "缺少 modprobe，无法加载模块。"; return 1; }
  confirm "加载当前内核的 tcp_bbr 模块？不安装或更换内核。" || return 0
  run modprobe tcp_bbr || return 1
  (( DRY_RUN == 1 )) || ui_kv "可用算法" "$(sysctl -n net.ipv4.tcp_available_congestion_control)"
}

network_tuning_adapter_menu() {
  local choice active
  while true; do
    active="$(tuning_strategy_id || true)"
    ui_page "网络 / 调优方案"
    ui_panel_begin "独立策略 · 统一管理"
    ui_panel_kv "当前方案" "${active:-未启用}"
    ui_panel_kv "拥塞算法" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '不可用')"
    ui_panel_end
    ui_action 1 "tcpfit" "action" "带宽 × RTT · 内存约束"
    ui_action 2 "vps-tcp-tune" "action" "带宽 / 地区档位"
    ui_action 3 "当前参数与队列" "action"
    ui_action 4 "持久配置来源" "action"
    ui_action 5 "加载 BBR 模块" "action"
    ui_action 6 "按需测量" "action" "探测 / 扫描 / 验证"
    ui_action 7 "队列与初始窗口" "action" "FQ / HTB / 路由窗口"
    ui_action R "撤销参数方案" "warning"
    ui_menu_footer "返回"; ui_read_choice choice
    case "$choice" in
      1) tuning_strategy_configure tcpfit || true ;;
      2) tuning_strategy_configure vps-tcp-tune || true ;;
      3) tuning_strategy_status || true ;;
      4) network_tuning_sources ;;
      5) tuning_strategy_load_bbr || true ;;
      6) tuning_measure_menu; continue ;;
      7) tuning_runtime_menu; continue ;;
      R|r) if confirm "撤销整个方案并恢复首次应用前的参数？"; then tuning_strategy_restore || true; fi ;;
      0) return 0 ;; *) warn "未知选项"; continue ;;
    esac
    pause
  done
}

network_tuning_menu() {
  local choice
  while true; do
    ui_page "网络 / 网络调优"
    ui_action 1 "调优方案" "action" "tcpfit / vps-tcp-tune"
    ui_action 2 "手动连接参数" "action"
    ui_action 3 "BBR 拥塞控制" "action"
    ui_action 4 "IP 地址优先级" "action"
    ui_menu_footer "返回"; ui_read_choice choice
    case "$choice" in
      1) network_tuning_adapter_menu ;;
      2) network_parameters_menu ;;
      3) network_bbr_manage || true; pause ;;
      4) network_set_address_preference || true; pause ;;
      0) return 0 ;; *) warn "未知选项" ;;
    esac
  done
}
