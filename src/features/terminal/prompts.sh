#!/usr/bin/env bash

PROMPT_BLOCK_BEGIN="# BEGIN keine: Prompt"
PROMPT_BLOCK_END="# END keine: Prompt"

software_prompt_paths() {
  local user home state
  user="$(software_target_user)"
  home="$(software_target_home "$user")"
  state="$home/.local/share/keine/prompts"
  printf '%s|%s|%s|%s' "$user" "$home" "$home/.local/bin" "$state"
}

software_prompt_marker() {
  local provider="$1" paths _user _home _bin state
  paths="$(software_prompt_paths)"
  IFS='|' read -r _user _home _bin state <<<"$paths"
  printf '%s/%s.managed' "$state" "$provider"
}

software_prompt_managed() {
  [[ -f "$(software_prompt_marker "$1")" ]]
}

software_prompt_active() {
  local provider="$1" paths user home _bin _state rc
  paths="$(software_prompt_paths)"; IFS='|' read -r user home _bin _state <<<"$paths"
  if [[ "$provider" == spaceship && "$(terminal_login_shell "$user" || true)" != zsh ]]; then return 1; fi
  rc="$(terminal_prompt_rc "$provider" "$user" "$home")" || return 1
  grep -Fqx "# provider: $provider" "$rc" 2>/dev/null
}

terminal_spaceship_directory() {
  local home="$1" directory remote
  for directory in "$home/.local/share/keine/prompts/spaceship" "$home/.oh-my-zsh/custom/themes/spaceship-prompt" "$home/.oh-my-zsh/custom/themes/spaceship"; do
    [[ -f "$directory/spaceship.zsh" && -d "$directory/.git" && ! -L "$directory" ]] || continue
    remote="$(git -C "$directory" remote get-url origin 2>/dev/null || true)"
    case "$remote" in https://github.com/spaceship-prompt/spaceship-prompt|https://github.com/spaceship-prompt/spaceship-prompt.git)
      printf '%s' "$directory"; return 0 ;;
    esac
  done
  return 1
}

software_prompt_version() {
  local provider="$1" paths _user home bin _state directory
  paths="$(software_prompt_paths)"
  IFS='|' read -r _user home bin _state <<<"$paths"
  case "$provider" in
    starship) "$(terminal_prompt_command starship "$bin")" --version 2>/dev/null | awk 'NR == 1 {print $2}' ;;
    oh-my-posh) "$(terminal_prompt_command oh-my-posh "$bin")" version 2>/dev/null | awk 'NR == 1 {print $1}' ;;
    spaceship)
      directory="$(terminal_spaceship_directory "$home")" || return 1
      git -C "$directory" rev-parse --short=12 HEAD 2>/dev/null || true
      ;;
  esac
}

software_prompt_installed() {
  local provider="$1" paths _user home bin _state
  paths="$(software_prompt_paths)"
  IFS='|' read -r _user home bin _state <<<"$paths"
  case "$provider" in
    starship) [[ -x "$bin/starship" ]] || command_exists starship ;;
    oh-my-posh) [[ -x "$bin/oh-my-posh" ]] || command_exists oh-my-posh ;;
    spaceship) terminal_spaceship_directory "$home" >/dev/null ;;
    *) return 1 ;;
  esac
}

terminal_normalize_zshrc() {
  local zshrc="$1" theme="${2:-}" owner="${3:-}" payload
  payload="$(terminal_rc_content "$zshrc" zsh "$theme")" || { warn "提示符托管块不完整，未修改配置。"; return 1; }
  terminal_write_rc "$zshrc" zsh "$payload" "$owner"
}

