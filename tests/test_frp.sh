#!/usr/bin/env bash
# Offline systemd/FRP fixtures; all writes stay in the disposable test directory.
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
trap 'printf "FAIL: FRP test at line %s\n" "$LINENO" >&2' ERR
IFS=$'\n\t'
# MSYS derives reported permission bits from the caller's umask; match transactions.
umask 077
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export TMPDIR="$test_root/transactions"
mkdir "$TMPDIR"
export KEINE_FRP_CONFIG_DIR="$test_root/config" KEINE_FRP_UNIT_DIR="$test_root/units"
export KEINE_STATE_ROOT="$test_root/keine-state"
CONFIG_DIR="$ROOT_DIR/config"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/core/changes.sh"
. "$ROOT_DIR/src/core/configuration.sh"
. "$ROOT_DIR/src/features/software/releases.sh"
. "$ROOT_DIR/src/features/network/frp.sh"
. "$ROOT_DIR/src/features/recovery.sh"
CHANGES_ENABLED=1
declare -Ag FRP_CONFIG
declare -ag FRP_MAPS
mkdir -p "$KEINE_FRP_UNIT_DIR" "$test_root/bin"
SOFTWARE_RELEASE_BIN_DIR="$test_root/bin"
require_root() { :; }
audit() { printf '%s\n' "$*" >>"$test_root/audit"; changes_commit_pending; }
software_release_integrity() { return 0; }
flock() { [[ ! -f "$test_root/locked" ]]; }
sleep() { :; }
runtime_with_timeout() { shift; "$@"; }
systemd-analyze() { [[ ! -f "$test_root/invalid-unit" ]]; }
service_state() { if systemctl is-active --quiet "$1"; then printf active; else printf inactive; fi; }
systemctl() {
  local unit="${2:-}" verb="$1"
  [[ "$unit" != --quiet && "$unit" != --now ]] || unit="${3:-}"
  { printf '%s ' "$@"; printf '\n'; } >>"$test_root/calls"
  case "$verb" in
    show)
      case "$4" in
        FragmentPath) [[ ! -f "$KEINE_FRP_UNIT_DIR/$unit" ]] || printf '%s' "$KEINE_FRP_UNIT_DIR/$unit" ;;
        DropInPaths) printf '%s' "${dropin_fixture:-}" ;;
        MainPID) printf 123 ;;
        InvocationID) printf aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
      esac ;;
    is-active) [[ -f "$test_root/$unit.active" ]] ;;
    is-enabled)
      if [[ -f "$test_root/$unit.boot" ]]; then [[ "$2" == --quiet ]] || printf enabled; return 0; fi
      [[ "$2" == --quiet ]] || printf disabled; return 1 ;;
    enable)
      if [[ -f "$test_root/ignore-enable-once" ]]; then rm "$test_root/ignore-enable-once"; return 0; fi
      touch "$test_root/$unit.boot" ;;
    disable)
      rm -f "$test_root/$unit.boot"
      [[ "$2" != --now ]] || rm -f "$test_root/$unit.active" ;;
    stop) rm -f "$test_root/$unit.active" ;;
    restart)
      if [[ -f "$test_root/external-once" ]]; then
        rm "$test_root/external-once"
        printf '# external during restart\n' >>"$(frp_config_path frps)"
        return 1
      fi
      if [[ -f "$test_root/fail-once" ]]; then rm "$test_root/fail-once"; return 1; fi
      touch "$test_root/$unit.active" ;;
    daemon-reload)
      if [[ -f "$test_root/reload-fail-once" ]]; then rm "$test_root/reload-fail-once"; return 1; fi ;;
    *) return 1 ;;
  esac
}
ss() {
  if [[ "${occupied:-0}" == 1 ]]; then printf 'LISTEN 0 128 0.0.0.0:7000 *:* users:(("other",pid=999,fd=3))\n'
  elif [[ -f "$test_root/keine-frps.service.active" ]]; then printf 'LISTEN 0 128 0.0.0.0:7000 *:* users:(("frps",pid=123,fd=3))\n'; fi
}
journalctl() {
  [[ "${login_failure:-0}" != 1 ]] || return 0
  printf 'login to server success\n'
  [[ "${registration_failure:-0}" == 1 ]] || printf '[%sweb] start proxy success\n[%sdns] start proxy success\n' "${log_prefix-edge.}" "${log_prefix-edge.}"
  printf '%s\n' "${log_fixture:-}"
}
# Executable fixture exercises verify argument passing and confidential failures.
for role in frps frpc; do
  cat >"$test_root/bin/$role" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == verify && "$2" == -c && -f "$3" ]] || exit 1
