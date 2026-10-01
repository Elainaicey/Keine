#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
# shellcheck source=../src/core/runtime.sh
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/features/services/audit.sh"

[[ "$(read_input "测试输入" "默认值" </dev/null)" == "默认值" ]] || {
  printf 'FAIL: 非交互输入没有正确返回默认值\n' >&2
  exit 1
}

sanitized_text="$(terminal_safe_text $'safe\e[31m\r\ntext')"
if [[ "$sanitized_text" == *[[:cntrl:]]* || "$sanitized_text" != safe\ \[31m*text ]]; then
  printf 'FAIL: 终端控制字符没有被清理\n' >&2
  exit 1
fi

captured_audit=""
audit() { captured_audit="$*"; }
SAFETY_ERROR_FILE="$(mktemp)"
runtime_error 42 9 $'token=super-secret\e[31m' 2>"$SAFETY_ERROR_FILE"
error_output="$(<"$SAFETY_ERROR_FILE")"
rm -f -- "$SAFETY_ERROR_FILE"
[[ "$captured_audit" == 'result=failed status=9 line=42' ]] || {
  printf 'FAIL: 运行时错误审计包含了完整失败命令\n' >&2
  exit 1
}
if [[ "$error_output" == *'super-secret'* || "$error_output" == *[[:cntrl:]]* ]]; then
  printf 'FAIL: 运行时错误向终端泄漏命令参数或控制字符\n' >&2
  exit 1
fi

legacy_audit="$(services_audit_safe_line '2026-08-23 user=root pid=42 result=failed status=1 line=9 command=curl%20token=legacy-secret')"
if [[ "$legacy_audit" == *'legacy-secret'* || "$legacy_audit" != *'command=[redacted]'* ]]; then
  printf 'FAIL: 旧版失败命令审计没有在展示前脱敏\n' >&2
  exit 1
fi

valid_port 22 || { printf 'FAIL: 22 应有效\n' >&2; exit 1; }
valid_port 65535 || { printf 'FAIL: 65535 应有效\n' >&2; exit 1; }
if valid_port 0 || valid_port 65536 || valid_port text; then
  printf 'FAIL: 接受了无效端口\n' >&2
  exit 1
fi

valid_port_range 443 || { printf 'FAIL: 单端口范围被拒绝\n' >&2; exit 1; }
valid_port_range 10000:10100 || { printf 'FAIL: 正常端口范围被拒绝\n' >&2; exit 1; }
if valid_port_range 10100:10000 || valid_port_range 1:70000 || valid_port_range '80-90'; then
  printf 'FAIL: 接受了无效端口范围\n' >&2
  exit 1
fi

valid_firewall_rule_spec 443/tcp || { printf 'FAIL: TCP 防火墙规则被拒绝\n' >&2; exit 1; }
valid_firewall_rule_spec 8443/udp || { printf 'FAIL: UDP 防火墙规则被拒绝\n' >&2; exit 1; }
valid_firewall_rule_spec 10000:10100/udp || { printf 'FAIL: UDP 端口范围被拒绝\n' >&2; exit 1; }
if valid_firewall_rule_spec 443/icmp || valid_firewall_rule_spec 70000/tcp; then
  printf 'FAIL: 接受了无效防火墙规则\n' >&2
  exit 1
fi

valid_firewall_source any || { printf 'FAIL: any 来源被拒绝\n' >&2; exit 1; }
valid_firewall_source 203.0.113.10 || { printf 'FAIL: IPv4 来源被拒绝\n' >&2; exit 1; }
valid_firewall_source 10.0.0.0/8 || { printf 'FAIL: IPv4 CIDR 被拒绝\n' >&2; exit 1; }
valid_firewall_source 2001:db8::/32 || { printf 'FAIL: IPv6 CIDR 被拒绝\n' >&2; exit 1; }
valid_firewall_source ::1 || { printf 'FAIL: IPv6 回环地址被拒绝\n' >&2; exit 1; }
valid_firewall_source 2001:db8:0:1:2:3:4:5 || { printf 'FAIL: 完整 IPv6 地址被拒绝\n' >&2; exit 1; }
if valid_firewall_source 999.0.0.1 || valid_firewall_source 10.0.0.0/33 ||
  valid_firewall_source 1:2:3 || valid_firewall_source 1::2::3 ||
  valid_firewall_source 2001:db8::/129 || valid_firewall_source 'host;reboot'; then
  printf 'FAIL: 接受了无效防火墙来源\n' >&2
  exit 1
fi

safe_managed_path /opt/keine || { printf 'FAIL: 正常路径被拒绝\n' >&2; exit 1; }
if safe_managed_path / || safe_managed_path /opt || safe_managed_path /var/ ||
  safe_managed_path /var// || safe_managed_path /var//log ||
  safe_managed_path /var/../etc || safe_managed_path $'/var/log\n/unsafe'; then
  printf 'FAIL: 接受了危险路径\n' >&2
  exit 1
fi
safe_toolkit_path /var/lib/keine/software-releases || {
  printf 'FAIL: 正常项目数据路径被拒绝\n' >&2
  exit 1
}
if safe_toolkit_path /var/log || safe_toolkit_path /var/backups/general ||
  safe_toolkit_path /var//keine; then
  printf 'FAIL: 接受了不属于项目的数据根路径\n' >&2
  exit 1
fi

valid_service_name ssh.service || { printf 'FAIL: 正常服务名被拒绝\n' >&2; exit 1; }
if valid_service_name '../ssh' || valid_service_name 'ssh service' || valid_service_name '--help.service'; then
  printf 'FAIL: 接受了危险服务名\n' >&2
  exit 1
fi

valid_package_name linux-image-amd64 || { printf 'FAIL: 正常软件包名被拒绝\n' >&2; exit 1; }
if valid_package_name '../curl' || valid_package_name 'curl;reboot'; then
  printf 'FAIL: 接受了危险软件包名\n' >&2
  exit 1
fi

valid_pid 1234 || { printf 'FAIL: 正常 PID 被拒绝\n' >&2; exit 1; }
if valid_pid 1 || valid_pid '1234;reboot'; then
  printf 'FAIL: 接受了危险 PID\n' >&2
  exit 1
fi

valid_nice_value -10 || { printf 'FAIL: 正常 nice 值被拒绝\n' >&2; exit 1; }
if valid_nice_value -21 || valid_nice_value 20; then
  printf 'FAIL: 接受了越界 nice 值\n' >&2
  exit 1
fi

valid_network_target github.com || { printf 'FAIL: 正常域名被拒绝\n' >&2; exit 1; }
valid_network_target 2001:db8::1 || { printf 'FAIL: 正常 IPv6 被拒绝\n' >&2; exit 1; }
if valid_network_target '../host' || valid_network_target 'host;reboot'; then
  printf 'FAIL: 接受了危险网络目标\n' >&2
  exit 1
fi

valid_network_interface ens3 || { printf 'FAIL: 正常网络接口名被拒绝\n' >&2; exit 1; }
valid_network_interface br-ab12cd34 || { printf 'FAIL: 正常网桥接口名被拒绝\n' >&2; exit 1; }
if valid_network_interface '../eth0' || valid_network_interface 'eth0;down' ||
  valid_network_interface 'interface-name-is-too-long'; then
  printf 'FAIL: 接受了危险或过长网络接口名\n' >&2
  exit 1
fi

printf 'PASS: safety\n'
