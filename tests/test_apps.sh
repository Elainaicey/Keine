#!/usr/bin/env bash
# 测试桩由应用 reload 流程间接调用。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/core/platform.sh"
. "$ROOT_DIR/src/features/apps.sh"

[[ "$(apps_service_record 1)" == 'docker|Docker|docker.service|docker|docker-ce|容器引擎' ]] || {
  printf 'FAIL: Docker 应用服务映射错误\n' >&2
  exit 1
}
[[ "$(apps_service_record 5)" == 'haproxy|HAProxy|haproxy.service|haproxy|haproxy|Web 服务' ]] || {
  printf 'FAIL: HAProxy 应用服务映射错误\n' >&2
  exit 1
}
[[ "$(apps_service_record 10)" == 'mosquitto|Mosquitto|mosquitto.service|mosquitto|mosquitto|消息服务' ]] || {
  printf 'FAIL: Mosquitto 应用服务映射错误\n' >&2
  exit 1
}
[[ "$(apps_service_record 11)" == 'x-ui|3x-ui|x-ui.service|||代理面板' ]] || {
  printf 'FAIL: 3x-ui 应用服务映射错误\n' >&2
  exit 1
}
[[ "$(apps_service_catalog | awk -F '|' '{print $3}' | sort -u | wc -l | tr -d ' ')" == "11" ]] || {
  printf 'FAIL: 应用服务名称不唯一\n' >&2
  exit 1
}
app_count=0
while IFS='|' read -r app_id app_name service catalog_id package_name category; do
  [[ "$app_id" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { printf 'FAIL: 应用 ID 无效：%s\n' "$app_id" >&2; exit 1; }
  [[ -n "$app_name" && "$service" == *.service && -n "$category" ]] || {
    printf 'FAIL: 应用元数据字段无效：%s\n' "$app_id" >&2
    exit 1
  }
  [[ -z "$catalog_id" || "$catalog_id" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
    printf 'FAIL: 软件目录 ID 无效：%s\n' "$catalog_id" >&2
    exit 1
  }
  [[ -z "$package_name" || "$package_name" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || {
    printf 'FAIL: 应用包名无效：%s\n' "$package_name" >&2
    exit 1
  }
  app_count=$((app_count + 1))
done < <(apps_service_catalog)
[[ "$app_count" -eq 11 ]] || { printf 'FAIL: 应用目录条目数错误\n' >&2; exit 1; }
[[ "$(apps_service_unit nginx)" == "nginx.service" &&
  "$(apps_service_catalog_id nginx)" == "nginx" &&
  "$(apps_service_package nginx)" == "nginx" &&
  "$(apps_service_field nginx 6)" == "Web 服务" ]] || {
  printf 'FAIL: 应用服务字段读取错误\n' >&2
  exit 1
}
apps_service_config_validation_supported nginx || {
  printf 'FAIL: Nginx 没有声明配置检查能力\n' >&2
  exit 1
}
apps_service_reload_supported caddy || {
  printf 'FAIL: Caddy 没有声明安全 reload 能力\n' >&2
  exit 1
}
if ! apps_service_config_validation_supported haproxy ||
  ! apps_service_reload_supported haproxy; then
  printf 'FAIL: HAProxy 没有声明配置检查与 reload 能力\n' >&2
  exit 1
fi
if apps_service_reload_supported redis; then
  printf 'FAIL: Redis 被错误声明为通用安全 reload\n' >&2
  exit 1
fi
grep -Fxq /etc/nginx/nginx.conf < <(apps_service_config_paths nginx) || {
  printf 'FAIL: Nginx 配置资产缺少主配置\n' >&2
  exit 1
}
grep -Fxq /etc/mosquitto/mosquitto.conf < <(apps_service_config_paths mosquitto) || {
  printf 'FAIL: Mosquitto 配置资产缺少主配置\n' >&2
  exit 1
}

service_exists() {
  case "$1" in nginx.service|haproxy.service) return 0 ;; *) return 1 ;; esac
}
service_state() {
  case "$1" in nginx.service) printf 'active' ;; haproxy.service) printf 'failed' ;; *) printf 'inactive' ;; esac
}
[[ "$(apps_service_inventory_counts)" == '2|1|1' ]] || {
  printf 'FAIL: 应用服务运行统计错误\n' >&2
  exit 1
}

valid_service_name() { return 0; }
terminal_safe_text() { printf '%s' "$1"; }
systemctl() {
  if [[ "$1" == "show" ]]; then
    printf '%s\n' 'ControlGroup=' 'MainPID=123'
  fi
}
command_exists() { [[ "$1" == "ss" ]]; }
ss() {
  printf '%s\n' \
    'tcp LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=123,fd=6))' \
    'tcp LISTEN 0 4096 127.0.0.1:5432 0.0.0.0:* users:(("postgres",pid=456,fd=7))'
}
listeners="$(apps_service_listener_rows nginx.service)"
[[ "$(grep -c . <<<"$listeners")" -eq 1 && "$listeners" == *"0.0.0.0:80"* ]] || {
  printf 'FAIL: 应用监听端口没有按 systemd PID 过滤\n' >&2
  exit 1
}

