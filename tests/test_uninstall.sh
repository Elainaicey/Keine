#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
INSTALLER="$ROOT_DIR/scripts/install.sh"

if grep -q 'confirm "将 keine 安装到' "$INSTALLER"; then
  printf 'FAIL: 安装仍有重复确认\n' >&2; exit 1
fi
[[ "$(grep -c '^    confirm ' "$INSTALLER")" == 2 ]] || {
  printf 'FAIL: 移除安装确认时影响了卸载确认\n' >&2; exit 1
}

bash "$INSTALLER" --help | grep -q -- '--purge-data' || {
  printf 'FAIL: 卸载器帮助缺少彻底清除选项\n' >&2
  exit 1
}
# 匹配安装器源码中的字面量变量名，不应在测试进程中展开。
# shellcheck disable=SC2016
grep -Fq 'rm -rf -- "$BACKUP_ROOT" "$LOG_ROOT" "$STATE_ROOT"' "$INSTALLER" || {
  printf 'FAIL: 彻底清除没有覆盖全部项目数据目录\n' >&2
  exit 1
}
# shellcheck disable=SC2016
grep -Fq 'rm -rf -- "$DOCKER_BACKUP_ROOT"' "$INSTALLER" || {
  printf 'FAIL: 彻底清除没有覆盖 Docker 卷备份目录\n' >&2
  exit 1
}
# 安装器独立运行，必须保留自己的递归删除路径归属校验。
# shellcheck disable=SC2016
if ! grep -Fq 'safe_toolkit_data_path "$BACKUP_ROOT"' "$INSTALLER" ||
  ! grep -Fq 'safe_toolkit_data_path "$DOCKER_BACKUP_ROOT"' "$INSTALLER"; then
  printf 'FAIL: 彻底清除缺少项目数据路径归属校验\n' >&2
  exit 1
fi
grep -Fq 'normalized_link_target()' "$INSTALLER" || {
  printf 'FAIL: 安装器缺少悬空命令链接的安全解析\n' >&2
  exit 1
}
grep -Fq 'source_archive_root()' "$INSTALLER" || {
  printf 'FAIL: 安装器缺少源码归档结构检查\n' >&2
  exit 1
}
# shellcheck disable=SC2016
grep -Fq 'exec bash "$installer" --uninstall --purge-data --dir "$ROOT_DIR" --bin "$bin_path"' "$ROOT_DIR/src/features/maintenance.sh" || {
  printf 'FAIL: 交互菜单没有连接彻底清除流程\n' >&2
  exit 1
}

printf 'PASS: uninstall\n'
