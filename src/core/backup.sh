#!/usr/bin/env bash

BACKUP_ROOT="${SERVER_TOOLKIT_BACKUP_ROOT:-/var/backups/server-toolkit}"
BACKUP_SESSION=""

backup_valid_snapshot() {
  [[ "${1:-}" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ ]]
}

backup_snapshot_dir_safe() {
  local snapshot="${1:-}"
  backup_valid_snapshot "$snapshot" || return 1
  [[ -d "$BACKUP_ROOT/$snapshot" && ! -L "$BACKUP_ROOT/$snapshot" ]]
}

backup_snapshot_label() {
  local snapshot="${1:-}" label_file
  backup_snapshot_dir_safe "$snapshot" || return 1
  label_file="$BACKUP_ROOT/$snapshot/label.txt"
  [[ -f "$label_file" && ! -L "$label_file" ]] || return 0
  head -n 1 "$label_file"
}

backup_snapshot_protected() {
  local snapshot="${1:-}" marker
  backup_snapshot_dir_safe "$snapshot" || return 1
  marker="$BACKUP_ROOT/$snapshot/protected"
  [[ -f "$marker" && ! -L "$marker" ]]
}

backup_set_label() {
  local snapshot="$1" label="${2:-}" snapshot_dir label_file temporary
  backup_snapshot_dir_safe "$snapshot" || { warn "备份不存在或不是安全目录：$snapshot"; return 1; }
  valid_backup_label "$label" || { warn "备注最多 60 个字符，且不能包含换行或控制字符。"; return 1; }
  snapshot_dir="$BACKUP_ROOT/$snapshot"
  label_file="$snapshot_dir/label.txt"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ -n "$label" ]]; then info "将设置快照备注：$snapshot → $label"; else info "将清除快照备注：$snapshot"; fi
    return 0
  fi
  if [[ -z "$label" ]]; then
    [[ ! -L "$label_file" ]] || { warn "备注文件不能是符号链接：$label_file"; return 1; }
    rm -f -- "$label_file"
    return
  fi
  if [[ ( -e "$label_file" && ! -f "$label_file" ) || -L "$label_file" ]]; then
    warn "备注文件不是安全的普通文件：$label_file"
    return 1
  fi
  temporary="$snapshot_dir/.label.$$"
  printf '%s\n' "$label" >"$temporary" || return 1
  chmod 0600 "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "$label_file"
}

backup_set_protection() {
  local snapshot="$1" enabled="$2" marker
  backup_snapshot_dir_safe "$snapshot" || { warn "备份不存在或不是安全目录：$snapshot"; return 1; }
  [[ "$enabled" == "0" || "$enabled" == "1" ]] || return 1
  marker="$BACKUP_ROOT/$snapshot/protected"
  [[ ! -L "$marker" ]] || { warn "保护标记不能是符号链接：$marker"; return 1; }
  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ "$enabled" == "1" ]]; then info "将保护快照：$snapshot"; else info "将取消保护：$snapshot"; fi
    return 0
  fi
  if [[ "$enabled" == "1" ]]; then
    printf 'Managed by Server Toolkit\n' >"$marker"
    chmod 0600 "$marker" 2>/dev/null || true
  else
    rm -f -- "$marker"
  fi
}