if grep -q 'serverPort = 9999' "$3"; then cat "$3"; exit 1; fi
EOF
  chmod 0755 "$test_root/bin/$role"
done

server_defaults() {
  FRP_CONFIG=([role]=frps [addr]=0.0.0.0 [port]=7000 [proxy_addr]=127.0.0.1 [first]=10000 [last]=20000 [token]=test_secret_0123456789 [active]=1 [boot]=0)
  FRP_MAPS=()
}
client_defaults() {
  FRP_CONFIG=([role]=frpc [addr]=example.com [port]=7000 [user]=edge [token]=test_secret_0123456789 [active]=1 [boot]=0)
  FRP_MAPS=('web|tcp|127.0.0.1|8080|10080|1' 'dns|udp|::1|53|10053|1')
}
assert_fails() { if "$@" >"$test_root/rejected" 2>&1; then die "unexpected success: $*"; fi; }

server_defaults
FRP_CONFIG[first]=7000; assert_fails frp_values_valid; server_defaults
FRP_CONFIG[token]='{{ .Envs.HOME }}'; assert_fails frp_values_valid; server_defaults
FRP_CONFIG[port]=07000; assert_fails frp_values_valid; server_defaults
DRY_RUN=1; frp_save create >/dev/null
[[ ! -e "$(frp_config_path frps)" && ! -d "$STATE_ROOT" ]]
DRY_RUN=0
touch "$test_root/locked"; assert_fails frp_save create; rm "$test_root/locked"
[[ ! -e "$(frp_config_path frps)" ]]
occupied=1; assert_fails frp_save create; occupied=0
[[ ! -e "$(frp_config_path frps)" ]]
frp_save create >/dev/null
frp_owned frps
[[ -f "$test_root/keine-frps.service.active" && ! -f "$test_root/keine-frps.service.boot" ]]
server_before="$(cat "$(frp_config_path frps)")"
FRP_CONFIG[port]=7001; touch "$test_root/fail-once"
assert_fails frp_save
[[ "$(cat "$(frp_config_path frps)")" == "$server_before" && -f "$test_root/keine-frps.service.active" ]]
frp_owned frps
frp_load frps; FRP_CONFIG[boot]=1
touch "$test_root/ignore-enable-once"; assert_fails frp_save
[[ ! -f "$test_root/keine-frps.service.boot" ]]
frp_load frps; FRP_CONFIG[boot]=1
: >"$test_root/calls"; frp_save >/dev/null
if grep -q '^restart ' "$test_root/calls"; then die 'boot change restarted active tunnel'; fi
[[ -f "$test_root/keine-frps.service.boot" ]]
frp_load frps; frp_save restart >/dev/null
grep -q '^restart keine-frps.service' "$test_root/calls"
assert_fails frp_release_guard frps install
assert_fails frp_release_guard frps remove
frp_load frps; FRP_CONFIG[active]=0; frp_save >/dev/null
frp_release_guard frps install
[[ ! -f "$test_root/keine-frps.service.active" && -f "$test_root/keine-frps.service.boot" ]]
frp_load frps; FRP_CONFIG[active]=1; frp_save >/dev/null
dropin_fixture=/external.conf; assert_fails frp_remove frps; dropin_fixture=''
printf '# external\n' >>"$(frp_config_path frps)"
assert_fails frp_save; assert_fails frp_remove frps
sed -i '$d' "$(frp_config_path frps)"
frp_owned frps
touch "$test_root/reload-fail-once"; assert_fails frp_remove frps
frp_owned frps
[[ -f "$test_root/keine-frps.service.active" && -f "$test_root/keine-frps.service.boot" ]]

