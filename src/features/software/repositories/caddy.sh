#!/usr/bin/env bash

software_configure_caddy_repository() {
  local force="${1:-0}" status key_file source_file key_source key_binary list_source
  [[ "$force" == "0" || "$force" == "1" ]] || return 1
  software_repository_paths_safe caddy_official || return 1
  status="$(software_repository_status caddy_official)"
  if [[ "$status" == "configured" && "$force" -eq 0 ]]; then
    info "Caddy 官方仓库文件结构完整。"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ "$force" -eq 1 ]]; then
      info "将重新获取并配置 Caddy 官方稳定仓库。"
    else
      info "将配置 Caddy 官方稳定仓库。"
    fi
    return 0
  fi

  key_file="$(software_repository_key_file caddy_official)"
  source_file="$(software_repository_source_file caddy_official)"
  key_source="$(mktemp)" || { warn "无法创建 Caddy 密钥临时文件。"; return 1; }
  key_binary="$(mktemp)" || { rm -f -- "$key_source"; warn "无法创建 Caddy 密钥临时文件。"; return 1; }
  list_source="$(mktemp)" || {
    rm -f -- "$key_source" "$key_binary"; warn "无法创建 Caddy 软件源临时文件。"; return 1;
  }
  if ! curl --disable -fsSL --proto '=https' --proto-redir '=https' \
    https://dl.cloudsmith.io/public/caddy/stable/gpg.key -o "$key_source" ||
    ! gpg --batch --yes --dearmor -o "$key_binary" "$key_source" ||
    ! curl --disable -fsSL --proto '=https' --proto-redir '=https' \
      https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt -o "$list_source" ||
    [[ ! -s "$key_binary" || ! -s "$list_source" ]] ||
    ! software_repository_key_valid caddy_official "$key_binary"; then
    rm -f -- "$key_source" "$key_binary" "$list_source"
    warn "下载或转换 Caddy 官方仓库配置失败。"
    return 1
  fi
  grep -Fq 'https://dl.cloudsmith.io/public/caddy/stable/deb/debian' "$list_source" || {
    rm -f -- "$key_source" "$key_binary" "$list_source"
    warn "Caddy 官方软件源内容与预期不符。"
    return 1
  }
  backup_file "$key_file" || { rm -f -- "$key_source" "$key_binary" "$list_source"; return 1; }
  backup_file "$source_file" || { rm -f -- "$key_source" "$key_binary" "$list_source"; return 1; }
  install -d -m 0755 "$(dirname "$key_file")" "$(dirname "$source_file")" || {
    rm -f -- "$key_source" "$key_binary" "$list_source"; warn "无法创建 Caddy 仓库目录。"; return 1;
  }
  install -m 0644 "$key_binary" "$key_file" || {
    rm -f -- "$key_source" "$key_binary" "$list_source"; warn "无法安装 Caddy 仓库签名。"; return 1;
  }
  install -m 0644 "$list_source" "$source_file" || {
    rm -f -- "$key_source" "$key_binary" "$list_source"; warn "无法安装 Caddy 软件源配置。"; return 1;
  }
  rm -f -- "$key_source" "$key_binary" "$list_source"
  [[ "$(software_repository_status caddy_official)" == "configured" ]] || {
    warn "Caddy 软件源写入后未通过内容验证。"
    return 1
  }
  info "Caddy 官方仓库已配置。"
}

software_prepare_caddy_repository() {
  local force="${1:-0}" status preconfigured=0
  [[ "$force" == "0" || "$force" == "1" ]] || return 1
  status="$(software_repository_status caddy_official)"
  if command_exists curl && command_exists gpg &&
    { [[ "$force" -eq 1 ]] || [[ "$status" == "incomplete" ]]; }; then
    software_configure_caddy_repository "$force" || return 1
    preconfigured=1
  fi
  package_install ca-certificates curl gnupg debian-keyring debian-archive-keyring apt-transport-https || return 1
  if [[ "$preconfigured" -eq 1 ]]; then
    software_configure_caddy_repository 0 || return 1
  else
    software_configure_caddy_repository "$force" || return 1
  fi
  package_invalidate_index
  package_update_index || return 1
  software_repository_verify_candidate caddy_official
}

software_install_caddy() {
  info "准备 Caddy 官方仓库。"
  software_prepare_caddy_repository 0 || return 1
  package_install_latest caddy || return 1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "将启用并启动 caddy.service。"
    return 0
  fi
  service_enable_now caddy.service || return 1
}

software_remove_caddy() { package_remove caddy; }

software_update_caddy() {
  software_prepare_caddy_repository 0 || return 1
  package_upgrade caddy
}
