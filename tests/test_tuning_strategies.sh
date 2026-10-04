#!/usr/bin/env bash
# Only fixture files and mock sysctl values are changed; no real network writes.
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
TEST_TUNING_ROOT="$(mktemp -d)"
trap '[[ "$TEST_TUNING_ROOT" == /tmp/* ]] && rm -rf -- "$TEST_TUNING_ROOT"' EXIT
KEINE_STATE_ROOT="$TEST_TUNING_ROOT/keine-state"
KEINE_BACKUP_ROOT="$TEST_TUNING_ROOT/keine-backups"
KEINE_TUNING_STRATEGY_FILE="$TEST_TUNING_ROOT/tuning.conf"
KEINE_NETWORK_TUNING_FILE="$TEST_TUNING_ROOT/manual.conf"
KEINE_BBR_FILE="$TEST_TUNING_ROOT/bbr.conf"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/core/changes.sh"
. "$ROOT_DIR/src/core/backup.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/core/configuration.sh"
. "$ROOT_DIR/src/features/network/parameters.sh"
. "$ROOT_DIR/src/features/network/tuning.sh"
. "$ROOT_DIR/src/integrations/network-tuning.sh"
. "$ROOT_DIR/src/features/recovery.sh"
CHANGES_ENABLED=1
require_root() { :; }
audit() { :; }
confirm() { return 0; }
flock() { :; }
getconf() { [[ "$1" == PAGESIZE ]] && printf '4096\n'; }
tuning_strategy_source_files() { [[ ! -f "$TEST_TUNING_ROOT/external.conf" ]] || printf '%s\n' "$TEST_TUNING_ROOT/external.conf"; }
mkdir "$TEST_TUNING_ROOT/values"
failure_key=''
sysctl() {
  local key value arg
  case "$1" in
    -n)
      case "$2" in
        net.ipv4.tcp_available_congestion_control) printf 'reno cubic bbr\n'; return 0 ;;
        net.ipv4.tcp_ehash_entries) printf '32768\n'; return 0 ;;
      esac
      [[ -f "$TEST_TUNING_ROOT/values/$2" ]] || return 1
      cat "$TEST_TUNING_ROOT/values/$2"
      ;;
    -w)
      shift
      for arg in "$@"; do
        key="${arg%%=*}"; value="${arg#*=}"
        [[ "$key" != "$failure_key" || "$value" != 32 ]] || return 1
        # Real procps prints vector values with tabs.
        printf '%s\n' "${value// /$'\t'}" >"$TEST_TUNING_ROOT/values/$key"
      done
      ;;
    *) return 1 ;;
  esac
}
tcp_plan="$(tuning_strategy_plan tcpfit 300 proxy 150 1024)"
eric_plan="$(tuning_strategy_plan vps-tcp-tune 1000 overseas 150 1024)"
grep -qx 'net.core.rmem_max=13347152' <<<"$tcp_plan" || die 'TCPFit BDP formula changed'
grep -qx 'net.ipv4.tcp_mem=16384 32768 65536' <<<"$tcp_plan" || die 'TCPFit memory formula changed'
grep -qx 'net.core.rmem_max=67108864' <<<"$eric_plan" || die 'Eric region tier changed'
grep -qx 'net.ipv4.tcp_max_tw_buckets=16384' <<<"$eric_plan" || die 'Eric ehash floor changed'
grep -qx 'vm.swappiness=20' <<<"$eric_plan" || die 'Eric small RAM tier changed'
for bad in 0 -1 001 '100;reboot' 100001; do
  if tuning_strategy_plan tcpfit "$bad" proxy 150 1024 >/dev/null; then die "Invalid bandwidth accepted: $bad"; fi
