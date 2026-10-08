#!/usr/bin/env bash

declare -Ag WEB_SITE

web_site_defaults() {
  WEB_SITE=([engine]="$1" [domain]="$2" [upstream]="$3" [tls]=http [cert]=- [key]=- [enabled]=1 [timeout]=60 [body]=64 [ipv6]=0)
  [[ ! -s /proc/net/if_inet6 ]] || WEB_SITE[ipv6]=1
}

web_site_pick_certificate() {
  local choice index cert key root name names=()
  root="$(security_certbot_root)"
  mapfile -t names < <(security_certbot_names)
  ui_page "选择证书 / ${WEB_SITE[domain]}"
  for index in "${!names[@]}"; do ui_item "$((index+1))" "${names[$index]}" "$(security_certbot_expiry_label "${names[$index]}")"; done
  ui_action P "指定 PEM 与私钥路径" action
  ui_menu_footer "返回"; ui_read_choice choice
  case "$choice" in
    0) return 1 ;;
    P|p) cert="$(read_input '证书链 PEM 绝对路径')"; key="$(read_input '私钥绝对路径')" ;;
    *)
      [[ "$choice" =~ ^[1-9][0-9]{0,3}$ ]] && (( choice <= ${#names[@]} )) || return 1
      name="${names[$((choice-1))]}"; cert="$root/live/$name/fullchain.pem"; key="$root/live/$name/privkey.pem" ;;
  esac
  web_certificate_pair_valid "${WEB_SITE[domain]}" "$cert" "$key" || return 1
  WEB_SITE[tls]=pem; WEB_SITE[cert]="$cert"; WEB_SITE[key]="$key"
}

web_site_create() {
  local engine="$1" domain upstream choice email='' issue=0 path
  web_engine_guard "$engine" || return 1
  ui_page "创建反向代理 / $engine"
  domain="$(read_input '域名（0 返回）')"; [[ "$domain" != 0 ]] || return 0; domain="${domain,,}"
  web_domain_valid "$domain" || { warn "请输入完整域名，不包含协议、端口或路径。"; return 1; }
  path="$(web_site_path "$engine" "$domain")"
  [[ ! -e "$path" && ! -L "$path" ]] || { warn "此站点已存在，请从列表进入管理。"; return 1; }
  web_domain_available "$engine" "$domain" || return 1
  upstream="$(read_input '上游地址' 'http://127.0.0.1:8080')"
  web_upstream_valid "$upstream" || { warn "格式：http(s)://主机:端口；IPv6 使用 [地址]:端口。"; return 1; }
  web_site_defaults "$engine" "$domain" "$upstream"
  ui_action 1 "HTTP" action
  if [[ "$engine" == caddy ]]; then ui_action 2 "Caddy 自动 HTTPS" success
  else ui_action 2 "申请并部署 HTTPS 证书" success; fi
  ui_action 3 "使用已有证书" action
  ui_menu_footer "返回"; ui_read_choice choice
  case "$choice" in
    0) return 0 ;;
    1) ;;
    2)
      if [[ "$engine" == caddy ]]; then
        WEB_SITE[tls]=auto
        ui_note "证书由 Caddy 服务自动申请和续期；需正确解析域名并开放 80/443。"
      else
        command_exists certbot || { warn "请先安装 Certbot，或先创建 HTTP 站点再申请证书。"; return 1; }
        email="$(read_input '证书联系邮箱')"; issue=1
      fi ;;
    3) web_site_pick_certificate || return 1 ;;
    *) return 1 ;;
  esac
  web_endpoint_check "$domain" "$upstream"
  ui_kv "站点" "$domain → $upstream"
  ui_kv "配置文件" "$path"
  confirm "创建站点并应用配置？" || return 0
  web_site_write || return 1
  if (( issue == 1 && DRY_RUN == 0 )); then
    if ! systemctl is-active --quiet nginx.service; then
      ui_note "HTTP 配置已就绪。启动 Nginx 后，可从站点详情申请证书。"; return 0
    fi
    if security_acme_issue http "$domain" "$email" "$domain" "$(web_acme_root)"; then
      web_site_deploy_certificate "$path" "$(security_certbot_root)/live/$domain/fullchain.pem" "$(security_certbot_root)/live/$domain/privkey.pem" || return 1
    else ui_note "保留 HTTP 站点，可在详情页重新申请或绑定已有证书。"; return 1; fi
  fi
  (( DRY_RUN != 0 )) || web_site_detail "$path"
}

