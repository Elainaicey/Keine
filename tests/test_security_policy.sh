#!/usr/bin/env bash
# 离线配置事务夹具；不调用真实 SSH、systemd 或 Fail2ban。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
policy_test_root="$(mktemp -d)"
trap '[[ "$policy_test_root" == /tmp/* ]] && rm -rf -- "$policy_test_root"' EXIT
KEINE_STATE_ROOT="$policy_test_root/keine-state"
KEINE_BACKUP_ROOT="$policy_test_root/keine-backups"
KEINE_SSH_MAIN="$policy_test_root/sshd_config"
KEINE_SSH_POLICY="$policy_test_root/00-keine-policy.conf"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/core/changes.sh"
. "$ROOT_DIR/src/core/backup.sh"
. "$ROOT_DIR/src/core/configuration.sh"
. "$ROOT_DIR/src/features/security.sh"
CHANGES_ENABLED=1
require_root() { :; }
getent() { [[ "$1" == passwd && "${2:-root}" == root ]] && printf 'root:x:0:0:root:/root:/bin/bash\n'; }
service_exists() { [[ "$1" == ssh.service ]]; }
systemctl() { [[ "$1" == reload || "$1" == is-active ]]; }
run() { "$@"; }
effective_mismatch=0
pubkey_mismatch=0
sshd() {
  case "$1" in
    -t) return 0 ;;
    -T)
      awk '!/^#/ && NF {print tolower($1),$2}' "$SECURITY_SSH_POLICY"
      (( effective_mismatch == 0 )) || printf 'maxauthtries 9\n'
      (( pubkey_mismatch == 0 )) || printf 'pubkeyauthentication no\n'
      return 0 ;;
    *) return 1 ;;
  esac
}
original=$'# Managed by keine\nPasswordAuthentication no\nPort 2222'
printf 'Include /etc/ssh/sshd_config.d/*.conf\n' >"$SECURITY_SSH_MAIN"
printf '%s\n' "$original" >"$SECURITY_SSH_POLICY"
security_ssh_write_settings "$SECURITY_SSH_POLICY" 'MaxAuthTries 3' >/dev/null
grep -Fxq 'PasswordAuthentication no' "$SECURITY_SSH_POLICY" || die 'SSH 策略修改丢失认证设置'
grep -Fxq 'Port 2222' "$SECURITY_SSH_POLICY" || die 'SSH 策略修改丢失端口'
grep -Fxq 'MaxAuthTries 3' "$SECURITY_SSH_POLICY" || die 'SSH 参数未写入'
effective_mismatch=1
if security_ssh_write_settings "$SECURITY_SSH_POLICY" 'MaxAuthTries 5' >/dev/null 2>&1; then die '未发现 SSH 有效配置冲突'; fi
grep -Fxq 'MaxAuthTries 3' "$SECURITY_SSH_POLICY" || die 'SSH 验证失败未恢复操作前状态'
effective_mismatch=0
printf '# external change\n' >>"$SECURITY_SSH_POLICY"
if security_ssh_write_settings "$SECURITY_SSH_POLICY" 'MaxAuthTries 4' >/dev/null 2>&1; then die '覆盖了外部 SSH 修改'; fi
sed -i '/^# external change$/d' "$SECURITY_SSH_POLICY"
config_file_restore "$SECURITY_SSH_POLICY" security_ssh_reload_only >/dev/null
[[ "$(cat "$SECURITY_SSH_POLICY")" == "$original" ]] || die '初始 SSH 配置未恢复'

# Reject scoped directives even with a project marker and no previous ownership record.
for scoped in 'Match User guest' 'Include /etc/ssh/custom.conf'; do
  printf '# Managed by keine\n%s\nPasswordAuthentication yes\n' "$scoped" >"$SECURITY_SSH_POLICY"
  before_scoped="$(cat "$SECURITY_SSH_POLICY")"
  if security_ssh_write_settings "$SECURITY_SSH_POLICY" 'MaxAuthTries 4' >/dev/null 2>&1; then die '合并了含作用域指令的文件'; fi
  [[ "$(cat "$SECURITY_SSH_POLICY")" == "$before_scoped" ]] || die '作用域拒绝仍改写文件'
