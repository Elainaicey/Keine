#!/usr/bin/env bash

CHANGES_ENABLED=0
CHANGES_RESTORING=0
declare -Ag CHANGES_PENDING_FILES=()

changes_root() { printf '%s/changes' "$STATE_ROOT"; }

changes_ready() {
  (( CHANGES_ENABLED == 1 && CHANGES_RESTORING == 0 && DRY_RUN == 0 ))
}

changes_path_safe() {
  local path="$1" parent
  safe_managed_path "$path" || return 1
  [[ "$path" != *'|'* && "$path" != *[[:cntrl:]]* ]] || return 1
  parent="$(dirname -- "$path")"
  [[ "$(readlink -m -- "$parent")" == "$parent" ]] || return 1
  case "$path" in
    "$STATE_ROOT"|"$STATE_ROOT"/*|"${BACKUP_ROOT:-/var/backups/keine}"/*|"${ROOT_DIR:-/opt/keine}"/*) return 1 ;;
  esac
}

changes_storage_ready() {
  local root
  root="$(changes_root)"
  if ! safe_toolkit_path "$root" || [[ "$(readlink -m -- "$root")" != "$root" ]]; then
    warn "变更记录路径不安全：$root"; return 1
  fi
  mkdir -p "$root/files" "$root/packages" "$root/settings" || return 1
  chmod 0700 "$root" "$root/files" "$root/packages" "$root/settings"
}

changes_fingerprint() {
  local path="$1"
  if [[ -L "$path" ]]; then
    printf 'link:%s' "$(readlink -- "$path")" | sha256sum | awk '{print $1}'
  elif [[ -f "$path" ]]; then
    { stat -c '%a:%u:%g' -- "$path"; sha256sum -- "$path"; } | sha256sum | awk '{print $1}'
  elif [[ -d "$path" ]]; then
    {
      find "$path" -printf '%P|%y|%m|%l\n' | LC_ALL=C sort
      find "$path" -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum --
    } | sha256sum | awk '{print $1}'
  elif [[ ! -e "$path" ]]; then printf 'absent'; else return 1; fi
}

changes_file_entry() {
  local key
  key="$(printf '%s' "$1" | sha256sum | awk '{print $1}')"
  printf '%s/files/%s' "$(changes_root)" "$key"
}

changes_prepare_file() {
  local path="$1" kind="${2:-file}" entry original temporary parent owner
  changes_ready || return 0
  changes_path_safe "$path" || { warn "无法记录不安全的修改路径：$path"; return 1; }
  # 新建目录整体撤销，避免父目录与子文件重复恢复。
  parent="$(dirname -- "$path")"
  while [[ "$parent" != / ]]; do
    owner="$(changes_file_entry "$parent")"
    if [[ -d "$owner" && ! -L "$owner" && -f "$owner/kind" && -f "$owner/before" &&
      "$(<"$owner/kind")" == directory && "$(<"$owner/before")" == absent ]]; then
      [[ -n "${CHANGES_PENDING_FILES[$parent]:-}" || "$(changes_fingerprint "$parent")" == "$(<"$owner/last")" ]] || {
        warn "项目目录包含外部修改：$parent"; return 1;
      }
      CHANGES_PENDING_FILES["$parent"]=1
      return 0
    fi
    parent="$(dirname -- "$parent")"
  done
  entry="$(changes_file_entry "$path")"
  if [[ -d "$entry" && ! -L "$entry" ]]; then
    if [[ "$(<"$entry/path")" != "$path" ]] ||
      { [[ -z "${CHANGES_PENDING_FILES[$path]:-}" ]] && [[ "$(changes_fingerprint "$path")" != "$(<"$entry/last")" ]]; }; then
      warn "$path 在上次项目操作后被修改；请先到备份与恢复中心检查冲突。"; return 1;
    fi
  else
    [[ ! -e "$entry" && ! -L "$entry" ]] || return 1
    [[ "$kind" == file || "$kind" == directory ]] || return 1
    if [[ -d "$path" && ! -L "$path" ]]; then
      warn "已有目录只能由原生工具管理，不能登记为项目新建目录：$path"; return 1
    fi
    changes_storage_ready || return 1
    temporary="$(mktemp -d "$(changes_root)/files/.pending.XXXXXX")" || return 1
    original="$(changes_fingerprint "$path")" || { rmdir "$temporary"; return 1; }
    printf '%s\n' "$path" >"$temporary/path"
    printf '%s\n' "$kind" >"$temporary/kind"
    printf '%s\n' "$original" >"$temporary/before"
    printf '%s\n' "$original" >"$temporary/last"
    if [[ -e "$path" || -L "$path" ]]; then
      cp -a -- "$path" "$temporary/original" || { rm -rf -- "$temporary"; return 1; }
    fi
    chmod 0700 "$temporary"
    mv -- "$temporary" "$entry" || { rm -rf -- "$temporary"; return 1; }
  fi
  CHANGES_PENDING_FILES["$path"]=1
}

changes_commit_pending() {
  local path entry fingerprint
  changes_ready || return 0
  for path in "${!CHANGES_PENDING_FILES[@]}"; do
    entry="$(changes_file_entry "$path")"
    [[ -d "$entry" && ! -L "$entry" ]] || return 1
    fingerprint="$(changes_fingerprint "$path")" || return 1
    printf '%s\n' "$fingerprint" >"$entry/last" || return 1
  done
  CHANGES_PENDING_FILES=()
}

changes_file_status() {
  local entry="$1" path current field
  [[ "$entry" == "$(changes_root)/files/"* && "$(readlink -m -- "$entry")" == "$entry" ]] || { printf 'invalid'; return; }
  for field in path kind before last; do
    [[ -f "$entry/$field" && ! -L "$entry/$field" ]] || { printf 'invalid'; return; }
  done
  [[ -f "$entry/path" && -f "$entry/last" && -f "$entry/before" ]] || { printf 'invalid'; return; }
  path="$(<"$entry/path")"
  if ! changes_path_safe "$path" || [[ "$entry" != "$(changes_file_entry "$path")" ]]; then
    printf 'invalid'; return
  fi
  current="$(changes_fingerprint "$path")" || { printf 'conflict'; return; }
  if [[ "$current" == "$(<"$entry/before")" ]]; then printf 'unchanged'
  elif [[ "$current" == "$(<"$entry/last")" ]]; then printf 'ready'
  else printf 'conflict'; fi
}

changes_restore_file() {
  local entry="$1" retain="${2:-0}" path status parent temporary
  [[ "$retain" == 0 || "$retain" == 1 ]] || return 1
  status="$(changes_file_status "$entry")"
  [[ "$status" == ready || "$status" == unchanged ]] || { warn "已保留冲突资源：$entry"; return 1; }
  path="$(<"$entry/path")"
  if (( DRY_RUN == 1 )); then info "将恢复项目操作前的资源：$path"; return 0; fi
  if [[ "$status" == ready ]]; then
    if [[ "$(<"$entry/before")" == absent ]]; then
      if [[ -d "$path" && ! -L "$path" ]]; then
        [[ "$(<"$entry/kind")" == directory ]] || return 1
        rm -rf -- "$path" || return 1
      else rm -f -- "$path" || return 1; fi
    else
      [[ -f "$entry/original" || -L "$entry/original" ]] || return 1
      parent="$(dirname -- "$path")"
      mkdir -p "$parent" || return 1
      temporary="$(mktemp "$parent/.keine-restore.XXXXXX")" || return 1
      rm -f -- "$temporary"
      if ! cp -a -- "$entry/original" "$temporary" || ! mv -fT -- "$temporary" "$path"; then
        rm -f -- "$temporary"; return 1
      fi
    fi
    [[ "$(changes_fingerprint "$path")" == "$(<"$entry/before")" ]] || return 1
  fi
  [[ "$retain" == 1 ]] || rm -rf -- "$entry"
}

. "$ROOT_DIR/src/core/changes/packages.sh"
. "$ROOT_DIR/src/core/changes/settings.sh"
