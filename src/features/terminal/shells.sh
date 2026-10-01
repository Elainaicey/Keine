#!/usr/bin/env bash

terminal_login_shell() {
  local path
  path="$(getent passwd "$1" | awk -F: 'NR==1 {print $7}')"
  case "${path##*/}" in bash|zsh) printf '%s' "${path##*/}" ;; *) return 1 ;; esac
}

terminal_prompt_rc() {
  local provider="$1" user="$2" home="$3" shell
  shell="$(terminal_login_shell "$user")" || { warn "仅自动配置 Bash / Zsh；请先选择受支持的登录 Shell。"; return 1; }
  if [[ "$provider" == spaceship || "$provider" == oh-my-zsh ]]; then shell=zsh; fi
  printf '%s/.%src' "$home" "$shell"
}

terminal_bash_profile() {
  local home="$1" path
  for path in "$home/.bash_profile" "$home/.bash_login" "$home/.profile"; do
    if [[ -e "$path" || -L "$path" ]]; then printf '%s' "$path"; return 0; fi
  done
  printf '%s/.bash_profile' "$home"
}

terminal_rc_validate() {
  case "$TERMINAL_RC_SHELL" in
    bash) bash -n "$TERMINAL_RC_PATH" ;;
    zsh) zsh -f -n "$TERMINAL_RC_PATH" ;;
    *) return 1 ;;
  esac
}

terminal_write_rc() {
  local path="$1" shell="$2" payload="$3" owner="${4:-}" mode=0644
  local TERMINAL_RC_PATH="$path" TERMINAL_RC_SHELL="$shell"
  local TERMINAL_RC_OWNER="$owner"
  if [[ -f "$path" && ! -L "$path" ]]; then mode="$(stat -c '%a' -- "$path")"; fi
  config_file_write "$path" "$mode" "$payload" terminal_rc_apply terminal_rc_validate
}

terminal_rc_apply() {
  terminal_rc_validate || return 1
  if [[ "$EUID" -eq 0 && -n "$TERMINAL_RC_OWNER" ]]; then
    chown "$TERMINAL_RC_OWNER":"$(id -gn "$TERMINAL_RC_OWNER")" "$TERMINAL_RC_PATH" || return 1
  fi
}

terminal_bash_login_setup() {
  local home="$1" owner="$2" profile payload
  profile="$(terminal_bash_profile "$home")"
  config_file_safe "$profile" || { warn "Bash 登录配置不是安全的普通文件：$profile"; return 1; }
  if grep -Fqx '# BEGIN keine: Bash login' "$profile" 2>/dev/null; then return 0; fi
  # 字面量启动配置只在用户之后进入交互式 Bash 时执行。
  # shellcheck disable=SC2016
  payload="$({
    [[ ! -f "$profile" ]] || cat -- "$profile"
    printf '\n%s\n' '# BEGIN keine: Bash login' \
      'case "$-" in *i*)' \
      '  if [ -n "${BASH_VERSION:-}" ] && [ -z "${KEINE_PROMPT_LOADED:-}" ] && [ -f "$HOME/.bashrc" ]; then' \
      '    . "$HOME/.bashrc"' '  fi' ';; esac' '# END keine: Bash login'
  })"
  terminal_write_rc "$profile" bash "$payload" "$owner"
}

terminal_rc_content() {
  local path="$1" shell="$2" theme="${3:-}"
  [[ -f "$path" ]] || { [[ -z "$theme" ]] || printf 'ZSH_THEME="%s"\n' "$theme"; return 0; }
  awk -v shell="$shell" -v theme="$theme" '
    BEGIN {if (theme!="") print "ZSH_THEME=\"" theme "\""}
    $0=="# BEGIN keine: Prompt" {if(block) bad=1; block=1; next}
    $0=="# END keine: Prompt" {if(!block) bad=1; block=0; next}
    block {next}
    /^[[:space:]]*eval.*(starship init|oh-my-posh init)/ {next}
    shell=="zsh" && /^[[:space:]]*source.*spaceship.*[.]zsh/ {next}
    shell=="zsh" && /^[[:space:]]*(export[[:space:]]+)?ZSH_THEME=/ {if(theme=="") print "ZSH_THEME=\"\""; next}
    {print}
    END {if(block || bad) exit 1}
  ' "$path"
}

