#!/usr/bin/env bash

security_ssh_login_diagnose() {
  local settings key value rows count line
  ui_page "SSH / 登录诊断" "按需检查配置、root 认证和公钥路径，不修改服务"
  command_exists sshd || { warn "未找到 sshd。"; return 1; }
  if sshd -t -f "$SECURITY_SSH_MAIN" >/dev/null 2>&1; then ui_check pass "sshd 配置与主机密钥检查通过"
  else ui_check fail "sshd -t 检查失败；请在控制台检查配置及主机密钥"; return 1; fi
  settings="$(security_ssh_context_values)" || { warn "无法读取有效配置。"; return 1; }
  ui_kv "检查上下文" "root / ${SSH_CONNECTION:-本机控制台，模拟 127.0.0.1 来源}"
  for key in permitrootlogin pubkeyauthentication passwordauthentication kbdinteractiveauthentication authenticationmethods authorizedkeysfile authorizedkeyscommand pubkeyacceptedalgorithms allowusers denyusers allowgroups denygroups forcecommand chrootdirectory strictmodes; do
    value="$(security_ssh_effective_values "$settings" "$key")"
    [[ -z "$value" ]] || ui_kv "$key" "$(terminal_safe_text "$value")"
  done
  if [[ "$(security_ssh_effective_values "$settings" permitrootlogin)" == no ]]; then ui_check fail "当前上下文禁止 root SSH 登录"; fi
  if [[ "$(security_ssh_effective_values "$settings" pubkeyauthentication)" == no ]]; then ui_check warn "当前上下文关闭公钥认证"; fi
  if security_ssh_key_path_active "$settings"; then ui_check pass "标准 root authorized_keys 在有效搜索路径中"
  else ui_check warn "使用自定义路径或关闭文件取钥；本工具不改写自定义公钥来源"; fi
  if security_ssh_key_safe; then
    ui_check pass "root 主目录、公钥路径、所有者及写权限检查通过"
    rows="$(security_ssh_key_rows)"
    count="$(awk -F'|' '$2=="enabled" {n++} END{print n+0}' <<<"$rows")"
    if (( count > 0 )); then ui_check pass "标准文件中有 $count 把可解析的启用公钥"
    else ui_check warn "标准文件中没有可解析的启用公钥"; fi
  else
    ui_check fail "root 公钥路径存在链接、非 root 所有、组/其他用户可写或非普通文件"
    ui_hint "请通过控制台核对路径；常规权限为 root 主目录 0700、.ssh 0700、authorized_keys 0600，所有者 root。工具不会自动接管异常路径。"
  fi
  if command_exists passwd; then
    value="$(passwd -S root 2>/dev/null | awk '{print $2}')"
    ui_kv "root 密码状态" "${value:-无法读取}（P=已设置，L=锁定，NP=空密码）"
    [[ "$value" != L && "$value" != NP ]] || ui_check warn "密码状态可能阻止认证；是否影响公钥取决于 UsePAM 和账户策略"
  fi
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then ui_check warn "ssh.socket 激活：实际监听以 Socket 和 ss 为准"; fi
  ui_section "最近认证错误线索" "accent"
  count=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '  %s\n' "$(terminal_safe_text "$line")"; count=$((count+1))
  done < <(security_auth_activity_data 24 | grep -Ei 'bad ownership|bad modes|not allowed|account.*locked|authentication refused|maximum authentication attempts|not in PubkeyAcceptedAlgorithms' | tail -n 12 || true)
  (( count > 0 )) || ui_empty "没有匹配到已知错误线索；这不能证明登录成功"
  ui_note "有效值针对当前来源；其他来源的 Match 可能不同。检查不覆盖云防火墙、客户端私钥、PAM 全部规则或真实登录；请保留当前会话并从客户端另开窗口验证。"
}

security_ssh_auth_profile() {
  local choice payload settings
  ui_page "SSH / 登录方式" "更改 root 新连接的认证方式，保留当前会话"
  ui_action 1 "仅公钥登录" "warning" "禁用密码与键盘交互"
  ui_action 2 "公钥或密码登录" "warning" "重新允许 root 密码登录"
  ui_menu_footer "取消"; ui_read_choice choice
  case "$choice" in
    1)
      security_root_public_key_exists || { warn "没有在有效标准路径中找到安全、可解析的 root 公钥。"; return 1; }
      confirm "已使用公钥在另一个窗口成功登录，并保留服务商控制台？" || return 0
      payload=$'PubkeyAuthentication yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin prohibit-password'
      ;;
    2)
      ui_hint "此选项扩大远程认证入口；需要 root 已设置可用密码，建议保留 Fail2ban 和来源限制。"
      [[ "$(passwd -S root 2>/dev/null | awk '{print $2}')" == P ]] || { warn "root 密码未设置或已锁定；请先在服务商控制台处理。"; return 1; }
      confirm "明确允许 root 使用密码远程登录？" || return 0
      payload=$'PubkeyAuthentication yes\nPasswordAuthentication yes\nKbdInteractiveAuthentication no\nPermitRootLogin yes'
      ;;
    0) return 0 ;; *) return 1 ;;
  esac
  settings="$(security_ssh_context_values)" || return 1
  if [[ "$(security_ssh_effective_values "$settings" authenticationmethods)" != any ]]; then
    warn "存在 AuthenticationMethods 组合认证要求；请先通过原生配置管理，工具不覆盖 MFA 策略。"; return 1
  fi
  require_root
  if security_ssh_write_settings "$SECURITY_SSH_AUTH" "$payload"; then
    audit "action=ssh-auth-profile profile=$choice"
    if (( DRY_RUN == 0 )); then ui_success "认证配置已验证并 reload；请验证新的客户端连接。"; fi
  else warn "认证设置失败，已尝试回退。"; return 1; fi
}
