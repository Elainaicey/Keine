#!/usr/bin/env bash

security_native_status() {
  local family command data
  ui_page "原生防火墙 / 当前规则"
  for family in 4 6; do
    command="$(security_native_command "$family")"
    command_exists "$command" || continue
    ui_section "IPv$family · INPUT" primary
    if data="$(runtime_with_timeout 8 "$command" -w 5 -L INPUT -n -v --line-numbers 2>&1)"; then
      printf '%s\n' "$data" | LC_ALL=C tr -d '\000-\010\013-\037\177' | sed -n '1,100p'
    else ui_empty "无法读取；需要 root 权限和可用的内核后端"; fi
    ui_kv "持久规则" "$(security_native_file "$family")"
  done
  ui_note "仅展示 INPUT 前 100 行；不修改 OUTPUT、转发、NAT 或云平台规则。"
}

security_firewall_manage() {
  local choice backend cloud
  while true; do
    backend="$(platform_firewall_backend)"; cloud="$(platform_cloud_provider)"
    ui_page "主机防火墙"
    ui_panel_begin "当前环境"
    ui_panel_kv "后端" "$(platform_firewall_label "$backend")" "$CYAN"
    [[ "$cloud" == unknown ]] || ui_panel_kv "云平台" "$cloud"
    ui_panel_kv "SSH 端口" "$(platform_ssh_ports | paste -sd ',')"
    ui_panel_end
    if [[ "$cloud" == oracle ]]; then ui_note "保留 Oracle Cloud 预置规则；云安全列表 / NSG 需另行放行。"; fi
    ui_section "规则管理" primary
    if [[ "$backend" == ufw || "$backend" == ufw-inactive || "$backend" == unknown ]]; then
      ui_action 1 "UFW 管理" action
    fi
    ui_action 2 "查看原生规则" action
    if [[ "$backend" == iptables ]]; then
      ui_action 3 "放行本机端口" success
      ui_action 4 "删除托管端口规则" danger
    fi
    if [[ "$backend" == nftables || "$backend" == firewalld ]]; then ui_action 5 "查看后端配置" action; fi
    ui_action R "刷新环境" accent
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      1)
        case "$backend" in ufw|ufw-inactive|unknown) security_ufw_manage ;; *) warn "请使用当前防火墙后端。"; pause ;; esac
        ;;
      2) security_native_status; pause ;;
      3|4)
        if [[ "$backend" != iptables ]]; then warn "当前后端不支持原生端口写入。"
        elif [[ "$choice" == 3 ]]; then security_native_add || true
        else security_native_delete || true; fi
        pause
        ;;
      5)
        if [[ "$backend" == nftables ]]; then runtime_with_timeout 8 nft list ruleset | LC_ALL=C tr -d '\000-\010\013-\037\177' | sed -n '1,160p' || true
        elif [[ "$backend" == firewalld ]]; then runtime_with_timeout 8 firewall-cmd --list-all-zones | LC_ALL=C tr -d '\000-\010\013-\037\177' | sed -n '1,160p' || true
        else warn "未知选项"; fi
        pause
        ;;
      R|r) continue ;;
      0) return 0 ;;
      *) warn "未知选项"; pause ;;
    esac
  done
}
