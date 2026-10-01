#!/usr/bin/env bash

SOFTWARE_CATALOG="${SERVER_TOOLKIT_CATALOG:-$CONFIG_DIR/software.tsv}"

catalog_source_kind() {
  local record="$1" _id _category _name _description _packages handler
  IFS='|' read -r _id _category _name _description _packages handler <<<"$record"
  case "$handler" in
    official_release) printf 'official-release' ;;
    docker_official|caddy_official) printf 'official-repository' ;;
    "") printf 'distribution' ;;
    *) printf 'other' ;;
  esac
}

catalog_source_label() {
  local record="$1" id _category _name _description packages handler
  IFS='|' read -r id _category _name _description packages handler <<<"$record"
  case "$handler" in
    official_release)
      if software_release_managed "$id"; then
        printf '项目官方 GitHub Release'
      elif [[ -n "$packages" ]] && catalog_package_installed "$packages"; then
        printf 'Debian / Ubuntu 软件仓库'
      elif command_exists "$(software_release_command "$id")"; then
        printf '原生外部安装（未接管）'
      else
        printf '项目官方 GitHub Release（推荐）'
      fi
      ;;
    docker_official|caddy_official) printf '项目官方 APT 仓库' ;;
    "") printf 'Debian / Ubuntu 软件仓库' ;;
    *) printf '专用安装器' ;;
  esac
}

catalog_rows() {
  local query="${1:-}"
  [[ -r "$SOFTWARE_CATALOG" ]] || die "软件目录不可读：$SOFTWARE_CATALOG"
  if [[ -z "$query" ]]; then
    awk -F '|' '!/^#/ && NF == 6' "$SOFTWARE_CATALOG"
  else
    awk -F '|' -v query="$query" 'BEGIN {query=tolower(query)} !/^#/ && NF==6 && index(tolower($1" "$2" "$3" "$4),query){print}' "$SOFTWARE_CATALOG"
  fi
}

catalog_category_rows() {
  local category="$1"
  [[ -r "$SOFTWARE_CATALOG" ]] || die "软件目录不可读：$SOFTWARE_CATALOG"
  awk -F '|' -v category="$category" '!/^#/ && NF==6 && $2==category {print}' "$SOFTWARE_CATALOG"
}

catalog_categories() {
  [[ -r "$SOFTWARE_CATALOG" ]] || die "软件目录不可读：$SOFTWARE_CATALOG"
  awk -F '|' '
    !/^#/ && NF==6 {
      if (!seen[$2]++) order[++total]=$2
      count[$2]++
    }
    END {
      for (i=1; i<=total; i++) print order[i] "|" count[order[i]]
    }
  ' "$SOFTWARE_CATALOG"
}

catalog_record() {
  awk -F '|' -v wanted="$1" '!/^#/ && NF==6 && $1==wanted {print; found=1; exit} END{if(!found)exit 1}' "$SOFTWARE_CATALOG"
}

catalog_primary_package() {
  local record="$1" _id _category _name _description packages handler
  IFS='|' read -r _id _category _name _description packages handler <<<"$record"
  case "$handler" in
    docker_official)
      if catalog_package_installed docker-ce; then printf 'docker-ce'
      elif catalog_package_installed docker.io; then printf 'docker.io'
      else printf 'docker-ce'
      fi
      ;;
    caddy_official) printf 'caddy' ;;
    *) printf '%s' "$packages" ;;
  esac
}

catalog_package_installed() {
  [[ -n "${1:-}" ]] || return 1
  if (( CATALOG_CACHE_READY == 1 )); then
    catalog_cache_package_installed "$1"
  else
    package_installed "$1"
  fi
}

catalog_package_installed_version() {
  [[ -n "${1:-}" ]] || return 0
  if (( CATALOG_CACHE_READY == 1 )); then
    catalog_cache_installed_version "$1"
  else
    package_installed_version "$1"
  fi
}

catalog_package_candidate_version() {
  [[ -n "${1:-}" ]] || return 0
  if (( CATALOG_CACHE_READY == 1 )); then
    catalog_cache_candidate_version "$1"
  else
    package_candidate_version "$1"
  fi
}

catalog_package_has_update() {
  [[ -n "${1:-}" ]] || return 1
  if (( CATALOG_CACHE_READY == 1 )); then
    catalog_cache_package_has_update "$1"
  else
    package_has_update "$1"
  fi
}

catalog_installed() {
  local record="$1" id _category _name _description packages handler
  IFS='|' read -r id _category _name _description packages handler <<<"$record"
  case "$handler" in
    docker_official) command_exists docker ;;
    caddy_official) command_exists caddy ;;
    official_release)
      software_release_managed "$id" || { [[ -n "$packages" ]] && catalog_package_installed "$packages"; } ||
        command_exists "$(software_release_command "$id")"
      ;;
    "") catalog_package_installed "$packages" ;;
    *) return 1 ;;
  esac
}

