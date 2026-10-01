#!/usr/bin/env bash

SECURITY_SSH_MAIN="${KEINE_SSH_MAIN:-/etc/ssh/sshd_config}"
SECURITY_SSH_POLICY="${KEINE_SSH_POLICY:-/etc/ssh/sshd_config.d/00-keine-policy.conf}"

security_ssh_policy_rows() {
  printf '%s\n' \
    'MaxAuthTries|认证尝试上限|1|10|6|每次连接；过低会影响尝试多个公钥的客户端' \
    'LoginGraceTime|认证宽限时间|10|300|120|秒；只限制尚未完成认证的连接' \
    'MaxSessions|单连接会话上限|1|100|10|复用会话/SFTP；不限制独立 SSH 连接总数' \
    'ClientAliveInterval|客户端存活探测|0|3600|0|秒；0 关闭，探测失联客户端，不是交互空闲超时' \
    'ClientAliveCountMax|存活探测次数|1|10|3|连续探测失败后断开；结合探测间隔设置' \
    'X11Forwarding|X11 图形转发|no|yes|no|SSH 图形程序；不影响节点 TCP/UDP 监听' \
    'AllowAgentForwarding|SSH Agent 转发|no|yes|yes|关闭会影响远端使用本机 SSH Agent' \
    'AllowTcpForwarding|SSH TCP 转发|no|yes|yes|关闭会影响 SSH 隧道和 ssh -D；不控制 Xray 端口' \
    'GatewayPorts|SSH 转发监听范围|no|yes|no|no 限制远程转发在回环；不接管节点软件监听'
}

