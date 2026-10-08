#!/usr/bin/env bash
# Site metadata is data, never sourced as shell code.
# shellcheck disable=SC2034
declare -Ag WEB_SITE=()

web_domain_valid() {
  local value="${1:-}" label labels=()
  [[ ${#value} -le 253 && "$value" == *.* && "$value" != *..* && "$value" != *. ]] || return 1
  IFS=. read -r -a labels <<<"$value"
  for label in "${labels[@]}"; do
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
  done
  ! valid_ipv4_address "$value"
}

web_path_valid() {
  [[ "${1:-}" =~ ^/[a-zA-Z0-9_./-]+$ ]] && safe_managed_path "$1"
}

web_upstream_valid() {
  local value="${1:-}" authority host port
  [[ "$value" == http://* || "$value" == https://* ]] || return 1
  authority="${value#*://}"
  if [[ "$authority" =~ ^\[([0-9a-fA-F:]+)\]:([0-9]{1,5})$ ]]; then
    host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
    valid_ipv6_address "$host" && valid_port "$port"
  elif [[ "$authority" =~ ^([a-zA-Z0-9.-]+):([0-9]{1,5})$ ]]; then
    host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
    valid_port "$port" && { [[ "$host" == localhost ]] || valid_ipv4_address "$host" || web_domain_valid "${host,,}"; }
  else return 1; fi
}

web_engine_config() {
  local start config=''
  case "$1" in
    nginx) [[ -z "${KEINE_NGINX_CONFIG:-}" ]] || { printf '%s' "$KEINE_NGINX_CONFIG"; return; } ;;
    caddy) [[ -z "${KEINE_CADDY_CONFIG:-}" ]] || { printf '%s' "$KEINE_CADDY_CONFIG"; return; } ;;
    *) return 1 ;;
  esac
  if command_exists systemctl; then
    start="$(runtime_with_timeout 3 systemctl show "$1.service" -p ExecStart --value 2>/dev/null || true)"
    if [[ "$1" == caddy && "$start" =~ --config[=[:space:]]+([^[:space:];\}]+) ]]; then config="${BASH_REMATCH[1]}"
    elif [[ "$1" == nginx && "$start" =~ [[:space:]]-c[[:space:]]+([^[:space:];\}]+) ]]; then config="${BASH_REMATCH[1]}"; fi
  fi
  if [[ -z "$config" && "$1" == nginx ]] && command_exists nginx; then
    config="$(nginx -V 2>&1 | sed -n 's/.*--conf-path=\([^ ]*\).*/\1/p')"
  fi
  if [[ -n "$config" ]] && web_path_valid "$config"; then printf '%s' "$config"
  elif [[ "$1" == nginx ]]; then printf /etc/nginx/nginx.conf
  else printf /etc/caddy/Caddyfile; fi
}

web_sites_dir() {
  case "$1" in
    nginx) printf '%s' "${KEINE_NGINX_SITES:-/etc/nginx/conf.d}" ;;
    caddy) printf '%s' "${KEINE_CADDY_SITES:-/etc/caddy/keine.d}" ;;
    *) return 1 ;;
  esac
}

web_acme_root() { printf '%s' "${KEINE_ACME_ROOT:-/var/lib/keine-acme}"; }

web_tls_label() {
  case "$1" in http) printf 'HTTP' ;; auto) printf '自动 HTTPS' ;; pem) printf '已有证书' ;; *) printf '未知' ;; esac
}

web_site_path() {
  web_domain_valid "$2" || return 1
  case "$1" in
    nginx) printf '%s/keine-%s.conf' "$(web_sites_dir nginx)" "$2" ;;
    caddy) printf '%s/keine-%s.caddy' "$(web_sites_dir caddy)" "$2" ;;
    *) return 1 ;;
  esac
}

web_site_values_valid() {
  local key
  for key in engine domain upstream tls cert key enabled timeout body ipv6; do
    [[ -v "WEB_SITE[$key]" ]] || return 1
  done
  [[ "${WEB_SITE[engine]}" == nginx || "${WEB_SITE[engine]}" == caddy ]] || return 1
  web_domain_valid "${WEB_SITE[domain]}" && web_upstream_valid "${WEB_SITE[upstream]}" || return 1
  [[ "${WEB_SITE[enabled]}" =~ ^[01]$ && "${WEB_SITE[ipv6]}" =~ ^[01]$ ]] || return 1
  [[ "${WEB_SITE[timeout]}" =~ ^[1-9][0-9]{0,3}$ && "${WEB_SITE[body]}" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
  (( WEB_SITE[timeout] <= 3600 && WEB_SITE[body] <= 32768 )) || return 1
  case "${WEB_SITE[tls]}" in
    http) [[ "${WEB_SITE[cert]}" == - && "${WEB_SITE[key]}" == - ]] ;;
    auto) [[ "${WEB_SITE[engine]}" == caddy && "${WEB_SITE[cert]}" == - && "${WEB_SITE[key]}" == - ]] ;;
    pem) web_path_valid "${WEB_SITE[cert]}" && web_path_valid "${WEB_SITE[key]}" ;;
    *) return 1 ;;
  esac
}