client_defaults
rendered="$(frp_render_config)"
[[ "$rendered" == *'localIP = "::1"'* && "$rendered" == *'transport.tls.enable = true'* ]]
FRP_MAPS+=('web|tcp|127.0.0.1|8081|10081|1'); assert_fails frp_values_valid
client_defaults; FRP_MAPS+=('duplicate-port|tcp|127.0.0.1|8081|10080|1'); assert_fails frp_values_valid
# Literal shell syntax must stay data and be rejected.
client_defaults
# shellcheck disable=SC2016
FRP_MAPS+=('bad|tcp|$(id)|8081|10081|1')
assert_fails frp_values_valid
client_defaults; FRP_CONFIG[port]=9999; assert_fails frp_save create
if grep -q 'test_secret' "$test_root/rejected"; then die 'credential leaked in validation error'; fi
[[ ! -f "$(frp_config_path frpc)" ]]
client_defaults; registration_failure=1; assert_fails frp_save create; registration_failure=0
[[ ! -f "$(frp_config_path frpc)" ]]
client_defaults; login_failure=1; assert_fails frp_save create; login_failure=0
[[ ! -f "$(frp_config_path frpc)" && ! -f "$(frp_unit_path frpc)" && ! -f "$test_root/keine-frpc.service.active" ]]
frp_remove frpc >/dev/null
[[ ! -d "$(changes_file_entry "$(frp_config_path frpc)")" ]]
client_defaults; frp_save create >/dev/null
frp_owned frpc
log_prefix=''; frp_verify_running frpc; unset log_prefix
log_fixture='sensitive test_secret_0123456789 value'
output="$(frp_logs frpc)"
[[ "$output" != *test_secret* && "$output" == *'已隐藏'* && "$output" == *$'\n'* ]]
frp_load frpc; FRP_MAPS[0]='web|tcp|127.0.0.1|8080|10080|0'; frp_save >/dev/null
[[ "$(cat "$(frp_config_path frpc)")" != *'name = "web"'* ]]
frp_load frpc; FRP_MAPS=(); frp_save >/dev/null
[[ "$(cat "$(frp_config_path frpc)")" != *'[[proxies]]'* ]]

# Recovery groups the pair ahead of binaries, never restoring a bare unit/config first.
rows="$(recovery_entries)"
[[ "$rows" == *'frp|frps|'* && "$rows" == *'frp|frpc|'* && "$rows" != *'file|'* ]]
frp_preflight_remove frps; frp_preflight_remove frpc
frp_remove frpc >/dev/null; frp_remove frps >/dev/null
[[ ! -f "$(frp_config_path frps)" && ! -f "$(frp_unit_path frps)" && ! -f "$test_root/keine-frps.service.boot" ]]
[[ -z "$(recovery_entries)" ]]
if grep -q 'test_secret' "$test_root/audit"; then die 'credential leaked in audit'; fi

# A concurrent edit must survive both failure rollback and fingerprint recording.
server_defaults; frp_save create >/dev/null
touch "$test_root/external-once"; assert_fails frp_save restart
grep -q '# external during restart' "$(frp_config_path frps)"
[[ "$(changes_file_status "$(changes_file_entry "$(frp_config_path frps)")")" == conflict ]]
assert_fails frp_remove frps
# Restoring the exact last project content resolves the conflict; retained copies
# remain under this test's TMPDIR and are cleaned by the EXIT trap.
sed -i '$d' "$(frp_config_path frps)"
frp_remove frps >/dev/null

# Unowned and symlinked resources cannot be adopted by creating a new instance.
mkdir -p "$KEINE_FRP_CONFIG_DIR"
printf external >"$(frp_config_path frps)"
server_defaults; assert_fails frp_save create
[[ "$(cat "$(frp_config_path frps)")" == external ]]
rm "$(frp_config_path frps)"
printf 'external target\n' >"$test_root/outside"
if ln -s "$test_root/outside" "$(frp_config_path frps)" 2>/dev/null && [[ -L "$(frp_config_path frps)" ]]; then
  assert_fails frp_save create
  [[ "$(cat "$test_root/outside")" == 'external target' ]]
else
  printf 'NOTE: host lacks native symlink support; Linux runs the symlink rejection case\n'
fi
printf 'PASS: FRP validation, credentials, grouped transactions, rollback, ownership and recovery\n'
