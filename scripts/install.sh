#!/usr/bin/env bash
# shellcheck shell=bash
set -Eeuo pipefail
IFS=$'\n\t'

REPOSITORY="${SERVER_TOOLKIT_REPO:-Elainaicey/server-toolkit}"
REF="${SERVER_TOOLKIT_REF:-main}"
INSTALL_DIR="${SERVER_TOOLKIT_INSTALL_DIR:-/opt/server-toolkit}"
BIN_PATH="${SERVER_TOOLKIT_BIN_PATH:-/usr/local/bin/serverctl}"
DRY_RUN=0
UNINSTALL=0
PURGE_DATA=0
TEMP_ROOT=""
STAGE_DIR=""
BACKUP_ROOT="${SERVER_TOOLKIT_BACKUP_ROOT:-/var/backups/server-toolkit}"
DOCKER_BACKUP_ROOT="${SERVER_TOOLKIT_DOCKER_BACKUP_ROOT:-/var/backups/server-toolkit-docker}"
LOG_ROOT="${SERVER_TOOLKIT_LOG_ROOT:-/var/log/server-toolkit}"
STATE_ROOT="${SERVER_TOOLKIT_STATE_ROOT:-/var/lib/server-toolkit}"

usage() {
  cat <<EOF
Server Toolkit 安装器

用法：
  sudo bash install.sh [选项]

选项：
  --repo OWNER/REPO     源码仓库，默认 $REPOSITORY
  --ref REF             分支或标签，默认 $REF
  --dir PATH            安装目录，默认 $INSTALL_DIR
  --bin PATH            命令入口，默认 $BIN_PATH
  --dry-run             只显示将要执行的安装或卸载
  --uninstall           卸载程序文件，默认保留操作日志和配置备份
  --purge-data          卸载时同时删除本项目的日志、备份和状态数据
  -h, --help            显示帮助
EOF
}

info() { printf '[安装器] %s\n' "$*"; }
die() { printf '[安装器][错误] %s\n' "$*" >&2; exit 1; }

read_tty() {
  local prompt="$1" answer=""
  if [[ -t 0 ]]; then
    read -r -p "$prompt" answer || true
  elif [[ -t 2 && -r /dev/tty ]]; then
    read -r -p "$prompt" answer </dev/tty || true
  fi
  printf '%s' "$answer"
}

confirm() {
  local answer
  answer="$(read_tty "$1 [y/N]: ")"
  [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ || "$answer" == "是" || "$answer" == "确认" ]]
}

