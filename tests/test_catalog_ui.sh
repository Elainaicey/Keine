#!/usr/bin/env bash
# Cross-module fixtures are consumed by the sourced software and catalog modules.
# shellcheck disable=SC2034
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
# 软件目录模块与 ui.sh 在加载后消费这些测试夹具变量。
SOFTWARE_CATALOG="$CONFIG_DIR/software.tsv"
SERVERCTL_VERSION=0.3.0
NO_COLOR=1
CATALOG_UI_TEST_ROOT="$(mktemp -d)"
trap '[[ "$CATALOG_UI_TEST_ROOT" == /tmp/* ]] && rm -rf -- "$CATALOG_UI_TEST_ROOT"' EXIT
SERVER_TOOLKIT_APT_SOURCES_DIR="$CATALOG_UI_TEST_ROOT/sources"
SERVER_TOOLKIT_APT_KEYRING_DIR="$CATALOG_UI_TEST_ROOT/keyrings"
SERVER_TOOLKIT_SHARE_KEYRING_DIR="$CATALOG_UI_TEST_ROOT/share-keyrings"
OS_ID=debian
OS_NAME='Debian test'
OS_CODENAME=bookworm
ARCH=amd64

. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/features/software.sh"

command_exists() { return 1; }
software_oh_my_zsh_installed() { return 1; }
software_oh_my_zsh_version() { :; }
software_prompt_installed() { return 1; }
software_prompt_version() { :; }
software_release_managed() { return 1; }
software_release_installed() { return 1; }
software_release_integrity() { return 1; }
software_release_supported() { return 0; }
software_release_version() { :; }
software_release_homepage() { printf 'https://example.com'; }
software_release_repository() { printf 'owner/repo'; }
software_release_target() { printf '/usr/local/bin/example'; }
package_installed() { [[ "$1" == "jq" ]]; }
package_installed_version() { if [[ "$1" == "jq" ]]; then printf '1.6-2.1'; fi; }
package_candidate_version() {
  case "$1" in jq) printf '1.7.1-1' ;; docker-ce) printf '(none)' ;; esac
}
package_has_update() { [[ "$1" == "jq" ]]; }
. "$ROOT_DIR/src/features/software/catalog.sh"

output="$(catalog_item_menu jq </dev/null)"
grep -q '软件信息' <<<"$output" || { printf 'FAIL: 软件详情缺少信息面板\n' >&2; exit 1; }
grep -q '当前版本.*1.6-2.1' <<<"$output" || { printf 'FAIL: 软件详情缺少当前版本\n' >&2; exit 1; }
grep -q '目标 / 候选版本.*1.7.1-1' <<<"$output" || { printf 'FAIL: 软件详情缺少候选版本\n' >&2; exit 1; }
grep -q '可更新' <<<"$output" || { printf 'FAIL: 软件详情没有识别更新状态\n' >&2; exit 1; }
grep -q '\[2\].*更新' <<<"$output" || { printf 'FAIL: 软件详情缺少更新操作\n' >&2; exit 1; }

output="$(catalog_item_menu docker </dev/null)"
grep -q '待配置' <<<"$output" || { printf 'FAIL: Docker 安装前没有显示待配置状态\n' >&2; exit 1; }
grep -q '未配置（安装时自动创建）' <<<"$output" || { printf 'FAIL: Docker 仓库缺少自动配置说明\n' >&2; exit 1; }
grep -q '\[1\].*配置仓库并安装' <<<"$output" || { printf 'FAIL: Docker 安装操作被错误禁用\n' >&2; exit 1; }

output="$(catalog_browse_view search jq "软件搜索" "查询结果" </dev/null)"
grep -q '共 1 项 · 第 1/1 页' <<<"$output" || { printf 'FAIL: 搜索结果没有按页显示\n' >&2; exit 1; }
grep -q '\[ 1\].*jq.*可更新' <<<"$output" || { printf 'FAIL: 页内编号与软件状态缺失\n' >&2; exit 1; }

# 回退菜单后点击已安装条目的安装按钮，不得引用已移除的提示符变量。
choice_fixture="$CATALOG_UI_TEST_ROOT/choice"
touch "$choice_fixture"
read_input() { if [[ -f "$choice_fixture" ]]; then rm -f -- "$choice_fixture"; printf 1; else printf 0; fi; }
pause() { :; }
output="$(catalog_item_menu jq 2>&1)"
grep -q '已经安装' <<<"$output" || { printf 'FAIL: 已安装软件操作没有安全回退\n' >&2; exit 1; }

printf 'PASS: catalog ui\n'
