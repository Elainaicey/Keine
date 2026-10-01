#!/usr/bin/env bash

backups_list() {
  ui_page "配置备份" "按时间倒序显示快照、保护状态、备注与磁盘占用"
  local snapshots=() snapshot count bytes state state_color label protection
  mapfile -t snapshots < <(backup_snapshots)
  ((${#snapshots[@]} > 0)) || { ui_empty "还没有配置备份"; return 0; }
  for snapshot in "${snapshots[@]}"; do
    if backup_manifest "$snapshot" >/dev/null 2>&1; then
      count="$(backup_manifest "$snapshot" | grep -c . || true)"
      state="可恢复 · $count 个文件"
      state_color="$GREEN"
    else
      state="清单无效"
      state_color="$YELLOW"
    fi
    if backup_snapshot_protected "$snapshot"; then protection="◆ 已保护"; else protection="◇ 普通"; fi
    label="$(backup_snapshot_label "$snapshot" 2>/dev/null || true)"
    bytes="$(backup_snapshot_bytes "$snapshot" 2>/dev/null || printf '0')"
    printf '  %b%s%b  %b%s%b  %b%s%b  %b%s%b\n' \
      "$CYAN" "$snapshot" "$NC" "$state_color" "$state" "$NC" \
      "$MAGENTA" "$protection" "$NC" "$MUTED" "$(backup_human_bytes "$bytes")" "$NC"
    [[ -z "$label" ]] || printf '    %b↳ %s%b\n' "$MUTED" "$(terminal_safe_text "$label")" "$NC"
  done
}

backups_recent_hint() {
  local snapshots=() preview="" snapshot index=0
  mapfile -t snapshots < <(backup_snapshots)
  for snapshot in "${snapshots[@]}"; do
    [[ -z "$preview" ]] || preview+=" · "
    preview+="$snapshot"
    index=$((index + 1))
    (( index < 3 )) || break
  done
  [[ -z "$preview" ]] || ui_hint "最近：$preview"
}

backups_summary() {
  local snapshots=() total newest oldest snapshot protected=0
  mapfile -t snapshots < <(backup_snapshots)
  total="$(backup_total_bytes)"
  newest="${snapshots[0]:-—}"
  if ((${#snapshots[@]} > 0)); then oldest="${snapshots[${#snapshots[@]}-1]}"; else oldest="—"; fi
  for snapshot in "${snapshots[@]}"; do
    backup_snapshot_protected "$snapshot" && protected=$((protected + 1))
  done
  ui_panel_begin "备份存储"
  ui_panel_kv "快照数量" "${#snapshots[@]} 份"
  ui_panel_kv "受保护" "$protected 份"
  ui_panel_kv "总占用" "$(backup_human_bytes "$total")"
  ui_panel_kv "最新快照" "$newest"
  ui_panel_kv "最早快照" "$oldest"
  ui_panel_end
  if ((${#snapshots[@]} >= 50)) || { [[ "$total" =~ ^[0-9]+$ ]] && (( total >= 536870912 )); }; then
    ui_hint "备份较多，可使用「清理历史快照」保留最近版本。"
  fi
}

backups_inspect() {
  local snapshot label protection
  backups_recent_hint
  snapshot="$(read_input "备份编号" "")"; [[ -n "$snapshot" ]] || return 0
  ui_page "备份内容" "$snapshot"
  label="$(backup_snapshot_label "$snapshot" 2>/dev/null || true)"
  if backup_snapshot_protected "$snapshot"; then protection="已保护"; else protection="普通"; fi
  ui_panel_begin "快照信息"
  ui_panel_kv "保护状态" "$protection"
  ui_panel_kv "备注" "${label:-—}"
  ui_panel_kv "占用" "$(backup_human_bytes "$(backup_snapshot_bytes "$snapshot" 2>/dev/null || printf '0')")"
  ui_panel_end
  ui_section "文件清单" "primary"
  backup_manifest "$snapshot" | nl -ba || { warn "备份不存在或清单无效。"; return 1; }
}

backups_metadata() {
  local snapshot choice label
  backups_recent_hint
  snapshot="$(read_input "备份编号" "")"; [[ -n "$snapshot" ]] || return 0
  backup_snapshot_dir_safe "$snapshot" || { warn "备份不存在或不是安全目录。"; return 1; }
  while true; do
    ui_page "快照保护与备注" "$snapshot"
    ui_panel_begin "当前状态"
    if backup_snapshot_protected "$snapshot"; then
      ui_panel_kv "保护" "● 已保护" "$GREEN"
    else
      ui_panel_kv "保护" "○ 未保护" "$MUTED"
    fi
    label="$(backup_snapshot_label "$snapshot" 2>/dev/null || true)"
    ui_panel_kv "备注" "${label:-—}"
    ui_panel_end
    ui_action 1 "设置备注" "action" "最多 60 个字符；留空会清除"
    if backup_snapshot_protected "$snapshot"; then
      ui_action 2 "取消保护" "warning" "之后可被手动删除或批量清理"
    else
      ui_action 2 "保护快照" "success" "批量清理和直接删除都会跳过"
    fi
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      1)
        label="$(read_input "快照备注" "$label")"
        valid_backup_label "$label" || { warn "备注最多 60 个字符，且只能是单行文本。"; continue; }
        confirm "$([[ -n "$label" ]] && printf '更新' || printf '清除')快照 $snapshot 的备注？" || continue
        require_root
        backup_set_label "$snapshot" "$label" || return 1
        audit "action=backup-label snapshot=$snapshot"
        [[ "$DRY_RUN" -eq 1 ]] || ui_success "快照备注已更新"
        ;;
      2)
        require_root
        if backup_snapshot_protected "$snapshot"; then
          confirm "取消保护快照 $snapshot？" || continue
          backup_set_protection "$snapshot" 0 || return 1
          audit "action=backup-unprotect snapshot=$snapshot"
          [[ "$DRY_RUN" -eq 1 ]] || ui_success "快照已取消保护"
        else
          confirm "保护快照 $snapshot，阻止直接删除和批量清理？" || continue
          backup_set_protection "$snapshot" 1 || return 1
          audit "action=backup-protect snapshot=$snapshot"
          [[ "$DRY_RUN" -eq 1 ]] || ui_success "快照已保护"
        fi
        ;;
      0) return 0 ;;
      *) warn "未知选项" ;;
    esac
  done
}

backups_create() {
  local target choice entry snapshot result=0
  local targets=()
  ui_page "手动创建配置快照" "每次创建独立快照；不会在修改设置时自动备份"
  ui_action 1 "已托管的配置" "action" "备份当前系统配置与 Shell 启动文件，不复制软件目录"
  ui_action 2 "常用系统配置" "action" "主机名、hosts、时区、fstab 和 SSH 主配置"
  ui_action 3 "指定配置文件" "action" "输入一个 /etc 下的完整路径"
  ui_menu_footer "取消"
  ui_read_choice choice "选择" "1"
  case "$choice" in
    1)
      for entry in "$(changes_root)"/files/*; do
        [[ -d "$entry" && ! -L "$entry" && -f "$entry/path" && ! -L "$entry/path" ]] || continue
        target="$(<"$entry/path")"
        case "$target" in /etc/*|*/.bashrc|*/.zshrc|*/.profile|*/.bash_profile|*/.bash_login)
          [[ "$(changes_file_status "$entry")" != invalid ]] || continue
          [[ -f "$target" || -L "$target" ]] && targets+=("$target") ;;
        esac
      done
      ;;
    2)
      for target in /etc/hostname /etc/hosts /etc/timezone /etc/fstab /etc/ssh/sshd_config; do
        [[ -f "$target" || -L "$target" ]] && targets+=("$target")
      done
      ;;
    3)
      target="$(read_input "配置文件完整路径" "/etc/hosts")"
      [[ "$target" == /etc/* && "$target" != *'/../'* && "$target" != */.. && "$target" != *[[:cntrl:]]* ]] || { warn "只允许备份 /etc 下的明确路径。"; return 1; }
      [[ -f "$target" || -L "$target" ]] || { warn "目标不是现有文件：$target"; return 1; }
      targets+=("$target")
      ;;
    0) return 0 ;;
    *) warn "未知选项"; return 1 ;;
  esac
  ((${#targets[@]} > 0)) || { ui_empty "没有可备份的配置文件"; return 0; }
  ui_section "快照文件" "primary"
  for target in "${targets[@]}"; do ui_kv "配置" "$target"; done
  ui_hint "只保存当前文件，不创建整机或业务数据备份；快照可能包含凭据。"
  confirm "创建包含 ${#targets[@]} 个配置文件的快照？" || return 0
  require_root
  backup_begin
  snapshot="$(backup_active_snapshot)"
  for target in "${targets[@]}"; do backup_file "$target" || { result=1; break; }; done
  # 当前写入会话由 core/backup 的清理保护逻辑消费。
  # shellcheck disable=SC2034
  BACKUP_SESSION=""
  (( result == 0 )) || { warn "快照 $snapshot 未完整创建，请在备份管理中检查或删除。"; return 1; }
  [[ "$DRY_RUN" -eq 1 ]] || ui_success "已创建手动快照：$snapshot（${#targets[@]} 个文件）。"
}

backups_verify() {
  local snapshot
  backups_recent_hint
  snapshot="$(read_input "备份编号" "")"; [[ -n "$snapshot" ]] || return 0
  ui_page "校验配置快照" "$snapshot · 检查清单格式与备份文件完整性"
  if backup_verify "$snapshot"; then
    ui_success "快照结构完整，可以用于恢复。"
  else
    ui_danger "快照校验失败，请勿使用它覆盖当前配置。"
    return 1
  fi
}

backups_compare() {
  local snapshot target source
  backups_recent_hint
  snapshot="$(read_input "备份编号" "")"; [[ -n "$snapshot" ]] || return 0
  backup_manifest "$snapshot" >/dev/null || { warn "备份不存在或清单无效。"; return 1; }
  printf '\n'; backup_manifest "$snapshot" | nl -ba
  target="$(read_input "要比较的完整路径" "")"; [[ -n "$target" ]] || return 0
  backup_manifest "$snapshot" | grep -Fxq "$target" || { warn "路径不在该备份清单中。"; return 1; }
  source="$BACKUP_ROOT/$snapshot$target"
  ui_page "比较配置" "$snapshot · $target"
  [[ -e "$source" || -L "$source" ]] || { warn "备份内容不存在。"; return 1; }
  if [[ ! -e "$target" && ! -L "$target" ]]; then
    ui_status "当前文件" "不存在" "warn"
    ui_status "备份文件" "可用" "good"
    return 0
  fi
  if cmp -s -- "$source" "$target"; then
    ui_success "当前文件与备份内容一致。"
  else
    ui_status "比较结果" "内容已发生变化" "warn"
    ui_section "差异（最多 120 行）" "accent"
    diff -u --label "备份/$snapshot$target" --label "当前$target" "$source" "$target" 2>/dev/null | sed -n '1,120p' || true
  fi
}

backups_delete_snapshot() {
  local snapshot="$1" bytes count state
  backup_valid_snapshot "$snapshot" || { warn "备份编号格式无效。"; return 1; }
  [[ -d "$BACKUP_ROOT/$snapshot" && ! -L "$BACKUP_ROOT/$snapshot" ]] || { warn "备份不存在或不是安全目录。"; return 1; }
  if backup_snapshot_protected "$snapshot"; then
    warn "该快照已受保护，请先在保护与备注中取消保护。"
    return 1
  fi
  bytes="$(backup_snapshot_bytes "$snapshot" 2>/dev/null || printf '0')"
  if backup_manifest "$snapshot" >/dev/null 2>&1; then
    count="$(backup_manifest "$snapshot" | grep -c . || true)"
    state="$count 个文件"
  else
    state="清单无效，不能恢复"
  fi
  ui_page "删除配置快照" "$snapshot"
  ui_panel_begin "删除目标"
  ui_panel_kv "快照" "$snapshot" "$YELLOW"
  ui_panel_kv "内容" "$state"
  ui_panel_kv "占用" "$(backup_human_bytes "$bytes")"
  ui_panel_end
  ui_danger "删除后无法通过 keine 恢复此快照。"
  confirm "确认永久删除快照 $snapshot？" || return 0
  require_root
  backup_delete "$snapshot" || return 1
  audit "action=backup-delete snapshot=$snapshot"
  [[ "$DRY_RUN" -eq 1 ]] || ui_success "配置快照已删除。"
}

backups_delete() {
  local snapshot
  backups_recent_hint
  snapshot="$(read_input "备份编号" "")"; [[ -n "$snapshot" ]] || return 0
  backups_delete_snapshot "$snapshot"
}

backups_cleanup() {
  local choice value label snapshot bytes total_bytes=0 preview=""
  local candidates=()
  ui_page "清理历史快照" "只清理 keine 配置备份，不触碰业务数据"
  backups_summary
  ui_section "清理方式" "accent"
  ui_action 1 "保留最近若干份" "warning" "适合控制快照数量"
  ui_action 2 "删除早于若干天" "warning" "适合按维护周期清理"
  ui_menu_footer "取消"
  ui_read_choice choice
  case "$choice" in
    1)
      ui_hint "建议至少保留 10 份；当前操作中的快照始终受保护。"
      value="$(read_input "保留最近多少份" "20")"
      if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < 1 || value > 10000 )); then
        warn "保留数量必须为 1 到 10000。"
        return 1
      fi
      mapfile -t candidates < <(backup_cleanup_keep_candidates "$value")
      label="仅保留最近 $value 份"
      ;;
    2)
      ui_hint "例如 30 表示删除创建时间早于 30 天的快照。"
      value="$(read_input "删除早于多少天" "30")"
      if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < 1 || value > 3650 )); then
        warn "天数必须为 1 到 3650。"
        return 1
      fi
      mapfile -t candidates < <(backup_cleanup_age_candidates "$value")
      label="删除早于 $value 天"
      ;;
    0) return 0 ;;
    *) warn "未知选项"; return 1 ;;
  esac
  ((${#candidates[@]} > 0)) || { ui_success "没有符合清理条件的历史快照。"; return 0; }
  for snapshot in "${candidates[@]}"; do
    bytes="$(backup_snapshot_bytes "$snapshot" 2>/dev/null || printf '0')"
    total_bytes=$((total_bytes + bytes))
  done
  ui_panel_begin "清理预览"
  ui_panel_kv "策略" "$label"
  ui_panel_kv "删除数量" "${#candidates[@]} 份" "$YELLOW"
  ui_panel_kv "预计释放" "$(backup_human_bytes "$total_bytes")"
  ui_panel_end
  if ((${#candidates[@]} <= 8)); then
    for snapshot in "${candidates[@]}"; do
      [[ -z "$preview" ]] || preview+=" · "
      preview+="$snapshot"
    done
    ui_hint "目标：$preview"
  else
    ui_hint "目标较多；最早 ${candidates[${#candidates[@]}-1]}，共 ${#candidates[@]} 份。"
  fi
  ui_danger "清理后的快照无法恢复；受保护、策略保留和当前操作快照不会删除。"
  confirm "执行备份清理？" || return 0
  require_root
  for snapshot in "${candidates[@]}"; do
    backup_delete "$snapshot" || { warn "清理在 $snapshot 处停止。"; return 1; }
  done
  audit "action=backup-cleanup policy=$(printf '%q' "$label") count=${#candidates[@]} bytes=$total_bytes"
  [[ "$DRY_RUN" -eq 1 ]] || ui_success "已删除 ${#candidates[@]} 份历史快照，释放约 $(backup_human_bytes "$total_bytes")。"
}

backups_restore() {
  local snapshot target
  backups_recent_hint
  snapshot="$(read_input "备份编号" "")"; [[ -n "$snapshot" ]] || return 0
  backup_manifest "$snapshot" >/dev/null || { warn "备份不存在或清单无效。"; return 1; }
  printf '\n'; backup_manifest "$snapshot" | nl -ba
  target="$(read_input "要恢复的完整路径" "")"; [[ -n "$target" ]] || return 0
  backup_manifest "$snapshot" | grep -Fxq "$target" || { warn "路径不在该备份清单中。"; return 1; }
  ui_hint "恢复会覆盖当前文件；若要保留当前版本，请先手动创建快照。"
  confirm "从 $snapshot 恢复 $target？" || return 0
  require_root
  backup_restore "$snapshot" "$target" || return 1
  [[ "$DRY_RUN" -eq 1 ]] || ui_success "配置文件已恢复。"
}

backups_menu() {
  local choice
  while true; do
    ui_page "手动备份管理"
    backups_summary
    ui_section "创建与恢复" "accent"
    ui_item 1 "创建配置快照"
    ui_item 2 "恢复一个文件"
    ui_section "查看与验证" "primary"
    ui_item 3 "列出备份"
    ui_item 4 "查看备份内容"
    ui_item 5 "校验备份完整性"
    ui_item 6 "与当前配置比较"
    ui_item 7 "保护与备注"
    ui_section "空间管理" "warning"
    ui_item 8 "删除一个快照"
    ui_item 9 "清理历史快照"
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      1) backups_create || true ;;
      2) backups_restore || true ;;
      3) backups_list ;;
      4) backups_inspect || true ;;
      5) backups_verify || true ;;
      6) backups_compare || true ;;
      7) backups_metadata || true ;;
      8) backups_delete || true ;;
      9) backups_cleanup || true ;;
      0) return 0 ;;
      *) warn "未知选项"; continue ;;
    esac
    pause
  done
}
