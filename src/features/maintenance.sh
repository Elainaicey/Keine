#!/usr/bin/env bash

. "$ROOT_DIR/src/features/maintenance/doctor.sh"
. "$ROOT_DIR/src/features/maintenance/menu.sh"

toolkit_about() {
  ui_page "关于 keine" "版本、路径与项目资源"
  ui_panel_begin "版本"
  ui_panel_kv "当前版本" "$KEINE_VERSION" "$CYAN"
  ui_panel_kv "发布通道" "stable / main"
  ui_panel_end
  ui_panel_begin "本机路径"
  ui_panel_kv "安装目录" "$ROOT_DIR"
  ui_panel_kv "软件目录" "$SOFTWARE_CATALOG"
  ui_panel_kv "配置备份" "$BACKUP_ROOT"
  ui_panel_kv "Docker 卷备份" "$DOCKER_VOLUME_BACKUP_ROOT"
  ui_panel_kv "操作记录" "$AUDIT_LOG"
  ui_panel_end
  ui_note "项目主页：https://github.com/Elainaicey/keine"
}

toolkit_remote_version() {
  command_exists curl || return 1
  curl --disable -fsSL --retry 2 --connect-timeout 5 --max-time 15 \
    "https://raw.githubusercontent.com/Elainaicey/keine/refs/heads/main/VERSION" 2>/dev/null |
    tr -d '[:space:]'
}

toolkit_update_reload() {
  local answer
  while true; do
    answer="$(read_input "Enter 加载新版 · Q 退出" "")"
    case "$answer" in
      Q|q) exit 0 ;;
      ""|H|h)
        # The installer may have replaced the directory we were running inside.
        cd -- "$ROOT_DIR" || die "无法进入更新后的目录，请退出并重新运行 keine。"
        navigation_home
        # A successful exec never returns. Do not resume an outdated menu.
        die "无法加载新版，请重新运行 keine。"
        ;;
      *) warn "按 Enter 加载新版，或按 Q 退出。" ;;
    esac
  done
}

toolkit_self_update() {
  local context="${1:-command}" latest installed_version installer bin_path="/usr/local/bin/keine"
  local installer_args=()
  case "$context" in menu|command) ;; *) return 1 ;; esac
  command_exists curl || { warn "缺少 curl，无法获取更新。"; return 1; }
  latest="$(toolkit_remote_version)" || { warn "无法连接 GitHub 或读取远端版本。"; return 1; }
  [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { warn "远端版本格式无效：$latest"; return 1; }
  ui_page "更新 keine" "使用原子替换安装流程更新项目自身"
  ui_panel_begin "更新目标"
  ui_panel_kv "当前版本" "$KEINE_VERSION"
  ui_panel_kv "远端版本" "$latest" "$CYAN"
  ui_panel_kv "安装目录" "$ROOT_DIR"
  ui_panel_end
  if [[ "$latest" == "$KEINE_VERSION" ]]; then
    ui_success "已经是最新发布版本。"
    confirm "仍要从 GitHub main 重新部署当前版本？" || return 0
  else
    confirm "从 GitHub main 更新 keine？" || return 0
  fi
  require_root
  if [[ -r "$ROOT_DIR/config/installation.conf" ]]; then
    # shellcheck source=/dev/null
    . "$ROOT_DIR/config/installation.conf"
    bin_path="${KEINE_BIN_PATH:-$bin_path}"
  fi
  installer="$(mktemp)" || { warn "无法创建更新安装器临时文件。"; return 1; }
  if ! curl --disable -fsSL --retry 3 --connect-timeout 10 --max-time 120 \
    "https://raw.githubusercontent.com/Elainaicey/keine/refs/heads/main/scripts/install.sh" -o "$installer"; then
    rm -f -- "$installer"
    warn "更新安装器下载失败。"
    return 1
  fi
  [[ "$DRY_RUN" -eq 0 ]] || installer_args+=(--dry-run)
  if bash "$installer" --ref main --dir "$ROOT_DIR" --bin "$bin_path" "${installer_args[@]}"; then
    rm -f -- "$installer"
    if (( DRY_RUN == 1 )); then
      info "更新预览完成；未替换程序，不重新加载。"
      return 0
    fi
    installed_version="$(tr -d '[:space:]' <"$ROOT_DIR/VERSION" 2>/dev/null)" || installed_version=""
    if ! toolkit_version_valid "$installed_version" || [[ ! -r "$ROOT_DIR/bin/keine" ]] ||
      ! "$BASH" -n "$ROOT_DIR/bin/keine"; then
      warn "更新后的版本或入口验证失败，请重新安装 keine。"
      # Files were replaced: continuing this interactive process could mix old code and new data.
      [[ "$context" != menu ]] || exit 1
      return 1
    fi
    audit "action=toolkit-update from=$KEINE_VERSION to=$installed_version"
    ui_success "keine 已更新至 $installed_version。"
    if [[ "$context" == menu ]]; then
      toolkit_update_reload
    else
      ui_note "下次启动 keine 将加载新版。"
    fi
  else
    rm -f -- "$installer"
    return 1
  fi
}

toolkit_uninstall() {
  local choice installer install_metadata bin_path
  local uninstall_args=()
  installer="$ROOT_DIR/scripts/install.sh"
  install_metadata="$ROOT_DIR/config/installation.conf"
  bin_path="/usr/local/bin/keine"
  [[ -f "$installer" ]] || die "没有找到卸载器：$installer"
  if [[ -r "$install_metadata" ]]; then
    # 该文件由安装器生成，只包含经过 shell 转义的安装路径。
    # shellcheck source=/dev/null
    . "$install_metadata"
    bin_path="${KEINE_BIN_PATH:-$bin_path}"
    export KEINE_BACKUP_ROOT KEINE_DOCKER_BACKUP_ROOT KEINE_LOG_ROOT KEINE_STATE_ROOT
  fi

  ui_page "卸载 keine" "安全删除程序文件与可选的项目数据"
  ui_danger "卸载会立即结束当前控制台。"
  ui_action 1 "仅卸载程序" "warning" "删除程序，保留日志与备份"
  ui_action 2 "彻底清除项目数据" "danger" "同时删除项目日志、备份和状态数据"
  ui_action 3 "撤销已记录修改并卸载" "danger" "先校验恢复；存在冲突或撤销失败时保留项目"
  ui_hint "仅选项 3 撤销已记录的系统修改。"
  ui_menu_footer "取消"
  (( DRY_RUN == 0 )) || uninstall_args+=(--dry-run)
  ui_read_choice choice
  case "$choice" in
    1) exec bash "$installer" --uninstall --dir "$ROOT_DIR" --bin "$bin_path" "${uninstall_args[@]}" ;;
    2) exec bash "$installer" --uninstall --purge-data --dir "$ROOT_DIR" --bin "$bin_path" "${uninstall_args[@]}" ;;
    3)
      recovery_restore_all || { warn "撤销未全部完成；已保留工具和恢复记录。"; return 1; }
      exec bash "$installer" --uninstall --purge-data --dir "$ROOT_DIR" --bin "$bin_path" "${uninstall_args[@]}"
      ;;
    0) return 0 ;;
    *) warn "未知选项"; return 1 ;;
  esac
}
