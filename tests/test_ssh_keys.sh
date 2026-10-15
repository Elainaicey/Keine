#!/usr/bin/env bash
# 公钥解析使用本机 ssh-keygen；SSHD/systemd 使用替身，不生成私钥或访问真实 root 文件。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
key_test_root="$(mktemp -d)"
trap '[[ "$key_test_root" == /tmp/* ]] && rm -rf -- "$key_test_root"' EXIT
KEINE_STATE_ROOT="$key_test_root/keine-state"
KEINE_BACKUP_ROOT="$key_test_root/keine-backups"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/core/changes.sh"
. "$ROOT_DIR/src/core/configuration.sh"
. "$ROOT_DIR/src/features/security.sh"
CHANGES_ENABLED=1
require_root() { :; }
audit() { :; }
confirm() { return 0; }
security_ssh_root_home() { printf '%s' "$key_test_root/root"; }
umask 077
mkdir "$key_test_root/root"
ssh_test_settings=$'authorizedkeysfile .ssh/authorized_keys .ssh/authorized_keys2\npubkeyauthentication yes\nauthenticationmethods any'
security_ssh_context_values() { printf '%s\n' "$ssh_test_settings"; }
# CI 以非 root 运行，所有者通过替身模拟；Linux 使用真实权限和链接。
stat() {
  if [[ "$2" == '%u' ]]; then printf '%s' "${test_uid:-0}"; return; fi
  if [[ "$(uname -s)" == MINGW* ]]; then
    case "$2" in '%a') printf '%s' "${test_mode:-600}"; return ;; esac
  fi
  command stat "$@"
}
key1='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB fixture-one'
key2='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC fixture-two'
security_ssh_key_plain_valid "$key1" || die '有效公钥未通过原生解析'
for invalid in '-----BEGIN OPENSSH PRIVATE KEY-----' 'ssh-ed25519 invalid' "no-pty $key1" "$key1"$'\n'"$key2" "$key1"$'\e[31m'; do
  if security_ssh_key_plain_valid "$invalid"; then die '接收了私钥/无效公钥/选项/多行/控制字符'; fi
done
for source in '' 192.0.2.1 192.0.2.0/24 2001:db8::/32; do security_ssh_key_sources_valid "$source" || die '来源验证错误'; done
for source in any '192.0.2.1",command="reboot' 'host.example' '::/129'; do
  if security_ssh_key_sources_valid "$source"; then die '接收不安全来源'; fi
done
security_ssh_key_path_active "$ssh_test_settings" || die '标准路径识别失败'
security_ssh_key_path_active 'authorizedkeysfile %h/.ssh/authorized_keys' || die '%h 解析失败'
if security_ssh_key_path_active 'authorizedkeysfile /custom/root'; then die '错误接管自定义路径'; fi

path="$(security_ssh_key_path)"
DRY_RUN=1
security_ssh_key_write "$key1" absent >/dev/null
[[ ! -e "$path" && ! -e "$STATE_ROOT" ]] || die '预览产生文件'
DRY_RUN=0
security_ssh_key_write "$key1" absent >/dev/null
[[ "$(cat "$path")" == "$key1" ]] || die '首把公钥未写入'
security_root_public_key_exists || die '未识别启用公钥'
before="$(changes_fingerprint "$path")"
original="$key1"

# 最后一把公钥停用与删除都必须拒绝。
read_input() { printf '1'; }
ui_read_choice() { printf -v "$1" '%s' "$test_choice"; }
for test_choice in 1 2; do
  if security_ssh_keys_change >/dev/null 2>&1; then die '移除了最后一把公钥'; fi
  [[ "$(changes_fingerprint "$path")" == "$before" ]] || die '拒绝操作仍修改文件'
done
payload="$key1"$'\n'"from=\"192.0.2.0/24\",no-port-forwarding $key2"
security_ssh_key_write "$payload" "$before" >/dev/null
test_choice=1
security_ssh_keys_change >/dev/null
grep -Fxq "# keine-disabled $key1" "$path" || die '公钥未停用'
grep -Fxq "from=\"192.0.2.0/24\",no-port-forwarding $key2" "$path" || die '破坏了其他公钥限制'
security_ssh_keys_change >/dev/null
grep -Fxq "$key1" "$path" || die '公钥未启用'
test_choice=2
security_ssh_keys_change >/dev/null
[[ "$(security_ssh_key_rows | wc -l)" -eq 1 ]] || die '删除数量错误'

# 摘要不匹配/首次基线后的外部修改都停止；既有文件需要明确接管。
before="$(changes_fingerprint "$path")"
printf '# external\n' >>"$path"
if security_ssh_key_write "$key1" "$before" >/dev/null 2>&1; then die '覆盖了等待输入期间的修改'; fi
if security_ssh_key_write "$key1" "$(changes_fingerprint "$path")" >/dev/null 2>&1; then die '覆盖了外部修改'; fi
sed -i '/^# external$/d' "$path"

