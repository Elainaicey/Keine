#!/usr/bin/env bash

security_certbot_root() { printf '%s' "${KEINE_LETSENCRYPT_ROOT:-/etc/letsencrypt}"; }

security_certbot_valid_name() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,199}$ && "$1" != *..* ]]
}

security_certbot_names() {
  local path name root
  root="$(security_certbot_root)"
  for path in "$root"/renewal/*.conf; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    name="${path##*/}"; name="${name%.conf}"
    security_certbot_valid_name "$name" || continue
    printf '%s\n' "$name"
  done
}

security_certbot_has_name() {
  security_certbot_valid_name "$1" && security_certbot_names | grep -Fxq -- "$1"
}

security_certbot_setting() {
  local name="$1" key="$2" path
  security_certbot_has_name "$name" || return 1
  case "$key" in authenticator|installer|server) ;; *) return 1 ;; esac
  path="$(security_certbot_root)/renewal/$name.conf"
  awk -F= -v key="$key" '
    /^\[renewalparams\][[:space:]]*$/ {section=1; next}
    /^\[/ {section=0}
    section {name=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)}
    section && name==key {sub(/^[^=]*=[[:space:]]*/, ""); print; exit}
  ' "$path"
}

security_certbot_expiry_label() {
  local name="$1" expiry days
  expiry="$(openssl x509 -in "$(security_certbot_root)/live/$name/cert.pem" -noout -enddate 2>/dev/null)" || { printf '证书不可读'; return; }
  days="$(security_certificate_days_left "${expiry#notAfter=}")" || { printf '有效期未知'; return; }
  if (( days < 0 )); then printf '已过期 %s 天' "$((-days))"
  else printf '剩余 %s 天' "$days"; fi
}

security_certbot_renew() {
  local name="$1" mode="$2" root before after
  local arguments=(renew --cert-name "$name" --non-interactive)
  case "$mode" in test) arguments+=(--dry-run) ;; renew) ;; *) return 1 ;; esac
  security_certbot_has_name "$name" || { warn "未找到 Certbot 证书。"; return 1; }
  command_exists certbot || { warn "未安装 Certbot。"; return 1; }
  require_root
  root="$(security_certbot_root)"
  [[ "$root" == /etc/letsencrypt ]] || { warn "续期仅使用 Certbot 默认配置目录。"; return 1; }
  ui_page "Certbot / $name"
  ui_kv "验证方式" "$(terminal_safe_text "$(security_certbot_setting "$name" authenticator)")"
  if [[ "$mode" == test ]]; then ui_kv "操作" "测试续期 · 测试环境，不保存新证书"
  else ui_kv "操作" "按原配置续期 · 仅在到期窗口内更新"; fi
  ui_note "沿用 Certbot 验证插件和已有钩子，可能临时调整站点或启停服务。"
  confirm "现在执行本次续期操作？" || return 0
  before="$(openssl x509 -in "$root/live/$name/cert.pem" -noout -fingerprint -sha256 2>/dev/null || true)"
  run certbot "${arguments[@]}" || { warn "Certbot 未完成；请查看上方验证或钩子错误。"; return 1; }
  (( DRY_RUN == 0 )) || return 0
  audit "action=certbot-renew name=$name mode=$mode"
  if [[ "$mode" == test ]]; then ui_success "Certbot 测试续期通过"; return 0; fi
  after="$(openssl x509 -in "$root/live/$name/cert.pem" -noout -fingerprint -sha256 2>/dev/null)" || {
    warn "操作结束后证书不可读，请检查 Certbot 状态。"; return 1;
  }
  if [[ "$before" == "$after" ]]; then ui_note "证书未变化；可能尚未进入续期窗口。"
  else ui_success "证书已更新 · $(security_certbot_expiry_label "$name")"; fi
}

security_certbot_detail() {
  local name="$1" choice root authenticator installer
  root="$(security_certbot_root)"
  while security_certbot_has_name "$name"; do
    authenticator="$(security_certbot_setting "$name" authenticator)"
    installer="$(security_certbot_setting "$name" installer)"
    ui_page "证书 / $name"
    ui_panel_begin "Certbot 证书"
    ui_panel_kv "有效期" "$(security_certbot_expiry_label "$name")" "$CYAN"
    ui_panel_kv "验证插件" "$(terminal_safe_text "${authenticator:-未知}")"
    ui_panel_kv "部署插件" "$(terminal_safe_text "${installer:-未配置}")"
    ui_panel_kv "证书文件" "$root/live/$name/fullchain.pem"
    ui_panel_end
    ui_action 1 "查看证书详情" action
    if command_exists certbot; then
      ui_action 2 "测试续期" warning
      ui_action 3 "手动续期" success
    else ui_action I "安装 Certbot" action; fi
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      1) security_certificate_file_inspect "$root/live/$name/cert.pem" || true ;;
      2) security_certbot_renew "$name" test || true ;;
      3) security_certbot_renew "$name" renew || true ;;
      I|i) catalog_item_menu certbot; continue ;;
      0) return 0 ;;
      *) warn "未知选项" ;;
    esac
    pause
  done
}

security_certbot_menu() {
  local names=() page=0 page_size=6 start index choice
  while true; do
    mapfile -t names < <(security_certbot_names)
    ui_page "本机 Certbot 证书"
    if ((${#names[@]} == 0)); then ui_empty "未发现 /etc/letsencrypt/renewal 中的证书"; pause; return 0; fi
    (( page * page_size < ${#names[@]} )) || page=0
    start=$((page * page_size))
    ui_context "共 ${#names[@]} 张 · 第 $((page+1)) 页"
    for ((index=start; index<start+page_size && index<${#names[@]}; index++)); do
      ui_item "$((index-start+1))" "${names[$index]}" "$(security_certbot_expiry_label "${names[$index]}")"
    done
    (( page == 0 )) || ui_action P "上一页" action
    (( start+page_size >= ${#names[@]} )) || ui_action N "下一页" action
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      0) return 0 ;;
      P|p) if (( page > 0 )); then page=$((page-1)); fi ;;
      N|n) if (( start+page_size < ${#names[@]} )); then page=$((page+1)); fi ;;
      *)
        if [[ "$choice" =~ ^[1-6]$ ]] && (( start+choice <= ${#names[@]} )); then
          security_certbot_detail "${names[$((start+choice-1))]}"
        else warn "编号无效。"; pause; fi
        ;;
    esac
  done
}
