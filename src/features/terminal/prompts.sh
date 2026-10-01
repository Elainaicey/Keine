#!/usr/bin/env bash

PROMPT_BLOCK_BEGIN="# BEGIN Server Toolkit: Prompt"
PROMPT_BLOCK_END="# END Server Toolkit: Prompt"

software_prompt_paths() {
  local user home
  user="$(software_target_user)"
  home="$(software_target_home "$user")"
  printf '%s|%s|%s|%s' "$user" "$home" "$home/.local/bin" "$home/.local/share/server-toolkit/prompts"
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
  local provider="$1" paths _user home _bin _state
  paths="$(software_prompt_paths)"; IFS='|' read -r _user home _bin _state <<<"$paths"
  grep -Fqx "# provider: $provider" "$home/.zshrc" 2>/dev/null
}

terminal_spaceship_directory() {
  local home="$1" directory remote
  for directory in "$home/.local/share/server-toolkit/prompts/spaceship" "$home/.oh-my-zsh/custom/themes/spaceship-prompt" "$home/.oh-my-zsh/custom/themes/spaceship"; do
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

software_prompt_remove_block() {
  local zshrc="$1" temporary
  [[ -f "$zshrc" ]] || return 0
  grep -Fq "$PROMPT_BLOCK_BEGIN" "$zshrc" || return 0
  grep -Fq "$PROMPT_BLOCK_END" "$zshrc" || { warn "$zshrc 中的提示符托管块不完整，已保留原文件。"; return 1; }
  temporary="$(mktemp)" || { warn "无法创建提示符配置临时文件。"; return 1; }
  awk -v begin="$PROMPT_BLOCK_BEGIN" -v end="$PROMPT_BLOCK_END" '
    $0 == begin {managed=1; next}
    $0 == end && managed {managed=0; next}
    !managed {print}
  ' "$zshrc" >"$temporary"
  printf '%s' "$temporary"
}

terminal_normalize_zshrc() {
  local zshrc="$1" theme="${2:-}" temporary stripped=""
  backup_file "$zshrc" || return 1
  (( DRY_RUN == 0 )) || return 0
  stripped="$(software_prompt_remove_block "$zshrc")" || return 1
  temporary="$(mktemp)" || { [[ -z "$stripped" ]] || rm -f -- "$stripped"; return 1; }
  if [[ -f "$zshrc" ]]; then
    awk -v theme="$theme" '
      BEGIN {if (theme != "") print "ZSH_THEME=\"" theme "\""}
      /^[[:space:]]*(eval.*(starship init|oh-my-posh init)|source.*spaceship.*[.]zsh)/ {next}
      /^[[:space:]]*(export[[:space:]]+)?ZSH_THEME=/ {if (theme == "") print "ZSH_THEME=\"\"";next}
      {print}
    ' "${stripped:-$zshrc}" >"$temporary" || { rm -f -- "$temporary" "$stripped"; return 1; }
  fi
  install -m 0644 "$temporary" "$zshrc" || { rm -f -- "$temporary" "$stripped"; return 1; }
  rm -f -- "$temporary"
  [[ -z "$stripped" ]] || rm -f -- "$stripped"
}

terminal_prepare_paths() {
  local home="$1" path
  declare -F changes_prepare_file >/dev/null || return 0
  # 对新建的父目录只登记一次；已有用户目录不会整体接管。
  for path in "$home/.local" "$home/.local/bin" "$home/.local/share" "$home/.local/share/server-toolkit" "$home/.local/share/server-toolkit/prompts"; do
    if [[ ! -e "$path" ]]; then changes_prepare_file "$path" directory || return 1; fi
  done
}

software_prompt_activate() {
  local provider="$1" user="$2" home="$3" zshrc="$3/.zshrc" init_line separator="" directory
  case "$provider" in
    starship) init_line="eval \"\$(starship init zsh)\"" ;;
    oh-my-posh) init_line="eval \"\$(oh-my-posh init zsh --strict)\"" ;;
    spaceship)
      if [[ "$DRY_RUN" -eq 1 ]]; then directory="$home/.local/share/server-toolkit/prompts/spaceship"
      else directory="$(terminal_spaceship_directory "$home")" || return 1; fi
      printf -v init_line 'source %q' "$directory/spaceship.zsh"
      ;;
    *) die "未知提示符引擎：$provider" ;;
  esac
  backup_file "$zshrc" || { warn "无法备份 $zshrc。"; return 1; }
  if [[ "$DRY_RUN" -eq 1 ]]; then info "将把 $provider 设置为 $user 的活动 Zsh 提示符。"; return 0; fi
  terminal_normalize_zshrc "$zshrc" || return 1
  [[ ! -s "$zshrc" ]] || separator=$'\n'
  printf '%s%s\n%s\n%s\n%s\n%s\n' "$separator" "$PROMPT_BLOCK_BEGIN" \
    "# provider: $provider" "export PATH=\"\$HOME/.local/bin:\$PATH\"" "$init_line" "$PROMPT_BLOCK_END" >>"$zshrc" || {
      warn "无法写入 $zshrc。"
      return 1
    }
  if [[ "$EUID" -eq 0 ]]; then chown "$user":"$(id -gn "$user")" "$zshrc" || { warn "无法设置 $zshrc 所有者。"; return 1; }; fi
}