web_site_load() {
  local path="$1" key value
  WEB_SITE=()
  [[ -f "$path" && ! -L "$path" ]] && grep -Fqx '# keine-web-v1' "$path" || return 1
  while IFS='=' read -r key value; do
    case "$key" in engine|domain|upstream|tls|cert|key|enabled|timeout|body|ipv6)
      [[ ! -v "WEB_SITE[$key]" ]] || return 1; WEB_SITE["$key"]="$value" ;;
      *) return 1 ;;
    esac
  done < <(sed -n 's/^# site\.//p' "$path")
  web_site_values_valid || return 1
  [[ "$path" == "$(web_site_path "${WEB_SITE[engine]}" "${WEB_SITE[domain]}")" ]]
}

# Nginx variables below must remain literal in the generated configuration.
# shellcheck disable=SC2016
web_site_render() {
  web_site_values_valid || return 1
  local field engine="${WEB_SITE[engine]}" domain="${WEB_SITE[domain]}" host authority variable scheme
  printf '# Managed by keine\n# keine-web-v1\n'
  for field in engine domain upstream tls cert key enabled timeout body ipv6; do
    printf '# site.%s=%s\n' "$field" "${WEB_SITE[$field]}"
  done
  [[ "${WEB_SITE[enabled]}" == 1 ]] || return 0
  if [[ "$engine" == caddy ]]; then
    scheme=https; [[ "${WEB_SITE[tls]}" != http ]] || scheme=http
    printf '%s://%s {\n' "$scheme" "$domain"
    if [[ "${WEB_SITE[tls]}" == pem ]]; then printf '    tls %s %s\n' "${WEB_SITE[cert]}" "${WEB_SITE[key]}"; fi
    printf '    request_body {\n        max_size %s\n    }\n' "$((WEB_SITE[body]*1024*1024))"
    printf '    reverse_proxy %s {\n' "${WEB_SITE[upstream]}"
    if [[ "${WEB_SITE[upstream]}" == https://* ]]; then
      printf '        header_up Host %s\n' "${WEB_SITE[upstream]#*://}"
    fi
    printf '        transport http {\n            dial_timeout 10s\n            response_header_timeout %ss\n        }\n    }\n}\n' "${WEB_SITE[timeout]}"
    return 0
  fi
  variable="keine_ws_$(printf '%s' "$domain" | sha256sum | cut -c1-12)"
  printf 'map $http_upgrade $%s {\n    default upgrade;\n    "" close;\n}\n' "$variable"
  printf 'server {\n    listen 80;\n'
  [[ "${WEB_SITE[ipv6]}" != 1 ]] || printf '    listen [::]:80;\n'
  printf '    server_name %s;\n' "$domain"
  printf '    location ^~ /.well-known/acme-challenge/ {\n        root %s;\n        default_type text/plain;\n        try_files $uri =404;\n    }\n' "$(web_acme_root)"
  if [[ "${WEB_SITE[tls]}" == pem ]]; then
    printf '    location / { return 301 https://%s$request_uri; }\n}\nserver {\n    listen 443 ssl;\n' "$domain"
    [[ "${WEB_SITE[ipv6]}" != 1 ]] || printf '    listen [::]:443 ssl;\n'
    printf '    server_name %s;\n    ssl_certificate %s;\n    ssl_certificate_key %s;\n    ssl_protocols TLSv1.2 TLSv1.3;\n' "$domain" "${WEB_SITE[cert]}" "${WEB_SITE[key]}"
  fi
  printf '    client_max_body_size %sm;\n    location / {\n        proxy_pass %s;\n' "${WEB_SITE[body]}" "${WEB_SITE[upstream]}"
  printf '        proxy_http_version 1.1;\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $remote_addr;\n        proxy_set_header X-Forwarded-Proto $scheme;\n'
  printf '        proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection $%s;\n' "$variable"
  printf '        proxy_connect_timeout 10s;\n        proxy_read_timeout %ss;\n        proxy_send_timeout %ss;\n' "${WEB_SITE[timeout]}" "${WEB_SITE[timeout]}"
  if [[ "${WEB_SITE[upstream]}" == https://* ]]; then
    authority="${WEB_SITE[upstream]#*://}"; host="${authority%:*}"; host="${host#[}"; host="${host%]}"
    printf '        proxy_ssl_server_name on;\n        proxy_ssl_name %s;\n        proxy_ssl_verify on;\n        proxy_ssl_verify_depth 5;\n        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;\n' "$host"
  fi
  printf '    }\n}\n'
}

web_certificate_pair_valid() {
  local domain="$1" cert="$2" key="$3" public_cert public_key
  web_domain_valid "$domain" && web_path_valid "$cert" && web_path_valid "$key" || return 1
  [[ -r "$cert" && -f "$cert" && -r "$key" && -f "$key" ]] || { warn "证书或私钥不可读。"; return 1; }
  if ! openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null 2>&1 ||
    ! openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1; then
    warn "证书已过期或不覆盖 $domain。"; return 1
  fi
  public_cert="$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null)" || return 1
  public_key="$(openssl pkey -in "$key" -passin pass: -pubout 2>/dev/null)" || return 1
  [[ -n "$public_cert" && "$public_cert" == "$public_key" ]] || { warn "证书与私钥不匹配。"; return 1; }
}