security_ssh_policy_valid() {
  local key="$1" value="$2" row _key _label minimum maximum _reference _description
  row="$(security_ssh_policy_rows | awk -F '|' -v key="$key" '$1==key {print;found=1} END{if(!found)exit 1}')" || return 1
  IFS='|' read -r _key _label minimum maximum _reference _description <<<"$row"
  if [[ "$minimum" == no ]]; then [[ "$value" == no || "$value" == yes ]]
  else [[ "$value" =~ ^[0-9]{1,4}$ ]] && (( 10#$value >= minimum && 10#$value <= maximum )); fi
}

security_ssh_context_values() {
  local address client_port local_address local_port context
  IFS=' ' read -r address client_port local_address local_port <<<"${SSH_CONNECTION:-}"
  if [[ -n "$address" ]] && security_exact_ip_valid "$address"; then
    context="user=root,host=$address,addr=$address"
    if [[ -n "$client_port" && -n "$local_address" && -n "$local_port" ]] && security_exact_ip_valid "$local_address" && valid_port "$local_port"; then
      context+=",laddr=$local_address,lport=$local_port"
    fi
    sshd -T -f "$SECURITY_SSH_MAIN" -C "$context" 2>/dev/null
  else sshd -T -f "$SECURITY_SSH_MAIN" 2>/dev/null; fi
}

security_ssh_reload_only() {
  local unit
  sshd -t -f "$SECURITY_SSH_MAIN" || return 1
  if service_exists ssh.service; then unit=ssh.service
  elif service_exists sshd.service; then unit=sshd.service
  else warn "未识别 SSH 服务，不能安全加载。"; return 1; fi
  systemctl reload "$unit" || return 1
  systemctl is-active --quiet "$unit"
}

security_ssh_apply_validate() {
  local settings key value effective
  sshd -t -f "$SECURITY_SSH_MAIN" || return 1
  settings="$(security_ssh_context_values)" || return 1
  while IFS=' ' read -r key value; do
    [[ "$key" != \#* && -n "$key" ]] || continue
    effective="$(security_ssh_effective_values "$settings" "${key,,}")"
    if [[ "$value" == prohibit-password && "$effective" == without-password ]]; then continue; fi
    [[ "$effective" == "$value" ]] || { warn "SSH 最终值与计划不一致：$key；检查 Include / Match 优先级。"; return 1; }
  done <<<"$SECURITY_SSH_EXPECTED"
  security_ssh_reload_only
}

security_ssh_write_settings() {
  local path="$1" updates="$2" existing="" payload main_payload main_changed=0
  local SECURITY_SSH_EXPECTED="$updates"
  config_file_safe "$path" && config_file_safe "$SECURITY_SSH_MAIN" || return 1
  command_exists sshd || { warn "未找到 sshd。"; return 1; }
  if [[ -e "$path" ]]; then
    if ! grep -Fqx '# Managed by keine' "$path"; then
      warn "该 SSH 文件不是项目配置，拒绝覆盖。"; return 1
    fi
    existing="$(cat -- "$path")"
  fi
  payload="$(awk 'FNR==NR {if(NF && $1 !~ /^#/) updated[tolower($1)]=1; next}
    NF && $1 !~ /^#/ && !updated[tolower($1)] {print}' <(printf '%s\n' "$updates") <(printf '%s\n' "$existing"))"
  payload="$(printf '# Managed by keine\n%s\n%s\n' "$payload" "$updates")"
  if ! security_ssh_dropin_has_precedence "$SECURITY_SSH_MAIN"; then
    main_payload="$(printf 'Include /etc/ssh/sshd_config.d/*.conf\n'; cat -- "$SECURITY_SSH_MAIN")"
    config_file_write "$SECURITY_SSH_MAIN" 0644 "$main_payload" security_ssh_main_validate || return 1
    main_changed=1
  fi
  if ! config_file_write "$path" 0644 "$payload" security_ssh_apply_validate security_ssh_reload_only; then
    if (( main_changed == 1 && DRY_RUN == 0 )); then
      config_file_restore "$SECURITY_SSH_MAIN" security_ssh_reload_only || warn "SSH 主配置恢复失败，记录已保留。"
    fi
    return 1
  fi
}

security_ssh_main_validate() { sshd -t -f "$SECURITY_SSH_MAIN"; }

security_ssh_policy_menu() {
  local rows=() row index key label minimum maximum reference description settings current choice value
  while true; do
    mapfile -t rows < <(security_ssh_policy_rows)
    settings="$(security_ssh_context_values || true)"
    ui_page "SSH / 连接与转发策略" "逐项设置、有效值验证、reload 与原始恢复"
    for index in "${!rows[@]}"; do
      IFS='|' read -r key label minimum maximum reference description <<<"${rows[$index]}"
      current="$(security_ssh_effective_values "$settings" "${key,,}")"
      ui_item "$((index+1))" "$label" "${current:-未知}"
    done
    ui_action R "恢复初始策略" "warning" "只撤销本页独立文件，不改变其他 SSH 配置"
    ui_action 0 "返回" "muted"
    choice="$(read_input "参数编号 / R / 0" "0")"
    case "$choice" in
      0) return 0 ;;
      R|r) if confirm "恢复初始 SSH 连接与转发策略？"; then require_root; config_file_restore "$SECURITY_SSH_POLICY" security_ssh_reload_only || true; fi ;;
      *)
        if [[ ! "$choice" =~ ^[1-9]$ ]] || (( choice > ${#rows[@]} )); then warn "参数编号无效。"; continue; fi
        row="${rows[$((choice-1))]}"; IFS='|' read -r key label minimum maximum reference description <<<"$row"
        current="$(security_ssh_effective_values "$settings" "${key,,}")"
        ui_page "SSH / $label" "$key"; ui_kv "当前值" "${current:-未知}"; ui_hint "$description；范围 $minimum – $maximum，参考值 $reference。"
        value="$(read_input "新值；留空保持当前值" "$current")"
        security_ssh_policy_valid "$key" "$value" || { warn "参数不在允许范围内。"; pause; continue; }
        [[ "$value" == yes || "$value" == no ]] || value="$((10#$value))"
        confirm "设置 $key=$value？请保留当前 SSH 会话与服务商控制台。" || continue
        require_root
        if security_ssh_write_settings "$SECURITY_SSH_POLICY" "$key $value"; then
          audit "action=ssh-policy key=$key value=$value"; ui_success "SSH 策略已加载；请在新窗口验证连接。"
        else warn "SSH 策略未完成，已尝试恢复本次配置。"; fi
        ;;
    esac
    pause
  done
}
