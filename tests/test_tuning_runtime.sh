#!/usr/bin/env bash
# Kernel/network commands are fixtures: never send traffic or modify the host.
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TUNING_RUNTIME="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TUNING_RUNTIME"' EXIT
KEINE_STATE_ROOT="$TEST_TUNING_RUNTIME/keine-state"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/core/changes.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/integrations/network-tuning.sh"
. "$ROOT_DIR/src/features/recovery.sh"
CHANGES_ENABLED=1
require_root() { :; }
audit() { :; }
flock() { :; }
tuning_boot_id() { printf '%s' "$test_boot"; }
tuning_device_identity() { printf '%s' "$test_identity"; }
test_boot=boot1
test_identity=1:aa
test_route_device=eth0
test_iperf_fail=0
test_spike_rate=0
test_slow=0
test_filters=''
test_samples=0
printf 'qdisc fq_codel 0: root refcnt 2 limit 10240p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 32Mb ecn\n' >"$TEST_TUNING_RUNTIME/qdisc"
: >"$TEST_TUNING_RUNTIME/class"
: >"$TEST_TUNING_RUNTIME/writes"
printf 'default via 192.0.2.1 dev eth0 proto dhcp src 192.0.2.10 metric 100\n' >"$TEST_TUNING_RUNTIME/route4"
printf 'default via 2001:db8::1 dev eth0 proto static metric 1024 pref medium\n' >"$TEST_TUNING_RUNTIME/route6"

ip() {
  local family
  case "$1:$2" in
    link:show) [[ "$4" == eth0 ]] ;;
    route:get) printf '%s via 192.0.2.1 dev %s src 192.0.2.10\n' "$3" "$test_route_device" ;;
    -4:route|-6:route)
      family="${1#-}"; shift 2
      case "$1" in
        show) cat "$TEST_TUNING_RUNTIME/route$family" ;;
        change)
          shift; printf 'route\n' >>"$TEST_TUNING_RUNTIME/writes"
          (IFS=' '; printf '%s\n' "$*") >"$TEST_TUNING_RUNTIME/route$family" ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}

tc() {
  local detailed=0 handle kind options parent line class_options
  local -a words=() kept=()
  if [[ "$1" == -d ]]; then detailed=1; shift; fi
  case "$1:$2" in
    filter:show) printf '%s' "$test_filters" ;;
    qdisc:show) cat "$TEST_TUNING_RUNTIME/qdisc" ;;
    class:show)
      if (( detailed == 1 )); then cat "$TEST_TUNING_RUNTIME/class"
      else sed -E 's/ quantum [0-9]+//g' "$TEST_TUNING_RUNTIME/class"; fi ;;
    qdisc:replace)
      printf 'qdisc\n' >>"$TEST_TUNING_RUNTIME/writes"
      [[ "$3:$4" == dev:eth0 ]] || return 1
      shift 4
      if [[ "$1" == root ]]; then
        handle="$3"; kind="$4"; shift 4
        if [[ "$kind" == mq ]] && grep -q "^qdisc mq $handle root" "$TEST_TUNING_RUNTIME/qdisc"; then return 1; fi
        options="$(IFS=' '; printf '%s' "$*")"
        printf 'qdisc %s %s root %s\n' "$kind" "$handle" "$options" >"$TEST_TUNING_RUNTIME/qdisc"
        : >"$TEST_TUNING_RUNTIME/class"
        if [[ "$kind" == mq ]]; then
          printf 'qdisc fq_codel 0: parent %s1 limit 10240p\nqdisc fq_codel 0: parent %s2 limit 10240p\n' "$handle" "$handle" >>"$TEST_TUNING_RUNTIME/qdisc"
        fi
      else
        [[ "$1" == parent ]] || return 1
        parent="$2"; shift 2
        [[ "$1" != handle ]] || shift 2
        kind="$1"; shift
        options="$(IFS=' '; printf '%s' "$*")"
        options="${options//mbit/Mbit}"
        while IFS= read -r line; do
          [[ "$line" == *"parent $parent "* ]] || kept+=("$line")
        done <"$TEST_TUNING_RUNTIME/qdisc"
        printf '%s\n' "${kept[@]}" >"$TEST_TUNING_RUNTIME/qdisc"
        printf 'qdisc %s 7e11: parent %s %s\n' "$kind" "$parent" "$options" >>"$TEST_TUNING_RUNTIME/qdisc"
      fi ;;
    class:replace)
      if [[ -f "$TEST_TUNING_RUNTIME/fail-class" ]]; then rm "$TEST_TUNING_RUNTIME/fail-class"; return 1; fi
      printf 'class\n' >>"$TEST_TUNING_RUNTIME/writes"
      shift 9
      class_options="$(IFS=' '; printf '%s' "$*")"
      # Mimic tc's normalized rate units.
      class_options="${class_options//mbit/Mbit}"
      printf 'class htb 7e10:1 root leaf 7e11: %s\n' "$class_options" >"$TEST_TUNING_RUNTIME/class" ;;
    *) return 1 ;;
  esac
}

