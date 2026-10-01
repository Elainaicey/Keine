#!/usr/bin/env bash
# Docker 命令由被测 Compose 上下文解析函数间接调用。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/features/apps/docker.sh"

docker_compose_project_valid edge-proxy || {
  printf 'FAIL: 正常 Compose 项目名被拒绝\n' >&2
  exit 1
}
if docker_compose_project_valid '../project' || docker_compose_project_valid 'project;reboot'; then
  printf 'FAIL: 接受了危险 Compose 项目名\n' >&2
  exit 1
fi
docker_container_ref_valid web-01 || {
  printf 'FAIL: 正常容器名称被拒绝\n' >&2
  exit 1
}
if docker_container_ref_valid '../container' || docker_container_ref_valid '--help' ||
  docker_container_ref_valid 'container;reboot'; then
  printf 'FAIL: 接受了危险容器名称\n' >&2
  exit 1
fi

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
touch "$test_root/compose.yml"
docker() {
  if [[ "$1" == "ps" ]]; then
    printf 'container-id\n'
  elif [[ "$1" == "inspect" && "$3" == *working_dir* ]]; then
    printf '%s\n' "$test_root"
  elif [[ "$1" == "inspect" && "$3" == *config_files* ]]; then
    printf '%s\n' "$test_root/compose.yml"
  fi
}

DOCKER_TIMEOUT_FILE="$test_root/docker-timeout"
command_exists() { [[ "$1" == docker ]]; }
runtime_with_timeout() {
  printf '%s:%s:%s' "$1" "$2" "$3" >"$DOCKER_TIMEOUT_FILE"
  shift
  "$@"
}
docker_require || { printf 'FAIL: Docker 测试替身没有被识别\n' >&2; exit 1; }
docker_daemon_ready || { printf 'FAIL: Docker Daemon 短时探测失败\n' >&2; exit 1; }
[[ "$(<"$DOCKER_TIMEOUT_FILE")" == '5:docker:info' ]] || {
  printf 'FAIL: Docker Daemon 探测没有设置 5 秒超时\n' >&2
  exit 1
}

context_output="$(docker_compose_context edge-proxy)"
[[ "$context_output" == "$test_root"$'\n'"$test_root/compose.yml" ]] || {
  printf 'FAIL: Compose 项目上下文解析错误\n' >&2
  exit 1
}

DOCKER_VOLUME_BACKUP_ROOT="$test_root/keine-docker"
backup_id="20260723-120000-42-1234"
mkdir -p "$test_root/volume-source" "$DOCKER_VOLUME_BACKUP_ROOT/$backup_id"
printf 'volume data\n' >"$test_root/volume-source/example.txt"
tar -czf "$DOCKER_VOLUME_BACKUP_ROOT/$backup_id/volume.tar.gz" -C "$test_root/volume-source" .
checksum="$(sha256sum "$DOCKER_VOLUME_BACKUP_ROOT/$backup_id/volume.tar.gz" | awk '{print $1}')"
{
  printf 'format=keine-docker-volume-v1\n'
  printf 'created=2026-07-23T12:00:00+08:00\n'
  printf 'volume=database-data\n'
  printf 'helper_image=alpine:latest\n'
  printf 'reason=manual\n'
  printf 'sha256=%s\n' "$checksum"
} >"$DOCKER_VOLUME_BACKUP_ROOT/$backup_id/metadata"
docker_volume_backup_validate_record "$backup_id" || {
  printf 'FAIL: 正常 Docker 卷备份记录没有通过校验\n' >&2
  exit 1
}
[[ "$(docker_volume_backup_meta "$backup_id" volume)" == "database-data" ]] || {
  printf 'FAIL: 无法读取 Docker 卷备份元数据\n' >&2
  exit 1
}
if docker_volume_backup_valid_id '../backup' || valid_docker_volume_name 'data:/host'; then
  printf 'FAIL: Docker 卷备份接受了危险编号或卷名\n' >&2
  exit 1
fi
printf 'tampered\n' >>"$DOCKER_VOLUME_BACKUP_ROOT/$backup_id/volume.tar.gz"
if docker_volume_backup_validate_record "$backup_id"; then
  printf 'FAIL: Docker 卷备份校验没有发现归档被修改\n' >&2
  exit 1
fi

# 容器浏览返回详情时复用一次 inspect；不隐式请求端口、挂载或资源。
choice_counter="$test_root/container-choice"
query_counter="$test_root/container-query"
printf 0 >"$choice_counter"
read_input() {
  local step
  step="$(<"$choice_counter")"
  printf '%s' "$((step + 1))" >"$choice_counter"
  case "$step" in 0) printf web ;; 1) printf 1 ;; *) printf 0 ;; esac
}
runtime_with_timeout() { shift; "$@"; }
docker() {
  if [[ "$1" == inspect && "$2" == --format ]]; then
    printf 'inspect\n' >>"$query_counter"
    printf 'running|healthy|unless-stopped|nginx:stable|2026-01-01T00:00:00.000Z|123\n'
  elif [[ "$1" == logs ]]; then :
  else printf 'FAIL: 菜单隐式执行了 %s\n' "$1" >&2; return 1; fi
}
# 颜色由已加载的菜单模块消费。
# shellcheck disable=SC2034
GREEN=''; YELLOW=''
ui_page() { :; }; ui_panel_begin() { :; }; ui_panel_kv() { :; }; ui_panel_end() { :; }
ui_hint() { :; }; ui_section() { :; }; ui_action() { :; }; pause() { :; }
docker_container_action
[[ "$(grep -c '^inspect$' "$query_counter")" == 1 ]] || { printf 'FAIL: 容器返回详情时重复 inspect\n' >&2; exit 1; }

printf 'PASS: docker\n'