backup_file() {
  local source="$1"
  if declare -F changes_prepare_file >/dev/null; then changes_prepare_file "$source" || return 1; fi
  [[ -e "$source" || -L "$source" ]] || return 0
  safe_toolkit_path "$BACKUP_ROOT" || { warn "备份根目录不安全：$BACKUP_ROOT"; return 1; }
  [[ ! -L "$BACKUP_ROOT" ]] || { warn "备份根目录不能是符号链接：$BACKUP_ROOT"; return 1; }
  [[ -n "$BACKUP_SESSION" ]] || BACKUP_SESSION="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-$$"
  [[ "$BACKUP_SESSION" == "$BACKUP_ROOT/"* && ! -L "$BACKUP_SESSION" ]] || {
    warn "备份会话目录不安全：$BACKUP_SESSION"
    return 1
  }
  local destination="$BACKUP_SESSION$source"
  if [[ "$DRY_RUN" -eq 1 ]]; then info "将备份 $source 到 $destination"; return 0; fi
  [[ ! -e "$destination" && ! -L "$destination" ]] || { info "本次会话已经备份：$source"; return 0; }
  mkdir -p "$(dirname "$destination")" || { warn "无法创建备份目录：$(dirname "$destination")"; return 1; }
  cp -a "$source" "$destination" || { warn "无法复制备份内容：$source"; return 1; }
  printf '%s\n' "$source" >>"$BACKUP_SESSION/manifest.txt" || {
    rm -rf -- "$destination" 2>/dev/null || true
    warn "无法更新备份清单：$BACKUP_SESSION/manifest.txt"
    return 1
  }
  audit "action=backup source=$source snapshot=$BACKUP_SESSION"
  info "已备份：$source"
}

backup_snapshots() {
  local snapshot
  [[ -d "$BACKUP_ROOT" && ! -L "$BACKUP_ROOT" ]] || return 0
  while IFS= read -r snapshot; do
    backup_valid_snapshot "$snapshot" && printf '%s\n' "$snapshot"
  done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null) | sort -r
}

backup_snapshot_bytes() {
  local snapshot="$1"
  backup_valid_snapshot "$snapshot" || return 1
  backup_snapshot_dir_safe "$snapshot" || return 1
  du -sb "$BACKUP_ROOT/$snapshot" 2>/dev/null | awk '{print $1}'
}

backup_total_bytes() {
  local bytes
  if [[ -d "$BACKUP_ROOT" ]]; then
    bytes="$(du -sb "$BACKUP_ROOT" 2>/dev/null | awk '{print $1}' || true)"
    printf '%s' "${bytes:-0}"
  else
    printf '0'
  fi
}

backup_human_bytes() {
  local bytes="${1:-0}"
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
  if command_exists numfmt; then
    numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || printf '%s B' "$bytes"
  else
    awk -v bytes="$bytes" 'BEGIN {
      split("B KiB MiB GiB TiB", units, " "); value=bytes; unit=1
      while (value >= 1024 && unit < 5) {value/=1024; unit++}
      if (unit == 1) printf "%d %s", value, units[unit]
      else printf "%.1f %s", value, units[unit]
    }'
  fi
}

backup_active_snapshot() {
  [[ -n "$BACKUP_SESSION" ]] || return 0
  basename -- "$BACKUP_SESSION"
}

backup_cleanup_keep_candidates() {
  local keep="$1" snapshot active index=0
  [[ "$keep" =~ ^[0-9]+$ ]] && (( keep >= 1 && keep <= 10000 )) || return 1
  active="$(backup_active_snapshot)"
  while IFS= read -r snapshot; do
    index=$((index + 1))
    (( index > keep )) || continue
    [[ "$snapshot" != "$active" ]] || continue
    backup_snapshot_protected "$snapshot" && continue
    printf '%s\n' "$snapshot"
  done < <(backup_snapshots)
}

backup_cleanup_age_candidates() {
  local days="$1" snapshot active cutoff stamp epoch
  [[ "$days" =~ ^[0-9]+$ ]] && (( days >= 1 && days <= 3650 )) || return 1
  active="$(backup_active_snapshot)"
  cutoff="$(date -d "$days days ago" +%s 2>/dev/null)" || return 1
  while IFS= read -r snapshot; do
    [[ "$snapshot" != "$active" ]] || continue
    backup_snapshot_protected "$snapshot" && continue
    stamp="${snapshot:0:8} ${snapshot:9:2}:${snapshot:11:2}:${snapshot:13:2}"
    epoch="$(date -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9}" +%s 2>/dev/null || true)"
    [[ "$epoch" =~ ^[0-9]+$ ]] || continue
    (( epoch < cutoff )) && printf '%s\n' "$snapshot"
  done < <(backup_snapshots)
}

