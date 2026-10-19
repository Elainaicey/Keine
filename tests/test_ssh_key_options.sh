#!/usr/bin/env bash
# 测试原生选项保留和菜单修改事务，不创建私钥或修改真实账户。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/features/security.sh"
key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB workstation'
# 单独使用包含转义引号、空格与逗号的原生选项。
extras='command="echo a,b \"quoted\"",no-pty,expiry-time="20301231"'
line="from=\"192.0.2.1\",$extras,no-agent-forwarding $key"
updated="$(security_ssh_key_option_update "$line" from '192.0.2.0/24,2001:db8::/32')"
[[ "$updated" == "$extras,no-agent-forwarding,from=\"192.0.2.0/24,2001:db8::/32\" $key" ]] || die '修改来源破坏原生选项'
security_ssh_key_details "$updated" || die '无法解析选项'
[[ "$SSH_KEY_SOURCE" == '192.0.2.0/24,2001:db8::/32' && "$SSH_KEY_COMMENT" == workstation && "$SSH_KEY_AGENT" == '禁止*' ]] || die '详情识别错误'
updated="$(security_ssh_key_option_update "$updated" from '')"
[[ "$updated" == "$extras,no-agent-forwarding $key" ]] || die '解除来源破坏其他选项'
updated="$(security_ssh_key_option_update "$updated" no-agent-forwarding no)"
[[ "$updated" == "$extras $key" ]] || die '解除 Agent 限制错误'
updated="$(security_ssh_key_option_update "$key" no-port-forwarding yes)"
[[ "$updated" == "no-port-forwarding $key" ]] || die '添加 TCP 限制错误'
updated="$(security_ssh_key_option_update "$updated" no-x11-forwarding yes)"
[[ "$updated" == "no-port-forwarding,no-x11-forwarding $key" ]] || die '独立 X11 限制错误'
updated="$(security_ssh_key_option_update "# keine-disabled $line" comment '备用 VPS')"
[[ "$updated" == "# keine-disabled from=\"192.0.2.1\",$extras,no-agent-forwarding ${key% workstation} 备用 VPS" ]] || die '备注修改改变选项或启停状态'
for source in 'a.example' '1.2.3.4,' ',1.2.3.4' '1.2.3.4,,::1' '1.2.3.4",command="id' '::/129'; do
  if security_ssh_key_option_update "$key" from "$source" >/dev/null 2>&1; then die '接受非法来源'; fi
done
if security_ssh_key_option_update "$key" comment $'bad\ncomment' >/dev/null; then die '备注允许注入新行'; fi
if security_ssh_key_option_update "restrict $key" no-agent-forwarding no >/dev/null 2>&1; then die '错误解除 restrict 限制'; fi
if security_ssh_key_option_update "from=\"::1\",from=\"127.0.0.1\" $key" from '' >/dev/null 2>&1; then die '静默处理重复来源选项'; fi
if security_ssh_key_option_update "command=\"broken $key" from '' >/dev/null 2>&1; then die '接受未闭合选项'; fi
# OpenSSH 只将反斜杠紧接双引号识别为转义，不使用 shell 的双反斜杠规则。
slash_options='command="echo \\"a,b\"",no-pty'
updated="$(security_ssh_key_option_update "$slash_options $key" from '192.0.2.1')"
[[ "$updated" == "$slash_options,from=\"192.0.2.1\" $key" ]] || die '连续反斜杠选项解析与 OpenSSH 不一致'

option_test_root="$(mktemp -d)"
trap '[[ "$option_test_root" == /tmp/* ]] && rm -rf -- "$option_test_root"' EXIT
security_ssh_key_path() { printf '%s/authorized_keys' "$option_test_root"; }
security_ssh_key_write() {
  [[ "$2" == expected && "$3" == 0 && "$4" == 1 ]] || die '编辑未复用摘要确认保护，或错误改变认证'
  printf '%s\n' "$1" >"$option_test_root/result"
}
security_ssh_key_confirm() { return 0; }
audit() { :; }
ui_read_choice() { printf -v "$1" '%s' 1; }
read_input() { printf '%s' '2001:db8::/32'; }
printf '# preserved\n%s\n%s\n' "$line" "$key" >"$(security_ssh_key_path)"
security_ssh_keys_edit 2 expected >/dev/null
[[ "$(sed -n '1p' "$option_test_root/result")" == '# preserved' && "$(sed -n '3p' "$option_test_root/result")" == "$key" ]] || die '编辑改变相邻条目'
[[ "$(sed -n '2p' "$option_test_root/result")" == "$extras,no-agent-forwarding,from=\"2001:db8::/32\" $key" ]] || die '编辑菜单破坏引号和反斜杠'
printf 'PASS: SSH key restrictions, metadata and option preservation\n'
