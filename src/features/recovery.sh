#!/usr/bin/env bash
# 共享变更状态由 core/changes 模块消费。
# shellcheck disable=SC2034

recovery_entries() {
  local entry status label
  local -A grouped=()
  if declare -F tuning_strategy_id >/dev/null && [[ -d "$(changes_file_entry "$TUNING_STRATEGY_FILE")" ]]; then
    printf 'tuning|%s|整组撤销|网络调优 / %s\n' "$TUNING_STRATEGY_FILE" "$(tuning_strategy_id || printf '需检查')"
    while IFS= read -r entry; do [[ -z "$entry" ]] || grouped["$entry"]=1; done < <(tuning_strategy_entries)
  fi
  for entry in "$(changes_root)"/files/*; do
    [[ -d "$entry" && ! -L "$entry" && -f "$entry/path" ]] || continue
    [[ ! -v 'grouped[$entry]' ]] || continue
    status="$(changes_file_status "$entry")"
    case "$status" in ready) label="可撤销" ;; unchanged) label="已恢复 / 未改变" ;; *) label="外部修改 / 冲突" ;; esac
    printf 'file|%s|%s|%s\n' "$entry" "$label" "$(terminal_safe_text "$(<"$entry/path")")"
  done
  for entry in "$(changes_root)"/settings/*; do
    [[ -d "$entry" && ! -L "$entry" && -f "$entry/before" && -f "$entry/last" ]] || continue
    [[ ! -v 'grouped[$entry]' ]] || continue
    label="$(changes_setting_key "$entry")" || continue
    printf 'setting|%s|设置|%s\n' "$entry" "$label"
  done
  for entry in "$(changes_root)"/packages/*; do
    [[ -f "$entry" && ! -L "$entry" ]] || continue
    printf 'package|%s|项目新增软件包|%s\n' "$entry" "${entry##*/}"
  done
}

recovery_reconcile_file() {
  local path="$1" id _repository _command _amd64 _arm64 _homepage marker
  (( DRY_RUN == 0 )) || return 0
  while IFS='|' read -r id _repository _command _amd64 _arm64 _homepage; do
    [[ "$id" != \#* && -n "$id" ]] || continue
    if [[ "$(software_release_target "$id")" == "$path" ]]; then
      marker="$(software_release_marker "$id")" || return 1
      [[ "$(readlink -m -- "$SOFTWARE_RELEASE_STATE_DIR")" == "$SOFTWARE_RELEASE_STATE_DIR" && ! -L "$marker" ]] || return 1
      rm -f -- "$marker" || return 1
    fi
  done <"$OFFICIAL_RELEASE_CATALOG"
}

recovery_restore_file() {
  local entry="$1" path
  path="$(<"$entry/path")"
  case "$path" in
    "$(security_native_file 4)") security_native_restore 4 ;;
    "$(security_native_file 6)") security_native_restore 6 ;;
    "${NETWORK_DNS_RESOLV:-/etc/resolv.conf}"|"${NETWORK_DNS_DROPIN:-/etc/systemd/resolved.conf.d/90-keine-dns.conf}"|"${NETWORK_DNS_HEAD:-/etc/resolvconf/resolv.conf.d/head}")
      network_dns_restore_path "$path" ;;
    *) changes_restore_file "$entry" ;;
  esac
}

recovery_preflight() {
  local kind entry label path current failed=0
  while IFS='|' read -r kind entry label path; do
    case "$kind" in
      tuning) tuning_strategy_preflight || failed=1 ;;
      file) case "$(changes_file_status "$entry")" in ready|unchanged) ;; *) warn "恢复前发现冲突：$path"; failed=1 ;; esac ;;
      setting)
        current="$(changes_setting_value "$(changes_setting_key "$entry")")" || { failed=1; continue; }
        [[ "$current" == "$(<"$entry/last")" || "$current" == "$(<"$entry/before")" ]] || { warn "设置已被其他工具修改：$path"; failed=1; }
        ;;
    esac
  done < <(recovery_entries)
  changes_packages_plan || failed=1
  (( failed == 0 ))
}