terminal_create_directory() {
  local user="$1" home="$2" directory="$3" path index
  local missing=()
  [[ "$directory" == "$home/"* && "$(readlink -m -- "$directory")" == "$directory" ]] || {
    warn "终端目录不是安全的用户目录：$directory"; return 1;
  }
  path="$directory"
  while [[ "$path" != "$home" && ! -e "$path" ]]; do
    missing+=("$path"); path="$(dirname -- "$path")"
  done
  # 在实际 mkdir 前登记新目录，在 mkdir 后立即提交；不提前消费安装器的记录。
  if declare -F changes_prepare_file >/dev/null; then
    for ((index=${#missing[@]}-1; index>=0; index--)); do
      changes_prepare_file "${missing[$index]}" directory || return 1
    done
  fi
  software_run_as_target "$user" "$home" mkdir -p "$directory"
}

software_prompt_activate() {
  local provider="$1" user="$2" home="$3" rc shell init_line directory command payload
  rc="$(terminal_prompt_rc "$provider" "$user" "$home")" || return 1
  shell=zsh; [[ "$rc" != "$home/.bashrc" ]] || shell=bash
  case "$provider" in
    starship|oh-my-posh)
      if (( DRY_RUN == 1 )); then command="$home/.local/bin/$provider"
      else command="$(terminal_prompt_command "$provider" "$home/.local/bin")" || return 1; fi
      printf -v command '%q' "$command"
      init_line="eval \"\$($command init $shell)\""
      ;;
    spaceship)
      if [[ "$DRY_RUN" -eq 1 ]]; then directory="$home/.local/share/keine/prompts/spaceship"
      else directory="$(terminal_spaceship_directory "$home")" || return 1; fi
      printf -v init_line 'source %q' "$directory/spaceship.zsh"
      ;;
    *) die "未知提示符引擎：$provider" ;;
  esac
  if [[ "$DRY_RUN" -eq 1 ]]; then info "将把 $provider 配置到 $user 的 $shell 提示符：$rc。"; return 0; fi
  config_file_safe "$rc" || { warn "启动文件不是安全的普通文件：$rc"; return 1; }
  payload="$(terminal_rc_content "$rc" "$shell")" || { warn "提示符托管块不完整，未修改配置。"; return 1; }
  # shellcheck disable=SC2016
  payload+="$(printf '\n%s\n' "$PROMPT_BLOCK_BEGIN" \
    "# provider: $provider" 'if [[ $- == *i* ]]; then' '  export PATH="$HOME/.local/bin:$PATH"' \
    "  $init_line" "  KEINE_PROMPT_LOADED=$provider" 'fi' "$PROMPT_BLOCK_END")"
  terminal_write_rc "$rc" "$shell" "$payload" "$user" || return 1
  if [[ "$shell" == bash ]]; then terminal_bash_login_setup "$home" "$user" || return 1; fi
}

software_prompt_mark() {
  local provider="$1" user="$2" home="$3" paths _user _home _bin state
  paths="$(software_prompt_paths)"; IFS='|' read -r _user _home _bin state <<<"$paths"
  if [[ "$DRY_RUN" -eq 1 ]]; then return 0; fi
  terminal_create_directory "$user" "$home" "$state" || return 1
  if declare -F changes_prepare_file >/dev/null; then changes_prepare_file "$state/$provider.managed" || return 1; fi
  software_run_as_target "$user" "$home" touch "$state/$provider.managed" || { warn "无法写入提示符托管标记。"; return 1; }
}

software_prompt_download_installer() {
  local url="$1" target
  target="$(mktemp)" || { warn "无法创建安装程序临时文件。"; return 1; }
  if ! curl --disable -fsSL --proto '=https' --proto-redir '=https' --retry 2 --connect-timeout 10 --max-time 120 --max-filesize 2097152 "$url" -o "$target"; then
    rm -f "$target"; warn "下载官方安装程序失败：$url"; return 1
  fi
  chmod 0755 "$target" || { rm -f "$target"; warn "无法设置安装程序权限。"; return 1; }
  printf '%s' "$target"
}

software_install_starship() {
  local paths user home bin _state installer
  paths="$(software_prompt_paths)"; IFS='|' read -r user home bin _state <<<"$paths"
  [[ ! -e "$bin/starship" ]] || software_prompt_managed starship || die "$bin/starship 已存在且不由 keine 管理。"
  package_install curl ca-certificates || return 1
  terminal_create_directory "$user" "$home" "$bin" || return 1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "将从 Starship 官方安装器部署到 $bin。"
  else
    installer="$(software_prompt_download_installer https://starship.rs/install.sh)" || return 1
    if declare -F changes_prepare_file >/dev/null && ! changes_prepare_file "$bin/starship"; then rm -f "$installer"; return 1; fi
    software_run_as_target "$user" "$home" sh "$installer" -y -b "$bin" || { rm -f "$installer"; warn "Starship 官方安装器执行失败。"; return 1; }
    rm -f "$installer"
  fi
  software_prompt_mark starship "$user" "$home" || return 1
  software_prompt_activate starship "$user" "$home" || return 1
}

software_install_oh_my_posh() {
  local paths user home bin _state installer
  paths="$(software_prompt_paths)"; IFS='|' read -r user home bin _state <<<"$paths"
  [[ ! -e "$bin/oh-my-posh" ]] || software_prompt_managed oh-my-posh || die "$bin/oh-my-posh 已存在且不由 keine 管理。"
  package_install curl ca-certificates unzip || return 1
  terminal_create_directory "$user" "$home" "$bin" || return 1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "将从 Oh My Posh 官方安装器部署到 $bin。"
  else
    installer="$(software_prompt_download_installer https://ohmyposh.dev/install.sh)" || return 1
    if declare -F changes_prepare_file >/dev/null; then
      if ! changes_prepare_file "$bin/oh-my-posh"; then rm -f "$installer"; return 1; fi
      if [[ ! -d "$home/.cache/oh-my-posh" ]] && ! changes_prepare_file "$home/.cache/oh-my-posh" directory; then rm -f "$installer"; return 1; fi
    fi
    software_run_as_target "$user" "$home" bash "$installer" -d "$bin" || { rm -f "$installer"; warn "Oh My Posh 官方安装器执行失败。"; return 1; }
    rm -f "$installer"
  fi
  software_prompt_mark oh-my-posh "$user" "$home" || return 1
  software_prompt_activate oh-my-posh "$user" "$home" || return 1
}

