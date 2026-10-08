#!/usr/bin/env bash
# Isolated files and command fixtures: no system service, network or ACME calls.
# shellcheck disable=SC2034,SC2317,SC2329,SC2016
set -Eeuo pipefail
IFS=$'\n\t'
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export KEINE_STATE_ROOT="$test_root/keine-state"
export KEINE_NGINX_CONFIG="$test_root/nginx/nginx.conf" KEINE_NGINX_SITES="$test_root/nginx/conf.d"
export KEINE_CADDY_CONFIG="$test_root/caddy/Caddyfile" KEINE_CADDY_SITES="$test_root/caddy/keine.d"
export KEINE_ACME_ROOT="$test_root/keine-acme"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/core/changes.sh"
. "$ROOT_DIR/src/core/configuration.sh"
. "$ROOT_DIR/src/features/apps/web.sh"
. "$ROOT_DIR/src/features/security/certificates.sh"
CHANGES_ENABLED=1
require_root() { :; }
audit() { changes_commit_pending; }
confirm() { return 0; }
runtime_with_timeout() { shift; "$@"; }
web_lock() { :; }
mkdir -p "$KEINE_NGINX_SITES" "$(dirname "$KEINE_CADDY_CONFIG")"
printf 'events {}\nhttp { include %s/*.conf; }\n' "$KEINE_NGINX_SITES" >"$KEINE_NGINX_CONFIG"
printf ':8080 { respond "original" }\n' >"$KEINE_CADDY_CONFIG"

for domain in example.com xn--fiqs8s.example a-b.example.com; do web_domain_valid "$domain" || die '有效域名被拒绝'; done
for domain in '' localhost -a.com a..com a_.com 127.0.0.1 'example.com;id' '*.example.com'; do
  if web_domain_valid "$domain"; then die "危险域名被接受：$domain"; fi
done
for url in http://127.0.0.1:8080 https://example.com:443 'http://[::1]:8080'; do web_upstream_valid "$url" || die '有效上游被拒绝'; done
for url in 'http://a.com:80/path' 'http://user:pass@a.com:80' 'http://a.com:0' 'http://a.com:80;return' 'http://$(id):80'; do
  if web_upstream_valid "$url"; then die '危险上游被接受'; fi
done
if security_acme_domains 'example.com,,other.com' >/dev/null; then die '空 SAN 未拒绝'; fi
[[ "$(security_acme_domains 'Example.com,*.example.com,example.com')" == $'example.com\n*.example.com' ]] || die 'SAN 解析错误'

# Use real OpenSSL for matching certificates and private keys.
MSYS2_ARG_CONV_EXCL='/CN=' openssl req -x509 -newkey rsa:2048 -nodes -keyout "$test_root/key.pem" -out "$test_root/cert.pem" \
  -days 1 -subj '/CN=example.com' -addext 'subjectAltName=DNS:example.com,DNS:*.example.com' >/dev/null 2>&1
web_certificate_pair_valid example.com "$test_root/cert.pem" "$test_root/key.pem" || die '有效证书匹配失败'
if web_certificate_pair_valid other.test "$test_root/cert.pem" "$test_root/key.pem" 2>/dev/null; then die '错误域名证书通过'; fi
openssl genrsa -out "$test_root/other.key" 2048 >/dev/null 2>&1
if web_certificate_pair_valid example.com "$test_root/cert.pem" "$test_root/other.key" 2>/dev/null; then die '私钥不匹配未阻止'; fi