recovery_restore_all() {
  local kind entry label path failed=0 ssh_changed=0 ufw_changed=0
  recovery_preflight || { warn "请先处理冲突，未执行撤销。"; return 1; }
  ui_page "撤销项目变更" "恢复首次修改前的资源，移除项目新增资源"
  ui_note "仅撤销有原始记录且未被外部修改的资源。未记录的历史变更、已有软件的升级和已删除的数据没有可推断的原始状态。"
  ui_hint "若列表涉及 SSH、UFW 或 WARP，请保留服务商控制台；撤销会改变当前网络设置。"
  confirm "撤销当前记录中的项目变更？" || return 1
  require_root
  CHANGES_RESTORING=1
  # Swap 文件可能在使用中，不能当作普通文件 unlink。
  if system_swap_managed; then
    if [[ ! -d "$(changes_file_entry /etc/fstab)" ]]; then
      CHANGES_RESTORING=0; warn "此 Swap 没有原始 fstab 记录；请先从系统中心移除，再执行撤销。"; return 1
    fi
    if system_swap_active && ! run swapoff /swapfile; then
      CHANGES_RESTORING=0; warn "Swap 无法安全停用；停止后续恢复。"; return 1
    fi
    if ! run rm -f -- /swapfile "$(system_swap_marker)"; then CHANGES_RESTORING=0; return 1; fi
  fi
  while IFS='|' read -r kind entry label path; do
    case "$kind" in
      tuning) tuning_strategy_restore || failed=1 ;;
      file)
        case "$path" in /etc/ssh/*) ssh_changed=1 ;; /etc/ufw/*|/etc/default/ufw) ufw_changed=1 ;; esac
        if recovery_restore_file "$entry"; then recovery_reconcile_file "$path" || failed=1; else failed=1; fi
        ;;
      setting) changes_restore_setting "$entry" || failed=1 ;;
    esac
  done < <(recovery_entries)
  if (( DRY_RUN == 0 )); then
    if (( ssh_changed == 1 )); then
      if sshd -t; then
        if service_exists ssh.service; then systemctl reload ssh.service || failed=1
        elif service_exists sshd.service; then systemctl reload sshd.service || failed=1; fi
      else warn "SSH 恢复后的配置检查失败；请保留当前连接并通过控制台修复。"; failed=1; fi
    fi
    if (( ufw_changed == 1 )) && command_exists ufw; then
      if grep -q '^ENABLED=yes' /etc/ufw/ufw.conf; then ufw reload || failed=1; else ufw disable || failed=1; fi
    fi
  fi
  changes_packages_remove || failed=1
  CHANGES_RESTORING=0
  CHANGES_PENDING_FILES=()
  catalog_cache_invalidate
  (( failed == 0 )) || { warn "部分资源已恢复，未完成项及其记录已保留。"; return 1; }
  audit "action=restore-toolkit-changes"
  ui_success "已撤销当前可验证的项目变更。"
}

recovery_changes_menu() {
  local rows=() kind entry label path index choice selected
  while true; do
    mapfile -t rows < <(recovery_entries)
    ui_page "项目变更记录" "原始状态、项目新增资源与外部修改冲突"
    if ((${#rows[@]} == 0)); then ui_empty "还没有可撤销的变更记录"; pause; return 0; fi
    for index in "${!rows[@]}"; do
      IFS='|' read -r kind entry label path <<<"${rows[$index]}"
      ui_item "$((index + 1))" "$path" "$label"
    done
    ui_action A "撤销全部可记录变更" "warning"
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      0) return 0 ;;
      A|a) recovery_restore_all || true; pause ;;
      *)
        if [[ ! "$choice" =~ ^[1-9][0-9]*$ || ${#choice} -gt 4 ]] || (( choice > ${#rows[@]} )); then
          warn "编号无效。"; pause; continue
        fi
        selected="${rows[$((choice - 1))]}"; IFS='|' read -r kind entry label path <<<"$selected"
        if [[ "$kind" == tuning ]]; then
          network_tuning_adapter_menu; continue
        fi
        ui_page "变更详情" "$path"
        ui_kv "类型" "$kind"; ui_kv "状态" "$label"
        ui_action 1 "撤销此资源" "warning" "冲突资源会停止，不覆盖外部修改"
        ui_action 2 "保留资源并解除托管" "danger" "删除这条恢复记录，今后不再撤销它"
        ui_menu_footer "返回"
        ui_read_choice choice
        if [[ "$choice" == 1 && "$kind" != package ]]; then
          confirm "恢复 $path？" || continue; require_root
          CHANGES_RESTORING=1
          if [[ "$kind" == file ]]; then
            if recovery_restore_file "$entry"; then recovery_reconcile_file "$path" || true; fi
          else changes_restore_setting "$entry" || true; fi
          CHANGES_RESTORING=0
          ui_note "DNS 与原生端口规则会重新验证并加载；其他单项配置请进入对应功能中心验证和加载。"
          pause
        elif [[ "$choice" == 1 ]]; then
          ui_note "软件包按依赖事务整体撤销，请使用撤销全部。"; pause
        elif [[ "$choice" == 2 ]]; then
          confirm "保留 $path 并永久删除这条撤销记录？" || continue; require_root
          [[ "$(readlink -m -- "$entry")" == "$entry" && ! -L "$entry" ]] || { warn "记录路径不安全。"; continue; }
          case "$entry" in "$(changes_root)"/files/*|"$(changes_root)"/settings/*|"$(changes_root)"/packages/*)
            run rm -rf -- "$entry" || true ;;
          esac
        fi
        ;;
    esac
  done
}

recovery_menu() {
  local choice
  while true; do
    ui_page "备份与恢复"
    ui_action 1 "手动备份管理" "action"
    ui_action 2 "Docker 卷备份" "action"
    ui_section "撤销项目修改" "warning"
    ui_action 3 "项目变更与撤销" "warning"
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      1) backups_menu ;;
      2) docker_volume_backups_menu ;;
      3) recovery_changes_menu ;;
      0) return 0 ;;
      *) warn "未知选项" ;;
    esac
  done
}
