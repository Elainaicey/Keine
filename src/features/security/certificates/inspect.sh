#!/usr/bin/env bash

security_certificate_days_left() {
  local not_after="$1" now="${2:-}" expiry_epoch delta
  [[ -n "$now" ]] || now="$(date +%s)"
  expiry_epoch="$(date -d "$not_after" +%s 2>/dev/null)" || return 1
  delta=$((expiry_epoch - now))
  if (( delta >= 0 )); then
    printf '%s' "$(((delta + 86399) / 86400))"
  else
    printf '%s' "$(((delta - 86399) / 86400))"
  fi
}

security_tls_inspect() {
  local target="${1:-}" port="${2:-}" endpoint pem result=0
  local arguments=()
  [[ -n "$target" ]] || target="$(read_input "域名或 IP" "")"
  valid_network_target "$target" || { warn "目标格式无效。"; return 1; }
  [[ -n "$port" ]] || port="$(read_input "TLS 端口" "443")"
  valid_port "$port" || { warn "端口无效。"; return 1; }
  command_exists openssl || { warn "未安装 openssl。"; return 1; }
  command_exists timeout || { warn "缺少 timeout 命令。"; return 1; }
  endpoint="$target:$port"
  if [[ "$target" == *:* ]]; then endpoint="[$target]:$port"; fi
  ui_page "TLS 证书检查" "$target:$port"
  if valid_ipv4_address "$target" || valid_ipv6_address "$target"; then
    arguments=(-verify_ip "$target")
  else arguments=(-servername "$target" -verify_hostname "$target"); fi
  pem="$(timeout 12 openssl s_client -showcerts -verify 8 "${arguments[@]}" -connect "$endpoint" </dev/null 2>&1)" || result=$?
  if (( result != 0 )); then
    ui_check fail "TLS 握手未完成（状态 $result）"
    printf '%s\n' "$pem" | LC_ALL=C tr -d '\000-\010\013-\037\177' | tail -n 8
    return 1
  fi
  security_certificate_report "$pem" || return 1
  ui_section "连接验证" accent
  if grep -Eq '^[[:space:]]*Verify return code: 0 \(ok\)' <<<"$pem"; then
    ui_check pass "证书信任链与目标身份验证通过"
  else
    ui_check fail "证书信任链或目标身份验证未通过"
    printf '%s\n' "$pem" | grep -E 'verify error:|Verify return code:' | LC_ALL=C tr -d '\000-\010\013-\037\177' || true
    return 1
  fi
}

security_certificate_report() {
  local pem="$1" certificate not_after not_before days_left start_epoch now
  certificate="$(openssl x509 -noout -subject -issuer -serial -dates -fingerprint -sha256 2>/dev/null <<<"$pem" || true)"
  [[ -n "$certificate" ]] || { warn "未能取得有效证书。"; return 1; }
  printf '%s\n' "$certificate" | LC_ALL=C tr -d '\000-\010\013-\037\177'
  ui_section "有效期与身份" "accent"
  not_after="$(openssl x509 -noout -enddate 2>/dev/null <<<"$pem" | sed 's/^notAfter=//' || true)"
  if [[ -n "$not_after" ]] && days_left="$(security_certificate_days_left "$not_after")"; then
    if (( days_left < 0 )); then
      ui_check fail "证书已经过期 $((-days_left)) 天"
    elif (( days_left < 14 )); then
      ui_check fail "证书将在 $days_left 天内过期"
    elif (( days_left < 30 )); then
      ui_check warn "证书将在 $days_left 天后过期"
    else
      ui_check pass "证书剩余有效期 $days_left 天"
    fi
  else
    ui_check warn "无法计算证书剩余有效期"
  fi
  not_before="$(openssl x509 -noout -startdate 2>/dev/null <<<"$pem" | sed 's/^notBefore=//' || true)"
  if start_epoch="$(date -d "$not_before" +%s 2>/dev/null)"; then
    now="$(date +%s)"
    if (( start_epoch > now )); then ui_check fail "证书尚未到生效时间"; fi
  fi
  ui_section "证书主机名" "primary"
  openssl x509 -noout -ext subjectAltName 2>/dev/null <<<"$pem" | LC_ALL=C tr -d '\000-\010\013-\037\177' || true
}

security_certificate_file_inspect() {
  local path="${1:-}" pem
  [[ -n "$path" ]] || path="$(read_input "PEM 证书绝对路径" "")"
  [[ "$path" == /* && "$path" != *[[:cntrl:]]* && -f "$path" && -r "$path" ]] || {
    warn "需要可读取的普通 PEM 证书文件。"; return 1;
  }
  command_exists openssl || { warn "未安装 openssl。"; return 1; }
  pem="$(runtime_with_timeout 5 openssl x509 -in "$path" -outform PEM 2>/dev/null)" || { warn "无法解析 PEM 证书。"; return 1; }
  ui_page "本地证书" "$(terminal_safe_text "$path")"
  security_certificate_report "$pem"
}