# 验证失败恢复本次状态，并保留首次基线。
before="$(changes_fingerprint "$path")"
security_ssh_key_verify() { return 1; }
if security_ssh_key_write "$key1" "$before" >/dev/null 2>&1; then die '忽略验证失败'; fi
[[ "$(changes_fingerprint "$path")" == "$before" ]] || die '验证失败没有回退'
security_ssh_key_verify() { printf '# concurrent\n' >>"$(security_ssh_key_path)"; return 1; }
if security_ssh_key_write "$key1" "$before" >/dev/null 2>&1; then die '忽略事务中外部修改'; fi
grep -Fxq '# concurrent' "$path" || die '回退覆盖了外部修改'
entry="$(changes_file_entry "$path")"
[[ "$(changes_file_status "$entry")" == conflict ]] || die '并发修改没有留下冲突'
sed -i '/^# concurrent$/d' "$path"
config_file_restore "$path" config_no_reload >/dev/null
[[ ! -e "$path" ]] || die '新文件基线未撤销'

printf '%s\n' "$key2" >"$path"; chmod 0600 "$path"
confirm() { return 1; }
if security_ssh_key_write "$key1" "$(changes_fingerprint "$path")" >/dev/null 2>&1; then die '未经选择接管外部文件'; fi
[[ "$(cat "$path")" == "$key2" ]] || die '取消仍修改外部文件'
confirm() { return 0; }
security_ssh_key_verify() { return 0; }
security_ssh_key_write "$key1" "$(changes_fingerprint "$path")" >/dev/null
config_file_restore "$path" config_no_reload >/dev/null
[[ "$(cat "$path")" == "$key2" ]] || die '已有文件基线未恢复'

test_mode=666
chmod 0666 "$path"
if security_ssh_key_safe; then die '接受组/其他用户可写的公钥路径'; fi
test_mode=600
chmod 0600 "$path"
ssh_test_import="$key_test_root/new.pub"
printf '%s\n' "$key1" >"$ssh_test_import"
read_input() {
  case "$1" in
    公钥文件绝对路径*) printf '%s' "$ssh_test_import" ;;
    允许来源*) printf '%s' '192.0.2.0/24' ;;
    *) printf '%s' "$key1" ;;
  esac
}
test_choice=2
security_ssh_keys_add >/dev/null
grep -Fxq "from=\"192.0.2.0/24\",no-port-forwarding,no-agent-forwarding,no-X11-forwarding $key1" "$path" || die '导入公钥或限制未写入'
test_choice=1
if security_ssh_keys_add >/dev/null 2>&1; then die '接收了重复公钥'; fi
config_file_restore "$path" config_no_reload >/dev/null
ssh_test_settings='authorizedkeysfile /custom/keys'
if security_ssh_key_write "$key1" "$(changes_fingerprint "$path")" >/dev/null 2>&1; then die '写入未启用的标准路径'; fi
test_uid=1001
if security_ssh_key_safe; then die '接受非 root 所有的公钥文件'; fi
test_uid=0
if [[ "$(uname -s)" != MINGW* ]]; then
  mv -- "$path" "$key_test_root/saved.pub"
  ln -s "$key_test_root/saved.pub" "$path"
  if security_ssh_key_safe; then die '接受公钥符号链接'; fi
  rm -- "$path"
  ln "$key_test_root/saved.pub" "$path"
  if security_ssh_key_safe; then die '接受公钥硬链接'; fi
  rm -- "$path"
  mv -- "$key_test_root/saved.pub" "$path"
fi
flock() { return 1; }
if security_ssh_keys_locked add >/dev/null 2>&1; then die '忽略公钥互斥锁失败'; fi

# 不伪装自定义组合认证为密码或公钥二选一。
ssh_test_settings=$'authorizedkeysfile .ssh/authorized_keys\nauthenticationmethods publickey,password'
test_choice=1
security_ssh_write_settings() { die '覆盖了 MFA 策略'; }
if security_ssh_auth_profile >/dev/null 2>&1; then die '未阻止 MFA 覆盖'; fi
events="$(security_auth_event_rows <<'EOF'
sshd[1]: Failed publickey for root from 192.0.2.1 port 1234 ssh2
sshd[2]: Failed keyboard-interactive/pam for invalid user guest from 2001:db8::1 port 1234 ssh2
sshd[3]: Unknown disconnect from 192.0.2.1
EOF
)"
[[ "$(grep -c '^failed|' <<<"$events")" == 2 ]] || die '新认证日志分类错误'
printf 'PASS: SSH keys, conflict protection, rollback and login policy\n'
