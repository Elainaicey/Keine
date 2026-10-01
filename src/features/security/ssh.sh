#!/usr/bin/env bash

security_root_public_key_exists() {
  [[ -f /root/.ssh/authorized_keys && ! -L /root/.ssh/authorized_keys && -s /root/.ssh/authorized_keys ]]
}

security_ssh_effective_values() {
  local settings="$1" key="$2"
  awk -v wanted="$key" '
    $1 == wanted {
      $1=""
      sub(/^[[:space:]]+/, "")
      if (!seen[$0]++) values=(values == "" ? $0 : values ", " $0)
    }
    END {print values}
  ' <<<"$settings"
}

security_ssh_effective_matches() {
  local main_config="$1" port="$2" password_disabled="$3" root_key_only="$4" settings
  settings="$(sshd -T -f "$main_config" 2>/dev/null)" || return 1
  [[ "$(security_ssh_effective_values "$settings" port)" == "$port" ]] || return 1
  if [[ "$password_disabled" -eq 1 ]]; then
    [[ "$(security_ssh_effective_values "$settings" passwordauthentication)" == "no" ]] || return 1
    [[ "$(security_ssh_effective_values "$settings" kbdinteractiveauthentication)" == "no" ]] || return 1
    [[ "$(security_ssh_effective_values "$settings" pubkeyauthentication)" == "yes" ]] || return 1
  fi
  if [[ "$root_key_only" -eq 1 ]]; then
    [[ "$(security_ssh_effective_values "$settings" permitrootlogin)" == "without-password" ||
      "$(security_ssh_effective_values "$settings" permitrootlogin)" == "prohibit-password" ]] || return 1
  fi
}

