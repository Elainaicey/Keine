#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT_DIR"

version="$(tr -d '[:space:]' < VERSION)"
tag="${1:-v$version}"
release_notes="docs/releases/$version.md"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'FAIL: VERSION 不是有效的语义版本：%s\n' "$version" >&2
  exit 1
}
[[ "$tag" == "v$version" ]] || {
  printf 'FAIL: 标签 %s 与 VERSION %s 不一致\n' "$tag" "$version" >&2
  exit 1
}
grep -Fqx "## $version" docs/CHANGELOG.md || {
  printf 'FAIL: docs/CHANGELOG.md 缺少 %s 发布章节\n' "$version" >&2
  exit 1
}
[[ -f "$release_notes" ]] || {
  printf 'FAIL: 缺少正式发布说明：%s\n' "$release_notes" >&2
  exit 1
}
grep -Fqx "# keine $version" "$release_notes" || {
  printf 'FAIL: %s 标题与 VERSION 不一致\n' "$release_notes" >&2
  exit 1
}
if ! grep -Fq '## 升级' "$release_notes" ||
  ! grep -Fq '## 兼容性与变更' "$release_notes"; then
  printf 'FAIL: %s 缺少升级或兼容性说明\n' "$release_notes" >&2
  exit 1
fi
grep -Fq 'MIT License' LICENSE || {
  printf 'FAIL: LICENSE 不是预期的 MIT License\n' >&2
  exit 1
}
grep -Fq 'Copyright (c) 2026 Elainaicey' LICENSE || {
  printf 'FAIL: LICENSE 缺少项目版权声明\n' >&2
  exit 1
}

bash scripts/check.sh
printf 'PASS: release %s\n' "$tag"
