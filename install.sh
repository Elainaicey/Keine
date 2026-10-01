#!/usr/bin/env bash
# keine bootstrap installer. The full installer lives in scripts/install.sh.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LOCAL_INSTALLER="$SCRIPT_DIR/scripts/install.sh"

if [[ -f "$LOCAL_INSTALLER" ]]; then
  exec bash "$LOCAL_INSTALLER" "$@"
fi

REPOSITORY="${KEINE_REPO:-Elainaicey/keine}"
REF="${KEINE_REF:-main}"
TEMP_FILE="$(mktemp "${TMPDIR:-/tmp}/keine-installer.XXXXXX")"
cleanup() { rm -f -- "$TEMP_FILE"; }
trap cleanup EXIT

command -v curl >/dev/null 2>&1 || {
  printf '[安装器][错误] 缺少 curl，无法下载安装器。\n' >&2
  exit 1
}

printf '[安装器] 获取 %s@%s 的安装程序…\n' "$REPOSITORY" "$REF"
curl --disable -fsSL --retry 3 --connect-timeout 10 --max-time 120 \
  "https://raw.githubusercontent.com/$REPOSITORY/$REF/scripts/install.sh" \
  -o "$TEMP_FILE"
bash "$TEMP_FILE" "$@"
