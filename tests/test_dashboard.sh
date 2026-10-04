#!/usr/bin/env bash
# 本文件定义的全局变量均为被加载运维总览模块消费的测试夹具。
# shellcheck disable=SC2034
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/core/firewall.sh"
. "$ROOT_DIR/src/features/dashboard.sh"

NO_COLOR=1
KEINE_VERSION=0.3.0
DASHBOARD_TIMEOUT_FILE="$(mktemp)"
trap 'rm -f -- "$DASHBOARD_TIMEOUT_FILE"' EXIT
runtime_locale
runtime_colors

platform_detect() {
  OS_NAME='Debian GNU/Linux 13 (trixie)'; ARCH=amd64; VIRTUALIZATION=kvm
  UPTIME_TEXT='3 hours'; LOAD_AVERAGE='0.05 0.02 0.00'; CPU_CORES=1
  MEMORY_USED_MB=453; MEMORY_MB=967; SWAP_USED_MB=0; SWAP_MB=2048
}
command_exists() {
  case "$1" in ss|docker|timedatectl|ufw) return 0 ;; *) return 1 ;; esac
}
package_upgradable_count() { printf '7'; }
service_state() { printf 'active'; }
service_exists() { [[ "$1" == "fail2ban.service" ]]; }
platform_firewall_active() { return 0; }
platform_firewall_backend() { printf ufw; }
timedatectl() { [[ "$1" == "show" ]] && printf 'yes\n'; }
backup_snapshots() { printf '20260730-010203-42\n20260729-010203-41\n'; }
dashboard_reboot_required() { return 1; }
systemctl() {
  case "$1" in
    --failed) return 0 ;;
    --type=service) printf 'one\ntwo\n' ;;
  esac
}
ss() { printf 'one\ntwo\nthree\n'; }
docker() {
  case "$1" in
    info) return 0 ;;
    ps)
      if [[ "$*" == *"--filter"* ]]; then return 0; fi
      printf 'one\ntwo\n'
      ;;
  esac
}
runtime_with_timeout() {
  printf '%s:%s:%s' "$1" "$2" "$3" >"$DASHBOARD_TIMEOUT_FILE"
  shift
  "$@"
}
df() {
  if [[ "$1" == '-Pm' ]]; then
    printf 'Filesystem 1M-blocks Used Available Use%% Mounted\n/dev/vda 10000 5300 4700 53%% /\n'
  fi
}

output="$(dashboard_show)"
grep -q '运维总览' <<<"$output" || { printf 'FAIL: 运维总览标题缺失\n' >&2; exit 1; }
grep -q 'Debian GNU/Linux 13.*amd64.*kvm' <<<"$output" || { printf 'FAIL: 主机上下文缺失\n' >&2; exit 1; }
grep -q '关键指标' <<<"$output" || { printf 'FAIL: 关键指标区缺失\n' >&2; exit 1; }
grep -q '46%  453/967 MiB' <<<"$output" || { printf 'FAIL: 内存进度计算错误\n' >&2; exit 1; }
grep -q 'Docker.*2 运行中' <<<"$output" || { printf 'FAIL: Docker 状态布局错误\n' >&2; exit 1; }
[[ "$(<"$DASHBOARD_TIMEOUT_FILE")" == '5:docker:info' ]] || { printf 'FAIL: Docker 总览探测没有设置超时\n' >&2; exit 1; }
grep -q '配置快照.*2 份' <<<"$output" || { printf 'FAIL: 配置快照状态缺失\n' >&2; exit 1; }
grep -q 'UFW.*已启用.*Fail2ban.*运行中.*系统时间.*已同步' <<<"$output" || {
  printf 'FAIL: 基础防护指标布局错误\n' >&2
  exit 1
}
grep -q '7 个系统软件包可更新' <<<"$output" || { printf 'FAIL: 状态驱动关注事项缺失\n' >&2; exit 1; }
[[ "$(dashboard_percent 9 10)" == "90" ]] || { printf 'FAIL: 总览百分比计算错误\n' >&2; exit 1; }
[[ "$(dashboard_resource_state 90)" == "bad" ]] || { printf 'FAIL: 高资源占用没有标记为异常\n' >&2; exit 1; }
[[ "$(dashboard_resource_state 75)" == "warn" ]] || { printf 'FAIL: 关注阈值状态错误\n' >&2; exit 1; }

declare -F dashboard_menu >/dev/null || { printf 'FAIL: 交互式运维总览入口缺失\n' >&2; exit 1; }
grep -q 'dashboard_menu' "$ROOT_DIR/src/core/navigation.sh" || { printf 'FAIL: 导航没有进入交互式运维总览\n' >&2; exit 1; }

printf 'PASS: dashboard\n'
