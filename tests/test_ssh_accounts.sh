#!/usr/bin/env bash
# 离线账户、权限和服务夹具；只在临时目录写公钥，不生成私钥。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
account_test_root="$(mktemp -d)"
trap '[[ "$account_test_root" == /tmp/* ]] && rm -rf -- "$account_test_root"' EXIT
KEINE_STATE_ROOT="$account_test_root/keine-state"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/core/changes.sh"
. "$ROOT_DIR/src/core/configuration.sh"
. "$ROOT_DIR/src/features/security.sh"
. "$ROOT_DIR/src/features/recovery.sh"
CHANGES_ENABLED=1
require_root() { :; }
audit() { :; }
flock() { return 0; }
confirm() { return 0; }
getent() {
  [[ "$1" == passwd ]] || return 1
  local records
  records="$(printf 'root:x:0:0:root:%s/root:/bin/bash\nazureuser:x:1001:1002:Azure:%s/azure:/bin/bash\nservice:x:1003:1003:Service:%s/service:/usr/sbin/nologin\nalias:x:0:0:Alias:%s/root:/bin/bash\n' "$account_test_root" "$account_test_root" "$account_test_root" "$account_test_root")"
  if [[ $# == 1 ]]; then printf '%s\n' "$records"
  else awk -F: -v user="$2" '$1==user {print;found=1} END{exit !found}' <<<"$records"; fi
}
umask 077
mkdir "$account_test_root/root" "$account_test_root/azure"
stat() {
  case "$2" in
    %u)
      if [[ "${test_root_file:-0}" == 1 && "${*: -1}" == */authorized_keys ]]; then printf 0
      else printf '%s' "${test_owner:-1001}"; fi ;;
    %a)
      if [[ "$(uname -s)" == MINGW* ]]; then
        if [[ -d "${*: -1}" ]]; then printf '%s' "${test_directory_mode:-700}"; else printf '%s' "${test_mode:-600}"; fi
      else command stat "$@"; fi ;;
    *) command stat "$@" ;;
  esac
}
chown() { printf '%s\n' "$*" >>"$account_test_root/owners"; test_root_file=0; }
key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB azure-key'
SECURITY_SSH_USER=azureuser
[[ "$(security_ssh_account_uid)" == 1001 && "$(security_ssh_account_gid)" == 1002 ]] || die '目标 UID/GID 错误'
for invalid in service alias unknown 'root,addr=1.2.3.4' '../root'; do
  if security_ssh_account_record "$invalid" >/dev/null; then die '接收无效或不可登录账户'; fi
done
sshd() { printf '%s\n' "$*" >"$account_test_root/context"; printf 'authorizedkeysfile .ssh/authorized_keys\npubkeyauthentication yes\nauthenticationmethods any\npermitrootlogin no\n'; }
SSH_CONNECTION='192.0.2.5 34567 198.51.100.5 22'
security_ssh_context_values >/dev/null
grep -Fq 'user=azureuser,host=192.0.2.5,addr=192.0.2.5' "$account_test_root/context" || die '未使用目标账户 Match 上下文'
path="$(security_ssh_key_path)"
[[ "$path" == "$account_test_root/azure/.ssh/authorized_keys" ]] || die '普通账户路径错误'
DRY_RUN=1
security_ssh_key_write "$key" absent >/dev/null
[[ ! -e "$path" && ! -e "$STATE_ROOT" ]] || die '账户预览产生文件'
DRY_RUN=0
security_ssh_key_write "$key" absent >/dev/null
[[ "$(cat "$path")" == "$key" && ! -e "$account_test_root/root/.ssh/authorized_keys" ]] || die '写入影响其他账户'
[[ "$(grep -c '1001:1002' "$account_test_root/owners")" == 2 ]] || die '新目录或公钥没有设置目标所有权'
security_ssh_public_key_exists || die '没有识别普通账户公钥'
SECURITY_SSH_ACCOUNT_SNAPSHOT='changed-account-record'
if security_ssh_key_safe; then die '未拒绝操作期间变化的账户记录'; fi
unset SECURITY_SSH_ACCOUNT_SNAPSHOT
test_owner=1005
if security_ssh_key_safe; then die '接受其他普通用户所有的路径'; fi
test_owner=0
if security_ssh_key_safe; then die '把 root 私有目录当作普通账户可访问目录'; fi
test_owner=1001
test_root_file=1
security_ssh_key_safe || die '拒绝可接管的 root 公钥文件'
security_ssh_key_write "$key" "$(changes_fingerprint "$path")" >/dev/null
[[ "$(grep -c '1001:1002' "$account_test_root/owners")" == 3 ]] || die '已有 root 公钥文件未转为目标账户所有'
test_root_file=0
chmod 0600 "$account_test_root/azure/.ssh"
test_directory_mode=600
if security_ssh_key_safe; then die '接受目标账户不能遍历的目录'; fi
chmod 0700 "$account_test_root/azure/.ssh"
unset test_directory_mode
if [[ "$(uname -s)" != MINGW* ]]; then
  chmod 0777 "$account_test_root/azure/.ssh"
  if security_ssh_key_safe; then die '接受可被其他用户写入的目录'; fi
  chmod 0700 "$account_test_root/azure/.ssh"
fi

# 恢复从路径定位账户；当前菜单选 root 也必须调用普通账户的保护流程。
entry="$(changes_file_entry "$path")"
[[ "$(security_ssh_account_for_key_path "$path")" == azureuser ]] || die '恢复账户识别失败'
SECURITY_SSH_USER=root
recovery_restore_file "$entry" >/dev/null
[[ ! -e "$path" && "$SECURITY_SSH_USER" == root ]] || die '恢复未隔离账户或污染当前选择'

# 普通账户切换登录方式不改变 PermitRootLogin；确认必须明确服务器级影响。
SECURITY_SSH_USER=azureuser
security_ssh_public_key_exists() { return 0; }
passwd() { [[ "$1 $2" == '-S azureuser' ]] || return 1; printf 'azureuser P\n'; }
security_ssh_write_settings() { printf '%s\n' "$2" >"$account_test_root/auth"; }
ui_read_choice() { printf -v "$1" '%s' "$profile"; }
for profile in 1 2; do
  output="$(security_ssh_auth_profile)"
  grep -q '服务器级' <<<"$output" || die '未说明认证影响范围'
  if grep -q PermitRootLogin "$account_test_root/auth"; then die '普通账户设置改变 root 登录权限'; fi
done
printf 'PASS: SSH account selection, ownership, recovery and authentication scope\n'
