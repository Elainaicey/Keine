#!/usr/bin/env bash
# Offline fixtures only: no real keys, SSH connections or remote changes.
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
client_test_root="$(mktemp -d)"
trap '[[ "$client_test_root" == /tmp/* ]] && rm -rf -- "$client_test_root"' EXIT
KEINE_STATE_ROOT="$client_test_root/keine-state"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/core/changes.sh"
. "$ROOT_DIR/src/core/configuration.sh"
. "$ROOT_DIR/src/features/security/ssh-client.sh"
CHANGES_ENABLED=1
require_root() { :; }
audit() { :; }
confirm() { :; }
flock() { :; }
security_ssh_root_home() { printf '%s/home' "$client_test_root"; }
mkdir "$client_test_root/home"
# Windows ACLs do not model Unix ownership/mode; exercise permission checks explicitly.
stat() {
  case "$2" in
    %u) printf '%s' "${test_owner:-0}" ;;
    %a) printf '%s' "${test_mode:-600}" ;;
    *) command stat "$@" ;;
  esac
}
ssh() { printf '%s\n' "$@" >"$client_test_root/ssh-args"; return "${test_ssh_status:-0}"; }
ssh-keygen() {
  [[ "$*" != *'-N'* ]] || die '不应在命令行传入口令'
  local path=''
  while (( $# > 0 )); do if [[ "$1" == -f ]]; then path="$2"; break; fi; shift; done
  [[ -n "$path" ]] || return 1
  printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' 'synthetic-test-fixture-not-a-private-key' >"$path"
  [[ "${test_keygen_fail:-0}" == 0 ]] || return 1
  printf '%s\n' 'ssh-ed25519 synthetic-public-fixture' >"$path.pub"
}
declare -A SSH_CLIENT=([host]=192.0.2.1 [port]=22 [user]=ubuntu [key]=none)
DRY_RUN=1
ssh_client_save first absent >/dev/null
ssh_client_key_create first >/dev/null
[[ ! -e "$(ssh_client_root)" ]] || die '预览写入磁盘'
DRY_RUN=0
saved_state_root="$STATE_ROOT"
STATE_ROOT="$(ssh_client_root)"
if ssh_client_ready >/dev/null 2>&1; then die '允许私钥进入项目清理范围'; fi
[[ ! -e "$(ssh_client_root)" ]] || die '拒绝重叠目录前发生写入'
STATE_ROOT="$saved_state_root"
ssh_client_save first absent >/dev/null
ssh_client_load first || die '保存后无法读取'
[[ "${SSH_CLIENT[user]}" == ubuntu ]] || die '远端账户丢失'
ssh_client_connect first >/dev/null
for arg in 'StrictHostKeyChecking=ask' 'ForwardAgent=no' 'PermitLocalCommand=no' 'PubkeyAuthentication=no' 'ubuntu' '192.0.2.1'; do
  grep -Fxq -- "$arg" "$client_test_root/ssh-args" || die "缺少连接约束：$arg"
done
for target in '-oProxyCommand=evil' 'host;touch /tmp/unsafe' 'user@host'; do
  SSH_CLIENT[host]="$target"
  if ssh_client_values_valid; then die '接受了可注入目标'; fi
done
ssh_client_load first
SSH_CLIENT[port]=70000
if ssh_client_values_valid; then die '接受无效端口'; fi
ssh_client_key_create dedicated >/dev/null
key_path="$(ssh_client_root)/keys/dedicated/key"
ssh_client_key_valid "$key_path" || die '不识别专用私钥格式'
test_mode=644
if ssh_client_key_valid "$key_path"; then die '接受了其他用户可读私钥'; fi
unset test_mode
test_owner=1000
if ssh_client_safe "$key_path"; then die '接受非 root 所有的出站文件'; fi
unset test_owner
ssh_client_load first
SSH_CLIENT[key]="$key_path"
profile_path="$(ssh_client_root)/profiles/first.conf"
ssh_client_save first "$(changes_fingerprint "$profile_path")" >/dev/null
ssh_client_connect first >/dev/null
grep -Fxq 'PreferredAuthentications=publickey' "$client_test_root/ssh-args" || die '未隔离密钥认证'
grep -Fxq "$key_path" "$client_test_root/ssh-args" || die '没有使用指定密钥'
if ssh_client_key_delete dedicated >/dev/null 2>&1; then die '删除仍被引用的密钥'; fi
[[ -f "$key_path" ]] || die '引用保护丢失密钥'
# Failed SSH must be reported, never labelled as successful authentication.
test_ssh_status=255
if ssh_client_connect first >/dev/null 2>&1; then die '忽略连接失败'; fi
unset test_ssh_status
# External profile changes cannot be overwritten or deleted.
printf '# external\n' >>"$profile_path"
SSH_CLIENT[host]=198.51.100.5
if ssh_client_save first "$(changes_fingerprint "$profile_path")" >/dev/null 2>&1; then die '覆盖外部修改'; fi
if ssh_client_delete first >/dev/null 2>&1; then die '删除外部修改'; fi
sed -i '/^# external$/d' "$profile_path"
ssh_client_delete first >/dev/null
[[ ! -e "$profile_path" && -f "$key_path" ]] || die '删除连接影响密钥'
printf 'external\n' >>"$key_path"
if ssh_client_key_delete dedicated >/dev/null 2>&1; then die '删除外部修改密钥'; fi
sed -i '/^external$/d' "$key_path"
# An externally edited alias path must not bypass the reference guard.
printf '# Managed by keine\nhost=192.0.2.1\nport=22\nuser=root\nkey=%s/../dedicated/key\n' "${key_path%/key}" >"$(ssh_client_root)/profiles/alias.conf"
if ssh_client_key_delete dedicated >/dev/null 2>&1; then die '路径别名绕过密钥引用保护'; fi
rm -- "$(ssh_client_root)/profiles/alias.conf"
ssh_client_key_delete dedicated >/dev/null
[[ ! -e "$key_path" ]] || die '未删除未引用的密钥'
test_keygen_fail=1
if ssh_client_key_create failed >/dev/null 2>&1; then die '忽略密钥生成失败'; fi
[[ ! -e "$(ssh_client_root)/keys/failed" ]] || die '生成失败留下完整密钥目录'
[[ -z "$(find "$(ssh_client_root)/keys" -name '.pending.*' -print)" ]] || die '遗留密钥暂存副本'
[[ -z "$(find "$STATE_ROOT" -name key -print)" ]] || die '私钥进入常规状态目录'
printf 'PASS: ssh_client\n'
