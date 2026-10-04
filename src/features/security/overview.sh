#!/usr/bin/env bash

security_firewall_status() {
  ui_page "UFW 状态" "默认策略、日志级别与编号规则"
  if command_exists ufw; then
    ufw status verbose
    ui_section "编号规则" "accent"
    ufw status numbered
  else
    ui_empty "UFW 未安装"
  fi
}

SECURITY_AUDIT_PASS=0
SECURITY_AUDIT_WARN=0
SECURITY_AUDIT_FAIL=0

security_audit_result() {
  local state="$1" message="$2" hint="${3:-}"
  case "$state" in
    pass) SECURITY_AUDIT_PASS=$((SECURITY_AUDIT_PASS + 1)) ;;
    warn) SECURITY_AUDIT_WARN=$((SECURITY_AUDIT_WARN + 1)) ;;
    fail) SECURITY_AUDIT_FAIL=$((SECURITY_AUDIT_FAIL + 1)) ;;
    *) return 1 ;;
  esac
  ui_check "$state" "$message"
  [[ -z "$hint" ]] || printf '    %b↳ %s%b\n' "$MUTED" "$hint" "$NC"
}

security_critical_path_safe() {
  local path="$1" owner mode numeric
  [[ -f "$path" && ! -L "$path" ]] || return 1
  owner="$(stat -c '%U' "$path" 2>/dev/null || true)"
  mode="$(stat -c '%a' "$path" 2>/dev/null || true)"
  [[ "$owner" == "root" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  numeric=$((8#$mode))
  (( (numeric & 0022) == 0 ))
}

security_audit() {
  local ssh_settings uid0_count empty_passwords failed_auth path unsafe_paths=0 auth_events firewall_backend
  local critical_paths=(/etc/passwd /etc/shadow /etc/group)
  SECURITY_AUDIT_PASS=0; SECURITY_AUDIT_WARN=0; SECURITY_AUDIT_FAIL=0
  [[ ! -e /etc/sudoers ]] || critical_paths+=(/etc/sudoers)
  [[ ! -e /etc/ssh/sshd_config ]] || critical_paths+=(/etc/ssh/sshd_config)
  ui_page "安全基线检查" "主机边界、身份认证、关键配置、登录活动与更新状态"

  ui_section "主机边界" "primary"
  firewall_backend="$(platform_firewall_backend)"
  case "$firewall_backend" in
    ufw) security_audit_result pass "UFW 主机防火墙已启用" ;;
    iptables|nftables|firewalld)
      security_audit_result warn "$(platform_firewall_label "$firewall_backend")" "已识别现有后端；请结合规则顺序、默认策略与云防火墙核对入站限制" ;;
    *) security_audit_result warn "未确认正在生效的主机防火墙" "进入主机防火墙检查原生规则与云端访问策略" ;;
  esac
  if command_exists fail2ban-client && fail2ban-client ping >/dev/null 2>&1; then
    security_audit_result pass "Fail2ban 正在运行"
  else
    security_audit_result warn "Fail2ban 未安装、未运行或当前用户无法访问"
  fi
  if [[ -f /var/run/reboot-required ]]; then
    security_audit_result warn "系统提示需要重启"
  else
    security_audit_result pass "没有待处理的重启提示"
  fi

  ui_section "SSH 与身份" "accent"
  if command_exists sshd; then
    ssh_settings="$(sshd -T 2>/dev/null || true)"
    if grep -q '^passwordauthentication no$' <<<"$ssh_settings"; then
      security_audit_result pass "SSH 密码登录已禁用"
    else
      security_audit_result warn "SSH 仍允许密码登录"
    fi
    if grep -Eq '^permitrootlogin (no|prohibit-password)$' <<<"$ssh_settings"; then
      security_audit_result pass "root SSH 登录已限制"
    else
      security_audit_result warn "root 可直接通过 SSH 登录"
    fi
    ui_kv "SSH 端口" "$(awk '/^port /{print $2;exit}' <<<"$ssh_settings")"
    if [[ "$EUID" -eq 0 ]]; then
      if sshd -t >/dev/null 2>&1; then
        security_audit_result pass "sshd 配置语法有效"
      else
        security_audit_result fail "sshd 配置语法或主机密钥检查失败"
      fi
    else
      security_audit_result warn "未以 root 运行，跳过 sshd 完整语法检查"
    fi
  else
    security_audit_result warn "无法检查 sshd 有效配置"
  fi
  uid0_count="$(awk -F: '$3==0{count++}END{print count+0}' /etc/passwd)"
  if [[ "$uid0_count" -eq 1 ]]; then
    security_audit_result pass "只有一个 UID 0 账户"
  else
    security_audit_result fail "检测到 $uid0_count 个 UID 0 账户"
  fi
  if [[ "$EUID" -eq 0 && -r /etc/shadow ]]; then
    empty_passwords="$(awk -F: '$2==""{count++}END{print count+0}' /etc/shadow)"
    if (( empty_passwords == 0 )); then
      security_audit_result pass "没有空密码哈希账户"
    else
      security_audit_result fail "检测到 $empty_passwords 个空密码哈希账户"
    fi
  else
    security_audit_result warn "未以 root 运行，跳过空密码哈希检查"
  fi

  ui_section "关键配置" "primary"
  for path in "${critical_paths[@]}"; do
    if security_critical_path_safe "$path"; then
      continue
    fi
    security_audit_result fail "关键文件缺失、非 root 所有或权限可写：$path"
    unsafe_paths=$((unsafe_paths + 1))
  done
  if (( unsafe_paths == 0 )); then
    security_audit_result pass "${#critical_paths[@]} 个关键配置文件所有权与写权限正常"
  fi
  if command_exists visudo && [[ "$EUID" -eq 0 ]]; then
    if visudo -cf /etc/sudoers >/dev/null 2>&1; then
      security_audit_result pass "sudoers 配置语法有效"
    else
      security_audit_result fail "sudoers 配置语法检查失败"
    fi
  else
    security_audit_result warn "无法执行 sudoers 完整语法检查"
  fi
  if [[ "$(sysctl -n kernel.randomize_va_space 2>/dev/null || true)" == "2" ]]; then
    security_audit_result pass "内核地址空间随机化处于完整模式"
  else
    security_audit_result warn "未确认完整 ASLR 状态"
  fi

  ui_section "登录活动" "accent"
  auth_events="$(security_auth_event_rows <<<"$(security_auth_activity_data 24)")"
  failed_auth="$(awk -F '|' '$1=="failed"{count++}END{print count+0}' <<<"$auth_events")"
  if (( failed_auth >= 100 )); then
    security_audit_result fail "最近 24 小时解析到 $failed_auth 次 SSH 登录失败" "进入 SSH 登录活动查看高频来源"
  elif (( failed_auth >= 20 )); then
    security_audit_result warn "最近 24 小时解析到 $failed_auth 次 SSH 登录失败"
  else
    security_audit_result pass "最近 24 小时 SSH 登录失败 $failed_auth 次"
  fi

  ui_section "检查结论" "primary"
  ui_health_summary "$SECURITY_AUDIT_PASS" "$SECURITY_AUDIT_WARN" "$SECURITY_AUDIT_FAIL"
  if (( SECURITY_AUDIT_FAIL > 0 )); then
    ui_danger "检测到 $SECURITY_AUDIT_FAIL 项明确安全异常，请优先核实。"
  elif (( SECURITY_AUDIT_WARN > 0 )); then
    ui_note "没有明确失败项，但有 $SECURITY_AUDIT_WARN 项需要结合主机用途判断。"
  else
    ui_success "当前安全基线检查项全部通过"
  fi
  ui_note "该检查是只读快照，不会自动修改 SSH、防火墙或更新策略。"
}