done
printf '%s\n' "$original" >"$SECURITY_SSH_POLICY"
# A main-file rollback must restore this operation, not the first historical baseline.
printf 'Port 2200\n' >"$SECURITY_SSH_MAIN"
config_file_write "$SECURITY_SSH_MAIN" 0644 'Port 2222' config_no_reload >/dev/null
main_before="$(cat "$SECURITY_SSH_MAIN")"
effective_mismatch=1
if security_ssh_write_settings "$SECURITY_SSH_POLICY" 'MaxAuthTries 5' >/dev/null 2>&1; then die '未识别失败应用'; fi
[[ "$(cat "$SECURITY_SSH_MAIN")" == "$main_before" ]] || die '回退到了历史基线而非本次修改前'
effective_mismatch=0
config_file_restore "$SECURITY_SSH_POLICY" config_no_reload >/dev/null
config_file_restore "$SECURITY_SSH_MAIN" config_no_reload >/dev/null
printf 'Include /etc/ssh/sshd_config.d/*.conf\n' >"$SECURITY_SSH_MAIN"

# 复用真实配置事务，只切换公钥认证；Match 冲突与 reload 失败必须恢复原文件。
SECURITY_SSH_AUTH="$SECURITY_SSH_POLICY"
auth_original=$'# Managed by keine\nPubkeyAuthentication no\nPasswordAuthentication yes\nPermitRootLogin prohibit-password\nAuthenticationMethods publickey,password\nPort 2222'
printf '%s\n' "$auth_original" >"$SECURITY_SSH_AUTH"
DRY_RUN=1
security_ssh_key_enable_auth >/dev/null
[[ "$(cat "$SECURITY_SSH_AUTH")" == "$auth_original" && ! -d "$(changes_file_entry "$SECURITY_SSH_AUTH")" ]] || die '预览改写认证或基线'
DRY_RUN=0
security_ssh_key_enable_auth >/dev/null
grep -Fxq 'PubkeyAuthentication yes' "$SECURITY_SSH_AUTH" || die '公钥认证未开启'
for preserved in 'PasswordAuthentication yes' 'PermitRootLogin prohibit-password' 'AuthenticationMethods publickey,password' 'Port 2222'; do
  grep -Fxq "$preserved" "$SECURITY_SSH_AUTH" || die '开启公钥认证改变了其他设置'
done
config_file_restore "$SECURITY_SSH_AUTH" security_ssh_reload_only >/dev/null
pubkey_mismatch=1
if security_ssh_key_enable_auth >/dev/null 2>&1; then die '未识别公钥认证有效值冲突'; fi
[[ "$(cat "$SECURITY_SSH_AUTH")" == "$auth_original" ]] || die '有效值冲突未恢复认证配置'
pubkey_mismatch=0
systemctl() { [[ "$1" == is-active ]]; }
if security_ssh_key_enable_auth >/dev/null 2>&1; then die '忽略公钥认证 reload 失败'; fi
[[ "$(cat "$SECURITY_SSH_AUTH")" == "$auth_original" ]] || die 'reload 失败未回退认证配置'
systemctl() { [[ "$1" == reload || "$1" == is-active ]]; }

SSH_CONNECTION='192.0.2.10 49152 198.51.100.10 22'
SECURITY_F2B_BANTIME=3600
SECURITY_F2B_FINDTIME=600
SECURITY_F2B_MAXRETRY=5
whitelist_present=1
fail2ban-client() {
  case "$*" in
    -t|reload|ping) return 0 ;;
    $'get\nsshd\nbantime') printf '3600' ;;
    $'get\nsshd\nfindtime') printf '600' ;;
    $'get\nsshd\nmaxretry') printf '5' ;;
    $'get\nsshd\nignoreip')
      printf 'These IP addresses/networks are ignored:\n|- 127.0.0.0/8\n'
      (( whitelist_present == 0 )) || printf '`- 192.0.2.10\n'
      return 0 ;;
    *) return 1 ;;
  esac
}
security_fail2ban_policy_verify >/dev/null || die '合法 Fail2ban 运行值未通过'
whitelist_present=0
if security_fail2ban_policy_verify >/dev/null 2>&1; then die 'Fail2ban 未验证当前 SSH 来源白名单'; fi
printf 'PASS: security policy transactions\n'
