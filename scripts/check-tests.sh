#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT_DIR"

test_files=()
if [[ "${1:-}" == --changed ]]; then
  [[ $# == 2 ]] || { printf '用法：check-tests.sh --changed COMMIT\n' >&2; exit 1; }
  base="$(git rev-parse --verify "$2^{commit}")" || exit 1
  selected=()
  all_needed=0
  while IFS= read -r path; do
    case "$path" in
      tests/test_*.sh)
        name="${path#tests/test_}"; name="${name%.sh}"
        [[ ! -f "$path" ]] || selected+=("$name") ;;
      src/integrations/network-tuning.sh|src/integrations/network-tuning/*)
        selected+=(tuning_strategies tuning_runtime native_recovery cli on_demand) ;;
      src/features/recovery.sh)
        selected+=(native_recovery tuning_strategies tuning_runtime node_network) ;;
      src/features/maintenance.sh|src/features/maintenance/menu.sh)
        selected+=(toolkit_update toolkit_doctor uninstall cli on_demand) ;;
      scripts/check-tests.sh|.github/workflows/ci.yml)
        selected+=(cli on_demand) ;;
      src/*|bin/*|scripts/*|install.sh|config/*) all_needed=1 ;;
    esac
  done < <(git diff --name-only "$base" HEAD)
  if (( all_needed == 0 )); then
    if (( ${#selected[@]} == 0 )); then printf 'PASS: 此变更无需功能回归\n'; exit 0; fi
    mapfile -t selected < <(printf '%s\n' "${selected[@]}" | LC_ALL=C sort -u)
    set -- "${selected[@]}"
  else
    # Unmapped runtime changes are conservatively treated as cross-cutting.
    set --
  fi
fi
if (( $# > 0 )); then
  for name in "$@"; do
    if [[ ! "$name" =~ ^[a-z0-9_]+$ || ! -f "tests/test_$name.sh" ]]; then
      printf 'FAIL: 未知测试：%s\n' "$name" >&2
      exit 1
    fi
    test_files+=("tests/test_$name.sh")
  done
else
  shopt -s nullglob
  test_files=(tests/test_*.sh)
fi
(( ${#test_files[@]} > 0 )) || {
  printf 'FAIL: 没有可运行的测试\n' >&2
  exit 1
}

printf '[tests] 离线回归（%s 个脚本）\n' "${#test_files[@]}"
for test_file in "${test_files[@]}"; do
  bash "$test_file"
done
printf 'PASS: tests (%s)\n' "${#test_files[@]}"
