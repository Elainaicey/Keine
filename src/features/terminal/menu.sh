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
  local provider="$1" user home shell result=0 switch_shell=0 zsh_path
  user="$(software_target_user)"; home="$(software_target_home "$user")"
  require_root
  shell="$(terminal_login_shell "$user")" || { warn "当前登录 Shell 不受支持。"; return 1; }
  if [[ "$provider" == oh-my-zsh || "$provider" == spaceship ]]; then
    if [[ "$shell" != zsh ]]; then
      ui_hint "$provider 只支持 Zsh；写入 .zshrc 不会让 Bash 加载它。"
      confirm "安装和配置成功后，将 $user 的登录 Shell 改为 Zsh？" || return 0
      switch_shell=1
    fi
    package_install zsh || return 1
  fi
  TERMINAL_SWITCHING=1
  if [[ "$provider" == oh-my-zsh ]]; then
    software_install_oh_my_zsh || result=$?
    if (( result == 0 )); then
      software_oh_my_zsh_configure "$user" "$home" || result=1
      (( result != 0 )) || terminal_normalize_zshrc "$home/.zshrc" robbyrussell "$user" || result=1
    fi
  elif terminal_installed "$provider"; then software_activate_prompt "$provider" || result=$?
  else
    case "$provider" in starship) software_install_starship ;; oh-my-posh) software_install_oh_my_posh ;; spaceship) software_install_spaceship ;; *) result=1 ;; esac || result=$?
  fi
  TERMINAL_SWITCHING=0
  audit "action=terminal-switch provider=$provider result=$result"
  (( result == 0 )) || return "$result"
  if (( switch_shell == 1 )); then
    zsh_path="$(command -v zsh)" || return 1
    run chsh -s "$zsh_path" "$user" || { warn "引擎已配置，但登录 Shell 切换失败。"; return 1; }
    (( DRY_RUN == 1 )) || [[ "$(terminal_login_shell "$user")" == zsh ]] || return 1
    shell=zsh
  fi
  ui_success "已为 $shell 配置 $provider；退出工具后重新连接 SSH 即可，无需重启 VPS。"
  ui_note "安装程序不能修改已经打开的父 Shell。生效异常可运行 keine terminal-check。"
}

terminal_menu() {
  local rows=() record id name _kind _handler project description index choice provider installed version action user home shell result
  while true; do
    mapfile -t rows < <(awk -F '|' '!/^#/ && NF==6' "$CONFIG_DIR/terminal.tsv")
    ui_page "系统 / 终端与美化" "默认 Shell、框架与提示符；自动识别已有安装"
    user="$(software_target_user)"; home="$(software_target_home "$user")"
    shell="$(terminal_login_shell "$user" || printf unsupported)"
    ui_kv "登录 Shell" "$shell"
    ui_hint "远程终端字体由你的本机终端设置；无需给 VPS 安装字体包。"
    for index in "${!rows[@]}"; do
      IFS='|' read -r id name _kind _handler project description <<<"${rows[$index]}"
      installed="未安装"; version="官方安装"; action="muted"
      if terminal_installed "$id"; then
        installed="已安装"; action="good"
        if [[ "$id" == oh-my-zsh ]]; then version="$(software_oh_my_zsh_version)"; else version="$(software_prompt_version "$id")"; fi
      fi
      if [[ "$id" != oh-my-zsh ]] && software_prompt_active "$id"; then installed="已配置 · $shell"; action="primary"; fi
      ui_state_item "$((index + 1))" "$name" "$installed" "$action" "$version"
    done
    ui_action D "生效诊断" "action" "登录 Shell、初始化文件与程序可用性"
    ui_action R "恢复原始终端配置" "warning" "Bash / Zsh 配置及记录的登录 Shell"
    ui_action S "默认 Shell" "action" "查看并切换 root 的登录 Shell"
    ui_action 0 "返回" "muted"
    choice="$(read_input "项目编号 / D / R / S / 0" "0")"
    case "$choice" in
      0) return 0 ;;
      D|d) terminal_diagnose || true; pause ;;
      R|r) terminal_restore_configuration || true; pause ;;
      S|s)
        ui_kv "root 默认 Shell" "$(getent passwd root | awk -F: '{print $7}')"
        if confirm "将 root 登录 Shell 切换为 Zsh？"; then
          require_root
          if package_install zsh && run chsh -s "$(command -v zsh)" root; then audit "action=terminal-default-shell result=0"
          else warn "登录 Shell 切换未完成。"; fi
        fi
        pause
        ;;
      *)
        if [[ ! "$choice" =~ ^[1-9][0-9]?$ ]] || (( choice > ${#rows[@]} )); then warn "编号无效。"; pause; continue; fi
        record="${rows[$((choice - 1))]}"; IFS='|' read -r provider name _kind _handler project description <<<"$record"
        ui_page "终端配置 / $name" "$description"
        ui_kv "官方项目" "$project"; ui_kv "配置文件" "$(terminal_prompt_rc "$provider" "$user" "$home" || printf '不受支持')"
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
          result=0
          if [[ "$provider" == oh-my-zsh ]]; then software_update_oh_my_zsh || result=$?; else software_update_prompt "$provider" || result=$?; fi
          audit "action=terminal-update provider=$provider result=$result"; pause
        elif [[ "$action" == 3 ]] && confirm "移除项目安装的 $name？"; then
          require_root
          result=0
          if [[ "$provider" == oh-my-zsh ]]; then software_remove_oh_my_zsh || result=$?; else software_remove_prompt "$provider" || result=$?; fi
          audit "action=terminal-remove provider=$provider result=$result"; pause
        fi
        ;;
    esac
  done
}
