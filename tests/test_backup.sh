#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
KEINE_BACKUP_ROOT="$TEST_ROOT/keine/backups"
# 该运行时覆盖值由 core/runtime 读取。
# shellcheck disable=SC2034
KEINE_STATE_ROOT="$TEST_ROOT/keine/state"

. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/core/backup.sh"
. "$ROOT_DIR/src/core/changes.sh"
. "$ROOT_DIR/src/core/configuration.sh"

require_root() { :; }

mkdir -p "$KEINE_BACKUP_ROOT/20260719-120000-42/etc"
printf '/etc/example.conf\n' > "$KEINE_BACKUP_ROOT/20260719-120000-42/manifest.txt"
printf 'original\n' > "$KEINE_BACKUP_ROOT/20260719-120000-42/etc/example.conf"

[[ "$(backup_manifest 20260719-120000-42)" == "/etc/example.conf" ]] || {
  printf 'FAIL: 无法读取有效备份清单\n' >&2
  exit 1
}
backup_verify 20260719-120000-42 >/dev/null || {
  printf 'FAIL: 有效备份没有通过完整性校验\n' >&2
  exit 1
}
if backup_manifest '../etc' >/dev/null 2>&1; then
  printf 'FAIL: 接受了危险快照名\n' >&2
  exit 1
fi
if backup_verify '../etc' >/dev/null 2>&1; then
  printf 'FAIL: 完整性校验接受了危险快照名\n' >&2
  exit 1
fi

for snapshot in 20260720-120000-43 20260721-120000-44 20260722-120000-45; do
  mkdir -p "$KEINE_BACKUP_ROOT/$snapshot/etc"
  printf '/etc/example.conf\n' >"$KEINE_BACKUP_ROOT/$snapshot/manifest.txt"
  printf '%s\n' "$snapshot" >"$KEINE_BACKUP_ROOT/$snapshot/etc/example.conf"
done

BACKUP_SESSION="$KEINE_BACKUP_ROOT/20260720-120000-43"
mapfile -t cleanup_candidates < <(backup_cleanup_keep_candidates 2)
[[ "${#cleanup_candidates[@]}" -eq 1 && "${cleanup_candidates[0]}" == "20260719-120000-42" ]] || {
  printf 'FAIL: 保留数量清理没有保护最新快照或当前会话\n' >&2
  exit 1
}
# backup_cleanup_keep_candidates 从运行时读取当前备份会话。
# shellcheck disable=SC2034
BACKUP_SESSION=""
mapfile -t cleanup_candidates < <(backup_cleanup_keep_candidates 2)
[[ "${#cleanup_candidates[@]}" -eq 2 && "${cleanup_candidates[0]}" == "20260720-120000-43" &&
  "${cleanup_candidates[1]}" == "20260719-120000-42" ]] || {
  printf 'FAIL: 保留最近快照的候选清单错误\n' >&2
  exit 1
}
if backup_cleanup_keep_candidates 0 >/dev/null || backup_cleanup_keep_candidates text >/dev/null; then
  printf 'FAIL: 接受了无效备份保留数量\n' >&2
  exit 1
fi
total_bytes="$(backup_total_bytes)"
if [[ ! "$total_bytes" =~ ^[0-9]+$ ]] || (( total_bytes <= 0 )); then
  printf 'FAIL: 无法统计备份总占用\n' >&2
  exit 1
fi
[[ -n "$(backup_human_bytes "$total_bytes")" ]] || {
  printf 'FAIL: 无法格式化备份占用\n' >&2
  exit 1
}

backup_set_label 20260719-120000-42 "SSH 调整前" >/dev/null
[[ "$(backup_snapshot_label 20260719-120000-42)" == "SSH 调整前" ]] || {
  printf 'FAIL: 无法写入或读取快照备注\n' >&2
  exit 1
}
backup_set_protection 20260719-120000-42 1 >/dev/null
backup_snapshot_protected 20260719-120000-42 || {
  printf 'FAIL: 快照保护标记没有生效\n' >&2
  exit 1
}
mapfile -t cleanup_candidates < <(backup_cleanup_keep_candidates 2)
if printf '%s\n' "${cleanup_candidates[@]}" | grep -Fxq 20260719-120000-42; then
  printf 'FAIL: 批量清理候选包含受保护快照\n' >&2
  exit 1
fi
if (backup_delete 20260719-120000-42 >/dev/null 2>&1); then
  printf 'FAIL: 直接删除接受了受保护快照\n' >&2
  exit 1
fi
backup_set_protection 20260719-120000-42 0 >/dev/null

DRY_RUN=1
backup_restore 20260719-120000-42 /etc/example.conf >/dev/null
backup_delete 20260719-120000-42 >/dev/null
[[ -d "$KEINE_BACKUP_ROOT/20260719-120000-42" ]] || {
  printf 'FAIL: dry-run 删除了备份\n' >&2
  exit 1
}

# backup_delete 从运行时读取该全局开关。
# shellcheck disable=SC2034
DRY_RUN=0
backup_delete 20260719-120000-42
[[ ! -e "$KEINE_BACKUP_ROOT/20260719-120000-42" ]] || {
  printf 'FAIL: 没有删除明确选择的备份\n' >&2
  exit 1
}

# 多次配置修改只保留首次基线，不追加历史快照。
# shellcheck disable=SC2034
CHANGES_ENABLED=1
config_path="$TEST_ROOT/manual.conf"
printf 'original\n' >"$config_path"
snapshot_count="$(backup_snapshots | wc -l)"
config_file_write "$config_path" 0600 first config_no_reload >/dev/null
config_file_write "$config_path" 0600 second config_no_reload >/dev/null
[[ "$(backup_snapshots | wc -l)" == "$snapshot_count" ]] || die '配置修改生成了自动快照'
[[ "$(cat "$(changes_file_entry "$config_path")/original")" == original ]] || die '重复修改覆盖了首次基线'

# 同一进程中主动备份两次，必须形成独立快照；恢复不能再自动另存一份。
backup_begin
first_snapshot="$(backup_active_snapshot)"
backup_file "$config_path" >/dev/null
config_file_write "$config_path" 0600 third config_no_reload >/dev/null
backup_begin
second_snapshot="$(backup_active_snapshot)"
backup_file "$config_path" >/dev/null
[[ "$first_snapshot" != "$second_snapshot" ]] || die '手动备份复用了历史快照'
[[ "$(cat "$BACKUP_ROOT/$first_snapshot$config_path")" == second ]] || die '手动快照内容被覆盖'
# Windows 的 Git Bash 不提供真实的 POSIX 权限；Linux CI 验证保护位。
case "$(uname -s)" in
  MINGW*|MSYS*) : ;;
  *) [[ "$(stat -c '%a' "$BACKUP_ROOT/$first_snapshot")" == 700 ]] || die '手动快照目录未保护' ;;
esac
snapshot_count="$(backup_snapshots | wc -l)"
backup_restore "$first_snapshot" "$config_path" >/dev/null
[[ "$(cat "$config_path")" == second ]] || die '手动快照没有正确恢复'
[[ "$(backup_snapshots | wc -l)" == "$snapshot_count" ]] || die '恢复创建了自动快照'

printf 'PASS: backup\n'