web_site_tls_menu() {
  local path="$1" choice domain engine
  web_site_load "$path" || return 1
  domain="${WEB_SITE[domain]}"; engine="${WEB_SITE[engine]}"
  ui_page "HTTPS / $domain"
  ui_action 1 "使用已有证书" action
  if [[ "$engine" == nginx ]]; then ui_action 2 "申请证书" success
  else ui_action 2 "Caddy 自动 HTTPS" success; fi
  ui_action 3 "关闭 HTTPS，使用 HTTP" warning
  ui_menu_footer "返回"; ui_read_choice choice
  case "$choice" in
    0) return 0 ;;
    1) web_site_pick_certificate || return 1 ;;
    2)
      if [[ "$engine" == nginx ]]; then
        security_certificate_issue_menu "$domain" "$(web_acme_root)"; return
      fi
      WEB_SITE[tls]=auto; WEB_SITE[cert]=-; WEB_SITE[key]=-
      ui_note "Caddy 自身负责申请与续期，需正确解析域名并开放 80/443。"
      ;;
    3) WEB_SITE[tls]=http; WEB_SITE[cert]=-; WEB_SITE[key]=- ;;
    *) return 1 ;;
  esac
  confirm "应用新的 HTTPS 配置？" || return 0
  web_site_write
}

web_site_check() {
  local path="$1" domain scheme status
  web_site_load "$path" || return 1
  domain="${WEB_SITE[domain]}"; scheme=https; [[ "${WEB_SITE[tls]}" != http ]] || scheme=http
  ui_page "访问检查 / $domain"
  web_endpoint_check "$domain" "${WEB_SITE[upstream]}"
  [[ "${WEB_SITE[enabled]}" == 1 ]] || { ui_note "站点当前停用。"; return 0; }
  if command_exists curl; then
    status="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 10 "$scheme://$domain/" 2>/dev/null)" || status=000
    if [[ "$status" != 000 ]]; then ui_kv "域名响应" "HTTP $status"
    else warn "域名访问失败；检查解析、证书、监听和云端放行。"; fi
  fi
  if [[ "$scheme" == https ]]; then security_tls_inspect "$domain" 443 || return 1; fi
}

web_site_detail() {
  local path="$1" choice upstream state timeout body
  while [[ -f "$path" ]]; do
    web_site_load "$path" || { warn "站点元数据无法识别。"; return 1; }
    state=停用; [[ "${WEB_SITE[enabled]}" != 1 ]] || state=启用
    ui_page "反向代理 / ${WEB_SITE[domain]}"
    ui_panel_begin "站点"
    ui_panel_kv "服务" "${WEB_SITE[engine]} · $state"
    ui_panel_kv "目标" "${WEB_SITE[upstream]}"
    ui_panel_kv "访问方式" "$(web_tls_label "${WEB_SITE[tls]}")"
    ui_panel_kv "配置" "$path"
    ui_panel_end
    ui_action_pair 1 "检查访问" action 2 "修改目标" action
    ui_action_pair 3 "HTTPS 与证书" accent 4 "超时与上传大小" action
    if [[ "${WEB_SITE[enabled]}" == 1 ]]; then ui_action 5 "停用站点" warning
    else ui_action 5 "启用站点" success; fi
    ui_action_pair 6 "应用服务管理" action 7 "主机防火墙" action
    ui_action 8 "删除站点" danger
    ui_menu_footer "返回"; ui_read_choice choice
    case "$choice" in
      0) return 0 ;;
      1) web_site_check "$path" || true ;;
      2)
        upstream="$(read_input '上游地址' "${WEB_SITE[upstream]}")"
        web_upstream_valid "$upstream" || { warn "上游格式无效。"; pause; continue; }
        WEB_SITE[upstream]="$upstream"
        if confirm "修改反代目标并应用？"; then web_site_write || true; fi ;;
      3) web_site_tls_menu "$path" || true ;;
      4)
        timeout="$(read_input '响应超时（秒，1–3600）' "${WEB_SITE[timeout]}")"
        body="$(read_input '上传上限（MiB，1–32768）' "${WEB_SITE[body]}")"
        WEB_SITE[timeout]="$timeout"; WEB_SITE[body]="$body"
        web_site_values_valid || { warn "参数超出范围。"; pause; continue; }
        if confirm "应用高级配置？"; then web_site_write || true; fi ;;
      5)
        WEB_SITE[enabled]="$((1-WEB_SITE[enabled]))"
        if confirm "切换站点启用状态？"; then web_site_write || true; fi ;;
      6) apps_service_detail "${WEB_SITE[engine]}"; continue ;;
      7) security_firewall_manage; continue ;;
      8) if confirm "删除该反代配置，保留证书和上游应用？"; then web_site_restore "$path" || true; fi ;;
      *) warn "未知选项" ;;
    esac
    pause
  done
}

