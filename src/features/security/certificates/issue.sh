#!/usr/bin/env bash
# Pending change records are consumed by core/changes.
# shellcheck disable=SC2034

security_acme_domains() {
  local input="${1,,}" domain base domains=() seen='|'
  [[ -n "$input" && "$input" != *, && "$input" != ,* && "$input" != *,,* ]] || return 1
  IFS=, read -r -a domains <<<"$input"
  (( ${#domains[@]} <= 10 )) || return 1
  for domain in "${domains[@]}"; do
    base="${domain#\*.}"
    web_domain_valid "$base" || return 1
    [[ "$seen" != *"|$domain|"* ]] || continue
    seen+="$domain|"
    printf '%s\n' "$domain"
  done
}

security_acme_http_check() (
  local root="$1" domain path token response addresses failed=0
  shift
  web_path_valid "$root" && [[ -d "$root" && "$(readlink -m -- "$root")" == "$root" ]] || return 1
  [[ "$(readlink -m -- "$root/.well-known/acme-challenge")" == "$root/.well-known/acme-challenge" ]] || return 1
  command_exists curl || { warn "HTTP 验证检查需要 curl。"; return 1; }
  [[ -d "$root/.well-known" ]] || mkdir -m 0755 -- "$root/.well-known" || return 1
  [[ -d "$root/.well-known/acme-challenge" ]] || mkdir -m 0755 -- "$root/.well-known/acme-challenge" || return 1
  path="$(mktemp "$root/.well-known/acme-challenge/keine-XXXXXXXXXX")" || return 1
  trap 'rm -f -- "$path"' EXIT
  token="${path##*/}"
  printf '%s' "$token" >"$path"; chmod 0644 "$path" || return 1
  for domain in "$@"; do
    [[ "$domain" != \*.* ]] || { warn "通配符证书必须使用 DNS 验证。"; return 1; }
    addresses="$(runtime_with_timeout 6 getent ahosts "$domain" 2>/dev/null)" || addresses=''
    if [[ -z "$addresses" ]]; then warn "$domain 无法解析。"; failed=1; continue; fi
    response="$(curl --noproxy '*' --fail --silent --show-error --location --max-redirs 3 \
      --proto '=http,https' --proto-redir '=http,https' --connect-timeout 4 --max-time 12 \
      "http://$domain/.well-known/acme-challenge/$token" 2>/dev/null)" || response=''
    if [[ "$response" != "$token" ]]; then warn "$domain 的 HTTP 验证路径不可达或未指向此目录。"; failed=1; fi
  done
  (( failed == 0 ))
)

security_acme_issue() {
  local mode="$1" name="$2" email="$3" input="$4" webroot="${5:-}" replace="${6:-0}" domain parsed root result=0
  local domains=() arguments=(certonly --config /dev/null --no-directory-hooks --agree-tos)
  command_exists certbot || { warn "请先在软件中心安装 Certbot。"; return 1; }
  command_exists openssl || return 1
  security_certbot_valid_name "$name" || { warn "证书名称无效。"; return 1; }
  [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || { warn "联系邮箱格式无效。"; return 1; }
  parsed="$(security_acme_domains "$input")" || { warn "请输入有效域名，多个域名用逗号分隔，最多 10 个。"; return 1; }
  mapfile -t domains <<<"$parsed"
  root="$(security_certbot_root)"
  [[ "$root" == /etc/letsencrypt ]] || { warn "签发仅使用 Certbot 默认配置目录。"; return 1; }
  if security_certbot_has_name "$name"; then
    [[ "$replace" == 1 ]] || { warn "同名证书已存在，请进入证书详情续期或选择其他名称。"; return 1; }
    [[ "$(security_certbot_setting "$name" authenticator)" == manual ]] || {
      warn "现有证书不是手动 DNS 证书，请使用原续期方式。"; return 1;
    }
    arguments+=(--force-renewal)
  elif [[ "$replace" == 1 || -e "$root/live/$name" || -L "$root/live/$name" || -e "$root/archive/$name" ]]; then
    warn "证书状态不完整或路径已存在，保留原资源。"; return 1
  fi
  arguments+=(--cert-name "$name" --email "$email")
  for domain in "${domains[@]}"; do arguments+=(-d "$domain"); done
  case "$mode" in
    http)
      [[ "$input" != *'*'* ]] || { warn "通配符证书需要 DNS 验证。"; return 1; }
      web_path_valid "$webroot" && [[ -d "$webroot" ]] || { warn "Webroot 必须是已有的绝对目录。"; return 1; }
      arguments+=(--non-interactive --webroot --webroot-path "$webroot" --preferred-challenges http)
      ;;
    dns)
      [[ -t 0 || ( -t 2 && -r /dev/tty ) || "$DRY_RUN" == 1 ]] || { warn "手动 DNS 验证需要交互式终端。"; return 1; }
      arguments+=(--manual --preferred-challenges dns)
      ;;
    *) return 1 ;;
  esac
  require_root
  ui_kv "证书名称" "$name"
  ui_kv "域名" "${domains[*]}"
  ui_kv "验证方式" "$mode"
  ui_hint "Let's Encrypt 服务条款：https://letsencrypt.org/repository/"
  if [[ "$mode" == dns ]]; then ui_note "按 Certbot 提示添加 TXT 记录；以后续期也需要手动验证。"; fi
  confirm "接受 Let's Encrypt 服务条款并申请证书？" || return 1
  if (( DRY_RUN == 1 )); then info "将调用 Certbot 签发并核验证书；预览不访问 ACME 服务。"; return 0; fi
  if [[ "$mode" == http ]]; then
    if [[ "$webroot" == "$(web_acme_root)" && -d "$(changes_file_entry "$webroot")" ]]; then
      changes_prepare_file "$webroot" directory || return 1
    fi
    security_acme_http_check "$webroot" "${domains[@]}" || result=$?
    if [[ "$webroot" == "$(web_acme_root)" && -d "$(changes_file_entry "$webroot")" ]]; then
      CHANGES_PENDING_FILES["$webroot"]=1; changes_commit_pending || return 1
    fi
    if (( result != 0 )); then
      ui_note "服务端自检也可能受回环访问限制；公网必须能访问域名的 80 端口。"
      confirm "已确认外部验证路径可达，仍交由 ACME 验证？" || return 1
    fi
  fi
  # Keep the official interactive DNS challenge attached to the terminal.
  if [[ "$mode" == dns && ! -t 0 ]]; then run certbot "${arguments[@]}" </dev/tty || result=$?
  else result=0; run certbot "${arguments[@]}" || result=$?; fi
  if [[ "$webroot" == "$(web_acme_root)" && -d "$(changes_file_entry "$webroot")" ]]; then
    CHANGES_PENDING_FILES["$webroot"]=1; changes_commit_pending || return 1
  fi
  (( result == 0 )) || { warn "证书签发未完成；原站点保持不变。"; return 1; }
  for domain in "${domains[@]}"; do
    domain="${domain/\*/keine-wildcard-check}"
    web_certificate_pair_valid "$domain" "$root/live/$name/fullchain.pem" "$root/live/$name/privkey.pem" || return 1
  done
  audit "action=certificate-issue name=$name method=$mode"
  ui_success "证书已签发 · $root/live/$name/fullchain.pem"
  ui_note "证书由 Certbot 原生管理；keine 不新增续期任务。"
}

security_certificate_issue_menu() {
  local preset_domain="${1:-}" preset_root="${2:-}" replace_name="${3:-}" choice input name email root='' mode
  ui_page "申请 HTTPS 证书"
  if [[ -z "$replace_name" ]]; then
    ui_action 1 "HTTP 验证" action
    ui_action 2 "手动 DNS 验证" action "支持通配符"
    ui_menu_footer "返回"; ui_read_choice choice
    case "$choice" in 1) mode=http ;; 2) mode=dns ;; 0) return 0 ;; *) return 1 ;; esac
  else mode=dns; fi
  input="$(read_input '域名（多个用逗号分隔）' "$preset_domain")"
  security_acme_domains "$input" >/dev/null || { warn "域名格式无效。"; return 1; }
  name="${replace_name:-${input%%,*}}"; name="${name#\*.}"; name="${name,,}"
  [[ -n "$replace_name" ]] || name="$(read_input '证书名称' "$name")"
  email="$(read_input '联系邮箱')"
  if [[ "$mode" == http ]]; then
    root="$(read_input 'HTTP 验证目录' "$preset_root")"
    ui_hint "该目录应通过 http://域名/.well-known/acme-challenge/ 对外提供文件。"
  fi
  security_acme_issue "$mode" "$name" "$email" "$input" "$root" "$([[ -n "$replace_name" ]] && printf 1 || printf 0)" || return 1
  (( DRY_RUN == 0 )) || return 0
  if [[ -n "$replace_name" ]]; then web_reload_certificate_users "$(security_certbot_root)/live/$name/fullchain.pem" || return 1
  else security_certificate_deploy_menu "$name"; fi
}