catalog_installed_version() {
  local record="$1" id _category _name _description _packages handler package version
  IFS='|' read -r id _category _name _description _packages handler <<<"$record"
  if [[ "$handler" == "official_release" ]] && software_release_managed "$id"; then
    version="$(software_release_version "$id")"
    printf '%s' "${version:-—}"
    return 0
  fi
  if [[ "$handler" == official_release ]] && ! catalog_package_installed "$_packages" && command_exists "$(software_release_command "$id")"; then
    local executable
    executable="$(command -v "$(software_release_command "$id")")"
    if [[ "$id" == actionlint ]]; then
      version="$(runtime_with_timeout 5 "$executable" -version 2>/dev/null | head -n 1 || true)"
    else
      version="$(runtime_with_timeout 5 "$executable" --version 2>/dev/null | head -n 1 || true)"
    fi
    printf '%s' "${version:-外部安装}"
    return 0
  fi
  package="$(catalog_primary_package "$record")"
  version="$(catalog_package_installed_version "$package")"
  if [[ -z "$version" ]]; then
    case "$package" in
      docker-ce) command_exists docker && version="$(docker --version 2>/dev/null | sed -E 's/^Docker version ([^,]+).*/\1/' || true)" ;;
      caddy) command_exists caddy && version="$(caddy version 2>/dev/null | awk '{print $1}' || true)" ;;
    esac
  fi
  printf '%s' "${version:-—}"
}

catalog_candidate_version() {
  local record="$1" id _category _name _description _packages handler package candidate repository_status
  IFS='|' read -r id _category _name _description _packages handler <<<"$record"
  if [[ "$handler" == "official_release" ]]; then
    if software_release_managed "$id"; then
      printf '官方稳定版（按需检查）'
    elif [[ -n "$_packages" ]] && catalog_package_installed "$_packages"; then
      local distro_candidate
      distro_candidate="$(catalog_package_candidate_version "$_packages")"
      printf '%s' "${distro_candidate:-—}"
    else
      printf '官方最新稳定版'
    fi
    return 0
  fi
  if software_official_repository_handler "$handler"; then
    if [[ "$handler" == docker_official ]] && catalog_package_installed docker.io && ! catalog_package_installed docker-ce; then
      candidate="$(catalog_package_candidate_version docker.io)"
    else
      repository_status="$(software_repository_status "$handler")"
      if [[ "$repository_status" != configured ]]; then printf '安装时获取官方稳定版'; return 0; fi
      candidate="$(software_repository_candidate "$handler")"
    fi
  else
    package="$(catalog_primary_package "$record")"
    candidate="$(catalog_package_candidate_version "$package")"
  fi
  [[ "$candidate" != '(none)' ]] || candidate=""
  printf '%s' "${candidate:-—}"
}

catalog_has_update() {
  local record="$1" id _category _name _description _packages handler package
  catalog_installed "$record" || return 1
  IFS='|' read -r id _category _name _description _packages handler <<<"$record"
  if [[ "$handler" == "official_release" ]]; then
    software_release_managed "$id" && return 1
    [[ -n "$_packages" ]] || return 1
    catalog_package_has_update "$_packages"
    return
  fi
  package="$(catalog_primary_package "$record")"
  catalog_package_has_update "$package"
}

catalog_available() {
  local record="$1" id _category _name _description packages handler candidate
  IFS='|' read -r id _category _name _description packages handler <<<"$record"
  if [[ "$handler" == "official_release" ]]; then
    software_release_supported "$id" && return 0
    [[ -n "$packages" ]] || return 1
    candidate="$(catalog_package_candidate_version "$packages")"
    [[ -n "$candidate" && "$candidate" != "(none)" ]]
    return
  fi
  if software_official_repository_handler "$handler"; then
    case "${OS_ID:-}" in debian|ubuntu) return 0 ;; *) return 1 ;; esac
  fi
  [[ -z "$handler" ]] || return 0
  candidate="$(catalog_package_candidate_version "$packages")"
  [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

catalog_state() {
  local record="$1" candidate="${2:-}" id _category _name _description _packages handler repository_status repository_candidate
  IFS='|' read -r id _category _name _description _packages handler <<<"$record"
  if software_official_repository_handler "$handler"; then
    if [[ "$handler" == "docker_official" ]] && catalog_package_installed docker.io && ! catalog_package_installed docker-ce; then
      if catalog_has_update "$record"; then printf 'update'; else printf 'current'; fi
      return 0
    fi
    repository_status="$(software_repository_status "$handler")"
    if catalog_installed "$record"; then
      if [[ "$repository_status" != "configured" ]]; then
        printf 'source-warning'
      elif catalog_has_update "$record"; then
        printf 'update'
      else
        printf 'current'
      fi
      return 0
    fi
    case "$repository_status" in
      missing) printf 'setup' ;;
      incomplete|unsafe) printf 'source-warning' ;;
      configured)
        repository_candidate="$(software_repository_candidate "$handler")"
        if [[ -n "$repository_candidate" && "$repository_candidate" != "(none)" ]]; then
          printf 'absent'
        else
          printf 'unavailable'
        fi
        ;;
      *) printf 'unavailable' ;;
    esac
    return 0
  fi
  if catalog_installed "$record"; then
    if [[ "$handler" == "official_release" ]] && software_release_managed "$id"; then
      if software_release_integrity "$id"; then printf 'managed'; else printf 'damaged'; fi
      return 0
    fi
    if [[ "$handler" == official_release && ( -z "$_packages" || -z "$(catalog_package_installed_version "$_packages")" ) ]]; then
      printf 'external'
      return 0
    fi
    if catalog_has_update "$record"; then printf 'update'; else printf 'current'; fi
  elif (( $# > 1 )); then
    if [[ -n "$candidate" && "$candidate" != "—" ]]; then printf 'absent'; else printf 'unavailable'; fi
  elif ! catalog_available "$record"; then
    printf 'unavailable'
  else
    printf 'absent'
  fi
}
