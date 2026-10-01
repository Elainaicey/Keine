#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
# shellcheck source=../src/core/runtime.sh
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/platform.sh"

# package_candidate_version 通过环境限定间接调用该测试桩。
# shellcheck disable=SC2317,SC2329
apt-cache() {
  if [[ "${LC_ALL:-}" == "C" ]]; then
    printf '%s\n' '  Candidate: 2.0.0'
  else
    printf '%s\n' '  候选版本：2.0.0'
  fi
}
[[ "$(package_candidate_version demo)" == "2.0.0" ]] || {
  printf 'FAIL: 候选版本解析受当前语言环境影响\n' >&2
  exit 1
}
unset -f apt-cache

updates=0
captured=()
# package_install 通过平台模块间接调用该测试桩。
# ShellCheck 0.9 使用 SC2317，新版使用 SC2329 标记间接测试桩。
# shellcheck disable=SC2317,SC2329
package_installed() { [[ "$1" == "curl" ]]; }
package_update_index() { updates=$((updates + 1)); }
# apt_run 由平台模块间接调用。
# shellcheck disable=SC2317,SC2329
apt_run() { captured=("$@"); }
# 本测试聚焦 APT 参数分发；安装后版本验证由平台函数独立负责。
# shellcheck disable=SC2317,SC2329
package_verify_candidate() { :; }

package_install curl jq >/dev/null
[[ "$updates" -eq 1 ]] || { printf 'FAIL: 缺失包没有触发一次索引刷新\n' >&2; exit 1; }
[[ "${#captured[@]}" -eq 3 && "${captured[0]}" == "install" && "${captured[1]}" == "-y" && "${captured[2]}" == "jq" ]] || {
  printf 'FAIL: 已安装的包没有被排除\n' >&2
  exit 1
}

updates=0
captured=()
package_install curl >/dev/null
[[ "$updates" -eq 0 && "${#captured[@]}" -eq 0 ]] || {
  printf 'FAIL: 已安装软件仍触发了 APT\n' >&2
  exit 1
}

updates=0
captured=()
package_candidate_version() { printf '2.0.0'; }
# package_install_latest 间接调用该测试桩。
# shellcheck disable=SC2317,SC2329
package_has_update() { [[ "$1" == "curl" ]]; }
# dry-run 只跳过安装后 dpkg 验证；测试桩仍记录 APT 参数。
# shellcheck disable=SC2034
DRY_RUN=1
package_install_latest curl jq >/dev/null
[[ "$updates" -eq 1 && "${#captured[@]}" -eq 4 && "${captured[0]}" == "install" &&
  "${captured[1]}" == "-y" && "${captured[2]}" == "curl" && "${captured[3]}" == "jq" ]] || {
  printf 'FAIL: 最新候选版本安装没有包含缺失或可更新软件\n' >&2
  exit 1
}
# package_verify_candidate 从运行时读取该全局开关。
# shellcheck disable=SC2034
DRY_RUN=0

updates=0
captured=()
# package_upgrade 通过平台模块间接调用这两个测试桩。
# shellcheck disable=SC2317,SC2329
package_installed() { return 0; }
# shellcheck disable=SC2317,SC2329
package_has_update() { return 0; }
package_upgrade jq >/dev/null
[[ "$updates" -eq 1 && "${#captured[@]}" -eq 4 && "${captured[0]}" == "install" && \
   "${captured[1]}" == "--only-upgrade" && "${captured[2]}" == "-y" && "${captured[3]}" == "jq" ]] || {
  printf 'FAIL: 单项软件更新没有使用 only-upgrade\n' >&2
  exit 1
}

installed_state=1
# package_remove 通过平台模块间接调用这两个测试桩。
# shellcheck disable=SC2317,SC2329
package_installed() { [[ "$installed_state" -eq 1 ]]; }
# shellcheck disable=SC2317,SC2329
apt_run() { installed_state=0; }
package_remove jq >/dev/null
[[ "$installed_state" -eq 0 ]] || {
  printf 'FAIL: 软件移除流程没有执行 APT\n' >&2
  exit 1
}
installed_state=1
# shellcheck disable=SC2317,SC2329
apt_run() { :; }
if package_remove jq >/dev/null 2>&1; then
  printf 'FAIL: 软件仍存在时移除流程误报成功\n' >&2
  exit 1
fi

service_exists() { return 1; }
if service_enable_now missing.service >/dev/null 2>&1; then
  printf 'FAIL: 不存在的 systemd 单元被误报为已启用\n' >&2
  exit 1
fi

systemctl() {
  if [[ "$1" == "is-active" ]]; then
    printf 'failed\n'
    return 3
  fi
}
[[ "$(service_state example.service)" == "failed" ]] || {
  printf 'FAIL: 非 active 服务状态被错误拼接\n' >&2
  exit 1
}

printf 'PASS: package\n'
