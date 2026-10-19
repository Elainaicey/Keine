#!/usr/bin/env bash

security_ssh_login_diagnose() {
  local settings key value rows count line
  ui_page "SSH / 登录诊断" "按需检查 $(security_ssh_user) 的认证和公钥路径"
  command_exists sshd || { warn "未找到 sshd。"; return 1; }
  if sshd -t -f "$SECURITY_SSH_MAIN" >/dev/null 2>&1; then ui_check pass "sshd 配置与主机密钥检查通过"
  else ui_check fail "sshd -t 检查失败；请在控制台检查配置及主机密钥"; return 1; fi
  settings="$(security_ssh_context_values)" || { warn "无法读取有效配置。"; return 1; }
  ui_kv "检查上下文" "$(security_ssh_user) / ${SSH_CONNECTION:-本机控制台，模拟 127.0.0.1 来源}"
  for key in permitrootlogin pubkeyauthentication passwordauthentication kbdinteractiveauthentication authenticationmethods authorizedkeysfile authorizedkeyscommand pubkeyacceptedalgorithms allowusers denyusers allowgroups denygroups forcecommand chrootdirectory strictmodes; do
    value="$(security_ssh_effective_values "$settings" "$key")"
    [[ -z "$value" ]] || ui_kv "$key" "$(terminal_safe_text "$value")"
  done
  if [[ "$(security_ssh_user)" == root && "$(security_ssh_effective_values "$settings" permitrootlogin)" == no ]]; then ui_check fail "当前上下文禁止 root SSH 登录"; fi
  if [[ "$(security_ssh_effective_values "$settings" pubkeyauthentication)" == no ]]; then ui_check warn "当前上下文关闭公钥认证"; fi
  if security_ssh_key_path_active "$settings"; then ui_check pass "所选账户的标准 authorized_keys 在有效搜索路径中"
  else ui_check warn "使用自定义路径或关闭文件取钥；本工具不改写自定义公钥来源"; fi
  if security_ssh_key_safe; then
    ui_check pass "账户主目录、公钥路径、所有者及写权限检查通过"
    rows="$(security_ssh_key_rows)"
    count="$(awk -F'|' '$2=="enabled" {n++} END{print n+0}' <<<"$rows")"
    if (( count > 0 )); then ui_check pass "标准文件中有 $count 把可解析的启用公钥"
    else ui_check warn "标准文件中没有可解析的启用公钥"; fi
  else
    ui_check fail "公钥路径、所有者或写权限异常"
    ui_hint "请核对所选账户主目录；.ssh 通常为 0700，authorized_keys 为 0600，归该账户或 root 所有。"
  fi
  if command_exists passwd; then
    value="$(passwd -S "$(security_ssh_user)" 2>/dev/null | awk '{print $2}')"
    ui_kv "账户密码状态" "${value:-无法读取}（P=已设置，L=锁定，NP=空密码）"
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
  local choice payload settings user root_effect=保持现状
  user="$(security_ssh_user)"
  ui_page "SSH / 登录方式" "服务器级认证策略；当前验证账户：$user"
  ui_note "密码、公钥和键盘交互设置影响所有适用账户；各账户的 Match 可能覆盖，当前会话保留。"
  ui_action 1 "仅公钥登录" "warning" "禁用密码与键盘交互"
  ui_action 2 "公钥或密码登录" "warning" "开启密码认证"
  ui_menu_footer "取消"; ui_read_choice choice
  case "$choice" in
    1)
      security_ssh_public_key_exists || { warn "所选账户没有安全、可解析的启用公钥。"; return 1; }
      payload=$'PubkeyAuthentication yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no'
      if [[ "$user" == root ]]; then payload+=$'\nPermitRootLogin prohibit-password'; root_effect=仅公钥; fi
      ;;
    2)
      [[ "$(passwd -S "$user" 2>/dev/null | awk '{print $2}')" == P ]] || { warn "所选账户密码未设置或已锁定，请先处理账户密码。"; return 1; }
      payload=$'PubkeyAuthentication yes\nPasswordAuthentication yes\nKbdInteractiveAuthentication no'
      if [[ "$user" == root ]]; then payload+=$'\nPermitRootLogin yes'; root_effect=允许密码; fi
      ;;
    0) return 0 ;; *) return 1 ;;
  esac
  settings="$(security_ssh_context_values)" || return 1
  if [[ "$(security_ssh_effective_values "$settings" authenticationmethods)" != any ]]; then
    warn "存在 AuthenticationMethods 组合认证要求；请先通过原生配置管理，工具不覆盖 MFA 策略。"; return 1
  fi
  ui_section "影响范围" "warning"
  ui_kv "公钥认证" "服务器级：开启"
  ui_kv "密码认证" "服务器级：$([[ "$choice" == 1 ]] && printf 关闭 || printf 开启)"
  ui_kv "键盘交互" "服务器级：关闭"
  ui_kv "root 登录策略" "$root_effect"
  ui_hint "需同时核对其他账户及 MFA；当前检查只验证 $user 的有效值。"
  if [[ "$choice" == 1 ]]; then
    confirm "已验证所需账户的公钥新登录，应用服务器级策略？" || return 0
  else confirm "确认以上影响范围并开启服务器密码认证？" || return 0; fi
  require_root
  if security_ssh_write_settings "$SECURITY_SSH_AUTH" "$payload"; then
    audit "action=ssh-auth-profile profile=$choice"
    if (( DRY_RUN == 0 )); then ui_success "认证配置已验证并 reload；请验证新的客户端连接。"; fi
  else warn "认证设置失败，已尝试回退。"; return 1; fi
}
