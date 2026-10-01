#!/usr/bin/env bash

# 菜单共享一次只读快照；返回、翻页不重复探测。R 或显式操作后重新读取。
# 不写入磁盘，不创建后台任务；真正的服务操作仍使用原生实时校验。
# 错误、版本与快照代数由应用 UI 消费。
# shellcheck disable=SC2034
APPS_SERVICE_CACHE_READY=0
APPS_SERVICE_CACHE_ERROR=0
APPS_SERVICE_CACHE_GENERATION=0
declare -A APPS_SERVICE_SNAPSHOT_CACHE=()
declare -A APPS_PACKAGE_VERSION_CACHE=()

apps_service_cache_invalidate() {
  APPS_SERVICE_CACHE_READY=0
  APPS_SERVICE_CACHE_ERROR=0
  APPS_SERVICE_SNAPSHOT_CACHE=()
  APPS_PACKAGE_VERSION_CACHE=()
}

apps_service_cache_store() {
  local snapshot="$1" line names="" unit
  local aliases=()
  while IFS= read -r line; do
    case "$line" in
      Id=*) aliases+=("${line#*=}") ;;
      Names=*) names="${line#*=}" ;;
    esac
  done <<<"$snapshot"
  IFS=' ' read -r -a aliases <<<"${aliases[*]} $names"
  for unit in "${aliases[@]}"; do
    [[ "$unit" == *.service ]] || continue
    APPS_SERVICE_SNAPSHOT_CACHE["$unit"]="$snapshot"
  done
}

apps_service_cache_build() {
  local _id _label unit _catalog package status version line output result=0 snapshot="" native_arch="${ARCH:-}"
  local units=()
  (( APPS_SERVICE_CACHE_READY == 0 )) || return 0
  command_exists systemctl || return 0
  while IFS='|' read -r _id _label unit _catalog package _; do units+=("$unit"); done < <(apps_service_catalog)
  ((${#units[@]} > 0)) || return 0
  output="$(runtime_with_timeout 3 systemctl show --no-pager \
    -p Id -p Names -p LoadState -p ActiveState -p UnitFileState \
    -p MainPID -p NRestarts -p MemoryCurrent -p TasksCurrent \
    -p CPUUsageNSec -p ActiveEnterTimestamp -p Result "${units[@]}" 2>/dev/null)" || result=$?
  if [[ -z "$output" || "$result" == 124 || "$result" == 137 ]]; then
    APPS_SERVICE_CACHE_ERROR=1
  else
    while IFS= read -r line; do
      if [[ -z "$line" ]]; then
        [[ -z "$snapshot" ]] || apps_service_cache_store "$snapshot"
        snapshot=""
      else
        snapshot+="$line"$'\n'
      fi
    done <<<"$output"
    [[ -z "$snapshot" ]] || apps_service_cache_store "$snapshot"
    for unit in "${units[@]}"; do
      [[ -n "${APPS_SERVICE_SNAPSHOT_CACHE[$unit]:-}" ]] || APPS_SERVICE_CACHE_ERROR=1
    done
  fi
  if command_exists dpkg-query; then
    while IFS='|' read -r package status version; do
      [[ -n "$package" && "$status" == installed && -n "$version" ]] || continue
      APPS_PACKAGE_VERSION_CACHE["$package"]="$version"
      if [[ -n "$native_arch" && "$package" == *":$native_arch" ]]; then
        APPS_PACKAGE_VERSION_CACHE["${package%:*}"]="$version"
      fi
    done < <(dpkg-query -W -f='${binary:Package}|${db:Status-Status}|${Version}\n' 2>/dev/null || true)
  fi
  APPS_SERVICE_CACHE_READY=1
  APPS_SERVICE_CACHE_GENERATION=$((APPS_SERVICE_CACHE_GENERATION + 1))
}

apps_service_cached_exists() {
  local unit="$1" load
  if (( APPS_SERVICE_CACHE_READY == 0 )); then service_exists "$unit"; return; fi
  load="$(unit_snapshot_value "${APPS_SERVICE_SNAPSHOT_CACHE[$unit]:-}" LoadState || true)"
  [[ -n "$load" && "$load" != not-found ]]
}

apps_service_cached_state() {
  if (( APPS_SERVICE_CACHE_READY == 0 )); then service_state "$1"; return; fi
  local state
  state="$(unit_snapshot_value "${APPS_SERVICE_SNAPSHOT_CACHE[$1]:-}" ActiveState || true)"
  printf '%s' "${state:-unknown}"
}

apps_service_cached_enabled() {
  local enabled
  if (( APPS_SERVICE_CACHE_READY == 1 )); then
    enabled="$(unit_snapshot_value "${APPS_SERVICE_SNAPSHOT_CACHE[$1]:-}" UnitFileState || true)"
  else
    enabled="$(systemctl is-enabled "$1" 2>/dev/null || true)"
  fi
  printf '%s' "${enabled:-unknown}"
}
