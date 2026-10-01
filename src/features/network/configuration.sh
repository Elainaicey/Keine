#!/usr/bin/env bash

# 共享待提交状态由 core/changes 消费。
# shellcheck disable=SC2034

# 网络配置共用事务：首次基线、原子写入、应用失败回退、外部修改冲突保护。
network_config_safe() {
  local path="$1" parent
  safe_managed_path "$path" || return 1
  parent="$(dirname -- "$path")"
  [[ ! -L "$path" && ( ! -e "$path" || -f "$path" ) && "$(readlink -m -- "$parent")" == "$parent" ]]
}

network_config_write() (
  local path="$1" mode="$2" content="$3" callback="$4" temporary previous="" existed=0
  network_config_safe "$path" || { warn "配置路径不是安全的普通文件：$path"; return 1; }
  require_root
  if (( DRY_RUN == 1 )); then info "将记录基线、原子写入 $path 并验证；不显示配置中的凭据。"; return 0; fi
  changes_ready || { warn "恢复记录未启用，拒绝写入网络配置。"; return 1; }
  mkdir -p -- "$(dirname -- "$path")" || return 1
  temporary="$(mktemp "$(dirname -- "$path")/.server-toolkit-network.XXXXXX")" || return 1
  trap 'rm -f -- "$temporary"; [[ -z "$previous" ]] || rm -f -- "$previous"' EXIT
  if [[ -f "$path" ]]; then
    existed=1; previous="$(mktemp)" || return 1
    cp -p -- "$path" "$previous" || return 1
  fi
  backup_file "$path" || return 1
  printf '%s\n' "$content" >"$temporary" || return 1
  chmod "$mode" "$temporary" || return 1
  mv -fT -- "$temporary" "$path" || return 1
  if "$callback"; then
    CHANGES_PENDING_FILES["$path"]=1
    if changes_commit_pending; then return 0; fi
  fi
  warn "新配置未通过应用验证，恢复本次操作前的文件。"
  if (( existed == 1 )); then
    cp -p -- "$previous" "$temporary" && mv -fT -- "$temporary" "$path" || return 1
  else rm -f -- "$path" || return 1; fi
  # 回调中的 run 可能已提交并清空待记录集合，回退后必须重新登记文件。
  CHANGES_PENDING_FILES["$path"]=1
  "$callback" || warn "文件已回退，但运行状态仍需人工检查。"
  CHANGES_PENDING_FILES["$path"]=1
  changes_commit_pending || return 1
  return 1
)

network_config_restore() (
  local path="$1" callback="$2" rollback="${3:-$2}" entry previous="" temporary="" existed=0
  entry="$(changes_file_entry "$path")"
  [[ -d "$entry" && ! -L "$entry" ]] || { warn "没有该配置的原始状态记录：$path"; return 1; }
  case "$(changes_file_status "$entry")" in ready|unchanged) ;; *) warn "配置已被外部修改，拒绝覆盖：$path"; return 1 ;; esac
  require_root
  (( DRY_RUN == 0 )) || { info "将恢复 $path 的初始状态并重新验证。"; return 0; }
  if [[ -f "$path" ]]; then
    existed=1; previous="$(mktemp)" || return 1; cp -p -- "$path" "$previous" || return 1
  fi
  trap '[[ -z "$previous" ]] || rm -f -- "$previous"; [[ -z "$temporary" ]] || rm -f -- "$temporary"' EXIT
  # 恢复过程不再次登记为新修改；由 core/changes 消费。
  # shellcheck disable=SC2034
  CHANGES_RESTORING=1
  changes_restore_file "$entry" 1 || return 1
  if ! "$callback"; then
    if (( existed == 1 )); then
      temporary="$(mktemp "$(dirname -- "$path")/.server-toolkit-rollback.XXXXXX")" || return 1
      cp -p -- "$previous" "$temporary" && mv -fT -- "$temporary" "$path" || return 1
    else rm -f -- "$path" || return 1; fi
    "$rollback" || true
    warn "恢复后的运行验证失败，已保留原配置与恢复记录。"; return 1
  fi
  rm -rf -- "$entry" || return 1
)

network_config_no_reload() { return 0; }

network_read_secret() {
  local answer=""
  if [[ -t 0 ]]; then read -r -s -p "$1: " answer || return 1; printf '\n' >&2
  elif [[ -r /dev/tty && -t 2 ]]; then read -r -s -p "$1: " answer </dev/tty || return 1; printf '\n' >&2
  else warn "凭据输入需要交互式终端。"; return 1; fi
  printf '%s' "$answer"
}