software_prompt_mark() {
  local provider="$1" user="$2" home="$3" state="$3/.local/share/server-toolkit/prompts"
  if [[ "$DRY_RUN" -eq 1 ]]; then return 0; fi
  if declare -F changes_prepare_file >/dev/null; then changes_prepare_file "$state/$provider.managed" || return 1; fi
  software_run_as_target "$user" "$home" mkdir -p "$state" || { warn "无法创建提示符状态目录。"; return 1; }
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
  terminal_prepare_paths "$home" || return 1
  [[ ! -e "$bin/starship" ]] || software_prompt_managed starship || die "$bin/starship 已存在且不由 Server Toolkit 管理。"
  if declare -F changes_prepare_file >/dev/null; then changes_prepare_file "$bin/starship" || return 1; fi
  package_install curl ca-certificates || return 1
  software_run_as_target "$user" "$home" mkdir -p "$bin" || { warn "无法创建用户命令目录。"; return 1; }
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "将从 Starship 官方安装器部署到 $bin。"
  else
    installer="$(software_prompt_download_installer https://starship.rs/install.sh)" || return 1
    software_run_as_target "$user" "$home" sh "$installer" -y -b "$bin" || { rm -f "$installer"; warn "Starship 官方安装器执行失败。"; return 1; }
    rm -f "$installer"
  fi
  software_prompt_mark starship "$user" "$home" || return 1
  software_prompt_activate starship "$user" "$home" || return 1
}

software_install_oh_my_posh() {
  local paths user home bin _state installer
  paths="$(software_prompt_paths)"; IFS='|' read -r user home bin _state <<<"$paths"
  terminal_prepare_paths "$home" || return 1
  [[ ! -e "$bin/oh-my-posh" ]] || software_prompt_managed oh-my-posh || die "$bin/oh-my-posh 已存在且不由 Server Toolkit 管理。"
  if declare -F changes_prepare_file >/dev/null; then
    changes_prepare_file "$bin/oh-my-posh" || return 1
    [[ -d "$home/.cache/oh-my-posh" ]] || changes_prepare_file "$home/.cache/oh-my-posh" directory || return 1
  fi
  package_install curl ca-certificates unzip || return 1
  software_run_as_target "$user" "$home" mkdir -p "$bin" || { warn "无法创建用户命令目录。"; return 1; }
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "将从 Oh My Posh 官方安装器部署到 $bin。"
  else
    installer="$(software_prompt_download_installer https://ohmyposh.dev/install.sh)" || return 1
    software_run_as_target "$user" "$home" bash "$installer" -d "$bin" || { rm -f "$installer"; warn "Oh My Posh 官方安装器执行失败。"; return 1; }
    rm -f "$installer"
  fi
  software_prompt_mark oh-my-posh "$user" "$home" || return 1
  software_prompt_activate oh-my-posh "$user" "$home" || return 1
}

software_install_spaceship() {
  local paths user home _bin state directory
  paths="$(software_prompt_paths)"; IFS='|' read -r user home _bin state <<<"$paths"
  terminal_prepare_paths "$home" || return 1
  directory="$state/spaceship"
  safe_managed_path "$directory" || die "Spaceship 目标路径不安全：$directory"
  [[ ! -e "$directory" ]] || software_prompt_managed spaceship || die "$directory 已存在且不由 Server Toolkit 管理。"
  if declare -F changes_prepare_file >/dev/null; then changes_prepare_file "$directory" directory || return 1; fi
  package_install zsh git || return 1
  software_run_as_target "$user" "$home" mkdir -p "$state" || { warn "无法创建提示符状态目录。"; return 1; }
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
  software_prompt_installed "$provider" || die "$provider 未由 Server Toolkit 安装。"
  software_prompt_activate "$provider" "$user" "$home" || return 1
}

software_remove_prompt() {
  local provider="$1" paths user home bin state zshrc temporary=""
  paths="$(software_prompt_paths)"; IFS='|' read -r user home bin state <<<"$paths"
  software_prompt_managed "$provider" || die "$provider 为外部安装，项目仅管理其配置，不删除原程序。"
  zshrc="$home/.zshrc"; backup_file "$zshrc" || { warn "无法备份 $zshrc。"; return 1; }
  safe_toolkit_path "$state" || die "提示符状态路径不安全：$state"
  if declare -F changes_prepare_file >/dev/null; then
    case "$provider" in starship|oh-my-posh) changes_prepare_file "$bin/$provider" || return 1 ;; spaceship) changes_prepare_file "$state/spaceship" directory || return 1 ;; esac
    changes_prepare_file "$state/$provider.managed" || return 1
  fi
  if [[ "$DRY_RUN" -eq 0 ]]; then
    if grep -Fq "# provider: $provider" "$zshrc" 2>/dev/null; then
      temporary="$(software_prompt_remove_block "$zshrc")" || return 1
      if [[ -n "$temporary" ]]; then
        install -m 0644 "$temporary" "$zshrc" || { rm -f "$temporary"; warn "无法更新 $zshrc。"; return 1; }
        rm -f "$temporary"
      fi
    fi
    case "$provider" in
      starship) rm -f -- "$bin/starship" || { warn "无法删除 Starship。"; return 1; } ;;
      oh-my-posh) rm -f -- "$bin/oh-my-posh" || { warn "无法删除 Oh My Posh。"; return 1; } ;;
      spaceship) rm -rf -- "$state/spaceship" || { warn "无法删除 Spaceship Prompt。"; return 1; } ;;
    esac
    rm -f -- "$state/$provider.managed" || { warn "无法删除提示符托管标记。"; return 1; }
    if [[ "$EUID" -eq 0 && -f "$zshrc" ]]; then chown "$user":"$(id -gn "$user")" "$zshrc" || { warn "无法设置 $zshrc 所有者。"; return 1; }; fi
  fi
  info "已保留其他提示符、Oh My Zsh、用户自定义配置和 Nerd Font。"
}
