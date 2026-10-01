#!/usr/bin/env bash
# Release 安装器通过运行时解析这些测试变量和替身。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
CONFIG_DIR="$TEST_ROOT/config"
STATE_ROOT="$TEST_ROOT/keine"
KEINE_RELEASE_CATALOG="$CONFIG_DIR/official-releases.tsv"
KEINE_RELEASE_STATE_DIR="$STATE_ROOT/releases"
KEINE_RELEASE_BIN_DIR="$TEST_ROOT/bin"
ARCH=amd64

mkdir -p "$CONFIG_DIR" "$KEINE_RELEASE_BIN_DIR"
printf '%s\n' \
  'sample|owner/sample|sample|sample-{version}-linux-amd64.tar.gz|sample-{version}-linux-arm64.tar.gz|https://github.com/owner/sample' \
  >"$KEINE_RELEASE_CATALOG"

. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/features/software/releases.sh"

fixture="$TEST_ROOT/release.json"
cat >"$fixture" <<'EOF'
{
  "tag_name": "v1.2.3",
  "assets": [
    {
      "name": "sample-1.2.3-linux-amd64.tar.gz",
      "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "browser_download_url": "https://github.com/owner/sample/releases/download/v1.2.3/sample-1.2.3-linux-amd64.tar.gz"
    }
  ]
}
EOF

parsed="$(software_release_parse_latest sample "$fixture")"
[[ "$parsed" == '1.2.3|sample-1.2.3-linux-amd64.tar.gz|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|https://github.com/owner/sample/releases/download/v1.2.3/sample-1.2.3-linux-amd64.tar.gz' ]] || {
  printf 'FAIL: 无法解析可信的 GitHub Release 元数据\n' >&2
  exit 1
}
SOFTWARE_RELEASE_LATEST_CACHE["sample"]="$parsed"
software_release_load_latest sample
[[ "$SOFTWARE_RELEASE_LATEST_VERSION" == "1.2.3" &&
  "$SOFTWARE_RELEASE_LATEST_ASSET" == "sample-1.2.3-linux-amd64.tar.gz" ]] || {
  printf 'FAIL: 进程内 Release 元数据缓存错误\n' >&2
  exit 1
}
[[ "$(software_release_asset_name sample 1.2.3)" == 'sample-1.2.3-linux-amd64.tar.gz' ]] || {
  printf 'FAIL: amd64 Release 资产映射错误\n' >&2
  exit 1
}
ARCH=arm64
[[ "$(software_release_asset_name sample 1.2.3)" == 'sample-1.2.3-linux-arm64.tar.gz' ]] || {
  printf 'FAIL: arm64 Release 资产映射错误\n' >&2
  exit 1
}
ARCH=amd64

sed 's/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/sha256:missing/' "$fixture" >"$TEST_ROOT/bad-digest.json"
if software_release_parse_latest sample "$TEST_ROOT/bad-digest.json" >/dev/null 2>&1; then
  printf 'FAIL: 接受了缺少可信 SHA-256 digest 的 Release\n' >&2
  exit 1
fi
sed 's#https://github.com/owner/sample/#https://example.com/owner/sample/#' "$fixture" >"$TEST_ROOT/bad-url.json"
if software_release_parse_latest sample "$TEST_ROOT/bad-url.json" >/dev/null 2>&1; then
  printf 'FAIL: 接受了非项目官方域名的 Release 下载地址\n' >&2
  exit 1
fi

target="$(software_release_target sample)"
version_fixture="$TEST_ROOT/actionlint-version"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' '[[ "$1" == "-version" ]] || exit 1' 'printf "1.7.12\\n"' >"$version_fixture"
chmod 0755 "$version_fixture"
[[ "$(software_release_version_output actionlint "$version_fixture")" == '1.7.12' ]] || {
  printf 'FAIL: actionlint 没有使用其官方 -version 参数\n' >&2
  exit 1
}
archive_root="$TEST_ROOT/archive/sample-1.2.3-linux-amd64"
mkdir -p "$archive_root"
printf '#!/usr/bin/env sh\nprintf "sample 1.2.3\\n"\n' >"$archive_root/sample"
chmod 0755 "$archive_root/sample"
TEST_RELEASE_ARCHIVE="$TEST_ROOT/sample-1.2.3-linux-amd64.tar.gz"
tar -czf "$TEST_RELEASE_ARCHIVE" -C "$TEST_ROOT/archive" sample-1.2.3-linux-amd64
asset_digest="$(sha256sum "$TEST_RELEASE_ARCHIVE" | awk '{print $1}')"
SOFTWARE_RELEASE_LATEST_CACHE["sample"]="1.2.3|sample-1.2.3-linux-amd64.tar.gz|$asset_digest|https://github.com/owner/sample/releases/download/v1.2.3/sample-1.2.3-linux-amd64.tar.gz"
package_install() { :; }
curl() {
  local output=""
  [[ "$1" == "--disable" ]] || return 1
  while (($# > 0)); do
    if [[ "$1" == "-o" ]]; then output="$2"; shift 2; else shift; fi
  done
  [[ -n "$output" ]] || return 1
  cp "$TEST_RELEASE_ARCHIVE" "$output"
}
software_install_release sample
software_release_managed sample || {
  printf 'FAIL: 没有识别可信的 Release 状态记录\n' >&2
  exit 1
}
software_release_integrity sample || {
  printf 'FAIL: 完整的托管二进制没有通过校验\n' >&2
  exit 1
}
printf '# modified\n' >>"$target"
if software_release_integrity sample; then
  printf 'FAIL: 没有识别被修改的托管二进制\n' >&2
  exit 1
fi
if software_remove_release sample >/dev/null 2>&1; then
  printf 'FAIL: 自动删除了完整性异常的托管二进制\n' >&2
  exit 1
fi

# Go yq 的资产内部使用架构名，不可错误匹配同名发行版 Python 工具。
printf '%s\n' 'yq|mikefarah/yq|yq|yq_linux_amd64.tar.gz|yq_linux_arm64.tar.gz|https://github.com/mikefarah/yq' >>"$KEINE_RELEASE_CATALOG"
mkdir -p "$TEST_ROOT/yq-archive"
printf '#!/usr/bin/env sh\nprintf "yq version v4.1.0\\n"\n' >"$TEST_ROOT/yq-archive/yq_linux_amd64"
TEST_RELEASE_ARCHIVE="$TEST_ROOT/yq_linux_amd64.tar.gz"
tar -czf "$TEST_RELEASE_ARCHIVE" -C "$TEST_ROOT/yq-archive" yq_linux_amd64
asset_digest="$(sha256sum "$TEST_RELEASE_ARCHIVE" | awk '{print $1}')"
SOFTWARE_RELEASE_LATEST_CACHE["yq"]="4.1.0|yq_linux_amd64.tar.gz|$asset_digest|https://github.com/mikefarah/yq/releases/download/v4.1.0/yq_linux_amd64.tar.gz"
software_install_release yq
software_release_integrity yq || { printf 'FAIL: Go yq 官方命令部署失败\n' >&2; exit 1; }
[[ "$(software_release_version yq)" == 4.1.0 ]] || exit 1
software_release_latest_invalidate yq
[[ -z "${SOFTWARE_RELEASE_LATEST_CACHE[yq]:-}" ]] || { printf 'FAIL: 显式检查官方更新没有清理旧查询缓存\n' >&2; exit 1; }

printf 'PASS: releases\n'