software_install_spaceship() {
  local paths user home _bin state directory
  paths="$(software_prompt_paths)"; IFS='|' read -r user home _bin state <<<"$paths"
  directory="$state/spaceship"
  safe_managed_path "$directory" || die "Spaceship 目标路径不安全：$directory"
  [[ ! -e "$directory" ]] || software_prompt_managed spaceship || die "$directory 已存在且不由 keine 管理。"
  package_install zsh git || return 1
  terminal_create_directory "$user" "$home" "$state" || return 1
  if declare -F changes_prepare_file >/dev/null; then changes_prepare_file "$directory" directory || return 1; fi
  software_run_as_target "$user" "$home" git clone --depth=1 https://github.com/spaceship-prompt/spaceship-prompt.git "$directory" || {
    warn "Spaceship Prompt 官方仓库克隆失败。"
    return 1
  }
  software_prompt_mark spaceship "$user" "$home" || return 1
  software_prompt_activate spaceship "$user" "$home" || return 1
}

software_update_prompt() {
  local provider="$1" paths user home bin state installer
  paths="$(software_prompt_paths)"; IFS='|' read -r user home bin state <<<"$paths"
  software_prompt_managed "$provider" || die "$provider 为外部安装，请使用原安装渠道更新。"
  if declare -F changes_prepare_file >/dev/null; then
    case "$provider" in starship|oh-my-posh) changes_prepare_file "$bin/$provider" || return 1 ;; spaceship) changes_prepare_file "$state/spaceship" directory || return 1 ;; esac
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then info "将从 $provider 官方来源检查并安装最新版本。"; return 0; fi
  case "$provider" in
    starship)
      installer="$(software_prompt_download_installer https://starship.rs/install.sh)" || return 1
      software_run_as_target "$user" "$home" sh "$installer" -y -b "$bin" || { rm -f "$installer"; warn "Starship 更新失败。"; return 1; }
      rm -f "$installer"
      ;;
    oh-my-posh)
      installer="$(software_prompt_download_installer https://ohmyposh.dev/install.sh)" || return 1
      software_run_as_target "$user" "$home" bash "$installer" -d "$bin" || { rm -f "$installer"; warn "Oh My Posh 更新失败。"; return 1; }
      rm -f "$installer"
      ;;
    spaceship)
      software_run_as_target "$user" "$home" git -C "$state/spaceship" pull --ff-only || { warn "Spaceship Prompt 更新失败。"; return 1; }
      ;;
  esac
}

software_activate_prompt() {
  local provider="$1" paths user home _bin _state
  paths="$(software_prompt_paths)"; IFS='|' read -r user home _bin _state <<<"$paths"
  software_prompt_installed "$provider" || die "$provider 未由 keine 安装。"
  software_prompt_activate "$provider" "$user" "$home" || return 1
}

software_remove_prompt() {
  local provider="$1" paths user home bin state rc shell payload
  paths="$(software_prompt_paths)"; IFS='|' read -r user home bin state <<<"$paths"
  software_prompt_managed "$provider" || die "$provider 为外部安装，项目仅管理其配置，不删除原程序。"
  safe_toolkit_path "$state" || die "提示符状态路径不安全：$state"
  if declare -F changes_prepare_file >/dev/null; then
    case "$provider" in starship|oh-my-posh) changes_prepare_file "$bin/$provider" || return 1 ;; spaceship) changes_prepare_file "$state/spaceship" directory || return 1 ;; esac
    changes_prepare_file "$state/$provider.managed" || return 1
  fi
  if [[ "$DRY_RUN" -eq 0 ]]; then
    for shell in bash zsh; do
      rc="$home/.${shell}rc"
      if grep -Fqx "# provider: $provider" "$rc" 2>/dev/null; then
        payload="$(terminal_rc_content "$rc" "$shell")" || return 1
        terminal_write_rc "$rc" "$shell" "$payload" "$user" || return 1
      fi
    done
    case "$provider" in
      starship) rm -f -- "$bin/starship" || { warn "无法删除 Starship。"; return 1; } ;;
      oh-my-posh) rm -f -- "$bin/oh-my-posh" || { warn "无法删除 Oh My Posh。"; return 1; } ;;
      spaceship) rm -rf -- "$state/spaceship" || { warn "无法删除 Spaceship Prompt。"; return 1; } ;;
    esac
    rm -f -- "$state/$provider.managed" || { warn "无法删除提示符托管标记。"; return 1; }
  fi
  info "已保留其他提示符、Oh My Zsh、用户自定义配置和 Nerd Font。"
}