original="$(tuning_queue_snapshot eth0)"
route_before="$(tuning_route_snapshot 4 eth0)"
DRY_RUN=1
tuning_runtime_apply qdisc eth0 fq >/dev/null
[[ ! -s "$TEST_TUNING_RUNTIME/writes" && ! -d "$(tuning_runtime_root)" ]]
DRY_RUN=0
tuning_runtime_apply qdisc eth0 fq >/dev/null
entry="$(tuning_runtime_entry qdisc eth0)"
[[ "$(tuning_runtime_status "$entry")" == ready && "$(<"$entry/before")" == "$original" ]]
tuning_runtime_apply qdisc eth0 htb 100 >/dev/null
tuning_queue_rate_matches "$(tuning_queue_snapshot eth0)" 100
[[ "$(<"$entry/before")" == "$original" ]]
grep -q '^network-runtime|' < <(recovery_entries)
printf 'qdisc fq 7e20: root limit 9999p\n' >"$TEST_TUNING_RUNTIME/qdisc"
: >"$TEST_TUNING_RUNTIME/class"
[[ "$(tuning_runtime_status "$entry")" == conflict ]]
if tuning_runtime_restore "$entry" >/dev/null 2>&1; then die 'External qdisc overwritten'; fi
tuning_queue_restore eth0 "$(<"$entry/last")"
tuning_runtime_restore "$entry" >/dev/null
[[ "$(tuning_queue_snapshot eth0)" == "$original" && ! -e "$entry" ]]
# Partial HTB install fails and rolls back; no baseline leak.
: >"$TEST_TUNING_RUNTIME/fail-class"
if tuning_runtime_apply qdisc eth0 htb 100 >/dev/null 2>&1; then die 'Partial shaper reported success'; fi
[[ "$(tuning_queue_snapshot eth0)" == "$original" && ! -e "$entry" ]]
test_filters=external-filter
if tuning_runtime_apply qdisc eth0 fq >/dev/null 2>&1; then die 'Filter overwritten'; fi
test_filters=''

tuning_runtime_apply route4 eth0 window 32 >/dev/null
route_entry="$(tuning_runtime_entry route4 eth0)"
[[ "$(tuning_route_base <"$TEST_TUNING_RUNTIME/route4")" == "$route_before" ]]
tuning_runtime_apply route4 eth0 window 16 >/dev/null
[[ "$(<"$route_entry/before")" == "$route_before" ]]
tuning_runtime_restore "$route_entry" >/dev/null
[[ "$(tuning_route_snapshot 4 eth0)" == "$route_before" ]]
tuning_runtime_apply route6 eth0 window 32 >/dev/null
tuning_runtime_restore "$(tuning_runtime_entry route6 eth0)" >/dev/null
printf 'default via 192.0.2.1 dev eth0 expires 30sec\n' >"$TEST_TUNING_RUNTIME/route4"
if tuning_runtime_apply route4 eth0 window 32 >/dev/null 2>&1; then die 'Dynamic route accepted'; fi
printf '%s\n' "$route_before" >"$TEST_TUNING_RUNTIME/route4"

# mq leaves survive FQ and HTB transitions, including removing an HTB over mq.
printf 'qdisc mq 0: root\nqdisc fq_codel 0: parent :1 limit 10240p\nqdisc fq_codel 0: parent :2 limit 5120p\n' >"$TEST_TUNING_RUNTIME/qdisc"
mq_before="$(tuning_queue_snapshot eth0)"
tuning_runtime_apply qdisc eth0 fq >/dev/null
[[ "$(tuning_queue_snapshot eth0)" == $'1|fq|\n2|fq|\nroot|mq|' ]]
tuning_runtime_apply qdisc eth0 htb 100 >/dev/null
tuning_runtime_apply qdisc eth0 fq >/dev/null
[[ "$(tuning_queue_snapshot eth0)" == $'1|fq|\n2|fq|\nroot|mq|' ]]
tuning_runtime_restore "$entry" >/dev/null
[[ "$(tuning_queue_snapshot eth0)" == "$mq_before" ]]

# A stale boot record must never replay network state over the current boot.
tuning_runtime_apply qdisc eth0 fq >/dev/null
test_boot=boot2
before_expire="$(tuning_queue_snapshot eth0)"
[[ "$(tuning_runtime_status "$entry")" == expired ]]
tuning_runtime_restore "$entry" >/dev/null
[[ "$(tuning_queue_snapshot eth0)" == "$before_expire" && ! -e "$entry" ]]

