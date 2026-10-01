#!/usr/bin/env bash

software_official_repository_handler() {
  case "${1:-}" in
    docker_official|caddy_official) return 0 ;;
    *) return 1 ;;
  esac
}

software_repository_name() {
  case "${1:-}" in
    docker_official) printf 'Docker' ;;
    caddy_official) printf 'Caddy' ;;
    *) return 1 ;;
  esac
}

software_repository_source_file() {
  local sources_dir="${KEINE_APT_SOURCES_DIR:-/etc/apt/sources.list.d}"
  case "${1:-}" in
    docker_official) printf '%s/docker.sources' "$sources_dir" ;;
    caddy_official) printf '%s/caddy-stable.list' "$sources_dir" ;;
    *) return 1 ;;
  esac
}

software_repository_key_file() {
  case "${1:-}" in
    docker_official)
      printf '%s/docker.asc' "${KEINE_APT_KEYRING_DIR:-/etc/apt/keyrings}"
      ;;
    caddy_official)
      printf '%s/caddy-stable-archive-keyring.gpg' \
        "${KEINE_SHARE_KEYRING_DIR:-/usr/share/keyrings}"
      ;;
    *) return 1 ;;
  esac
}

software_repository_uri() {
  case "${1:-}" in
    docker_official) printf 'https://download.docker.com/linux/%s' "${OS_ID:-debian}" ;;
    caddy_official) printf 'https://dl.cloudsmith.io/public/caddy/stable/deb/debian' ;;
    *) return 1 ;;
  esac
}

software_repository_file_state() {
  local path="$1"
  if [[ -L "$path" ]]; then
    printf 'unsafe'
  elif [[ -f "$path" && -r "$path" && -s "$path" ]]; then
    printf 'ready'
  elif [[ -e "$path" ]]; then
    printf 'invalid'
  else
    printf 'missing'
  fi
}

software_repository_key_valid() {
  local handler="$1" key_file="${2:-}" first_byte
  if [[ -z "$key_file" ]]; then
    key_file="$(software_repository_key_file "$handler")" || return 1
  fi
  [[ "$(software_repository_file_state "$key_file")" == "ready" ]] || return 1
  case "$handler" in
    docker_official)
      grep -Fq -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$key_file" &&
        grep -Fq -- '-----END PGP PUBLIC KEY BLOCK-----' "$key_file" || return 1
      ;;
    caddy_official)
      command_exists od || return 1
      first_byte="$(od -An -tx1 -N1 "$key_file" 2>/dev/null | tr -d '[:space:]')"
      case "$first_byte" in 98|99|9a|9b|c6) ;; *) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
  if command_exists gpg; then
    LC_ALL=C gpg --batch --quiet --show-keys "$key_file" >/dev/null 2>&1 || return 1
  fi
  return 0
}

software_repository_source_valid() {
  local handler="$1" source_file expected_uri
  source_file="$(software_repository_source_file "$handler")" || return 1
  [[ "$(software_repository_file_state "$source_file")" == "ready" ]] || return 1
  expected_uri="$(software_repository_uri "$handler")" || return 1
  case "$handler" in
    docker_official)
      grep -Fqx 'Types: deb' "$source_file" &&
        grep -Fqx "URIs: $expected_uri" "$source_file" &&
        grep -Fqx "Suites: ${OS_CODENAME:-}" "$source_file" &&
        grep -Fqx 'Components: stable' "$source_file" &&
        grep -Fqx "Architectures: ${ARCH:-}" "$source_file" &&
        grep -Fqx "Signed-By: $(software_repository_key_file "$handler")" "$source_file"
      ;;
    caddy_official)
      grep -Fq "$expected_uri" "$source_file" &&
        grep -Fq "signed-by=$(software_repository_key_file "$handler")" "$source_file"
      ;;
    *) return 1 ;;
  esac
}

software_repository_status() {
  local handler="$1" source_file key_file source_state key_state
  software_official_repository_handler "$handler" || return 1
  source_file="$(software_repository_source_file "$handler")" || return 1
  key_file="$(software_repository_key_file "$handler")" || return 1
  source_state="$(software_repository_file_state "$source_file")"
  key_state="$(software_repository_file_state "$key_file")"
  if [[ "$source_state" == "unsafe" || "$key_state" == "unsafe" ]]; then
    printf 'unsafe'
  elif [[ "$source_state" == "missing" && "$key_state" == "missing" ]]; then
    printf 'missing'
  elif [[ "$key_state" == "ready" ]] && software_repository_key_valid "$handler" &&
    software_repository_source_valid "$handler"; then
    printf 'configured'
  else
    printf 'incomplete'
  fi
}

software_repository_status_label() {
  case "${1:-}" in
    configured) printf '文件结构完整' ;;
    missing) printf '未配置（安装时自动创建）' ;;
    incomplete) printf '配置不完整' ;;
    unsafe) printf '路径异常（拒绝符号链接）' ;;
    *) printf '未知' ;;
  esac
}

software_repository_candidate() {
  local handler="$1" package
  case "$handler" in
    docker_official) package='docker-ce' ;;
    caddy_official) package='caddy' ;;
    *) return 1 ;;
  esac
  package_candidate_version "$package"
}

software_repository_verify_candidate() {
  local handler="$1" name candidate
  name="$(software_repository_name "$handler")" || return 1
  candidate="$(software_repository_candidate "$handler")"
  if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "$name 仓库候选版本将在实际配置并刷新索引后验证。"
      return 0
    fi
    warn "$name 官方仓库已配置，但当前系统没有可安装的候选版本。"
    warn "系统：${OS_NAME:-${OS_ID:-未知}} · 代号：${OS_CODENAME:-未知} · 架构：${ARCH:-未知}"
    return 1
  fi
  info "$name 官方仓库候选版本：$candidate"
}

software_repository_paths_safe() {
  local handler="$1" source_file key_file
  source_file="$(software_repository_source_file "$handler")" || return 1
  key_file="$(software_repository_key_file "$handler")" || return 1
  if [[ -L "$source_file" || -L "$key_file" ]]; then
    warn "拒绝覆盖符号链接形式的软件源或签名文件。"
    warn "请先人工核实：$source_file · $key_file"
    return 1
  fi
}
