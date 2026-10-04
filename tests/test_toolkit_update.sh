#!/usr/bin/env bash
# Only fixture installations are replaced; no network or privileged writes.
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/core/navigation.sh"
. "$ROOT_DIR/src/features/maintenance.sh"
TEST_UPDATE_ROOT="$(mktemp -d)"
export TEST_UPDATE_ROOT
trap 'rm -rf -- "$TEST_UPDATE_ROOT"' EXIT
ROOT_DIR="$TEST_UPDATE_ROOT/install"
mkdir -p "$ROOT_DIR/bin"
KEINE_VERSION=0.6.1
test_latest=0.6.2
test_answer=''
confirm_result=0
download_failure=0
export INSTALL_FAILURE=0 ACTUAL_VERSION=0.6.2
require_root() { :; }
toolkit_remote_version() { printf '%s' "$test_latest"; }
confirm() { return "$confirm_result"; }
read_input() { printf '%s' "$test_answer"; }
audit() { printf '%s\n' "$*" >>"$TEST_UPDATE_ROOT/audit"; }
curl() {
  (( download_failure == 0 )) || return 28
  while (( $# > 0 )); do
    if [[ "$1" == -o ]]; then cp "$TEST_UPDATE_ROOT/installer" "$2"; return; fi
    shift
  done
  return 1
}
cat >"$TEST_UPDATE_ROOT/entry" <<'ENTRY'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" >"$TEST_UPDATE_ROOT/reload-args"
pwd -P >"$TEST_UPDATE_ROOT/reload-cwd"
cat "$TEST_UPDATE_ROOT/install/VERSION" >"$TEST_UPDATE_ROOT/loaded-version"
printf 'new-runtime\n' >"$TEST_UPDATE_ROOT/loaded-code"
ENTRY
cat >"$TEST_UPDATE_ROOT/installer" <<'INSTALLER'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" >"$TEST_UPDATE_ROOT/installer-args"
[[ "$INSTALL_FAILURE" == 0 ]] || exit 19
fixture_dir=''
preview=0
while (( $# > 0 )); do
  case "$1" in
    --dir) fixture_dir="$2"; shift 2 ;;
    --ref|--bin) shift 2 ;;
    --dry-run) preview=1; shift ;;
    *) exit 2 ;;
  esac
done
(( preview == 0 )) || exit 0
[[ "$fixture_dir" == "$TEST_UPDATE_ROOT/install" ]] || exit 3
printf '%s\n' "$ACTUAL_VERSION" >"$fixture_dir/VERSION"
cp "$TEST_UPDATE_ROOT/entry" "$fixture_dir/bin/keine"
INSTALLER

# Interactive success replaces the process and loads fresh code, retaining options.
NO_COLOR=1
(
  toolkit_self_update menu
  printf 'stale\n' >"$TEST_UPDATE_ROOT/stale-menu"
) >"$TEST_UPDATE_ROOT/output"
[[ "$(<"$TEST_UPDATE_ROOT/loaded-version")" == 0.6.2 ]]
[[ "$(<"$TEST_UPDATE_ROOT/loaded-code")" == new-runtime ]]
[[ "$(<"$TEST_UPDATE_ROOT/reload-args")" == $'--no-color\nmenu' ]]
[[ "$(<"$TEST_UPDATE_ROOT/reload-cwd")" == "$(cd "$ROOT_DIR" && pwd -P)" ]]
[[ ! -e "$TEST_UPDATE_ROOT/stale-menu" ]]
grep -q 'from=0.6.1 to=0.6.2' "$TEST_UPDATE_ROOT/audit"

reset_reload() {
  rm -f "$TEST_UPDATE_ROOT/reload-args" "$TEST_UPDATE_ROOT/loaded-version" "$TEST_UPDATE_ROOT/loaded-code" "$TEST_UPDATE_ROOT/audit"
}
reset_reload
# Same-version redeployment must also reload: code can change without a version bump.
KEINE_VERSION=0.6.2
(
  toolkit_self_update menu
  printf stale >"$TEST_UPDATE_ROOT/stale-menu"
) >/dev/null
[[ -f "$TEST_UPDATE_ROOT/loaded-code" && ! -e "$TEST_UPDATE_ROOT/stale-menu" ]]
reset_reload

# Q closes the old console; command-line mode never opens a menu.
test_answer=Q
(
  toolkit_self_update menu
  printf stale >"$TEST_UPDATE_ROOT/stale-menu"
) >/dev/null
[[ ! -e "$TEST_UPDATE_ROOT/loaded-code" && ! -e "$TEST_UPDATE_ROOT/stale-menu" ]]
test_answer=''
ACTUAL_VERSION=0.6.3
toolkit_self_update >"$TEST_UPDATE_ROOT/output"
[[ ! -e "$TEST_UPDATE_ROOT/loaded-code" ]]
grep -q 'to=0.6.3' "$TEST_UPDATE_ROOT/audit"
grep -q '0.6.3' "$TEST_UPDATE_ROOT/output"
reset_reload
ACTUAL_VERSION=0.6.2

DRY_RUN=1
toolkit_self_update menu >"$TEST_UPDATE_ROOT/output"
grep -qx -- --dry-run "$TEST_UPDATE_ROOT/installer-args"
[[ "$(<"$ROOT_DIR/VERSION")" == 0.6.3 && ! -e "$TEST_UPDATE_ROOT/loaded-code" && ! -e "$TEST_UPDATE_ROOT/audit" ]]
if grep -q '已更新' "$TEST_UPDATE_ROOT/output"; then die 'Preview reported an update'; fi
DRY_RUN=0
confirm_result=1
toolkit_self_update menu >/dev/null
[[ ! -e "$TEST_UPDATE_ROOT/loaded-code" ]]
confirm_result=0
download_failure=1
if toolkit_self_update menu >/dev/null 2>&1; then die 'Failed download accepted'; fi
download_failure=0
INSTALL_FAILURE=1
if toolkit_self_update menu >/dev/null 2>&1; then die 'Failed install accepted'; fi
[[ ! -e "$TEST_UPDATE_ROOT/loaded-code" && "$(<"$ROOT_DIR/VERSION")" == 0.6.3 ]]
INSTALL_FAILURE=0

# Invalid installed metadata must end the old console instead of resuming it.
ACTUAL_VERSION=invalid
if (
  toolkit_self_update menu
  printf stale >"$TEST_UPDATE_ROOT/stale-menu"
) >/dev/null 2>&1; then die 'Invalid installed version accepted'; fi
[[ ! -e "$TEST_UPDATE_ROOT/stale-menu" && ! -e "$TEST_UPDATE_ROOT/loaded-code" ]]

# Entering update through the real menu must also replace the old console.
menu_calls=0
ui_read_choice() {
  menu_calls=$((menu_calls+1))
  if (( menu_calls == 1 )); then printf -v "$1" 3; else printf -v "$1" 0; fi
}
ACTUAL_VERSION=0.6.2
(
  toolkit_menu
  printf stale >"$TEST_UPDATE_ROOT/stale-menu"
) >/dev/null
[[ -f "$TEST_UPDATE_ROOT/loaded-code" && ! -e "$TEST_UPDATE_ROOT/stale-menu" ]]
printf 'PASS: self-update reload, cancellation, preview and failure handling\n'
