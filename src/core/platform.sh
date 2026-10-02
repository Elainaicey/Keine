#!/usr/bin/env bash

# 本文件定义由入口加载、再由 feature 模块消费的平台状态。
# ShellCheck 按单文件分析时无法跟踪这种跨模块读取。
# shellcheck disable=SC2034

OS_ID=""; OS_NAME=""; OS_CODENAME=""; ARCH=""
CPU_CORES=""; MEMORY_MB=""; MEMORY_USED_MB=""; SWAP_MB=""; SWAP_USED_MB=""; ROOT_USED_PERCENT=""; VIRTUALIZATION=""; LOAD_AVERAGE=""; UPTIME_TEXT=""
PACKAGE_INDEX_UPDATED=0
PLATFORM_IDENTITY_READY=0

platform_detect_identity() {
  (( PLATFORM_IDENTITY_READY == 0 )) || return 0
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"
  # shellcheck source=/dev/null
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_NAME="${PRETTY_NAME:-$OS_ID ${VERSION_ID:-unknown}}"
  if [[ "$OS_ID" == "ubuntu" ]]; then
    OS_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  else
    OS_CODENAME="${VERSION_CODENAME:-}"
  fi
  case "$OS_ID" in debian|ubuntu) ;; *) die "当前仅支持 Debian 和 Ubuntu，检测到：$OS_NAME" ;; esac
  ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  PLATFORM_IDENTITY_READY=1
}

platform_collect_metrics() {
  platform_detect_identity
  CPU_CORES="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '?')"
  MEMORY_MB="$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || printf '?')"
  MEMORY_USED_MB="$(awk '/MemTotal/{total=$2}/MemAvailable/{available=$2}END{printf "%.0f",(total-available)/1024}' /proc/meminfo 2>/dev/null || printf '0')"
  SWAP_MB="$(awk '/SwapTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || printf '0')"
  SWAP_USED_MB="$(awk '/SwapTotal/{total=$2}/SwapFree/{free=$2}END{printf "%.0f",(total-free)/1024}' /proc/meminfo 2>/dev/null || printf '0')"
  ROOT_USED_PERCENT="$(df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5);print $5}')"
  VIRTUALIZATION="$(systemd-detect-virt 2>/dev/null || printf 'unknown')"
  LOAD_AVERAGE="$(awk '{print $1 " " $2 " " $3}' /proc/loadavg 2>/dev/null || printf '?')"
  UPTIME_TEXT="$(uptime -p 2>/dev/null | sed 's/^up //' || printf '?')"
}

platform_detect() {
  platform_collect_metrics
}

package_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'; }

