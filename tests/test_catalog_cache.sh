#!/usr/bin/env bash
# 命令测试替身由软件目录快照间接调用。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
CACHE_TEST_ROOT="$(mktemp -d)"
trap '[[ "$CACHE_TEST_ROOT" == /tmp/* ]] && rm -rf -- "$CACHE_TEST_ROOT"' EXIT
CONFIG_DIR="$CACHE_TEST_ROOT"
SERVER_TOOLKIT_CATALOG="$CACHE_TEST_ROOT/software.tsv"
CALL_LOG="$CACHE_TEST_ROOT/calls"
printf '%s\n' \
  'one|测试|One|fixture|one|' \
  'two|测试|Two|fixture|two|' >"$SERVER_TOOLKIT_CATALOG"

command_exists() { case "$1" in dpkg-query|apt|apt-cache) return 0 ;; *) return 1 ;; esac; }
dpkg-query() {
  printf 'dpkg-query\n' >>"$CALL_LOG"
  printf '%s\n' 'one|1.0'
}
apt() {
  printf 'apt\n' >>"$CALL_LOG"
  printf 'apt-locale=%s\n' "${LC_ALL:-unset}" >>"$CALL_LOG"
  [[ "${LC_ALL:-}" == "C" ]] || { printf '%s\n' '正在列表…'; return 0; }
  printf '%s\n' 'Listing...' 'one/stable 2.0 amd64 [upgradable from: 1.0]'
}
apt-cache() {
  local package
  printf 'apt-cache\n' >>"$CALL_LOG"
  printf 'apt-cache-locale=%s\n' "${LC_ALL:-unset}" >>"$CALL_LOG"
  shift
  [[ "${LC_ALL:-}" == "C" ]] || { printf '%s\n' '  候选：3.0'; return 0; }
  for package in "$@"; do
    printf '%s:\n  Installed: %s\n  Candidate: %s\n' "$package" \
      "$([[ "$package" == one ]] && printf '1.0' || printf '(none)')" \
      "$([[ "$package" == one ]] && printf '2.0' || printf '3.0')"
  done
}

. "$ROOT_DIR/src/features/software/catalog/cache.sh"
catalog_cache_build
catalog_cache_package_installed one || { printf 'FAIL: 快照未识别已安装包\n' >&2; exit 1; }
[[ "$(catalog_cache_installed_version one)" == 1.0 ]] || { printf 'FAIL: 安装版本快照错误\n' >&2; exit 1; }
[[ "$(catalog_cache_candidate_version two)" == 3.0 ]] || { printf 'FAIL: 候选版本快照错误\n' >&2; exit 1; }
catalog_cache_package_has_update one || { printf 'FAIL: 快照未识别可更新包\n' >&2; exit 1; }
catalog_cache_build
[[ "$(grep -c '^dpkg-query$' "$CALL_LOG")" -eq 1 && "$(grep -c '^apt-cache$' "$CALL_LOG")" -eq 1 ]] || {
  printf 'FAIL: 同一页面重复构建软件状态快照\n' >&2
  exit 1
}
if ! grep -Fqx 'apt-locale=C' "$CALL_LOG" || ! grep -Fqx 'apt-cache-locale=C' "$CALL_LOG"; then
  printf 'FAIL: APT 快照解析没有固定为稳定的 C locale\n' >&2
  exit 1
fi
catalog_cache_invalidate
[[ "$CATALOG_CACHE_READY" -eq 0 ]] || { printf 'FAIL: 软件变更后快照未失效\n' >&2; exit 1; }

printf 'PASS: catalog cache\n'
