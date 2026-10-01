#!/usr/bin/env bash
# Platform fixtures are consumed by the sourced repository state module.
# shellcheck disable=SC2034
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
REPOSITORY_TEST_ROOT="$(mktemp -d)"
trap '[[ "$REPOSITORY_TEST_ROOT" == /tmp/* ]] && rm -rf -- "$REPOSITORY_TEST_ROOT"' EXIT
SERVER_TOOLKIT_APT_SOURCES_DIR="$REPOSITORY_TEST_ROOT/sources"
SERVER_TOOLKIT_APT_KEYRING_DIR="$REPOSITORY_TEST_ROOT/keyrings"
SERVER_TOOLKIT_SHARE_KEYRING_DIR="$REPOSITORY_TEST_ROOT/share-keyrings"
OS_ID=debian
OS_NAME='Debian test'
OS_CODENAME=bookworm
ARCH=amd64

. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/features/software/repositories/state.sh"
. "$ROOT_DIR/src/features/software/repositories/docker.sh"

command_exists() { case "$1" in gpg|od) return 0 ;; *) return 1 ;; esac; }
gpg() {
  local key_file="${!#}"
  grep -aFq 'VALID-KEY' "$key_file"
}

mkdir -p "$SERVER_TOOLKIT_APT_SOURCES_DIR" "$SERVER_TOOLKIT_APT_KEYRING_DIR" "$SERVER_TOOLKIT_SHARE_KEYRING_DIR"
[[ "$(software_repository_status docker_official)" == "missing" ]] || {
  printf 'FAIL: 空目录没有识别为未配置仓库\n' >&2
  exit 1
}

docker_key="$(software_repository_key_file docker_official)"
docker_source="$(software_repository_source_file docker_official)"
printf 'test-key\n' >"$docker_key"
printf '%s\n' \
  '# Managed by Server Toolkit' \
  'Types: deb' \
  'URIs: https://download.docker.com/linux/debian' \
  'Suites: bookworm' \
  'Components: stable' \
  'Architectures: amd64' \
    "Signed-By: $docker_key" >"$docker_source"
[[ "$(software_repository_status docker_official)" == "incomplete" ]] || {
  printf 'FAIL: 无效 Docker PGP 密钥被误判为配置完整\n' >&2
  exit 1
}
printf '%s\n' \
  '-----BEGIN PGP PUBLIC KEY BLOCK-----' \
  'VALID-KEY-OLD' \
  '-----END PGP PUBLIC KEY BLOCK-----' >"$docker_key"
[[ "$(software_repository_status docker_official)" == "configured" ]] || {
  printf 'FAIL: 有效 Docker DEB822 仓库没有通过验证\n' >&2
  exit 1
}

printf 'Types: deb\n' >"$docker_source"
[[ "$(software_repository_status docker_official)" == "incomplete" ]] || {
  printf 'FAIL: 不完整 Docker 仓库没有被识别\n' >&2
  exit 1
}
rm -f -- "$docker_source" "$docker_key"
if ln -s /etc/passwd "$docker_source" 2>/dev/null; then
  [[ "$(software_repository_status docker_official)" == "unsafe" ]] || {
    printf 'FAIL: Docker 仓库符号链接没有被拒绝\n' >&2
    exit 1
  }
  rm -f -- "$docker_source"
fi

caddy_key="$(software_repository_key_file caddy_official)"
caddy_source="$(software_repository_source_file caddy_official)"
printf 'test-key\n' >"$caddy_key"
printf 'deb [signed-by=%s] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main\n' \
  "$caddy_key" >"$caddy_source"
[[ "$(software_repository_status caddy_official)" == "incomplete" ]] || {
  printf 'FAIL: 无效 Caddy PGP 密钥被误判为配置完整\n' >&2
  exit 1
}
printf '\231VALID-KEY\n' >"$caddy_key"
[[ "$(software_repository_status caddy_official)" == "configured" ]] || {
  printf 'FAIL: 有效 Caddy 仓库没有通过验证\n' >&2
  exit 1
}

printf '%s\n' \
  '-----BEGIN PGP PUBLIC KEY BLOCK-----' \
  'VALID-KEY-OLD' \
  '-----END PGP PUBLIC KEY BLOCK-----' >"$docker_key"
printf '%s\n' \
  '# Managed by Server Toolkit' \
  'Types: deb' \
  'URIs: https://download.docker.com/linux/debian' \
  'Suites: bookworm' \
  'Components: stable' \
  'Architectures: amd64' \
  "Signed-By: $docker_key" >"$docker_source"
DRY_RUN=0
CURL_CALLS=0
backup_file() { :; }
curl() {
  local output=""
  CURL_CALLS=$((CURL_CALLS + 1))
  while (($# > 0)); do
    if [[ "$1" == "-o" ]]; then output="$2"; shift 2; else shift; fi
  done
  [[ -n "$output" ]] || return 1
  printf '%s\n' \
    '-----BEGIN PGP PUBLIC KEY BLOCK-----' \
    'VALID-KEY-NEW' \
    '-----END PGP PUBLIC KEY BLOCK-----' >"$output"
}
software_configure_docker_repository >/dev/null
[[ "$CURL_CALLS" -eq 0 ]] || {
  printf 'FAIL: 完整仓库在普通检查中被无故重写\n' >&2
  exit 1
}
software_configure_docker_repository 1 >/dev/null
if [[ "$CURL_CALLS" -ne 1 ]] || ! grep -Fq 'VALID-KEY-NEW' "$docker_key"; then
  printf 'FAIL: 强制修复没有重新获取 Docker 官方密钥\n' >&2
  exit 1
fi

printf 'PASS: repository sources\n'