package_installed_version() {
  dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

package_candidate_version() {
  LC_ALL=C apt-cache policy "$1" 2>/dev/null | awk '/^[[:space:]]*Candidate:/ {print $2; exit}'
}

package_has_update() {
  local package="$1" installed candidate
  installed="$(package_installed_version "$package")"
  candidate="$(package_candidate_version "$package")"
  [[ -n "$installed" && -n "$candidate" && "$candidate" != "(none)" ]] || return 1
  dpkg --compare-versions "$candidate" gt "$installed"
}

package_wait_for_lock() {
  command_exists fuser || return 0
  local waited=0
  local locks=(/var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock)
  while fuser "${locks[@]}" >/dev/null 2>&1; do
    (( waited == 0 )) && info "APT 正被其他进程使用，等待锁释放……"
    (( waited >= 180 )) && die "等待 APT 锁超过 180 秒，请稍后重试。"
    sleep 3; waited=$((waited + 3))
  done
}

apt_run() {
  local inventory="" result=0
  package_wait_for_lock
  if [[ "${1:-}" == install || "${1:-}" == upgrade ]] && declare -F changes_ready >/dev/null && changes_ready; then
    inventory="$(mktemp)" || return 1
    changes_package_inventory >"$inventory" || { rm -f -- "$inventory"; return 1; }
  fi
  run env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE="${APT_NEEDRESTART_MODE:-a}" apt-get \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o Acquire::Retries=3 "$@" || result=$?
  if [[ -n "$inventory" ]]; then
    changes_packages_record_new "$inventory" || result=1
    rm -f -- "$inventory"
  fi
  return "$result"
}

package_update_index() {
  [[ "$PACKAGE_INDEX_UPDATED" -eq 1 ]] && return 0
  info "刷新软件索引……"
  apt_run update || { warn "APT 软件索引刷新失败。"; return 1; }
  PACKAGE_INDEX_UPDATED=1
}
package_invalidate_index() { PACKAGE_INDEX_UPDATED=0; }

package_verify_candidate() {
  local package="$1" installed candidate
  [[ "$DRY_RUN" -eq 0 ]] || return 0
  installed="$(package_installed_version "$package")"
  candidate="$(package_candidate_version "$package")"
  [[ -n "$installed" ]] || { warn "$package 安装后未通过状态验证。"; return 1; }
  if [[ -n "$candidate" && "$candidate" != "(none)" ]] && dpkg --compare-versions "$candidate" gt "$installed"; then
    warn "$package 当前版本 $installed 仍低于软件源候选版本 $candidate。"
    return 1
  fi
}

package_install() {
  local requested=("$@") missing=() package display="" failed=0
  for package in "${requested[@]}"; do [[ -n "$package" ]] && ! package_installed "$package" && missing+=("$package"); done
  ((${#missing[@]} > 0)) || { info "已经安装，无需操作。"; return 0; }
  package_update_index || return 1
  printf -v display '%s ' "${missing[@]}"; info "将安装系统包：${display% }"
  apt_run install --no-remove -y "${missing[@]}" || { warn "APT 软件安装失败。"; return 1; }
  for package in "${missing[@]}"; do package_verify_candidate "$package" || failed=1; done
  (( failed == 0 ))
}

package_install_latest() {
  local requested=("$@") targets=() package candidate display="" failed=0
  package_update_index || return 1
  for package in "${requested[@]}"; do
    [[ -n "$package" ]] || continue
    candidate="$(package_candidate_version "$package")"
    if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then targets+=("$package"); continue; fi
      warn "软件源没有提供 $package 的候选版本。"
      return 1
    fi
    if ! package_installed "$package" || package_has_update "$package"; then targets+=("$package"); fi
  done
  ((${#targets[@]} > 0)) || { info "所选软件已经是当前软件源中的最新版本。"; return 0; }
  printf -v display '%s ' "${targets[@]}"
  info "将安装软件源最新候选版本：${display% }"
  apt_run install --no-remove -y "${targets[@]}" || { warn "APT 最新候选版本安装失败。"; return 1; }
  for package in "${targets[@]}"; do package_verify_candidate "$package" || failed=1; done
  (( failed == 0 ))
}

package_remove() {
  local requested=("$@") installed=() package display="" failed=0
  for package in "${requested[@]}"; do [[ -n "$package" ]] && package_installed "$package" && installed+=("$package"); done
  ((${#installed[@]} > 0)) || { info "软件未安装。"; return 0; }
  printf -v display '%s ' "${installed[@]}"; info "将移除系统包：${display% }"
  apt_run remove -y "${installed[@]}" || { warn "APT 软件移除失败。"; return 1; }
  if [[ "$DRY_RUN" -eq 0 ]]; then
    for package in "${installed[@]}"; do
      if package_installed "$package"; then warn "$package 移除后仍处于已安装状态。"; failed=1; fi
    done
  fi
  (( failed == 0 ))
}

package_upgrade() {
  local package="$1"
  package_installed "$package" || { warn "$package 尚未安装。"; return 1; }
  package_update_index || return 1
  if ! package_has_update "$package"; then
    info "$package 已经是软件仓库中的最新版本。"
    return 0
  fi
  info "将更新系统包：$package"
  apt_run install --only-upgrade -y "$package" || { warn "APT 软件更新失败。"; return 1; }
  package_verify_candidate "$package"
}

package_upgradable_count() { LC_ALL=C apt list --upgradable 2>/dev/null | sed '1d' | grep -c . || true; }

unit_exists() {
  command_exists systemctl || return 1
  if systemctl list-unit-files --no-legend 2>/dev/null |
    awk -v unit="$1" '$1 == unit { found=1 } END { exit !found }'; then return 0; fi
  # 未启用过的模板实例不一定出现在 list-unit-files 中，但仍可原生管理。
  [[ "$(systemctl show -p LoadState --value "$1" 2>/dev/null)" == loaded ]]
}
service_exists() {
  [[ "$1" == *.service ]] && unit_exists "$1"
}
service_enable_now() {
  service_exists "$1" || { warn "未找到 systemd 单元：$1"; return 1; }
  run systemctl enable --now "$1" || { warn "$1 启用或启动失败。"; return 1; }
  if [[ "$DRY_RUN" -eq 0 ]]; then
    systemctl is-enabled --quiet "$1" || { warn "$1 未启用开机启动。"; return 1; }
    systemctl is-active --quiet "$1" || { warn "$1 启动后未进入 active 状态。"; return 1; }
  fi
}
service_state() {
  local state
  state="$(systemctl is-active "$1" 2>/dev/null || true)"
  printf '%s' "${state:-inactive}"
}

unit_properties_snapshot() {
  local unit="$1" property
  local arguments=()
  shift
  valid_service_name "$unit" || return 1
  (($# > 0)) || return 1
  for property in "$@"; do
    [[ "$property" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || return 1
    arguments+=(-p "$property")
  done
  systemctl show --no-pager "${arguments[@]}" "$unit" 2>/dev/null
}

unit_snapshot_value() {
  local snapshot="$1" property="$2" line
  [[ "$property" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || return 1
  while IFS= read -r line; do
    if [[ "$line" == "$property="* ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <<<"$snapshot"
  return 1
}

detect_ssh_port() {
  local port="22"
  command_exists sshd && port="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')"
  printf '%s' "${port:-22}"
}

platform_firewall_active() {
  command_exists ufw || return 1
  ufw status 2>/dev/null | grep -q '^Status: active' ||
    grep -q '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null
}