terminal_restore_configuration() {
  local user home path entry found=0 failed=0 previous
  user="$(software_target_user)"; home="$(software_target_home "$user")"
  confirm "恢复首次修改前的 Bash / Zsh 配置和已记录的登录 Shell？保留下载的引擎。" || return 0
  require_root
  previous="$CHANGES_RESTORING"; CHANGES_RESTORING=1
  for path in "$home/.bashrc" "$home/.zshrc" "$home/.bash_profile" "$home/.bash_login" "$home/.profile"; do
    entry="$(changes_file_entry "$path")"; [[ -d "$entry" ]] || continue
    found=1; changes_restore_file "$entry" || failed=1
  done
  entry="$(changes_setting_entry shell)"
  if [[ "$user" == root && -d "$entry" ]]; then found=1; changes_restore_setting "$entry" || failed=1; fi
  CHANGES_RESTORING="$previous"
  (( found == 1 )) || { ui_note "没有终端配置的原始记录。"; return 0; }
  (( failed == 0 )) || { warn "部分配置存在冲突或恢复失败，记录已保留。"; return 1; }
  audit 'action=terminal-restore'
  ui_success "初始终端配置已恢复；重新登录后生效。"
}

terminal_diagnose() {
  local user home shell profile provider path command
  user="$(software_target_user)"; home="$(software_target_home "$user")"
  shell="$(terminal_login_shell "$user" || printf unsupported)"
  ui_page "终端 / 生效诊断" "检查登录 Shell、初始化文件和程序；不执行用户启动脚本"
  ui_panel_begin "启动环境"
  ui_panel_kv "用户" "$user"; ui_panel_kv "登录 Shell" "$shell"
  ui_panel_kv "Shell 环境变量" "${SHELL:-未知}（可能是旧会话值）"
  ui_panel_end
  case "$shell" in bash|zsh) path="$home/.${shell}rc" ;; *) warn "此登录 Shell 暂不支持自动配置。"; return 1 ;; esac
  provider="$(sed -n 's/^# provider: //p' "$path" 2>/dev/null | tail -n 1)"
  case "$provider" in starship|oh-my-posh|spaceship) ;; *) provider="未配置" ;; esac
  ui_kv "初始化文件" "$path"; ui_kv "配置引擎" "$provider"
  if [[ "$provider" != 未配置 ]]; then
    if terminal_write_check "$path" "$shell"; then ui_check pass "启动配置语法有效"; else ui_check fail "启动配置语法有误"; fi
    if [[ "$provider" != spaceship ]]; then
      command="$(terminal_prompt_command "$provider" "$home/.local/bin" || true)"
      if [[ -n "$command" && -x "$command" ]]; then ui_check pass "程序可执行：$command"; else ui_check fail "未找到可执行的提示符程序"; fi
    fi
  else ui_check warn "当前登录 Shell 没有项目提示符；可选择引擎重新切换，无需重复下载"; fi
  if [[ "$shell" == bash ]]; then profile="$(terminal_bash_profile "$home")"; ui_kv "登录入口" "$profile"; fi
  ui_hint "安装不改变已经打开的父 Shell。请退出工具后重新连接 SSH；无需重启 VPS。"
  ui_note "诊断检查配置，不宣称当前会话已加载。字体缺字请在 SSH 客户端设置 Nerd Font。"
}

terminal_write_check() {
  local TERMINAL_RC_PATH="$1" TERMINAL_RC_SHELL="$2"
  terminal_rc_validate
}