backup_manifest() {
  local snapshot="$1"
  backup_valid_snapshot "$snapshot" || return 1
  [[ -r "$BACKUP_ROOT/$snapshot/manifest.txt" ]] || return 1
  cat "$BACKUP_ROOT/$snapshot/manifest.txt"
}

backup_verify() {
  local snapshot="$1" manifest target source checked=0 failed=0
  backup_valid_snapshot "$snapshot" || { warn "备份编号格式无效：$snapshot"; return 1; }
  manifest="$BACKUP_ROOT/$snapshot/manifest.txt"
  [[ -r "$manifest" ]] || { warn "备份清单不存在：$snapshot"; return 1; }
  while IFS= read -r target || [[ -n "$target" ]]; do
    [[ -n "$target" ]] || continue
    checked=$((checked + 1))
    if [[ "$target" != /* || "$target" == *'/../'* || "$target" == */.. ]]; then
      printf '  %b×%b 非法清单路径：%s\n' "$RED" "$NC" "$target"
      failed=$((failed + 1))
      continue
    fi
    source="$BACKUP_ROOT/$snapshot$target"
    if [[ -e "$source" || -L "$source" ]]; then
      printf '  %b✓%b %s\n' "$GREEN" "$NC" "$target"
    else
      printf '  %b×%b 缺少备份内容：%s\n' "$RED" "$NC" "$target"
      failed=$((failed + 1))
    fi
  done <"$manifest"
  (( checked > 0 )) || { warn "备份清单为空：$snapshot"; return 1; }
  (( failed == 0 ))
}

backup_delete() {
  local snapshot="$1" snapshot_dir
  backup_valid_snapshot "$snapshot" || die "备份编号格式无效：$snapshot"
  safe_toolkit_path "$BACKUP_ROOT" || die "备份根目录不安全：$BACKUP_ROOT"
  [[ ! -L "$BACKUP_ROOT" ]] || die "备份根目录不能是符号链接：$BACKUP_ROOT"
  snapshot_dir="$BACKUP_ROOT/$snapshot"
  [[ -d "$snapshot_dir" && ! -L "$snapshot_dir" ]] || die "备份不存在或不是安全目录：$snapshot"
  backup_snapshot_protected "$snapshot" && die "快照已受保护，请先取消保护：$snapshot"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "将删除配置快照：$snapshot_dir"
    return 0
  fi
  rm -rf -- "$snapshot_dir" || { warn "备份删除失败：$snapshot"; return 1; }
  [[ ! -e "$snapshot_dir" && ! -L "$snapshot_dir" ]] || { warn "备份删除后仍然存在：$snapshot"; return 1; }
}

backup_restore() {
  local snapshot target source
  snapshot="$1"
  target="$2"
  source="$BACKUP_ROOT/$snapshot$target"
  backup_manifest "$snapshot" | grep -Fxq "$target" || die "目标不在备份清单中：$target"
  [[ -e "$source" || -L "$source" ]] || die "备份文件不存在：$source"
  backup_file "$target" || { warn "恢复前无法备份当前文件：$target"; return 1; }
  if [[ "$DRY_RUN" -eq 1 ]]; then info "将恢复 $source 到 $target"; return 0; fi
  mkdir -p "$(dirname "$target")" || { warn "无法创建恢复目标目录：$(dirname "$target")"; return 1; }
  cp -a "$source" "$target" || { warn "无法恢复文件：$target"; return 1; }
  [[ -e "$target" || -L "$target" ]] || { warn "恢复后未找到目标：$target"; return 1; }
  audit "action=restore snapshot=$snapshot target=$target"
  info "已恢复：$target"
}
