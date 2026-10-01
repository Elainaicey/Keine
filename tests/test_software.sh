#!/usr/bin/env bash
# Cross-module fixtures and function stubs are consumed after sourcing feature files.
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
SOFTWARE_TEST_ROOT="$(mktemp -d)"
trap '[[ "$SOFTWARE_TEST_ROOT" == /tmp/* ]] && rm -rf -- "$SOFTWARE_TEST_ROOT"' EXIT
SERVER_TOOLKIT_APT_SOURCES_DIR="$SOFTWARE_TEST_ROOT/sources"
SERVER_TOOLKIT_APT_KEYRING_DIR="$SOFTWARE_TEST_ROOT/keyrings"
SERVER_TOOLKIT_SHARE_KEYRING_DIR="$SOFTWARE_TEST_ROOT/share-keyrings"
OS_ID=debian
OS_NAME='Debian test'
OS_CODENAME=bookworm
ARCH=amd64
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/features/software.sh"

# software.sh 与 runtime.sh 在加载后消费这些测试夹具。
DRY_RUN=1
removed=""
confirmations=0
# software_install_docker 通过功能模块间接调用该测试桩。
# ShellCheck 0.9 使用 SC2317，新版使用 SC2329 标记间接测试桩。
package_installed() { [[ "$1" == "containerd" ]]; }
confirm() { confirmations=$((confirmations + 1)); return 0; }
package_remove() { removed="$1"; }
package_install() { :; }
package_install_latest() { :; }
package_invalidate_index() { :; }
package_update_index() { :; }
package_candidate_version() { printf '(none)'; }

software_install_docker >/dev/null 2>&1
[[ "$removed" == "containerd" && "$confirmations" -eq 1 ]] || {
  printf 'FAIL: Docker 冲突包没有经过单独确认和移除\n' >&2
  exit 1
}
[[ "$(software_repository_status docker_official)" == "missing" ]] || {
  printf 'FAIL: Docker 安装前仓库状态不应被误判为不可用\n' >&2
  exit 1
}

events=""
package_installed() { [[ "$1" == "containerd" ]]; }
software_prepare_docker_repository() { events+="prepare "; return 1; }
package_remove() { events+="remove "; }
if software_install_docker >/dev/null 2>&1; then
  printf 'FAIL: Docker 仓库准备失败仍返回成功\n' >&2
  exit 1
fi
[[ "$events" == "prepare " ]] || {
  printf 'FAIL: Docker 仓库失败前改动了现有运行时：%s\n' "$events" >&2
  exit 1
}

package_installed() { [[ "$1" == "docker.io" ]]; }
package_upgrade() { removed="upgrade:$1"; }
software_update_docker >/dev/null
[[ "$removed" == "upgrade:docker.io" ]] || {
  printf 'FAIL: 系统仓库 Docker 没有沿用其现有来源更新\n' >&2
  exit 1
}

printf 'PASS: software\n'