web_engine_menu() {
  local engine="$1" choice path index page=0 start paths=()
  while true; do
    mapfile -t paths < <(web_managed_paths "$engine")
    (( page*6 < ${#paths[@]} )) || page=0
    start=$((page*6))
    ui_page "反向代理 / $engine"
    for ((index=start; index<start+6 && index<${#paths[@]}; index++)); do
      web_site_load "${paths[$index]}" || continue
      ui_item "$((index-start+1))" "${WEB_SITE[domain]}" "$([[ "${WEB_SITE[enabled]}" == 1 ]] && printf '启用' || printf '停用') · $(web_tls_label "${WEB_SITE[tls]}")"
    done
    (( ${#paths[@]} != 0 )) || ui_empty "还没有托管站点"
    ui_action A "新建反向代理" success
    ui_action E "识别已有配置" action
    ui_action C "检查原生配置" action
    ui_action I "安装 / 更新 $engine" action
    if [[ "$engine" == caddy ]] && ! command_exists jq; then ui_action J "安装配置解析组件 jq" action; fi
    (( page == 0 )) || ui_action P "上一页" action
    (( start+6 >= ${#paths[@]} )) || ui_action N "下一页" action
    ui_menu_footer "返回"; ui_read_choice choice
    case "$choice" in
      0) return 0 ;;
      A|a) web_site_create "$engine" || true ;;
      E|e) web_existing_view "$engine" || true ;;
      C|c) web_engine_validate "$engine" || true ;;
      I|i) catalog_item_menu "$engine"; continue ;;
      J|j) if [[ "$engine" == caddy ]]; then catalog_item_menu jq; fi; continue ;;
      P|p) if (( page > 0 )); then page=$((page-1)); fi; continue ;;
      N|n) if (( start+6 < ${#paths[@]} )); then page=$((page+1)); fi; continue ;;
      *)
        if [[ "$choice" =~ ^[1-6]$ ]] && (( start+choice <= ${#paths[@]} )); then
          path="${paths[$((start+choice-1))]}"; web_site_detail "$path" || true
        else warn "未知选项"; fi ;;
    esac
    pause
  done
}

web_menu() {
  local choice
  while true; do
    ui_page "反向代理与 HTTPS"
    ui_action_pair 1 "Nginx 反向代理" action 2 "Caddy 反向代理" action
    ui_action 3 "证书中心" accent
    ui_menu_footer "返回"; ui_read_choice choice
    case "$choice" in
      1) web_engine_menu nginx ;;
      2) web_engine_menu caddy ;;
      3) security_certificates_menu ;;
      0) return 0 ;;
      *) warn "未知选项"; pause ;;
    esac
  done
}
