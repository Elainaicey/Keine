#!/usr/bin/env bash
# 离线替身验证更新边界，不调用主机 APT 或重启服务。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/features/system/updates.sh"
OS_ID=debian; OS_CODENAME=bookworm; OS_NAME='Debian fixture'
PACKAGE_INDEX_UPDATED=0
events=""; confirmations=0; accept=1; refresh_failure=0; upgrade_failure=0
broken=0; mixed=0; removal=0; simulation_failure=0
platform_detect_identity() { :; }
require_root() { events+="root>"; }
confirm() { confirmations=$((confirmations + 1)); (( confirmations <= accept )); }
package_invalidate_index() { PACKAGE_INDEX_UPDATED=0; }
catalog_cache_invalidate() { :; }
package_upgradable_count() { printf 1; }
audit() { :; }
dpkg() { if (( broken == 1 )); then printf 'half-configured fixture\n'; fi; }
apt-cache() {
  printf ' release o=Debian,n=bookworm\n release o=Debian,n=bookworm-security\n'
  if (( mixed == 1 )); then printf ' release o=Debian,n=trixie\n'; fi
}
apt-get() {
  [[ "${LC_ALL:-}" == C ]] || return 1
  if [[ "$*" == *upgrade* ]]; then
    (( simulation_failure == 0 )) || return 1
    printf '%s\n' 'Inst curl [1.0] (2.0 Debian-Security:stable-security [amd64])' \
      'Inst helper (1.0 Debian:stable [amd64])' '1 upgraded, 1 newly installed, 0 to remove and 2 not upgraded.'
    if (( removal == 1 )); then printf 'Remv critical [1.0]\n'; fi
  fi
}
apt_run() {
  if [[ "$1" == update ]]; then
    [[ "$2" == --error-on=any ]] || return 1
    events+="refresh>"; (( refresh_failure == 0 ))
  elif [[ "$1" == upgrade ]]; then
    [[ "$*" == *--with-new-pkgs* && "$*" == *--no-remove* && "$*" == *APT::Get::AutomaticRemove=false* ]] || return 1
    [[ "${APT_NEEDRESTART_MODE:-}" == l ]] || return 1
    events+="upgrade>"; (( upgrade_failure == 0 ))
  else
    printf 'FAIL: unexpected APT mutation\n' >&2; return 1
  fi
}
system_update_simulate
[[ "$SYSTEM_UPDATE_UPGRADED|$SYSTEM_UPDATE_NEW|$SYSTEM_UPDATE_KEPT" == '1|1|2' ]] || die '更新计划统计错误'
output="$(system_update_plan_render)"
grep -q 'curl.*1.0 → 2.0' <<<"$output" || die '更新预览缺少版本'
system_update_sources_check
mixed=1
if system_update_sources_check >/dev/null 2>&1; then die '接受了其他发行版来源'; fi
mixed=0; removal=1
if system_update_simulate >/dev/null 2>&1; then die '接受了移除软件包的计划'; fi
removal=0; simulation_failure=1
if system_update_simulate >/dev/null 2>&1; then die '忽略了 APT 模拟失败'; fi
simulation_failure=0
system_update_apply >/dev/null
[[ "$events" == 'root>refresh>' ]] || die '取消确认后仍执行升级'
events=""; confirmations=0; accept=2
system_update_apply >/dev/null
[[ "$events" == 'root>refresh>upgrade>' && "$PACKAGE_INDEX_UPDATED" -eq 1 ]] || die '系统更新流程或参数错误'
events=""; confirmations=0; refresh_failure=1
if system_update_apply >/dev/null 2>&1; then die '索引刷新失败仍报告成功'; fi
[[ "$events" == 'root>refresh>' ]] || die '索引刷新失败仍执行升级'
refresh_failure=0; events=""; confirmations=0; broken=1
if system_update_apply >/dev/null 2>&1; then die '软件包异常仍执行更新'; fi
[[ "$events" == 'root>' ]] || die '异常软件包触发了 APT 写入'
broken=0; events=""; confirmations=0; mixed=1
if system_update_apply >/dev/null 2>&1; then die '跨发行版来源仍执行更新'; fi
[[ "$events" == 'root>refresh>' ]] || die '跨发行版更新未被阻止'
mixed=0; events=""; confirmations=0; upgrade_failure=1
if system_update_apply >/dev/null 2>&1; then die '升级失败仍报告成功'; fi
upgrade_failure=0; events=""; confirmations=0; DRY_RUN=1
output="$(system_update_apply)"
grep -q '仅预览命令，未更新系统软件包' <<<"$output" || die 'dry-run 声称实际更新成功'
printf 'PASS: system update\n'
