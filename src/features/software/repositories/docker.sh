#!/usr/bin/env bash

software_configure_docker_repository() {
  local force="${1:-0}" status key_file source_file key_tmp source_tmp
  [[ "$force" == "0" || "$force" == "1" ]] || return 1
  case "${OS_ID:-}" in
    debian|ubuntu) ;;
    *) warn "Docker 官方仓库仅支持本项目已声明的 Debian / Ubuntu 平台。"; return 1 ;;
  esac
  [[ "${OS_CODENAME:-}" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || {
    warn "无法识别可用于 Docker 仓库的系统代号：${OS_CODENAME:-空}"
    return 1
  }
  [[ "${ARCH:-}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
    warn "无法识别可用于 Docker 仓库的系统架构：${ARCH:-空}"
    return 1
  }
  software_repository_paths_safe docker_official || return 1
  status="$(software_repository_status docker_official)"
  if [[ "$status" == "configured" && "$force" -eq 0 ]]; then
    info "Docker 官方仓库文件结构完整。"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ "$force" -eq 1 ]]; then
      info "将重新获取并配置 Docker 官方仓库（${OS_ID}/${OS_CODENAME}/${ARCH}）。"
    else
      info "将配置 Docker 官方仓库（${OS_ID}/${OS_CODENAME}/${ARCH}）。"
    fi
    return 0
  fi

  key_file="$(software_repository_key_file docker_official)"
  source_file="$(software_repository_source_file docker_official)"
  key_tmp="$(mktemp)" || { warn "无法创建 Docker 签名临时文件。"; return 1; }
  source_tmp="$(mktemp)" || { rm -f -- "$key_tmp"; warn "无法创建 Docker 软件源临时文件。"; return 1; }
  if ! curl --disable -fsSL --proto '=https' --proto-redir '=https' \
    "https://download.docker.com/linux/$OS_ID/gpg" -o "$key_tmp" ||
    [[ ! -s "$key_tmp" ]] || ! software_repository_key_valid docker_official "$key_tmp"; then
    rm -f -- "$key_tmp" "$source_tmp"
    warn "Docker 官方仓库签名下载或格式验证失败。"
    return 1
  fi
  if ! printf '%s\n' \
    '# Managed by Server Toolkit' \
    'Types: deb' \
    "URIs: https://download.docker.com/linux/$OS_ID" \
    "Suites: $OS_CODENAME" \
    'Components: stable' \
    "Architectures: $ARCH" \
    "Signed-By: $key_file" >"$source_tmp"; then
    rm -f -- "$key_tmp" "$source_tmp"
    warn "无法生成 Docker 软件源配置。"
    return 1
  fi
  backup_file "$key_file" || { rm -f -- "$key_tmp" "$source_tmp"; return 1; }
  backup_file "$source_file" || { rm -f -- "$key_tmp" "$source_tmp"; return 1; }
  install -d -m 0755 "$(dirname "$key_file")" "$(dirname "$source_file")" || {
    rm -f -- "$key_tmp" "$source_tmp"; warn "无法创建 APT 仓库目录。"; return 1;
  }
  install -m 0644 "$key_tmp" "$key_file" || {
    rm -f -- "$key_tmp" "$source_tmp"; warn "无法安装 Docker 仓库签名。"; return 1;
  }
  install -m 0644 "$source_tmp" "$source_file" || {
    rm -f -- "$key_tmp" "$source_tmp"; warn "无法安装 Docker 软件源配置。"; return 1;
  }
  rm -f -- "$key_tmp" "$source_tmp"
  [[ "$(software_repository_status docker_official)" == "configured" ]] || {
    warn "Docker 软件源写入后未通过内容验证。"
    return 1
  }
  info "Docker 官方仓库已配置。"
}

software_prepare_docker_repository() {
  local force="${1:-0}" status preconfigured=0
  [[ "$force" == "0" || "$force" == "1" ]] || return 1
  status="$(software_repository_status docker_official)"
  # 修复不完整来源时，若 curl 已存在，先替换坏源再运行 apt update，
  # 避免待修复的仓库反过来阻止依赖安装。
  if command_exists curl && { [[ "$force" -eq 1 ]] || [[ "$status" == "incomplete" ]]; }; then
    software_configure_docker_repository "$force" || return 1
    preconfigured=1
  fi
  package_install ca-certificates curl gnupg || return 1
  if [[ "$preconfigured" -eq 1 ]]; then
    software_configure_docker_repository 0 || return 1
  else
    software_configure_docker_repository "$force" || return 1
  fi
  package_invalidate_index
  package_update_index || return 1
  software_repository_verify_candidate docker_official
}

software_verify_docker_candidates() {
  local package candidate
  local packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  for package in "${packages[@]}"; do
    candidate="$(package_candidate_version "$package")"
    if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        info "$package 候选版本将在实际配置仓库后验证。"
        continue
      fi
      warn "Docker 官方仓库缺少必需组件：$package"
      return 1
    fi
  done
}

software_install_docker() {
  local conflict conflict_list
  local conflicts=(docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc)
  local installed_conflicts=()
  for conflict in "${conflicts[@]}"; do
    package_installed "$conflict" && installed_conflicts+=("$conflict")
  done
  # 先验证官方仓库和候选版本，再改动现有容器运行时。这样即使网络、
  # 签名或 APT 元数据失败，也不会先卸载一套仍可工作的 Docker。
  info "准备并验证 Docker 官方仓库。"
  software_prepare_docker_repository 0 || return 1
  software_verify_docker_candidates || return 1
  if ((${#installed_conflicts[@]} > 0)); then
    printf -v conflict_list '%s ' "${installed_conflicts[@]}"
    warn "检测到与 Docker 官方包冲突的软件：${conflict_list% }"
    confirm "先移除这些冲突包（不删除容器数据）？" || return 1
    package_remove "${installed_conflicts[@]}" || return 1
  fi
  package_install_latest docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "将启用并启动 docker.service。"
    return 0
  fi
  service_enable_now docker.service || return 1
}

software_remove_docker() {
  package_remove docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    docker.io docker-compose-v2
}

software_update_docker() {
  if package_installed docker.io && ! package_installed docker-ce; then
    package_upgrade docker.io
    return 0
  fi
  package_installed docker-ce || { warn "无法识别当前 Docker 的软件包来源。"; return 1; }
  local packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  local installed=() package
  for package in "${packages[@]}"; do
    package_installed "$package" && installed+=("$package")
  done
  ((${#installed[@]} > 0)) || { warn "没有检测到可更新的 Docker 官方组件。"; return 1; }
  software_prepare_docker_repository 0 || return 1
  apt_run install --only-upgrade -y "${installed[@]}" || { warn "Docker 官方组件更新失败。"; return 1; }
  local failed=0
  for package in "${installed[@]}"; do package_verify_candidate "$package" || failed=1; done
  (( failed == 0 ))
}