nginx_bad=0
nginx_loaded=1
reload_fail=0
nginx() {
  local file
  case "$1" in
    -V) printf 'configure arguments: --conf-path=%s\n' "$KEINE_NGINX_CONFIG" ;;
    -t) (( nginx_bad == 0 )) ;;
    -T)
      if [[ -f "$test_root/external-nginx" ]]; then cat "$test_root/external-nginx"; fi
      if (( nginx_loaded == 1 )); then
        for file in "$KEINE_NGINX_SITES"/*.conf; do
          [[ -f "$file" ]] || continue
          printf '# configuration file %s:\n' "$file"; cat "$file"
        done
      fi ;;
  esac
}
service_exists() { return 0; }
systemctl() {
  case "$1" in
    show)
      if [[ "$*" == *ExecStart* ]]; then
        if [[ "$2" == nginx.service ]]; then printf '/usr/sbin/nginx -c %s\n' "$KEINE_NGINX_CONFIG"
        else printf '/usr/bin/caddy run --config %s\n' "$KEINE_CADDY_CONFIG"; fi
      else printf 'root\n'; fi ;;
    is-active) return 0 ;;
    reload) printf '%s\n' "$2" >>"$test_root/reloads"; (( reload_fail == 0 )) ;;
  esac
}
ss() { :; }
caddy() {
  case "$1" in
    validate) return 0 ;;
    adapt) printf '{"host":["caddy.example.com"]}\n' ;;
  esac
}
jq() {
  if [[ "$*" == *--arg* ]]; then printf '1\n'; else :; fi
}

printf '# configuration file /etc/nginx/external.conf:\nserver { listen 80; server_name "taken.example.com"; proxy_pass http://127.0.0.1:3000; }\n' >"$test_root/external-nginx"
if web_domain_available nginx taken.example.com 2>/dev/null; then die '外部域名冲突未阻止'; fi
web_domain_available nginx free.example.com || die '空闲域名误报'

web_site_defaults nginx example.com http://127.0.0.1:8080
content="$(web_site_render)"
[[ "$content" == *'proxy_set_header Host $host;'* && "$content" == *'proxy_set_header X-Forwarded-For $remote_addr;'* ]] || die 'Nginx 变量错误展开或转发头不安全'
DRY_RUN=1
web_site_write >/dev/null
path="$(web_site_path nginx example.com)"
[[ ! -e "$path" && ! -e "$KEINE_ACME_ROOT" ]] || die '预览写入配置'
DRY_RUN=0
web_site_write >/dev/null
if [[ ! -f "$path" ]] || ! web_site_owned "$path"; then die '站点未正确登记'; fi
original="$(<"$path")"

web_site_load "$path"
WEB_SITE[upstream]=http://127.0.0.1:9999
reload_fail=1
if web_site_write >/dev/null 2>&1; then die '重载失败被报告成功'; fi
reload_fail=0
[[ "$(<"$path")" == "$original" ]] || die '重载失败未回退配置'
web_site_owned "$path" || die '回退后恢复记录不一致'
printf '\n# external edit\n' >>"$path"
if web_site_write >/dev/null 2>&1; then die '覆盖了人工修改'; fi
printf '%s\n' "$original" >"$path"

web_site_load "$path"; WEB_SITE[enabled]=0
web_site_write >/dev/null
if grep -q '^server {' "$path"; then die '停用站点仍生成监听'; fi
web_site_load "$path"; WEB_SITE[enabled]=1
web_site_write >/dev/null
web_site_deploy_certificate "$path" "$test_root/cert.pem" "$test_root/key.pem" >/dev/null
grep -q 'listen 443 ssl;' "$path" || die '证书未部署到 HTTPS'
if security_certificate_delete invalid >/dev/null 2>&1; then die '删除了不存在的证书'; fi
[[ -n "$(web_certificate_references "$test_root/cert.pem")" ]] || die '证书引用未识别'
web_site_restore "$path" >/dev/null
[[ ! -e "$path" && -f "$test_root/cert.pem" ]] || die '站点删除影响了证书或未删除站点'

web_site_defaults nginx not-loaded.example.com http://127.0.0.1:8080
nginx_loaded=0
if web_site_write >/dev/null 2>&1; then die '未 include 的站点误报应用成功'; fi
nginx_loaded=1
[[ ! -e "$(web_site_path nginx not-loaded.example.com)" ]] || die '未加载站点未回退'

web_site_defaults caddy caddy.example.com https://example.com:443
WEB_SITE[tls]=auto
web_site_write >/dev/null
path="$(web_site_path caddy caddy.example.com)"
grep -Fqx "import $KEINE_CADDY_SITES/*.caddy" "$KEINE_CADDY_CONFIG" || die 'Caddy import 未接入'
grep -q 'header_up Host example.com:443' "$path" || die 'HTTPS 上游 Host 未设置'
web_site_restore "$path" >/dev/null
[[ "$(<"$KEINE_CADDY_CONFIG")" == ':8080 { respond "original" }' ]] || die 'Caddy 主配置未恢复'

# ACME argument construction and dry-run boundaries, with no real certificate request.
security_certbot_root() { printf /etc/letsencrypt; }
security_certbot_has_name() { return 1; }
security_acme_http_check() { return 0; }
web_certificate_pair_valid() { return 0; }
certbot() { printf '%s\n' "$@" >"$test_root/issue-args"; }
security_acme_issue http issued.example.com admin@example.com issued.example.com "$KEINE_ACME_ROOT" >/dev/null
grep -Fxq -- '--webroot' "$test_root/issue-args" || die '未使用 webroot 签发'
grep -Fxq -- '--no-directory-hooks' "$test_root/issue-args" || die '新签发运行了外部目录钩子'
if grep -Eq -- '^--nginx$|^--force-renewal$' "$test_root/issue-args"; then die '首次签发修改外部站点或强制续期'; fi
before="$(<"$test_root/issue-args")"
DRY_RUN=1
security_acme_issue dns preview.example.com admin@example.com '*.preview.example.com' >/dev/null
[[ "$(<"$test_root/issue-args")" == "$before" ]] || die 'DNS 预览执行了签发'
DRY_RUN=0
security_certbot_has_name() { return 0; }
if security_acme_issue http existing admin@example.com example.com "$KEINE_ACME_ROOT" >/dev/null 2>&1; then die '覆盖了已有证书'; fi
web_certificate_references() { printf 'nginx reference\n'; }
if security_certificate_delete example.com >/dev/null 2>&1; then die '删除了仍在引用的证书'; fi
[[ "$(<"$test_root/issue-args")" == "$before" ]] || die '引用检查后仍执行了删除'
printf 'PASS: reverse proxies and certificate issuance\n'
