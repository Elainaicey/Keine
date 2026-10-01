#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT_DIR"

mapfile -t shell_files < <(
  while IFS= read -r file; do
    [[ -e "$file" || -L "$file" ]] || continue
    case "$file" in
      install.sh|*.sh|bin/keine) printf '%s\n' "$file" ;;
    esac
  done < <(git ls-files --cached --others --exclude-standard | LC_ALL=C sort -u)
)
(( ${#shell_files[@]} > 0 )) || {
  printf 'FAIL: 没有找到 Shell 文件\n' >&2
  exit 1
}

printf '[shell] Bash 语法（%s 个文件）\n' "${#shell_files[@]}"
for file in "${shell_files[@]}"; do
  bash -n "$file"
done

if command -v shellcheck >/dev/null 2>&1; then
  printf '[shell] 逐文件 ShellCheck\n'
  shellcheck_status=0
  for file in "${shell_files[@]}"; do
    # SC1090/SC1091: 入口根据运行时 ROOT_DIR 加载项目文件。
    shellcheck -e SC1090,SC1091 "$file" || shellcheck_status=1
  done
  (( shellcheck_status == 0 )) || exit 1
elif [[ "${REQUIRE_SHELLCHECK:-0}" == "1" ]]; then
  printf 'FAIL: 当前检查要求 ShellCheck，但系统中没有该命令\n' >&2
  exit 1
else
  printf '[shell] 未安装 ShellCheck，仅跳过本地静态分析\n'
fi

printf 'PASS: shell (%s)\n' "${#shell_files[@]}"
