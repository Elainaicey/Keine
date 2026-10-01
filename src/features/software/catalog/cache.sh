#!/usr/bin/env bash

# 软件中心一次页面渲染共享的只读快照。它不会跨操作持久化；任何软件变更
# 都会显式失效，避免为 100+ 个目录条目逐项启动 dpkg-query/apt-cache。
CATALOG_CACHE_READY=0
declare -A CATALOG_INSTALLED_VERSION_CACHE=()
declare -A CATALOG_CANDIDATE_VERSION_CACHE=()
declare -A CATALOG_UPGRADABLE_CACHE=()

catalog_cache_invalidate() {
  CATALOG_CACHE_READY=0
  CATALOG_INSTALLED_VERSION_CACHE=()
  CATALOG_CANDIDATE_VERSION_CACHE=()
  CATALOG_UPGRADABLE_CACHE=()
}

catalog_cache_packages() {
  local catalog="${SERVER_TOOLKIT_CATALOG:-$CONFIG_DIR/software.tsv}"
  [[ -r "$catalog" ]] || return 1
  awk -F '|' '
    !/^#/ && NF == 6 {
      if ($6 == "docker_official") {
        print "docker-ce"; print "docker.io"
      } else if ($6 == "caddy_official") {
        print "caddy"
      } else if (($6 == "" || $6 == "official_release") && $5 != "") {
        print $5
      }
    }
  ' "$catalog" | sort -u
}

catalog_cache_build() {
  local package status version line current="" native_arch="${ARCH:-}"
  local packages=()
  (( CATALOG_CACHE_READY == 0 )) || return 0
  # 精简测试环境或受损系统缺少 dpkg-query 时保留逐项后备路径。
  command_exists dpkg-query || return 0
  CATALOG_INSTALLED_VERSION_CACHE=()
  CATALOG_CANDIDATE_VERSION_CACHE=()
  CATALOG_UPGRADABLE_CACHE=()
  [[ -n "$native_arch" ]] || native_arch="$(dpkg --print-architecture 2>/dev/null || true)"

  while IFS='|' read -r package status version; do
    [[ -n "$package" && "$status" == installed && -n "$version" ]] || continue
    CATALOG_INSTALLED_VERSION_CACHE["$package"]="$version"
    if [[ -n "$native_arch" && "$package" == *":$native_arch" ]]; then
      CATALOG_INSTALLED_VERSION_CACHE["${package%:*}"]="$version"
    fi
  done < <(dpkg-query -W -f='${binary:Package}|${db:Status-Status}|${Version}\n' 2>/dev/null || true)
  if command_exists apt; then
    while IFS= read -r line; do
      package="${line%%/*}"
      [[ "$package" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] && CATALOG_UPGRADABLE_CACHE["$package"]=1
    done < <(LC_ALL=C apt list --upgradable 2>/dev/null | sed '1d')
  fi
  mapfile -t packages < <(catalog_cache_packages)
  if ((${#packages[@]} > 0)) && command_exists apt-cache; then
    while IFS= read -r line; do
      if [[ "$line" != [[:space:]]* && "$line" == *: ]]; then
        current="${line%:}"
      elif [[ -n "$current" && "$line" =~ ^[[:space:]]*Candidate:[[:space:]]*(.*)$ ]]; then
        CATALOG_CANDIDATE_VERSION_CACHE["$current"]="${BASH_REMATCH[1]}"
      fi
    done < <(LC_ALL=C apt-cache policy "${packages[@]}" 2>/dev/null || true)
  fi
  CATALOG_CACHE_READY=1
}

catalog_cache_package_installed() {
  [[ -n "${1:-}" ]] || return 1
  [[ -n "${CATALOG_INSTALLED_VERSION_CACHE[$1]:-}" ]]
}

catalog_cache_installed_version() {
  [[ -n "${1:-}" ]] || return 0
  printf '%s' "${CATALOG_INSTALLED_VERSION_CACHE[$1]:-}"
}

catalog_cache_candidate_version() {
  [[ -n "${1:-}" ]] || return 0
  printf '%s' "${CATALOG_CANDIDATE_VERSION_CACHE[$1]:-}"
}

catalog_cache_package_has_update() {
  local package="${1:-}" installed candidate
  [[ -n "$package" ]] || return 1
  [[ -n "${CATALOG_UPGRADABLE_CACHE[$package]:-}" ]] && return 0
  installed="${CATALOG_INSTALLED_VERSION_CACHE[$package]:-}"
  candidate="${CATALOG_CANDIDATE_VERSION_CACHE[$package]:-}"
  [[ -n "$installed" && -n "$candidate" && "$candidate" != "(none)" ]] || return 1
  dpkg --compare-versions "$candidate" gt "$installed"
}
