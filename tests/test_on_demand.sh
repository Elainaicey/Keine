#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT_DIR"

runtime_paths=(bin src scripts install.sh)

assert_no_runtime_match() {
  local pattern="$1" message="$2" matches
  matches="$(grep -R -nE --include='*.sh' --include='keine' -- "$pattern" "${runtime_paths[@]}" 2>/dev/null || true)"
  [[ -z "$matches" ]] || {
    printf 'FAIL: %s\n%s\n' "$message" "$matches" >&2
    exit 1
  }
}

assert_no_runtime_match \
  '(^|[;&|()[:space:]])(crontab|systemd-run|nohup|setsid|daemonize)([;&|()[:space:]]|$)' \
  '运行时代码包含计划任务或脱离终端的后台命令'
assert_no_runtime_match \
  '/etc/cron(\.|/)' \
  '运行时代码访问 Cron 配置路径'
assert_no_runtime_match \
  'systemctl[[:space:]]+(start|stop|restart|enable|disable|mask|unmask)[^\n]*\.timer' \
  '运行时代码可修改 systemd Timer 生命周期'
assert_no_runtime_match \
  '(^|[;&|()[:space:]])(install|cp|mv|tee|write_file_atomic)[[:space:]][^\n]*(/etc|/lib|/usr/lib)/systemd/system' \
  '运行时代码可部署项目自有 systemd 单元'
assert_no_runtime_match \
  '[[:space:]]&[[:space:]]*(#.*)?$' \
  '运行时代码包含 Shell 后台执行'

printf 'PASS: on-demand runtime\n'
