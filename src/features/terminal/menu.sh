#!/usr/bin/env bash
# 切换与撤销标记由其他领域模块消费。
# shellcheck disable=SC2034

TERMINAL_SWITCHING=0

terminal_prompt_command() {
  local provider="$1" bin="$2"
  if [[ -x "$bin/$provider" ]]; then printf '%s/%s' "$bin" "$provider"; else command -v "$provider"; fi
}

terminal_installed() {
  if [[ "$1" == oh-my-zsh ]]; then software_oh_my_zsh_installed; else software_prompt_installed "$1"; fi
}

terminal_apply() {
  local provider="$1" user home result=0
  user="$(software_target_user)"; home="$(software_target_home "$user")"
  require_root
  package_install zsh || return 1
  TERMINAL_SWITCHING=1
  if [[ "$provider" == oh-my-zsh ]]; then
    software_install_oh_my_zsh || result=$?
    if (( result == 0 )); then
      software_oh_my_zsh_configure "$user" "$home" || result=1
      (( result != 0 )) || terminal_normalize_zshrc "$home/.zshrc" robbyrussell || result=1
    fi
  elif terminal_installed "$provider"; then software_activate_prompt "$provider" || result=$?
  else
    case "$provider" in starship) software_install_starship ;; oh-my-posh) software_install_oh_my_posh ;; spaceship) software_install_spaceship ;; *) result=1 ;; esac || result=$?
  fi
  TERMINAL_SWITCHING=0
  audit "action=terminal-switch provider=$provider result=$result"
  (( result == 0 )) || return "$result"
  ui_success "已切换为 $provider；重新进入 Zsh 后生效。"
}

terminal_menu() {
  local rows=() record id name _kind _handler project description index choice provider installed version action user home entry
  while true; do
    mapfile -t rows < <(awk -F '|' '!/^#/ && NF==6' "$CONFIG_DIR/terminal.tsv")
    ui_page "终端与外观" "独立管理框架与提示符；自动识别已有安装"
    ui_hint "远程终端字体由你的本机终端设置；无需给 VPS 安装字体包。"
    for index in "${!rows[@]}"; do
      IFS='|' read -r id name _kind _handler project description <<<"${rows[$index]}"
      installed="未安装"; version="官方安装"; action="muted"
      if terminal_installed "$id"; then
        installed="已安装"; action="good"
        if [[ "$id" == oh-my-zsh ]]; then version="$(software_oh_my_zsh_version)"; else version="$(software_prompt_version "$id")"; fi
      fi
      if [[ "$id" != oh-my-zsh ]] && software_prompt_active "$id"; then installed="当前启用"; action="primary"; fi
      ui_state_item "$((index + 1))" "$name" "$installed" "$action" "$version"
    done
    ui_action R "恢复原始终端配置" "warning" "保留已下载引擎，恢复首次切换前的 .zshrc"
    ui_action S "默认 Shell" "action" "查看并切换 root 的登录 Shell"
    ui_action 0 "返回" "muted"
    choice="$(read_input "项目编号 / R / S / 0" "0")"
    case "$choice" in
      0) return 0 ;;
      R|r)
        user="$(software_target_user)"; home="$(software_target_home "$user")"; entry="$(changes_file_entry "$home/.zshrc")"
        if [[ -d "$entry" ]] && confirm "恢复首次切换前的 .zshrc？"; then require_root; CHANGES_RESTORING=1; changes_restore_file "$entry" || true; CHANGES_RESTORING=0
        else ui_note "没有可恢复记录，或操作已取消。"; fi
        pause
        ;;
      S|s)
        ui_kv "root 默认 Shell" "$(getent passwd root | awk -F: '{print $7}')"
        if confirm "将 root 登录 Shell 切换为 Zsh？"; then require_root; package_install zsh && run chsh -s "$(command -v zsh)" root; audit "action=terminal-default-shell"; fi
        pause
        ;;
      *)
        if [[ ! "$choice" =~ ^[1-9][0-9]?$ ]] || (( choice > ${#rows[@]} )); then warn "编号无效。"; pause; continue; fi
        record="${rows[$((choice - 1))]}"; IFS='|' read -r provider name _kind _handler project description <<<"$record"
        ui_page "终端配置 / $name" "$description"
        ui_kv "官方项目" "$project"; ui_kv "配置文件" "$(software_target_home "$(software_target_user)")/.zshrc"
        if [[ "$provider" != oh-my-zsh ]] && software_prompt_managed "$provider"; then ui_kv "安装归属" "项目安装，可更新或删除"
        else ui_kv "安装归属" "原生安装只复用配置；新安装会记录所有权"; fi
        ui_action 1 "安装并切换 / 直接切换" "success" "已有程序会复用；切换前记录原始配置"
        ui_action 2 "更新项目安装的引擎" "action"
        ui_action 3 "移除项目安装的引擎" "danger" "外部安装不删除；恢复初始配置请使用 R"
        ui_action 0 "返回" "muted"
        action="$(read_input "请选择" "0")"
        if [[ "$action" == 1 ]] && confirm "切换到 $name？"; then terminal_apply "$provider" || true; pause
        elif [[ "$action" == 2 ]] && confirm "更新 $name？"; then
          require_root
          if [[ "$provider" == oh-my-zsh ]]; then software_update_oh_my_zsh || true; else software_update_prompt "$provider" || true; fi
          audit "action=terminal-update provider=$provider"; pause
        elif [[ "$action" == 3 ]] && confirm "移除项目安装的 $name？"; then
          require_root
          if [[ "$provider" == oh-my-zsh ]]; then software_remove_oh_my_zsh || true; else software_remove_prompt "$provider" || true; fi
          audit "action=terminal-remove provider=$provider"; pause
        fi
        ;;
    esac
  done
}