safe_install_path() {
  local path="$1"
  [[ "$path" == /* ]] || return 1
  [[ "$path" != */ && "$path" != *//* && "$path" != *[[:cntrl:]]* ]] || return 1
  [[ "$path" != *'/../'* && "$path" != */.. && "$path" != *'/./'* && "$path" != */. ]] || return 1
  case "$path" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      return 1
      ;;
  esac
  [[ "${path#/}" == */* ]]
}

safe_toolkit_data_path() {
  local path="$1" component
  local components=()
  safe_install_path "$path" || return 1
  IFS='/' read -r -a components <<<"${path#/}"
  for component in "${components[@]}"; do
    case "$component" in
      server-toolkit|server-toolkit-*) return 0 ;;
    esac
  done
  return 1
}

normalized_link_target() {
  local link="$1" target
  [[ -L "$link" ]] || return 1
  target="$(readlink "$link")" || return 1
  if [[ "$target" != /* ]]; then
    target="$(dirname -- "$link")/$target"
  fi
  readlink -m -- "$target"
}

source_archive_root() {
  local archive="$1" listing="$2" verbose="$3" roots
  tar -tzf "$archive" >"$listing" || return 1
  awk '
    {
      name=$0
      sub(/^\.\//, "", name)
      if (name == "" || name ~ /^\// || name == ".." || name ~ /(^|\/)\.\.(\/|$)/) {
        failed=1
      }
    }
    END {exit failed}
  ' "$listing" || return 1
  (( $(wc -l <"$listing") <= 5000 )) || return 1
  LC_ALL=C tar -tvzf "$archive" >"$verbose" || return 1
  awk 'substr($1,1,1) != "-" && substr($1,1,1) != "d" {bad=1} END {exit bad}' "$verbose" || return 1
  awk '$3 ~ /^[0-9]+$/ {total += $3} END {exit total > 268435456}' "$verbose" || return 1
  roots="$(awk -F/ 'NF && $1 != "" {print $1}' "$listing" | LC_ALL=C sort -u)"
  [[ -n "$roots" && "$roots" != *$'\n'* && "$roots" =~ ^[a-zA-Z0-9._-]+$ ]] || return 1
  printf '%s' "$roots"
}

is_toolkit_dir() {
  local path="$1"
  [[ -f "$path/bin/serverctl" && -d "$path/src/core" && -d "$path/src/features" && -f "$path/config/software.tsv" && -f "$path/VERSION" ]]
}

cleanup() {
  if [[ -n "$STAGE_DIR" && -d "$STAGE_DIR" ]]; then
    rm -rf -- "$STAGE_DIR"
  fi
  if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" ]]; then
    rm -rf -- "$TEMP_ROOT"
  fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) [[ -n "${2:-}" ]] || die "--repo 缺少值"; REPOSITORY="$2"; shift 2 ;;
    --ref) [[ -n "${2:-}" ]] || die "--ref 缺少值"; REF="$2"; shift 2 ;;
    --dir) [[ -n "${2:-}" ]] || die "--dir 缺少值"; INSTALL_DIR="$2"; shift 2 ;;
    --bin) [[ -n "${2:-}" ]] || die "--bin 缺少值"; BIN_PATH="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge-data) PURGE_DATA=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ "$PURGE_DATA" -eq 0 || "$UNINSTALL" -eq 1 ]] || die "--purge-data 只能和 --uninstall 一起使用"

[[ "$EUID" -eq 0 ]] || die "请使用 root 运行：sudo bash install.sh"
safe_install_path "$INSTALL_DIR" || die "不安全的安装目录：$INSTALL_DIR"
if ! safe_install_path "$BIN_PATH" || [[ -d "$BIN_PATH" ]]; then
  die "命令入口必须是安全的绝对文件路径：$BIN_PATH"
fi
[[ ! -L "$INSTALL_DIR" ]] || die "安装目录不能是符号链接：$INSTALL_DIR"

if [[ "$UNINSTALL" -eq 1 ]]; then
  if [[ -d "$INSTALL_DIR" ]]; then
    is_toolkit_dir "$INSTALL_DIR" || die "目录不像 Server Toolkit，拒绝删除：$INSTALL_DIR"
  fi
  if [[ "$PURGE_DATA" -eq 1 ]]; then
    safe_toolkit_data_path "$BACKUP_ROOT" || die "不安全的备份目录：$BACKUP_ROOT"
    safe_toolkit_data_path "$DOCKER_BACKUP_ROOT" || die "不安全的 Docker 卷备份目录：$DOCKER_BACKUP_ROOT"
    safe_toolkit_data_path "$LOG_ROOT" || die "不安全的日志目录：$LOG_ROOT"
    safe_toolkit_data_path "$STATE_ROOT" || die "不安全的状态目录：$STATE_ROOT"
    info "彻底清除会删除："
    info "  程序：$INSTALL_DIR"
    info "  命令：$BIN_PATH"
    info "  备份：$BACKUP_ROOT"
    info "  Docker 卷备份：$DOCKER_BACKUP_ROOT"
    info "  日志：$LOG_ROOT"
    info "  状态：$STATE_ROOT"
    info "已安装的软件和系统配置不会自动删除。"
    confirm "确认彻底清除 Server Toolkit 自身文件和数据？" || { info "已取消。"; exit 0; }
  else
    confirm "删除 $INSTALL_DIR 和它的命令入口？日志与备份将保留。" || { info "已取消。"; exit 0; }
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "将删除 $INSTALL_DIR"
    info "若 $BIN_PATH 指向本项目，也将删除该链接"
    if [[ "$PURGE_DATA" -eq 1 ]]; then
      info "将删除 $BACKUP_ROOT、$DOCKER_BACKUP_ROOT、$LOG_ROOT 和 $STATE_ROOT"
    fi
    exit 0
  fi
  resolved_bin="$(normalized_link_target "$BIN_PATH" 2>/dev/null || true)"
  expected_bin="$(readlink -m -- "$INSTALL_DIR/bin/serverctl")"
  if [[ "$resolved_bin" == "$expected_bin" ]]; then
    rm -f -- "$BIN_PATH"
  fi
  if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf -- "$INSTALL_DIR"
  fi
  if [[ "$PURGE_DATA" -eq 1 ]]; then
    rm -rf -- "$BACKUP_ROOT" "$LOG_ROOT" "$STATE_ROOT"
    rm -rf -- "$DOCKER_BACKUP_ROOT"
    info "彻底清除完成；软件和系统配置保持现状。"
  else
    info "卸载完成；$BACKUP_ROOT、$DOCKER_BACKUP_ROOT 与 $LOG_ROOT 未被删除。"
  fi
  exit 0
fi

if [[ -e "$BIN_PATH" && ! -L "$BIN_PATH" ]]; then
  die "命令入口已经存在且不是符号链接：$BIN_PATH"
fi
if [[ -L "$BIN_PATH" ]]; then
  current_target="$(normalized_link_target "$BIN_PATH" 2>/dev/null || true)"
  expected_target="$(readlink -m -- "$INSTALL_DIR/bin/serverctl")"
  [[ "$current_target" == "$expected_target" ]] || die "命令入口指向其他程序：$BIN_PATH"
fi
if [[ -d "$INSTALL_DIR" ]]; then
  is_toolkit_dir "$INSTALL_DIR" || die "现有目录不属于 Server Toolkit：$INSTALL_DIR"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SOURCE_DIR=""
if is_toolkit_dir "$(dirname -- "$SCRIPT_DIR")"; then
  SOURCE_DIR="$(dirname -- "$SCRIPT_DIR")"
else
  command -v curl >/dev/null 2>&1 || die "缺少 curl"
  command -v tar >/dev/null 2>&1 || die "缺少 tar"
  TEMP_ROOT="$(mktemp -d)"
  archive="$TEMP_ROOT/source.tar.gz"
  archive_listing="$TEMP_ROOT/source.list"
  archive_verbose="$TEMP_ROOT/source.verbose"
  info "下载 $REPOSITORY@$REF"
  branch_url="https://github.com/$REPOSITORY/archive/refs/heads/$REF.tar.gz"
  tag_url="https://github.com/$REPOSITORY/archive/refs/tags/$REF.tar.gz"
  if ! curl --disable -fsSL --retry 3 --connect-timeout 10 --max-time 120 --max-filesize 134217728 "$branch_url" -o "$archive"; then
    curl --disable -fsSL --retry 3 --connect-timeout 10 --max-time 120 --max-filesize 134217728 "$tag_url" -o "$archive" ||
      die "下载源码失败"
  fi
  archive_root="$(source_archive_root "$archive" "$archive_listing" "$archive_verbose")" ||
    die "源码归档结构或文件类型不安全"
  tar -xzf "$archive" -C "$TEMP_ROOT"
  SOURCE_DIR="$TEMP_ROOT/$archive_root"
fi

is_toolkit_dir "$SOURCE_DIR" || die "源码结构不完整"
[[ "$SOURCE_DIR" != "$INSTALL_DIR" ]] || die "不能把项目安装到源码目录自身"

confirm "将 Server Toolkit 安装到 $INSTALL_DIR？已有安装会被完整替换。" || { info "已取消。"; exit 0; }
if [[ "$DRY_RUN" -eq 1 ]]; then
  info "将完整替换 $INSTALL_DIR"
  info "将创建命令入口 $BIN_PATH -> $INSTALL_DIR/bin/serverctl"
  exit 0
fi

parent_dir="$(dirname -- "$INSTALL_DIR")"
mkdir -p "$parent_dir" "$(dirname -- "$BIN_PATH")"
STAGE_DIR="$(mktemp -d "$parent_dir/.server-toolkit-stage.XXXXXX")"
for entry in bin src config docs scripts install.sh VERSION README.md LICENSE; do
  if [[ -e "$SOURCE_DIR/$entry" ]]; then
    cp -a "$SOURCE_DIR/$entry" "$STAGE_DIR/"
  fi
done
mkdir -p "$STAGE_DIR/.github"
for entry in assets CONTRIBUTING.md SECURITY.md; do
  if [[ -e "$SOURCE_DIR/.github/$entry" ]]; then
    cp -a "$SOURCE_DIR/.github/$entry" "$STAGE_DIR/.github/"
  fi
done
chmod 0755 "$STAGE_DIR/bin/serverctl" "$STAGE_DIR/install.sh" "$STAGE_DIR/scripts/install.sh"
find "$STAGE_DIR/src" -type f -name '*.sh' -exec chmod 0644 {} \;
{
  printf 'SERVER_TOOLKIT_INSTALL_DIR=%q\n' "$INSTALL_DIR"
  printf 'SERVER_TOOLKIT_BIN_PATH=%q\n' "$BIN_PATH"
  printf 'SERVER_TOOLKIT_BACKUP_ROOT=%q\n' "$BACKUP_ROOT"
  printf 'SERVER_TOOLKIT_DOCKER_BACKUP_ROOT=%q\n' "$DOCKER_BACKUP_ROOT"
  printf 'SERVER_TOOLKIT_LOG_ROOT=%q\n' "$LOG_ROOT"
  printf 'SERVER_TOOLKIT_STATE_ROOT=%q\n' "$STATE_ROOT"
} >"$STAGE_DIR/config/installation.conf"
chmod 0644 "$STAGE_DIR/config/installation.conf"
is_toolkit_dir "$STAGE_DIR" || die "暂存的安装内容不完整"

old_dir=""
if [[ -d "$INSTALL_DIR" ]]; then
  old_dir="$parent_dir/.server-toolkit-old.$$"
  mv "$INSTALL_DIR" "$old_dir"
fi
if ! mv "$STAGE_DIR" "$INSTALL_DIR"; then
  if [[ -n "$old_dir" && -d "$old_dir" ]]; then
    mv "$old_dir" "$INSTALL_DIR"
  fi
  die "替换安装目录失败，旧版本已恢复"
fi
STAGE_DIR=""
if ! ln -sfn "$INSTALL_DIR/bin/serverctl" "$BIN_PATH"; then
  failed_dir="$parent_dir/.server-toolkit-failed.$$"
  mv "$INSTALL_DIR" "$failed_dir"
  if [[ -n "$old_dir" && -d "$old_dir" ]]; then
    mv "$old_dir" "$INSTALL_DIR"
  fi
  rm -rf -- "$failed_dir"
  die "创建命令入口失败，旧版本已恢复"
fi
if [[ -n "$old_dir" && -d "$old_dir" ]]; then
  rm -rf -- "$old_dir"
fi

info "安装完成：sudo serverctl"
