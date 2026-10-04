#!/usr/bin/env bash
# 命令夹具模拟在线握手与续期，不访问网络或系统证书目录。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/features/security/certificates.sh"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
KEINE_LETSENCRYPT_ROOT="$test_root/letsencrypt"
mkdir -p "$KEINE_LETSENCRYPT_ROOT/renewal"
printf '[renewalparams]\nauthenticator = nginx\ninstaller = nginx\n' >"$KEINE_LETSENCRYPT_ROOT/renewal/example.com.conf"
printf '[renewalparams]\nauthenticator = standalone\n' >"$KEINE_LETSENCRYPT_ROOT/renewal/second.conf"
touch "$KEINE_LETSENCRYPT_ROOT/renewal/invalid;name.conf"
[[ "$(security_certbot_names)" == $'example.com\nsecond' ]] || die 'Certbot 证书枚举错误'
[[ "$(security_certbot_setting example.com authenticator)" == nginx ]] || die '续期验证插件解析错误'
if security_certbot_has_name '../outside' || security_certbot_valid_name '--help'; then die 'Certbot 名称缺少验证'; fi

ui_page() { :; }
security_certificate_report() { :; }
verify_code=0
timeout() { shift; "$@"; }
openssl() {
  case "$1" in
    s_client)
      printf '%s\n' "$@" >"$test_root/tls-args"
      printf 'Verify return code: %s (result)\n' "$verify_code"
      if (( verify_code == 0 )); then printf 'Verify return code: 0 (ok)\n'; fi
      ;;
    x509) printf 'sha256 Fingerprint=unchanged\n' ;;
  esac
}
security_tls_inspect example.com 443 >/dev/null
grep -Fxq -- '-verify_hostname' "$test_root/tls-args" || die '未验证 TLS 主机名'
security_tls_inspect 2001:db8::1 8443 >/dev/null
grep -Fxq -- '-verify_ip' "$test_root/tls-args" || die 'IPv6 未验证证书 IP'
grep -Fxq -- '[2001:db8::1]:8443' "$test_root/tls-args" || die 'IPv6 TLS 地址构造错误'
verify_code=18
if security_tls_inspect example.com 443 >/dev/null; then die '不可信证书被报告为通过'; fi

security_certbot_root() { printf /etc/letsencrypt; }
security_certbot_has_name() { [[ "$1" == example.com ]]; }
security_certbot_setting() { printf nginx; }
certbot() { printf '%s\n' "$@" >"$test_root/renew-args"; }
confirm() { return 0; }
require_root() { :; }
audit() { :; }
security_certbot_renew example.com test >/dev/null
grep -Fxq -- '--dry-run' "$test_root/renew-args" || die '测试续期未使用测试环境'
grep -Fxq -- '--cert-name' "$test_root/renew-args" || die '续期未限制为单张证书'
result="$(security_certbot_renew example.com renew)"
[[ "$result" == *证书未变化* ]] || die '未到期证书被误报为已更新'
if grep -Eq -- '--force-renewal|--dry-run' "$test_root/renew-args"; then die '普通续期被强制执行或混为测试'; fi
before="$(<"$test_root/renew-args")"
DRY_RUN=1
security_certbot_renew example.com test >/dev/null
[[ "$(<"$test_root/renew-args")" == "$before" ]] || die '项目预览调用了真实续期'
printf 'PASS: certificates\n'