command_exists jq || die 'This targeted test requires jq'
test_json='{"end":{"sum_sent":{"bits_per_second":100000000,"retransmits":0,"seconds":10},"sum_received":{"bits_per_second":95000000}}}'
[[ "$(tuning_measure_parse <<<"$test_json")" == '100|95|0|10' ]]
for invalid in '{}' '{"error":"busy"}' '{"end":{"sum_sent":{"bits_per_second":0}}}'; do
  if tuning_measure_parse <<<"$invalid" >/dev/null 2>&1; then die 'Incomplete iperf result accepted'; fi
done
[[ "$(tuning_tcpfit_calc calc_burst 100)" == 50000 ]]
[[ "$(tuning_tcpfit_calc calc_margin 100)" == 5 ]]
[[ "$(tuning_tcpfit_calc loss_pct 0 100 10)" == 0.0000 ]]
[[ "$(tuning_queue_options fq 'quantum 3Kb initial_quantum 10Kb timer_slack 10us')" == 'quantum 3072 initial_quantum 10240 timer_slack 10us' ]]
[[ "$(tuning_queue_options fq 'bands 3 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1 weights 524288 196608 65536')" == *'weights 524288 196608 65536' ]]
tuning_measure_spike 0.2 0
if tuning_measure_spike 0.4 0.1; then die 'Baseline spike rule changed'; fi
[[ "$(tuning_measure_resolve 192.0.2.2)" == 192.0.2.2 ]]
if tuning_measure_route eth0 '--help' >/dev/null 2>&1; then die 'Unvalidated peer accepted'; fi

timeout() {
  [[ "$1" == --foreground && "$2" == --signal=TERM && "$3" == --kill-after=3 ]] || return 1
  shift 4; "$@"
}
iperf3() {
  local rate=100 retrans=0 received
  [[ "$1" == -c && "$5" == --bind-dev && "$6" == eth0 ]] || return 1
  [[ "$test_iperf_fail" == 0 ]] || return 1
  rate="$(awk '{for(i=1;i<NF;i++)if($i=="rate"){print $(i+1)+0}}' "$TEST_TUNING_RUNTIME/class")"
  rate="${rate:-100}"
  if (( test_spike_rate > 0 && rate >= test_spike_rate )); then retrans=1000; fi
  received=$((rate*950000))
  (( test_slow == 0 )) || received=$((rate*100000))
  printf '{"end":{"sum_sent":{"bits_per_second":%s,"retransmits":%s,"seconds":10},"sum_received":{"bits_per_second":%s}}}' "$((rate*1000000))" "$retrans" "$received"
}

test_route_device=eth1
if tuning_measure_sample eth0 192.0.2.2 5201 10 1 >/dev/null 2>&1; then die 'Wrong egress accepted'; fi
test_route_device=eth0
DRY_RUN=1
if tuning_measure_sample eth0 192.0.2.2 5201 10 1 >/dev/null 2>&1; then die 'Dry run measured traffic'; fi
DRY_RUN=0
before_probe="$(tuning_queue_snapshot eth0)"
tuning_runtime_session eth0 probe 192.0.2.2 5201 10 >/dev/null
[[ "$(tuning_queue_snapshot eth0)" == "$before_probe" && ! -e "$entry" ]]
test_iperf_fail=1
if tuning_runtime_session eth0 probe 192.0.2.2 5201 10 >/dev/null 2>&1; then die 'Failed probe accepted'; fi
[[ "$(tuning_queue_snapshot eth0)" == "$before_probe" && ! -e "$entry" ]]
test_iperf_fail=0
test_spike_rate=70
tuning_runtime_session eth0 sweep 192.0.2.2 5201 10 50 100 10 >"$TEST_TUNING_RUNTIME/report"
grep -q 'Mbps' "$TEST_TUNING_RUNTIME/report"
grep -q '候选整形值' "$TEST_TUNING_RUNTIME/report"
[[ "$(tuning_queue_snapshot eth0)" == "$before_probe" && ! -e "$entry" ]]
test_slow=1; test_spike_rate=0
if tuning_runtime_session eth0 sweep 192.0.2.2 5201 10 50 100 10 >"$TEST_TUNING_RUNTIME/report" 2>/dev/null; then
  die 'Slow peer yielded a valid sweep'
fi
if grep -q '候选整形值' "$TEST_TUNING_RUNTIME/report"; then die 'Slow peer generated recommendation'; fi
[[ "$(tuning_queue_snapshot eth0)" == "$before_probe" ]]
test_slow=0
tuning_measure_verify eth0 192.0.2.2 5201 10 >/dev/null
printf 'PASS: tuning runtime and measurement transactions\n'