done
if tuning_strategy_plan tcpfit 100 proxy 2001 1024 >/dev/null; then die 'Invalid RTT accepted'; fi
if tuning_strategy_validate <<<"$tcp_plan"$'\nnet.ipv4.ip_forward=1'; then die 'Unknown parameter accepted'; fi
if tuning_strategy_validate <<<"$tcp_plan"$'\nnet.core.rmem_max=1'; then die 'Duplicate accepted'; fi
tuning_strategy_validate <<<"$tcp_plan" || die 'Full TCPFit plan rejected'
tuning_strategy_validate <<<"$eric_plan" || die 'Full Eric plan rejected'
# Exercise transactions on representative scalar, vector, shared and provider-only keys.
# Formula validation above uses the complete plans; this keeps filesystem fixtures small.
transaction_keys='^#|^(net.core.default_qdisc|net.ipv4.tcp_congestion_control|net.core.rmem_max|net.core.rmem_default|net.ipv4.tcp_rmem|fs.file-max|vm.swappiness)='
tcp_plan="$(grep -E "$transaction_keys" <<<"$tcp_plan")"
eric_plan="$(grep -E "$transaction_keys" <<<"$eric_plan")"
while IFS='=' read -r key value; do
  case "$key" in
    net.core.default_qdisc) value=fq_codel ;;
    net.ipv4.tcp_congestion_control) value=cubic ;;
    net.ipv4.tcp_rmem|net.ipv4.tcp_wmem|net.ipv4.tcp_mem) value='4096 8192 16384' ;;
    net.ipv4.ip_local_port_range) value='32768 60999' ;;
    fs.file-max) value=9223372036854775807 ;;
    *) value=32 ;;
  esac
  printf '%s\n' "$value" >"$TEST_TUNING_ROOT/values/$key"
done < <(printf '%s\n%s\n' "$tcp_plan" "$eric_plan" | tuning_strategy_values)
cp -R "$TEST_TUNING_ROOT/values" "$TEST_TUNING_ROOT/original"
DRY_RUN=1
tuning_strategy_apply "$tcp_plan" >/dev/null
[[ ! -e "$TUNING_STRATEGY_FILE" && ! -e "$KEINE_STATE_ROOT" ]] || die 'Dry run mutated state'
DRY_RUN=0
printf 'net/core/rmem_max = 123\n' >"$TEST_TUNING_ROOT/external.conf"
if tuning_strategy_apply "$tcp_plan" >/dev/null 2>&1; then die 'External persistent conflict ignored'; fi
rm "$TEST_TUNING_ROOT/external.conf"
tuning_strategy_apply "$tcp_plan" >/dev/null
[[ "$(tuning_strategy_id)" == tcpfit ]] || die 'Provider not recorded'
mapfile -t recovery_rows < <(recovery_entries)
[[ ${#recovery_rows[@]} == 1 && "${recovery_rows[0]}" == tuning\|* ]] || die 'Tuning resources were not grouped'
if tuning_strategy_guard >/dev/null 2>&1; then die 'Independent BBR was not blocked'; fi
sysctl -w net.core.rmem_max=777
if tuning_strategy_restore >/dev/null 2>&1; then die 'External runtime edit overwritten'; fi
sysctl -w net.core.rmem_max=13347152
tuning_strategy_apply "$eric_plan" >/dev/null
[[ "$(tuning_strategy_id)" == vps-tcp-tune ]] || die 'Switch failed'
[[ "$(changes_sysctl_read net.core.rmem_default)" == 32 ]] || die 'Old strategy parameters stacked'
[[ "$(changes_sysctl_read net.core.rmem_max)" == 67108864 ]] || die 'New strategy not active'
# A failure while restoring a retired parameter must preserve the previous complete plan.
failure_key=vm.swappiness
if tuning_strategy_apply "$tcp_plan" >/dev/null 2>&1; then die 'Partial switch succeeded'; fi
[[ "$(tuning_strategy_id)" == vps-tcp-tune ]] || die 'Failed switch changed persistence'
[[ "$(changes_sysctl_read net.core.rmem_max)" == 67108864 ]] || die 'Failed switch changed runtime'
failure_key=''
tuning_strategy_restore >/dev/null
[[ ! -e "$TUNING_STRATEGY_FILE" ]] || die 'Persistence remains after restore'
for original in "$TEST_TUNING_ROOT/original/"*; do
  [[ "$(changes_sysctl_read "${original##*/}")" == "$(cat "$original")" ]] || die "Wrong baseline: ${original##*/}"
done
printf 'PASS: independent tuning strategies, conflicts, switching and rollback\n'