DRY_RUN=1
captured=""
service_state() { printf 'active'; }
service_exists() { return 0; }
systemctl() {
  if [[ "$1" == "show" ]]; then
    printf '%s\n' 'CanReload=yes' 'ExecReload={ path=/usr/sbin/nginx ; argv[]=/usr/sbin/nginx -s reload ; }'
  fi
}
apps_service_config_validate() { return 0; }
confirm() { return 0; }
require_root() { :; }
run() { captured="$1 $2 $3"; }
audit() { :; }
ui_page() { :; }
ui_success() { :; }
warn() { :; }

services_apply_action() { captured="$1:$2"; }
apps_service_lifecycle_action haproxy restart
[[ "$captured" == "haproxy.service:restart" ]] || {
  printf 'FAIL: 应用生命周期没有复用验证后的 systemd 操作\n' >&2
  exit 1
}
if apps_service_lifecycle_action haproxy reload >/dev/null 2>&1; then
  printf 'FAIL: 应用生命周期接受了未声明动作\n' >&2
  exit 1
fi

captured=""
apps_service_reload nginx >/dev/null
[[ "$captured" == "systemctl reload nginx.service" ]] || {
  printf 'FAIL: Nginx 安全 reload 没有调用声明的 systemd 服务\n' >&2
  exit 1
}
captured=""
apps_service_config_validate() { return 1; }
if apps_service_reload nginx >/dev/null 2>&1; then
  printf 'FAIL: 配置检查失败后仍允许应用 reload\n' >&2
  exit 1
fi
[[ -z "$captured" ]] || {
  printf 'FAIL: 配置检查失败后仍执行了 systemctl\n' >&2
  exit 1
}

# 菜单快照只执行一次 systemctl 和 dpkg-query，且识别 systemd 别名。
APPS_TEST_ROOT="$(mktemp -d)"
trap '[[ "$APPS_TEST_ROOT" == /tmp/* ]] && rm -rf -- "$APPS_TEST_ROOT"' EXIT
APP_QUERY_LOG="$APPS_TEST_ROOT/queries"
ARCH=amd64
runtime_with_timeout() { [[ "$1" == 3 ]] || return 1; shift; "$@"; }
command_exists() { case "$1" in systemctl|dpkg-query) return 0 ;; *) return 1 ;; esac; }
systemctl() {
  local fixture_unit
  printf 'systemctl\n' >>"$APP_QUERY_LOG"
  printf '%s\n' 'Id=nginx.service' 'Names=nginx.service' 'LoadState=loaded' 'ActiveState=active' 'UnitFileState=enabled' 'MainPID=123' '' \
    'Id=redis-server.service' 'Names=redis-server.service redis.service' 'LoadState=loaded' 'ActiveState=failed' 'UnitFileState=disabled'
  printf '\n'
  while IFS='|' read -r _ _ fixture_unit _; do
    case "$fixture_unit" in nginx.service|redis.service) continue ;; esac
    printf 'Id=%s\nLoadState=not-found\nActiveState=inactive\n\n' "$fixture_unit"
  done < <(apps_service_catalog)
}
dpkg-query() { printf 'dpkg-query\n' >>"$APP_QUERY_LOG"; printf '%s\n' 'nginx|installed|1.28.0' 'removed|config-files|0.9'; }
apps_service_cache_invalidate
apps_service_cache_build
apps_service_cache_build
[[ "$APPS_SERVICE_CACHE_ERROR" == 0 ]] || { printf 'FAIL: 完整服务快照被误判为失败\n' >&2; exit 1; }
[[ "$(grep -c '^systemctl$' "$APP_QUERY_LOG")" == 1 && "$(grep -c '^dpkg-query$' "$APP_QUERY_LOG")" == 1 ]] || {
  printf 'FAIL: 菜单重复扫描应用状态或版本\n' >&2; exit 1;
}
apps_service_cached_exists redis.service || { printf 'FAIL: 没有识别原生服务别名\n' >&2; exit 1; }
[[ "$(apps_service_cached_state redis.service)" == failed && "$(apps_service_cached_enabled nginx.service)" == enabled ]] || exit 1
[[ "$(apps_service_package_version nginx)" == 1.28.0 ]] || exit 1
apps_service_binary_version() { printf 'FAIL: 已有包版本时仍探测程序\n' >&2; exit 1; }
[[ "$(apps_service_version nginx)" == 1.28.0 ]] || exit 1
apps_service_cache_invalidate
[[ "$APPS_SERVICE_CACHE_READY" == 0 && ${#APPS_PACKAGE_VERSION_CACHE[@]} == 0 ]] || exit 1
systemctl() { return 1; }
apps_service_cache_build
[[ "$APPS_SERVICE_CACHE_ERROR" == 1 ]] || { printf 'FAIL: systemd 查询失败被误报为正常\n' >&2; exit 1; }

printf 'PASS: apps\n'
