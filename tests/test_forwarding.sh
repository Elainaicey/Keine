#!/usr/bin/env bash
# Offline service fixtures: no listening sockets, root writes or firewall changes.
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export KEINE_FORWARD_UNITS="$test_root/units"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/core/changes.sh"
. "$ROOT_DIR/src/core/configuration.sh"
. "$ROOT_DIR/src/features/network/forwarding.sh"
STATE_ROOT="$test_root/keine-state"
CHANGES_ENABLED=1
mkdir -p "$KEINE_FORWARD_UNITS"
require_root() { :; }
audit() { changes_commit_pending; }
forward_engine_available() { return 0; }
flock() { return 0; }
sleep() { :; }
runtime_with_timeout() { shift; "$@"; }
systemd-analyze() { grep -q '^ExecStart=/usr/bin/socat ' "$2"; }
ip() { printf '%s\n' "${route_fixture:-unicast}"; }
systemctl() {
  printf '%s\n' "$*" >>"$test_root/calls"
  case "$1" in
    show)
      case "$4" in
        FragmentPath) [[ ! -f "$KEINE_FORWARD_UNITS/$2" ]] || printf '%s' "$KEINE_FORWARD_UNITS/$2" ;;
        DropInPaths) printf '%s' "${dropin_fixture:-}" ;;
        MainPID) printf 123 ;;
      esac ;;
    is-active) [[ -f "$test_root/active" ]] ;;
    is-enabled) [[ -f "$test_root/boot" ]] ;;
    enable) touch "$test_root/boot" ;;
    disable) rm -f "$test_root/boot"; [[ "${2:-}" != --now ]] || rm -f "$test_root/active" ;;
    stop) rm -f "$test_root/active" ;;
    restart)
      if [[ -f "$test_root/fail-once" ]]; then rm "$test_root/fail-once"; return 1; fi
      touch "$test_root/active" ;;
    daemon-reload) : ;;
    *) return 1 ;;
  esac
}
ss() {
  if [[ "${occupied:-0}" == 1 ]]; then printf 'LISTEN 0 128 0.0.0.0:2000 *:* users:(("other",pid=999,fd=3))\n'
  elif [[ -f "$test_root/active" ]]; then printf 'LISTEN 0 128 0.0.0.0:2000 *:* users:(("socat",pid=123,fd=3))\n'; fi
}
declare -Ag FORWARD_RULE=([id]=example [protocol]=tcp [listen]=127.0.0.1 [port]=2000 [target]=192.0.2.1 [target_port]=3000 [active]=1 [boot]=0 [idle]=120)
path="$(forward_path example)"
template="$(forward_render)"
[[ "$template" == *'TCP4-LISTEN:2000,bind=127.0.0.1,reuseaddr,fork,max-children=128'* && "$template" == *'TCP4:192.0.2.1:3000,connect-timeout=10'* ]]
FORWARD_RULE[protocol]=udp; FORWARD_RULE[target]=2001:db8::1; FORWARD_RULE[listen]=::1
template="$(forward_render)"
[[ "$template" == *'-b65535 -T120 UDP6-LISTEN:'* && "$template" == *'ipv6only=1 UDP6:[2001:db8::1]:3000'* ]]
FORWARD_RULE[target]='127.0.0.1,exec=sh'
if forward_render >/dev/null; then die 'Injected target accepted'; fi
FORWARD_RULE[target]=192.0.2.1; FORWARD_RULE[listen]=127.0.0.1; FORWARD_RULE[protocol]=tcp
DRY_RUN=1
forward_save >/dev/null
[[ ! -e "$path" && ! -d "$STATE_ROOT" ]]
DRY_RUN=0
occupied=1
if forward_save >/dev/null 2>&1; then die 'Occupied port accepted'; fi
occupied=0
route_fixture='local 127.0.0.1 dev lo'
FORWARD_RULE[target_port]=2000
if forward_save >/dev/null 2>&1; then die 'Local forwarding loop accepted'; fi
FORWARD_RULE[target_port]=3000; route_fixture=unicast
forward_save >/dev/null
[[ -f "$path" && -f "$test_root/active" && ! -f "$test_root/boot" ]]
forward_owned "$path"
before="$(<"$path")"
FORWARD_RULE[id]=second
if forward_save >/dev/null 2>&1; then die 'Reserved rule port accepted'; fi
FORWARD_RULE[id]=example
FORWARD_RULE[target_port]=3001
touch "$test_root/fail-once"
if forward_save >/dev/null 2>&1; then die 'Failed restart accepted'; fi
[[ "$(<"$path")" == "$before" && -f "$test_root/active" ]]
forward_owned "$path"
forward_load "$path"
FORWARD_RULE[boot]=1
restart_count="$(grep -c '^restart' "$test_root/calls")"
forward_save >/dev/null
[[ -f "$test_root/boot" && "$(grep -c '^restart' "$test_root/calls")" == "$restart_count" ]]
FORWARD_RULE[active]=0
forward_save >/dev/null
[[ ! -f "$test_root/active" && -f "$test_root/boot" ]]
FORWARD_RULE[active]=1
forward_save >/dev/null
[[ -f "$test_root/active" ]]
dropin_fixture=/etc/systemd/system/other.conf
if forward_remove "$path" >/dev/null 2>&1; then die 'External drop-in accepted'; fi
dropin_fixture=''
printf '# external edit\n' >>"$path"
if forward_remove "$path" >/dev/null 2>&1; then die 'External modification removed'; fi
sed -i '$d' "$path"
forward_remove "$path" >/dev/null
[[ ! -f "$path" && ! -f "$test_root/active" && ! -f "$test_root/boot" && ! -d "$(changes_file_entry "$path")" ]]
forward_recovery_handles "$path"
if forward_recovery_handles "$(forward_dir)/ssh.service"; then die 'Unrelated service claimed'; fi
touch "$test_root/fail-once"
if forward_save >/dev/null 2>&1; then die 'Failed first start accepted'; fi
[[ ! -f "$path" && ! -f "$test_root/active" ]]
forward_remove "$path" >/dev/null
[[ ! -d "$(changes_file_entry "$path")" ]]
printf 'PASS: forwarding validation, render, lifecycle, rollback and ownership\n'