security_ssh_dropin_has_precedence() {
  local main_config="$1"
  awk '
    /^[[:space:]]*($|#)/ {next}
    {
      seen=1
      if (tolower($1) == "include" && $2 == "/etc/ssh/sshd_config.d/*.conf") exit 0
      exit 1
    }
    END {if (!seen) exit 1}
  ' "$main_config"
}

security_ssh_effective_view() {
  local settings password root_login public_key keyboard forwarding x11 allow_users allow_groups
  ui_page "SSH / 有效配置" "读取 sshd -T 的最终生效值，而不是只查看单个配置文件"
  command_exists sshd || { warn "未找到 sshd。"; return 1; }
  settings="$(sshd -T 2>/dev/null || true)"
  [[ -n "$settings" ]] || { warn "无法读取 sshd 有效配置，请先执行 sshd -t 检查语法。"; return 1; }
  password="$(security_ssh_effective_values "$settings" passwordauthentication)"
  root_login="$(security_ssh_effective_values "$settings" permitrootlogin)"
  public_key="$(security_ssh_effective_values "$settings" pubkeyauthentication)"
  keyboard="$(security_ssh_effective_values "$settings" kbdinteractiveauthentication)"
  forwarding="$(security_ssh_effective_values "$settings" allowtcpforwarding)"
  x11="$(security_ssh_effective_values "$settings" x11forwarding)"
  allow_users="$(security_ssh_effective_values "$settings" allowusers)"
  allow_groups="$(security_ssh_effective_values "$settings" allowgroups)"
  ui_panel_begin "连接与认证"
  ui_panel_kv "端口" "$(security_ssh_effective_values "$settings" port)"
  ui_panel_kv "监听地址" "$(security_ssh_effective_values "$settings" listenaddress)"
  ui_panel_kv "公钥认证" "${public_key:-未知}"
  ui_panel_kv "密码认证" "${password:-未知}" "$([[ "$password" == "no" ]] && printf '%s' "$GREEN" || printf '%s' "$YELLOW")"
  ui_panel_kv "键盘交互" "${keyboard:-未知}" "$([[ "$keyboard" == "no" ]] && printf '%s' "$GREEN" || printf '%s' "$YELLOW")"
  ui_panel_kv "root 登录" "${root_login:-未知}" "$([[ "$root_login" == "no" || "$root_login" == "prohibit-password" ]] && printf '%s' "$GREEN" || printf '%s' "$YELLOW")"
  ui_panel_end
  ui_panel_begin "访问边界"
  ui_panel_kv "AllowUsers" "${allow_users:-未限制}"
  ui_panel_kv "AllowGroups" "${allow_groups:-未限制}"
  ui_panel_kv "TCP 转发" "${forwarding:-未知}"
  ui_panel_kv "X11 转发" "${x11:-未知}"
  ui_panel_kv "最大认证次数" "$(security_ssh_effective_values "$settings" maxauthtries)"
  ui_panel_kv "登录宽限时间" "$(security_ssh_effective_values "$settings" logingracetime)"
  ui_panel_end
  ui_note "转发和用户范围是否需要限制取决于实际用途；本页面不会自动修改配置。"
}

security_ssh_sessions() {
  local port sessions count=0 line
  port="$(detect_ssh_port)"
  ui_page "SSH / 当前会话" "当前连接到本机 SSH 端口 $port 的 TCP 会话"
  command_exists ss || { ui_empty "缺少 ss 命令"; return 0; }
  sessions="$(ss -H -tnp state established "( sport = :$port )" 2>/dev/null || true)"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '  %b◆%b %s\n' "$CYAN" "$NC" "$(terminal_safe_text "$line")"
    count=$((count + 1))
  done <<<"$sessions"
  (( count > 0 )) || ui_empty "当前没有已建立的 SSH TCP 会话"
  ui_note "当前终端也可能出现在清单中；终止 SSH 会话请先确认不是正在使用的管理连接。"
}

security_ssh_authorized_keys() {
  local file owner mode count total=0
  ui_page "SSH / 公钥资产" "authorized_keys 文件、权限、有效条目和指纹"
  while IFS= read -r file; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    owner="$(stat -c '%U' "$file" 2>/dev/null || printf '未知')"
    mode="$(stat -c '%a' "$file" 2>/dev/null || printf '未知')"
    count="$(grep -Ec '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-ssh-)' "$file" 2>/dev/null || true)"
    ui_section "$owner · $(terminal_safe_text "$file")" "primary"
    ui_kv "权限" "$mode"
    ui_kv "有效公钥" "$count 把"
    if command_exists ssh-keygen; then
      while IFS= read -r fingerprint; do
        printf '  %s\n' "$(terminal_safe_text "$fingerprint")"
      done < <(ssh-keygen -lf "$file" 2>/dev/null | sed -n '1,30p')
    fi
    total=$((total + count))
  done < <(find /root /home -maxdepth 3 -path '*/.ssh/authorized_keys' -type f 2>/dev/null | sort)
  (( total > 0 )) || ui_empty "没有检测到有效 authorized_keys 条目"
  ui_note "共检测到 $total 把公钥；本页只读，不添加、移除或改写 authorized_keys。"
}

security_ssh_host_keys() {
  local file count=0
  ui_page "SSH / 主机密钥" "服务器对外提供的 SSH 主机身份指纹"
  if ! command_exists ssh-keygen; then
    ui_empty "缺少 ssh-keygen"
    return 0
  fi
  for file in /etc/ssh/ssh_host_*_key.pub; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    ssh-keygen -lf "$file" 2>/dev/null || continue
    count=$((count + 1))
  done
  (( count > 0 )) || ui_empty "没有读取到 SSH 主机公钥"
  ui_note "首次连接或主机重装后，可用这里的指纹核对客户端提示。"
}

security_restore_ssh_files() {
  local main_config="$1" config="$2" config_existed="$3" failed=0
  if [[ -e "$BACKUP_SESSION$main_config" ]]; then
    cp -a "$BACKUP_SESSION$main_config" "$main_config" || failed=1
  else
    failed=1
  fi
  if [[ "$config_existed" -eq 1 && -e "$BACKUP_SESSION$config" ]]; then
    cp -a "$BACKUP_SESSION$config" "$config" || failed=1
  else
    rm -f -- "$config" || failed=1
  fi
  (( failed == 0 ))
}

security_configure_ssh() {
  local current_port new_port disable_password=0 root_key_only=0 key_label="否"
  local password_label="保持现状" root_label="保持现状"
  current_port="$(detect_ssh_port)"
  if security_root_public_key_exists; then key_label="是"; fi
  ui_page "SSH 安全向导" "端口、公钥、密码登录与 root 登录策略"
  ui_kv "当前端口" "$current_port"
  ui_kv "root 公钥" "$key_label"
  ui_hint "端口范围 1-65535；修改前请保留服务商控制台。"
  new_port="$(read_input "SSH 端口" "$current_port")"
  valid_port "$new_port" || { warn "SSH 端口无效。"; return 1; }
  if confirm "禁用密码登录？"; then disable_password=1; fi
  if confirm "限制 root 仅使用公钥登录？"; then root_key_only=1; fi
  if [[ "$disable_password" -eq 1 ]] && ! security_root_public_key_exists; then
    warn "未检测到 root authorized_keys，保持密码登录。"
    disable_password=0
  fi
  if [[ "$root_key_only" -eq 1 ]] && ! security_root_public_key_exists; then
    warn "未检测到 root authorized_keys，保持 root 登录策略。"
    root_key_only=0
  fi
  if [[ "$disable_password" -eq 1 ]]; then password_label="禁用"; fi
  if [[ "$root_key_only" -eq 1 ]]; then root_label="仅允许公钥"; fi
  ui_section "变更摘要"
  ui_kv "端口" "$new_port"
  ui_kv "密码登录" "$password_label"
  ui_kv "root 登录" "$root_label"
  confirm "应用以上 SSH 设置？" || return 0; require_root
  if [[ "$new_port" != "$current_port" ]] && ss -H -ltn "sport = :$new_port" 2>/dev/null | grep -q .; then warn "端口 $new_port 已被占用。"; return 1; fi
  command_exists sshd || die "未找到 sshd。"
  local main_config=/etc/ssh/sshd_config dropin_dir=/etc/ssh/sshd_config.d config=/etc/ssh/sshd_config.d/99-server-toolkit.conf config_existed=0
  if [[ -e "$config" ]]; then config_existed=1; fi
  backup_file "$main_config" || { warn "无法备份 SSH 主配置。"; return 1; }
  backup_file "$config" || { warn "无法备份 SSH 托管配置。"; return 1; }
  if [[ "$DRY_RUN" -eq 1 ]]; then info "将写入并验证 $config。"; return 0; fi
  mkdir -p "$dropin_dir" || { warn "无法创建 SSH 配置目录。"; return 1; }
  if ! security_ssh_dropin_has_precedence "$main_config"; then
    local main_temporary
    main_temporary="$(mktemp)" || { warn "无法创建 SSH 主配置临时文件。"; return 1; }
    if ! {
      printf 'Include /etc/ssh/sshd_config.d/*.conf\n'
      cat "$main_config"
    } >"$main_temporary" || ! install -m 0644 "$main_temporary" "$main_config"; then
      rm -f -- "$main_temporary"
      security_restore_ssh_files "$main_config" "$config" "$config_existed" || warn "SSH 主配置回滚失败，请立即检查。"
      warn "无法启用 SSH drop-in 配置目录。"
      return 1
    fi
    rm -f -- "$main_temporary"
  fi
  if ! {
    printf '# Managed by Server Toolkit\nPort %s\n' "$new_port"
    if [[ "$disable_password" -eq 1 ]]; then
      printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\n'
    fi
    if [[ "$root_key_only" -eq 1 ]]; then
      printf 'PermitRootLogin prohibit-password\n'
    fi
  } >"$config"; then
    security_restore_ssh_files "$main_config" "$config" "$config_existed" || warn "SSH 配置回滚失败，请立即检查。"
    warn "无法写入 SSH 托管配置。"
    return 1
  fi
  if ! chmod 0644 "$config"; then
    security_restore_ssh_files "$main_config" "$config" "$config_existed" || warn "SSH 配置回滚失败，请立即检查。"
    warn "无法设置 SSH 托管配置权限。"
    return 1
  fi
  if ! sshd -t -f "$main_config"; then
    security_restore_ssh_files "$main_config" "$config" "$config_existed" || warn "SSH 配置回滚失败，请立即检查。"
    warn "SSH 验证失败，已恢复配置。"
    return 1
  fi
  if ! security_ssh_effective_matches "$main_config" "$new_port" "$disable_password" "$root_key_only"; then
    security_restore_ssh_files "$main_config" "$config" "$config_existed" || warn "SSH 配置回滚失败，请立即检查。"
    warn "SSH 最终生效值与计划不一致，已恢复配置。请检查主配置中的 Match 或 Include 顺序。"
    return 1
  fi
  if [[ "$new_port" != "$current_port" ]] && command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    if ! run ufw allow "$new_port/tcp"; then
      security_restore_ssh_files "$main_config" "$config" "$config_existed" || warn "SSH 配置回滚失败，请立即检查。"
      warn "无法放行新的 SSH 端口，已恢复配置。"
      return 1
    fi
  fi
  local ssh_service=""
  if service_exists ssh.service; then
    ssh_service=ssh.service
  elif service_exists sshd.service; then
    ssh_service=sshd.service
  fi
  if [[ -z "$ssh_service" ]]; then
    security_restore_ssh_files "$main_config" "$config" "$config_existed" || warn "SSH 配置回滚失败，请立即检查。"
    warn "未找到 SSH 服务，已恢复配置。"
    return 1
  fi
  if ! systemctl restart "$ssh_service"; then
    security_restore_ssh_files "$main_config" "$config" "$config_existed" || warn "SSH 配置回滚失败，请立即检查。"
    systemctl restart "$ssh_service" 2>/dev/null || true
    warn "SSH 重启失败，已恢复旧配置。"
    return 1
  fi
  if ! systemctl is-active --quiet "$ssh_service"; then
    security_restore_ssh_files "$main_config" "$config" "$config_existed" || warn "SSH 配置回滚失败，请立即检查。"
    systemctl restart "$ssh_service" 2>/dev/null || true
    warn "SSH 重启后未进入运行状态，已恢复旧配置。"
    return 1
  fi
  audit "action=ssh-config port=$new_port password_disabled=$disable_password root_key_only=$root_key_only"
  warn "请保留当前会话，并在新窗口验证登录。"
}

security_auth_log() {
  local line count=0
  ui_page "SSH 登录事件" "最近 24 小时的成功、失败和无效用户记录"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '  %s\n' "$(terminal_safe_text "$line")"
    count=$((count + 1))
  done < <(journalctl -u ssh.service -u sshd.service --since '-24 hours' --no-pager 2>/dev/null |
    grep -Ei 'accepted|failed|invalid user|disconnect' | tail -n 80 || true)
  (( count > 0 )) || ui_empty "没有可显示的事件"
}

security_ssh_manage() {
  local action service state port
  while true; do
    port="$(detect_ssh_port)"
    service=""
    if service_exists ssh.service; then service="ssh.service"; elif service_exists sshd.service; then service="sshd.service"; fi
    if [[ -n "$service" ]]; then state="$(service_state "$service")"; else state="未找到服务"; fi
    ui_page "SSH 安全中心" "有效配置、会话、公钥、主机身份与安全向导"
    ui_panel_begin "运行状态"
    ui_panel_kv "服务" "${service:-—}"
    ui_panel_kv "状态" "$state" "$([[ "$state" == "active" ]] && printf '%s' "$GREEN" || printf '%s' "$YELLOW")"
    ui_panel_kv "端口" "$port/tcp"
    ui_panel_kv "托管配置" "$([[ -f /etc/ssh/sshd_config.d/99-server-toolkit.conf ]] && printf '已创建' || printf '未创建')"
    ui_panel_end
    ui_section "查看" "primary"
    ui_action_pair 1 "有效配置" "action" 2 "当前会话" "action"
    ui_action_pair 3 "公钥资产" "action" 4 "主机密钥" "action"
    ui_action 5 "登录事件" "action" "最近 24 小时成功、失败与无效用户"
    ui_section "配置" "accent"
    ui_action 6 "SSH 安全向导" "warning" "端口、密码认证与 root 登录策略"
    if [[ -n "$service" ]]; then ui_action 7 "服务与日志" "action" "$service"; else ui_action 7 "服务与日志" "disabled" "未找到 SSH 服务"; fi
    ui_action 0 "返回安全中心" "muted"
    action="$(read_input "请选择" "0")"
    case "$action" in
      1) security_ssh_effective_view || true ;;
      2) security_ssh_sessions ;;
      3) security_ssh_authorized_keys ;;
      4) security_ssh_host_keys ;;
      5) security_auth_log ;;
      6) security_configure_ssh || true ;;
      7) if [[ -n "$service" ]]; then services_select "$service"; else warn "未找到 SSH 服务。"; fi ;;
      0) return 0 ;;
      *) warn "未知选项：$action"; continue ;;
    esac
    pause
  done
}
