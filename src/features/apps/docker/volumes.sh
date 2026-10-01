#!/usr/bin/env bash

DOCKER_VOLUME_BACKUP_ROOT="${KEINE_DOCKER_BACKUP_ROOT:-/var/backups/keine-docker}"
DOCKER_VOLUME_HELPER_IMAGE="alpine:latest"

docker_volume_backup_valid_id() {
  [[ "${1:-}" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+-[0-9]+$ ]]
}

docker_volume_backup_root_safe() {
  safe_toolkit_path "$DOCKER_VOLUME_BACKUP_ROOT" && [[ ! -L "$DOCKER_VOLUME_BACKUP_ROOT" ]]
}

docker_volume_backup_dir_safe() {
  local backup_id="${1:-}"
  docker_volume_backup_valid_id "$backup_id" || return 1
  [[ -d "$DOCKER_VOLUME_BACKUP_ROOT/$backup_id" && ! -L "$DOCKER_VOLUME_BACKUP_ROOT/$backup_id" ]]
}

docker_volume_backup_ids() {
  local backup_id
  [[ -d "$DOCKER_VOLUME_BACKUP_ROOT" && ! -L "$DOCKER_VOLUME_BACKUP_ROOT" ]] || return 0
  while IFS= read -r backup_id; do
    docker_volume_backup_valid_id "$backup_id" && printf '%s\n' "$backup_id"
  done < <(find "$DOCKER_VOLUME_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null) | sort -r
}

docker_volume_backup_meta() {
  local backup_id="$1" key="$2" metadata
  docker_volume_backup_dir_safe "$backup_id" || return 1
  metadata="$DOCKER_VOLUME_BACKUP_ROOT/$backup_id/metadata"
  [[ -f "$metadata" && ! -L "$metadata" ]] || return 1
  awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$metadata"
}

docker_volume_archive_paths_safe() {
  local archive="$1"
  tar -tzf "$archive" 2>/dev/null | awk '
    {
      name=$0
      sub(/^\.\//, "", name)
      if (name ~ /^\// || name == ".." || name ~ /(^|\/)\.\.(\/|$)/) {
        failed=1
      }
    }
    END {exit failed}
  '
}

docker_volume_backup_validate_record() {
  local backup_id="$1" record archive expected actual volume image format
  docker_volume_backup_dir_safe "$backup_id" || return 1
  record="$DOCKER_VOLUME_BACKUP_ROOT/$backup_id"
  format="$(docker_volume_backup_meta "$backup_id" format 2>/dev/null || true)"
  volume="$(docker_volume_backup_meta "$backup_id" volume 2>/dev/null || true)"
  image="$(docker_volume_backup_meta "$backup_id" helper_image 2>/dev/null || true)"
  expected="$(docker_volume_backup_meta "$backup_id" sha256 2>/dev/null || true)"
  archive="$record/volume.tar.gz"
  [[ "$format" == "keine-docker-volume-v1" ]] || return 1
  valid_docker_volume_name "$volume" || return 1
  [[ "$image" == "$DOCKER_VOLUME_HELPER_IMAGE" ]] || return 1
  [[ "$expected" =~ ^[a-f0-9]{64}$ ]] || return 1
  [[ -f "$archive" && ! -L "$archive" ]] || return 1
  actual="$(sha256sum "$archive" 2>/dev/null | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || return 1
  docker_volume_archive_paths_safe "$archive"
}

docker_volume_helper_ready() {
  docker image inspect "$DOCKER_VOLUME_HELPER_IMAGE" >/dev/null 2>&1 && return 0
  ui_note "创建卷归档需要 Docker Hub 官方镜像 $DOCKER_VOLUME_HELPER_IMAGE（通常约数 MB）。"
  confirm "现在拉取辅助镜像？" || return 1
  require_root
  run docker pull "$DOCKER_VOLUME_HELPER_IMAGE" || { warn "辅助镜像拉取失败。"; return 1; }
  [[ "$DRY_RUN" -eq 1 ]] || docker image inspect "$DOCKER_VOLUME_HELPER_IMAGE" >/dev/null 2>&1
}

docker_volume_backup_execute() {
  local volume="$1" reason="${2:-manual}" backup_id record archive checksum created
  valid_docker_volume_name "$volume" || { warn "Docker 卷名称格式无效。"; return 1; }
  docker volume inspect "$volume" >/dev/null 2>&1 || { warn "没有找到 Docker 卷：$volume"; return 1; }
  docker_volume_backup_root_safe || { warn "Docker 卷备份目录不安全：$DOCKER_VOLUME_BACKUP_ROOT"; return 1; }
  docker_volume_helper_ready || return 1
  backup_id="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
  record="$DOCKER_VOLUME_BACKUP_ROOT/$backup_id"
  archive="$record/volume.tar.gz"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "将创建 Docker 卷备份：$volume → $record"
    run docker run --rm --read-only \
      --volume "$volume:/source:ro" --volume "$record:/backup" \
      "$DOCKER_VOLUME_HELPER_IMAGE" sh -c 'cd /source && tar -czf /backup/volume.tar.gz .'
    return 0
  fi
  install -d -m 0700 "$DOCKER_VOLUME_BACKUP_ROOT" "$record" || {
    warn "无法创建 Docker 卷备份目录。"
    return 1
  }
  if ! docker run --rm --read-only \
    --volume "$volume:/source:ro" --volume "$record:/backup" \
    "$DOCKER_VOLUME_HELPER_IMAGE" sh -c 'cd /source && tar -czf /backup/volume.tar.gz .'; then
    rm -rf -- "$record"
    warn "Docker 卷归档失败。"
    return 1
  fi
  [[ -f "$archive" && ! -L "$archive" ]] || { rm -rf -- "$record"; warn "归档没有生成。"; return 1; }
  checksum="$(sha256sum "$archive" | awk '{print $1}')"
  created="$(date -Is)"
  {
    printf 'format=keine-docker-volume-v1\n'
    printf 'created=%s\n' "$created"
    printf 'volume=%s\n' "$volume"
    printf 'helper_image=%s\n' "$DOCKER_VOLUME_HELPER_IMAGE"
    printf 'reason=%s\n' "$reason"
    printf 'sha256=%s\n' "$checksum"
  } >"$record/metadata"
  chmod 0600 "$record/metadata" "$archive" 2>/dev/null || true
  if ! docker_volume_backup_validate_record "$backup_id"; then
    rm -rf -- "$record"
    warn "归档创建后的完整性校验失败。"
    return 1
  fi
  audit "action=docker-volume-backup volume=$volume backup=$backup_id reason=$reason"
  ui_success "Docker 卷已备份：$backup_id"
}

docker_volume_backup_create() {
  local volume
  docker_require || return 1
  docker_daemon_ready || { warn "无法在 5 秒内连接 Docker Daemon。"; return 1; }
  ui_page "创建 Docker 卷备份" "只读挂载源卷，生成压缩归档和 SHA-256 校验"
  docker volume ls --format '  {{.Name}}' 2>/dev/null || true
  volume="$(read_input "卷名称" "")"; [[ -n "$volume" ]] || return 0
  valid_docker_volume_name "$volume" || { warn "卷名称只能包含字母、数字、点、下划线和短横线。"; return 1; }
  docker volume inspect "$volume" >/dev/null 2>&1 || { warn "没有找到 Docker 卷：$volume"; return 1; }
  ui_note "备份会读取卷中全部内容，不会停止或修改容器；一致性敏感的数据库应先暂停写入。"
  confirm "备份 Docker 卷 $volume？" || return 0
  require_root
  docker_volume_backup_execute "$volume" manual
}

docker_volume_backups_list() {
  local backup_ids=() backup_id volume created bytes state
  mapfile -t backup_ids < <(docker_volume_backup_ids)
  ui_page "Docker 卷备份" "独立于配置快照保存，可校验、恢复和清理"
  ui_panel_begin "存储"
  ui_panel_kv "目录" "$DOCKER_VOLUME_BACKUP_ROOT"
  ui_panel_kv "归档数量" "${#backup_ids[@]} 份"
  ui_panel_end
  ((${#backup_ids[@]} > 0)) || { ui_empty "还没有 Docker 卷备份"; return 0; }
  for backup_id in "${backup_ids[@]}"; do
    volume="$(docker_volume_backup_meta "$backup_id" volume 2>/dev/null || printf '未知')"
    created="$(docker_volume_backup_meta "$backup_id" created 2>/dev/null || printf '未知')"
    bytes="$(du -b "$DOCKER_VOLUME_BACKUP_ROOT/$backup_id/volume.tar.gz" 2>/dev/null | awk '{print $1}' || printf '0')"
    if docker_volume_backup_validate_record "$backup_id"; then state="可恢复"; else state="校验失败"; fi
    printf '  %b%s%b  %b%s%b  %s\n' "$CYAN" "$backup_id" "$NC" "$MAGENTA" "$volume" "$NC" "$state"
    printf '    %b%s · %s%b\n' "$MUTED" "$created" "$(backup_human_bytes "$bytes")" "$NC"
  done
}

docker_volume_backup_verify() {
  local backup_id
  docker_volume_backups_list
  backup_id="$(read_input "备份编号" "")"; [[ -n "$backup_id" ]] || return 0
  ui_page "校验 Docker 卷备份" "$backup_id"
  if docker_volume_backup_validate_record "$backup_id"; then
    ui_check pass "元数据、SHA-256 与归档路径检查通过"
    ui_kv "源卷" "$(docker_volume_backup_meta "$backup_id" volume)"
  else
    ui_check fail "备份校验失败，请勿用于恢复"
    return 1
  fi
}

docker_volume_backup_restore() {
  local backup_id volume running record
  docker_require || return 1
  docker_volume_backups_list
  backup_id="$(read_input "备份编号" "")"; [[ -n "$backup_id" ]] || return 0
  docker_volume_backup_validate_record "$backup_id" || { warn "备份完整性校验失败，拒绝恢复。"; return 1; }
  volume="$(docker_volume_backup_meta "$backup_id" volume)"
  valid_docker_volume_name "$volume" || { warn "备份中的卷名称无效。"; return 1; }
  docker volume inspect "$volume" >/dev/null 2>&1 || { warn "原 Docker 卷已不存在：$volume"; return 1; }
  running="$(docker ps -q --filter "volume=$volume" 2>/dev/null | grep -c . || true)"
  if (( running > 0 )); then
    warn "卷 $volume 正被 $running 个运行中容器使用；请先停止相关容器。"
    return 1
  fi
  record="$DOCKER_VOLUME_BACKUP_ROOT/$backup_id"
  ui_page "恢复 Docker 卷" "$backup_id → $volume"
  ui_danger "恢复会清空目标卷现有内容；操作前会自动创建一份 pre-restore 安全备份。"
  confirm "确认覆盖 Docker 卷 $volume？" || return 0
  require_root
  docker_volume_backup_execute "$volume" pre-restore || return 1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    run docker run --rm --read-only \
      --volume "$volume:/target" --volume "$record:/backup:ro" \
      "$DOCKER_VOLUME_HELPER_IMAGE" sh -c \
      'find /target -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && tar -xzf /backup/volume.tar.gz -C /target'
    return 0
  fi
  docker run --rm --read-only \
    --volume "$volume:/target" --volume "$record:/backup:ro" \
    "$DOCKER_VOLUME_HELPER_IMAGE" sh -c \
    'find /target -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && tar -xzf /backup/volume.tar.gz -C /target' || {
      warn "Docker 卷恢复失败；请使用刚创建的 pre-restore 备份人工恢复。"
      return 1
    }
  audit "action=docker-volume-restore volume=$volume backup=$backup_id"
  ui_success "Docker 卷 $volume 已从 $backup_id 恢复"
}

docker_volume_backup_delete() {
  local backup_id record volume bytes
  docker_volume_backups_list
  backup_id="$(read_input "备份编号" "")"; [[ -n "$backup_id" ]] || return 0
  docker_volume_backup_dir_safe "$backup_id" || { warn "备份编号无效或目录不安全。"; return 1; }
  docker_volume_backup_root_safe || { warn "Docker 卷备份目录不安全。"; return 1; }
  record="$DOCKER_VOLUME_BACKUP_ROOT/$backup_id"
  volume="$(docker_volume_backup_meta "$backup_id" volume 2>/dev/null || printf '未知')"
  bytes="$(du -sb "$record" 2>/dev/null | awk '{print $1}' || printf '0')"
  ui_page "删除 Docker 卷备份" "$backup_id"
  ui_kv "源卷" "$volume"
  ui_kv "预计释放" "$(backup_human_bytes "$bytes")"
  ui_danger "只会删除 keine 创建的这个归档，不会删除 Docker 卷。"
  confirm "永久删除备份 $backup_id？" || return 0
  require_root
  if [[ "$DRY_RUN" -eq 1 ]]; then info "将删除 Docker 卷备份：$record"; return 0; fi
  rm -rf -- "$record"
  [[ ! -e "$record" && ! -L "$record" ]] || { warn "Docker 卷备份删除失败。"; return 1; }
  audit "action=docker-volume-backup-delete backup=$backup_id volume=$volume"
  ui_success "Docker 卷备份已删除；Docker 卷保持不变"
}

docker_volume_backups_menu() {
  local choice
  while true; do
    ui_page "Docker / 卷备份" "压缩归档、完整性校验、安全恢复与空间清理"
    ui_context "数据库卷备份前应暂停写入；恢复仅允许覆盖原卷，且运行中容器会阻止操作。"
    ui_item 1 "列出卷备份"
    ui_item 2 "创建卷备份" "首次使用会询问拉取官方 Alpine 辅助镜像"
    ui_item 3 "校验卷备份" "检查元数据、SHA-256 与归档路径"
    ui_item 4 "恢复原卷" "先创建安全备份，再覆盖未被运行容器使用的原卷"
    ui_item 5 "删除一个卷备份" "不删除 Docker 卷"
    ui_item 0 "返回"
    choice="$(read_input "请选择" "0")"
    case "$choice" in
      1) docker_volume_backups_list ;;
      2) docker_volume_backup_create || true ;;
      3) docker_volume_backup_verify || true ;;
      4) docker_volume_backup_restore || true ;;
      5) docker_volume_backup_delete || true ;;
      0) return 0 ;;
      *) warn "未知选项"; continue ;;
    esac
    pause
  done
}
