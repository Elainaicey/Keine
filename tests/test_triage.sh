#!/usr/bin/env bash
# 测试夹具通过全局变量模拟平台探测结果。
# shellcheck disable=SC2034
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/features/system/triage.sh"

NO_COLOR=1
runtime_colors

platform_detect() {
  OS_NAME=Debian
  ARCH=amd64
  VIRTUALIZATION=kvm
  CPU_CORES=2
  MEMORY_MB=2048
  MEMORY_USED_MB=512
  ROOT_USED_PERCENT=20
  LOAD_AVERAGE='0.10 0.05 0.01'
}
systemctl() { return 0; }
package_upgradable_count() { printf '3'; }
journalctl() { return 0; }
df() {
  case "$1" in
    -Pm) printf 'Filesystem 1M-blocks Used Available Use%% Mounted\n/dev/vda 10000 2000 8000 20%% /\n' ;;
    -Pi) printf 'Filesystem Inodes IUsed IFree IUse%% Mounted\n/dev/vda 100000 1000 99000 1%% /\n' ;;
  esac
}
security_exposure_listener_rows() { printf 'tcp|0.0.0.0|22|sshd|1\n'; }
TRIAGE_TIMEOUT_FILE="$(mktemp)"
TRIAGE_DOCKER_STATUS=0
trap 'rm -f -- "$TRIAGE_TIMEOUT_FILE"' EXIT
command_exists() { [[ "$1" == docker ]]; }
runtime_with_timeout() {
  printf '%s:%s:%s' "$1" "$2" "$3" >"$TRIAGE_TIMEOUT_FILE"
  return "$TRIAGE_DOCKER_STATUS"
}
docker() { :; }
backup_snapshots() { printf '20260724-120000-42\n'; }
backup_snapshot_protected() { return 1; }

output="$(system_triage_report)"
[[ "$(<"$TRIAGE_TIMEOUT_FILE")" == '5:docker:info' ]] || {
  printf 'FAIL: 故障排查的 Docker 探测没有设置超时\n' >&2
  exit 1
}
grep -q '故障快速排查' <<<"$output" || {
  printf 'FAIL: 故障快速排查页面缺失\n' >&2
  exit 1
}
grep -q '没有失败的 systemd 单元' <<<"$output" || {
  printf 'FAIL: 故障排查没有汇总 systemd 状态\n' >&2
  exit 1
}
grep -q '存在可用的配置快照' <<<"$output" || {
  printf 'FAIL: 故障排查没有汇总恢复能力\n' >&2
  exit 1
}
grep -q '当前快速排查项没有发现异常' <<<"$output" || {
  printf 'FAIL: 正常夹具产生了错误排查结论\n' >&2
  exit 1
}

TRIAGE_DOCKER_STATUS=1
output="$(system_triage_report)"
grep -q 'Docker Daemon 在 5 秒内不可用' <<<"$output" || {
  printf 'FAIL: Docker Daemon 探测失败被误报为健康\n' >&2
  exit 1
}

printf 'PASS: triage\n'
