#!/usr/bin/env bash
# keine bootstrap installer. The full installer lives in scripts/install.sh.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LOCAL_INSTALLER="$SCRIPT_DIR/scripts/install.sh"
export KEINE_INSTALL_CALLER_CWD="${PWD:-}"
# Child processes must not inherit a directory that this installation replaces.
cd / || exit 1

if [[ -f "$LOCAL_INSTALLER" ]]; then
  exec bash "$LOCAL_INSTALLER" "$@"
fi

REPOSITORY="${KEINE_REPO:-Elainaicey/keine}"
REF="${KEINE_REF:-main}"
TEMP_FILE="$(mktemp "${TMPDIR:-/tmp}/keine-installer.XXXXXX")"
cleanup() { rm -f -- "$TEMP_FILE"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

command -v curl >/dev/null 2>&1 || {
  printf '[安装器][错误] 缺少 curl，无法下载安装器。\n' >&2
  exit 1
}

printf '[安装器] 获取 %s@%s 的安装程序…\n' "$REPOSITORY" "$REF"
curl --disable -fsSL --retry 3 --retry-max-time 180 --connect-timeout 10 --max-time 120 \
  "https://raw.githubusercontent.com/$REPOSITORY/$REF/scripts/install.sh" \
  -o "$TEMP_FILE"
bash -n "$TEMP_FILE" || { printf '[安装器][错误] 下载的安装器不完整，请重试。\n' >&2; exit 1; }
bash "$TEMP_FILE" "$@"
