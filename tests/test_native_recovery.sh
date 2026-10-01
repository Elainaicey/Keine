#!/usr/bin/env bash
# 离线夹具和共享状态由被加载模块使用；不执行主机写操作。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
test_root="$(mktemp -d)"
trap '[[ "$test_root" == /tmp/* ]] && rm -rf -- "$test_root"' EXIT
KEINE_STATE_ROOT="$test_root/keine-state"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/core/changes.sh"
CHANGES_ENABLED=1

path="$test_root/original.conf"
printf 'original\n' >"$path"
changes_prepare_file "$path"
printf 'modified\n' >"$path"
changes_commit_pending
entry="$(changes_file_entry "$path")"
[[ "$(changes_file_status "$entry")" == ready ]] || die "未识别项目修改"
printf 'external\n' >"$path"
[[ "$(changes_file_status "$entry")" == conflict ]] || die "未识别外部修改"
if changes_restore_file "$entry" >/dev/null 2>&1; then die "错误覆盖外部修改"; fi
[[ "$(<"$path")" == external ]] || die "冲突内容被破坏"
printf 'modified\n' >"$path"
changes_restore_file "$entry"
[[ "$(<"$path")" == original && ! -e "$entry" ]] || die "初始文件未还原"

path="$test_root/new.conf"
changes_prepare_file "$path"
printf 'new\n' >"$path"
changes_commit_pending
changes_restore_file "$(changes_file_entry "$path")"
[[ ! -e "$path" ]] || die "项目新增文件未删除"

directory="$test_root/new-directory"
changes_prepare_file "$directory" directory
mkdir -p "$directory/sub"
changes_prepare_file "$directory/sub/config"
printf 'config\n' >"$directory/sub/config"
changes_commit_pending
[[ ! -d "$(changes_file_entry "$directory/sub/config")" ]] || die "父子资源重复登记"
changes_restore_file "$(changes_file_entry "$directory")"
[[ ! -e "$directory" ]] || die "项目新增目录未撤销"
if changes_prepare_file /etc >/dev/null 2>&1; then die "接受了系统顶层目录"; fi
if changes_prepare_file "$STATE_ROOT/state" >/dev/null 2>&1; then die "登记了项目状态目录"; fi

DRY_RUN=1
changes_prepare_file "$test_root/preview"
[[ ! -d "$(changes_file_entry "$test_root/preview")" ]] || die "预览生成了变更记录"
DRY_RUN=0

inventory_after=$'base|2\nadded|1'
changes_package_inventory() { printf '%s\n' "$inventory_after"; }
printf 'base|1\n' >"$test_root/packages-before"
changes_packages_record_new "$test_root/packages-before"
[[ ! -e "$(changes_root)/packages/base" && "$(<"$(changes_root)/packages/added")" == 1 ]] || die "把原有包升级当成项目新增"
printf 'base|2\nadded|1\n' >"$test_root/packages-before"
inventory_after=$'base|2\nadded|2'
changes_packages_record_new "$test_root/packages-before"
[[ "$(<"$(changes_root)/packages/added")" == 2 ]] || die "项目更新没有同步新增包版本"
package_installed() { [[ "$1" == added ]]; }
package_installed_version() { printf 2; }
apt_mock_removal=added
apt-get() { printf 'Purg %s [2]\n' "$apt_mock_removal"; }
changes_packages_plan
apt_mock_removal=base
if changes_packages_plan >/dev/null 2>&1; then die "撤销计划会删除原有包却未阻止"; fi

. "$ROOT_DIR/src/integrations/warp.sh"
KEINE_WIREGUARD_DIR="$test_root/wireguard"
mkdir -p "$KEINE_WIREGUARD_DIR"
printf '[Peer]\nEndpoint = engage.cloudflareclient.com:2408\n' >"$KEINE_WIREGUARD_DIR/cloudflare.conf"
printf '[Peer]\nEndpoint = example.com:51820\n' >"$KEINE_WIREGUARD_DIR/private.conf"
[[ "$(warp_wireguard_profiles)" == cloudflare ]] || die "WARP 原生配置识别错误"
warp_cli_state=Disconnected
warp-cli() { printf 'Status update: %s\n' "$warp_cli_state"; }
runtime_with_timeout() { shift; "$@"; }
[[ "$(warp_connection_value)" == disconnected ]] || die "断开状态解析错误"
warp_cli_state=Connected
[[ "$(warp_connection_value)" == connected ]] || die "连接状态解析错误"
warp_cli_state=Connecting
if warp_connection_value; then die "异步连接误报为成功"; fi

. "$ROOT_DIR/src/core/navigation.sh"
if navigation_dispatch 'echo injected' >/dev/null 2>&1; then die "执行了未注册菜单动作"; fi
[[ "$(awk -F '|' '!/^#/ && NF==6 {total++} END {print total}' "$ROOT_DIR/config/navigation.tsv")" == 10 ]] || die "导航注册不完整"
printf 'PASS: native integration and recovery\n'
