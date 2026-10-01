#!/usr/bin/env bash
# curl 测试替身由 HTTP 诊断函数间接调用。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
HTTP_TEST_ROOT="$(mktemp -d)"
HTTP_ARGS_FILE="$HTTP_TEST_ROOT/curl-args"
HTTP_TEST_SCENARIO="success"
trap '[[ "$HTTP_TEST_ROOT" == /tmp/* ]] && rm -rf -- "$HTTP_TEST_ROOT"' EXIT
SERVERCTL_VERSION=0.3.0
NO_COLOR=1
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/features/network/http.sh"
runtime_colors

valid_http_url 'https://example.com/a?b=1' || { printf 'FAIL: 拒绝了有效 HTTPS URL\n' >&2; exit 1; }
for unsafe in 'ftp://example.com' 'https://user:pass@example.com' 'https://exa mple.com' 'https://-x'; do
  if valid_http_url "$unsafe"; then
    printf 'FAIL: 接受了不安全 URL：%s\n' "$unsafe" >&2
    exit 1
  fi
done
[[ "$(network_http_milliseconds 0.125)" == '125 ms' ]] || { printf 'FAIL: HTTP 耗时格式错误\n' >&2; exit 1; }
[[ "$(network_http_metric $'http_code=204\r\n' http_code)" == 204 ]] || { printf 'FAIL: HTTP 指标未兼容 CRLF\n' >&2; exit 1; }
[[ "$(network_http_status_style 204)" == good && "$(network_http_status_style 404)" == warn ]] || {
  printf 'FAIL: HTTP 状态样式错误\n' >&2
  exit 1
}

curl() {
  local header_file="" output_file="" effective='https://example.com/' status=200 version=2
  [[ "$1" == "--disable" ]] || return 90
  printf '%s\n' "$@" >"$HTTP_ARGS_FILE"
  while (($# > 0)); do
    case "$1" in
      --dump-header) header_file="$2"; shift 2 ;;
      --output) output_file="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$HTTP_TEST_SCENARIO" in
    downgrade) effective='http://example.com/'; version='1.1' ;;
    http) effective='http://example.com/'; status=204; version='1.1' ;;
    head_unsupported) status=405 ;;
  esac
  [[ -n "$header_file" && "$output_file" == /dev/null ]] || return 91
  printf '%s\n' "HTTP/$version $status" 'server: fixture' 'content-type: text/plain' >"$header_file"
  printf '%s\n' \
    "http_code=$status" "url_effective=$effective" 'remote_ip=203.0.113.8' \
    'remote_port=443' 'local_ip=192.0.2.2' "http_version=$version" 'num_redirects=0' \
    'time_namelookup=0.010' 'time_connect=0.020' \
    'time_appconnect=0.050' 'time_starttransfer=0.080' 'time_total=0.100' \
    'ssl_verify_result=0'
}

output="$(network_http_diagnose https://example.com/)" || {
  printf 'FAIL: 成功 HTTP 场景被误判为失败\n' >&2
  exit 1
}
grep -q 'HTTP 状态.*200' <<<"$output" || { printf 'FAIL: HTTP 诊断缺少状态码\n' >&2; exit 1; }
grep -q 'TLS 校验.*通过' <<<"$output" || { printf 'FAIL: HTTP 诊断缺少 TLS 校验\n' >&2; exit 1; }
grep -q '100 ms' <<<"$output" || { printf 'FAIL: HTTP 诊断缺少总耗时\n' >&2; exit 1; }
[[ "$(sed -n '1p' "$HTTP_ARGS_FILE")" == '--disable' ]] || {
  printf 'FAIL: HTTP 诊断没有禁用用户 curl 配置\n' >&2
  exit 1
}
for required_argument in \
  '--globoff' '--proto' '=http,https' '--proto-redir' '--disallow-username-in-url' \
  '--location' '--max-redirs' '8' '--connect-timeout' '5' '--max-time' '20' \
  '--head' '--output' '/dev/null' '--'; do
  grep -Fqx -- "$required_argument" "$HTTP_ARGS_FILE" || {
    printf 'FAIL: HTTP curl 缺少安全参数：%s\n' "$required_argument" >&2
    exit 1
  }
done
header_path="$(awk 'previous == "--dump-header" { print; exit } { previous=$0 }' "$HTTP_ARGS_FILE")"
[[ -n "$header_path" && ! -e "$header_path" && ! -d "$(dirname -- "$header_path")" ]] || {
  printf 'FAIL: HTTP 临时响应头或目录没有清理\n' >&2
  exit 1
}
if grep -Eq -- '^--cookie(-jar)?$' "$HTTP_ARGS_FILE"; then
  printf 'FAIL: HTTP 诊断不应保存或加载 Cookie\n' >&2
  exit 1
fi

HTTP_TEST_SCENARIO="downgrade"
output="$(network_http_diagnose https://example.com/)"
grep -q '降级为 HTTP' <<<"$output" || { printf 'FAIL: HTTPS 降级没有告警\n' >&2; exit 1; }

HTTP_TEST_SCENARIO="http"
output="$(network_http_diagnose http://example.com/)"
grep -q 'TLS 校验.*不适用（HTTP）' <<<"$output" || { printf 'FAIL: HTTP 被错误显示为完成 TLS 校验\n' >&2; exit 1; }
grep -q 'TLS 握手.*不适用' <<<"$output" || { printf 'FAIL: HTTP 被错误显示为完成 TLS 握手\n' >&2; exit 1; }

HTTP_TEST_SCENARIO="head_unsupported"
output="$(network_http_diagnose https://example.com/)"
grep -q '不支持 HEAD' <<<"$output" || { printf 'FAIL: HEAD 不受支持时缺少解释\n' >&2; exit 1; }

printf 'PASS: http\n'
