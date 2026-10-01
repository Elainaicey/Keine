#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/features/security/exposure.sh"

ss_fixture=$'tcp LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=123,fd=3))\n'
ss_fixture+=$'tcp LISTEN 0 4096 [::]:443 [::]:* users:(("caddy",pid=456,fd=7))\n'
ss_fixture+=$'udp UNCONN 0 0 127.0.0.1:53 0.0.0.0:* users:(("dns",pid=88,fd=4))'
parsed="$(security_exposure_parse_ss <<<"$ss_fixture")"
grep -Fqx 'tcp|0.0.0.0|22|sshd|123' <<<"$parsed" || {
  printf 'FAIL: 没有解析 IPv4 公网监听\n' >&2
  exit 1
}
grep -Fqx 'tcp|::|443|caddy|456' <<<"$parsed" || {
  printf 'FAIL: 没有解析 IPv6 公网监听\n' >&2
  exit 1
}
if grep -q '|53|' <<<"$parsed"; then
  printf 'FAIL: 回环地址被误判为公网监听\n' >&2
  exit 1
fi

docker_fixture=$'web|0.0.0.0:80->80/tcp, [::]:80->80/tcp\n'
docker_fixture+=$'dns|127.0.0.1:53->53/udp\ninvalid name|0.0.0.0:22->22/tcp'
docker_rows="$(security_exposure_parse_docker_ports <<<"$docker_fixture")"
[[ "$(grep -Fxc 'tcp|80|web' <<<"$docker_rows")" -eq 2 ]] || {
  printf 'FAIL: Docker IPv4/IPv6 发布端口解析错误\n' >&2
  exit 1
}
if grep -qE 'udp\|53\|dns|invalid name' <<<"$docker_rows"; then
  printf 'FAIL: 回环 Docker 端口或无效容器名被误判为公网发布\n' >&2
  exit 1
fi

ufw_fixture=$'Status: active\n22/tcp ALLOW Anywhere\n443/tcp DENY Anywhere\n[ 3] 53/udp ALLOW IN 10.0.0.0/8'
[[ "$(security_exposure_ufw_rule_state 22 tcp "$ufw_fixture")" == "allow" ]] || {
  printf 'FAIL: 没有识别 UFW 放行规则\n' >&2
  exit 1
}
[[ "$(security_exposure_ufw_rule_state 443 tcp "$ufw_fixture")" == "deny" ]] || {
  printf 'FAIL: 没有识别 UFW 拒绝规则\n' >&2
  exit 1
}
[[ "$(security_exposure_ufw_rule_state 53 udp "$ufw_fixture")" == "allow" ]] || {
  printf 'FAIL: 没有识别编号 UFW 规则\n' >&2
  exit 1
}
[[ "$(security_exposure_ufw_rule_state 8080 tcp "$ufw_fixture")" == "review" ]] || {
  printf 'FAIL: 无精确 UFW 规则的端口没有标记为需核对\n' >&2
  exit 1
}
[[ "$(security_exposure_ufw_rule_state 22 tcp 'Status: inactive')" == "inactive" ]] || {
  printf 'FAIL: 没有识别未启用的 UFW\n' >&2
  exit 1
}

proc_root="$(mktemp -d)"
trap 'rm -rf -- "$proc_root"' EXIT
mkdir -p "$proc_root/123"
printf '0::/system.slice/ssh.service\n' >"$proc_root/123/cgroup"
export KEINE_PROC_ROOT="$proc_root"
[[ "$(security_exposure_unit_for_pid 123)" == "ssh.service" ]] || {
  printf 'FAIL: 没有从 cgroup 识别 systemd 服务\n' >&2
  exit 1
}

printf 'PASS: exposure\n'