security_certificate_deploy_menu() {
  local name="$1" path choice index root sites=()
  root="$(security_certbot_root)"
  security_certbot_has_name "$name" || return 1
  while IFS= read -r path; do
    if (web_site_load "$path" && openssl x509 -in "$root/live/$name/fullchain.pem" -noout -checkhost "${WEB_SITE[domain]}" >/dev/null 2>&1); then sites+=("$path"); fi
  done < <(web_managed_paths)
  ui_page "证书部署 / $name"
  if (( ${#sites[@]} == 0 )); then ui_note "没有匹配的托管反代。可在反代管理中创建站点并选择已有证书。"; return 0; fi
  for index in "${!sites[@]}"; do
    web_site_load "${sites[$index]}" || return 1
    ui_item "$((index+1))" "${WEB_SITE[domain]}" "${WEB_SITE[engine]}"
  done
  ui_menu_footer "暂不部署"; ui_read_choice choice
  [[ "$choice" != 0 ]] || return 0
  [[ "$choice" =~ ^[1-9][0-9]{0,3}$ ]] && (( choice <= ${#sites[@]} )) || return 1
  confirm "将证书部署到选定站点并验证配置？" || return 0
  web_site_deploy_certificate "${sites[$((choice-1))]}" "$root/live/$name/fullchain.pem" "$root/live/$name/privkey.pem"
}

security_certificate_delete() {
  local name="$1" refs root
  root="$(security_certbot_root)"
  security_certbot_has_name "$name" || return 1
  [[ "$root" == /etc/letsencrypt ]] || return 1
  refs="$(web_certificate_references "$root/live/$name/fullchain.pem")" || return 1
  if [[ -n "$refs" ]]; then warn "证书仍被引用，请先解除关联："; printf '%s\n' "$refs"; return 1; fi
  ui_note "未发现 Nginx/Caddy 配置引用；请确认面板、容器或其他应用也未使用此证书。"
  confirm "确认没有其他应用使用，并删除 $name 证书及私钥？" || return 0
  require_root
  run certbot delete --cert-name "$name" --non-interactive || return 1
  (( DRY_RUN == 0 )) || return 0
  ! security_certbot_has_name "$name" || { warn "证书仍然存在，请检查 Certbot 输出。"; return 1; }
  audit "action=certificate-delete name=$name"
  ui_success "证书及私钥已删除；此操作无法由 keine 恢复"
}
