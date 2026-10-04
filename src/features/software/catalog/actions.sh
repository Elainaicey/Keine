#!/usr/bin/env bash

catalog_repair_repository() {
  local id="$1" record _id category name _description _packages handler status
  record="$(catalog_record "$id")" || { warn "软件目录中没有 '$id'。"; return 1; }
  IFS='|' read -r _id category name _description _packages handler <<<"$record"
  software_official_repository_handler "$handler" || { warn "$name 不使用项目官方 APT 仓库。"; return 1; }
  status="$(software_repository_status "$handler")"
  [[ "$status" != "unsafe" ]] || {
    warn "$name 仓库路径包含符号链接，必须先人工核实，工具不会自动覆盖。"
    return 1
  }
  ui_page "修复软件来源 / $name" "$id · $category"
  ui_panel_begin "变更摘要"
  ui_panel_kv "当前状态" "$(software_repository_status_label "$status")" "$(catalog_repository_status_color "$status")"
  ui_panel_kv "官方地址" "$(software_repository_uri "$handler")" "$CYAN"
  ui_panel_kv "软件源" "$(software_repository_source_file "$handler")"
  ui_panel_kv "签名密钥" "$(software_repository_key_file "$handler")"
  ui_panel_kv "结果验证" "刷新 APT 索引并检查候选版本"
  ui_panel_end
  ui_note "仅保存文件首次原始状态；不会创建历史快照，也不会安装、移除或更新软件包。"
  confirm "验证并按需修复 $name 官方仓库？" || return 0
  require_root
  catalog_cache_invalidate
  case "$handler" in
    docker_official) software_prepare_docker_repository 1 || return 1 ;;
    caddy_official) software_prepare_caddy_repository 1 || return 1 ;;
  esac
  catalog_cache_invalidate
  audit "action=software-repository-repair id=$id previous=$status"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "$name 官方仓库修复预览完成。"
  elif [[ "$(software_repository_status "$handler")" == "configured" ]]; then
    ui_success "$name 官方仓库配置与候选版本验证通过。"
  else
    warn "$name 官方仓库修复后仍未通过状态验证。"
    return 1
  fi
}

catalog_switch_source() {
  local id="$1" record _id category name description packages handler current candidate
  record="$(catalog_record "$id")" || { warn "软件目录中没有 '$id'。"; return 1; }
  IFS='|' read -r _id category name description packages handler <<<"$record"
  [[ "$handler" == "official_release" ]] || { warn "$name 不提供可切换的安装来源。"; return 1; }
  if software_release_managed "$id"; then
    [[ -n "$packages" ]] || { warn "$name 仅提供项目官方 Release，没有发行版软件包可切换。"; return 1; }
    candidate="$(package_candidate_version "$packages")"
    [[ -n "$candidate" && "$candidate" != "(none)" ]] || { warn "当前软件源不提供 $packages。"; return 1; }
    ui_page "切换软件来源 / $name" "$id · 官方 Release → 发行版仓库"
    ui_panel_begin "切换计划"
    ui_panel_kv "当前来源" "项目官方 GitHub Release" "$CYAN"
    ui_panel_kv "目标来源" "Debian / Ubuntu 软件仓库" "$YELLOW"
    ui_panel_kv "目标版本" "$candidate"
    ui_panel_kv "系统包" "$packages"
    ui_panel_end
    ui_note "先安装发行版候选版本，再删除由 keine 管理的 /usr/local/bin 命令。"
    confirm "切换到发行版软件仓库？" || return 0
    require_root
    catalog_cache_invalidate
    package_install_latest "$packages" || return 1
    software_remove_release "$id" || return 1
    current="official-release"
  else
    ui_page "切换软件来源 / $name" "$id · 发行版仓库 → 官方 Release"
    ui_panel_begin "切换计划"
    ui_panel_kv "当前来源" "Debian / Ubuntu 软件仓库" "$CYAN"
    ui_panel_kv "目标来源" "项目官方 GitHub Release" "$GREEN"
    ui_panel_kv "发布通道" "latest stable"
    ui_panel_kv "命令路径" "$(software_release_target "$id")"
    ui_panel_kv "完整性" "GitHub SHA-256 digest"
    ui_panel_end
    ui_note "系统包会保留；官方命令安装到 /usr/local/bin。若同路径已有外部普通文件，确认后保存首次原始状态再接管；符号链接不覆盖。"
    confirm "切换到项目官方稳定版？" || return 0
    require_root
    catalog_cache_invalidate
    software_release_latest_invalidate "$id"
    software_install_release "$id" adopt || return 1
    current="distribution"
  fi
  catalog_cache_invalidate
  audit "action=software-source-switch id=$id from=$current"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "$name 来源切换预览完成。"
  else
    ui_success "$name 已切换到 $(catalog_source_label "$record")。"
  fi
}

catalog_install() {
  local id="$1" record _id category name description packages handler source_label selected_handler candidate repository_status
  local plan_packages=()
  record="$(catalog_record "$id")" || { warn "软件目录中没有 '$id'。"; return 1; }
  IFS='|' read -r _id category name description packages handler <<<"$record"
  if catalog_installed "$record"; then
    if [[ "$handler" == "official_release" ]] && ! software_release_managed "$id"; then
      catalog_switch_source "$id"
      return
    fi
    info "$name 已经安装。"
    return 0
  fi
  # 发行版候选版本只能在明确刷新索引后判断；本地元数据缺失不能阻止安装入口。
  if [[ -n "$handler" ]] && ! catalog_available "$record"; then
    warn "当前平台没有可用的 $name 安装来源。"
    return 1
  fi
  selected_handler="$handler"
  if [[ "$id" == ufw ]]; then platform_ufw_preflight || return 1; fi
  require_root || return 1
  package_invalidate_index
  # 独立工具默认直装官方稳定版；系统软件包仅作为详情页的显式备选。
  ui_page "安装软件 / $name" "$id · $category"
  ui_panel_begin "变更摘要"
  ui_panel_kv "软件" "$name" "$CYAN"
  ui_panel_kv "说明" "$description"
  source_label="$(catalog_source_label "$record")"
  [[ -n "$selected_handler" ]] || source_label="Debian / Ubuntu 软件仓库"
  ui_panel_kv "来源" "$source_label"
  if [[ "$selected_handler" == "official_release" ]]; then
    ui_panel_kv "目标版本" "官方最新稳定版（安装时查询）" "$GREEN"
    ui_panel_kv "官方项目" "$(software_release_repository "$id")"
    ui_panel_kv "命令路径" "$(software_release_target "$id")"
    ui_panel_kv "完整性" "GitHub Release SHA-256 digest"
  elif software_official_repository_handler "$selected_handler"; then
    repository_status="$(software_repository_status "$selected_handler")"
    ui_panel_kv "仓库状态" "$(software_repository_status_label "$repository_status")" \
      "$(catalog_repository_status_color "$repository_status")"
    ui_panel_kv "目标版本" "$(catalog_candidate_version "$record")" "$GREEN"
    ui_panel_kv "配置方式" "安装时按需创建签名与 stable 仓库"
  else
    if [[ -z "$selected_handler" ]]; then
      candidate="$(package_candidate_version "$packages")"
    else
      candidate="$(catalog_candidate_version "$record")"
    fi
    [[ -n "$candidate" && "$candidate" != '(none)' ]] || candidate="刷新索引后确认"
    ui_panel_kv "目标版本" "$candidate" "$GREEN"
  fi
  if [[ -n "$packages" && "$selected_handler" != official_release ]]; then
    ui_panel_kv "系统包" "$packages"
  fi
  ui_panel_end
  if catalog_effect_has_persistent_impact "$id"; then
    ui_callout warn "安装后可能出现：$(catalog_effect_summary "$id")" \
      "$(catalog_effect_note "$id")；keine 自身仍只在调用期间运行。"
  else
    ui_note "未声明额外后台服务或计划任务；安装过程仍以 APT 实际事务为准。"
  fi
  if [[ -z "$selected_handler" ]]; then
    package_update_index || return 1
    catalog_cache_invalidate
    candidate="$(package_candidate_version "$packages")"
    [[ -n "$candidate" && "$candidate" != "(none)" ]] || {
      warn "刷新索引后，软件源不再提供 $packages 的候选版本。"
      return 1
    }
    ui_status "刷新后候选版本" "$packages · $candidate" "primary"
    mapfile -t plan_packages < <(catalog_apt_target_packages install "$selected_handler" "$packages")
    catalog_apt_plan_render install "${plan_packages[@]}" || return 1
  fi
  catalog_cache_invalidate
  case "$selected_handler" in
    docker_official) software_install_docker || return 1 ;;
    caddy_official) software_install_caddy || return 1 ;;
    official_release) software_release_latest_invalidate "$id"; software_install_release "$id" || return 1 ;;
    "") package_install_latest "$packages" || return 1 ;;
    *) die "未知安装器：$selected_handler" ;;
  esac
  catalog_cache_invalidate
  audit "action=software-install id=$id source=$(printf '%q' "$source_label")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "$name 安装预览完成。"
  else
    catalog_installed "$record" || { warn "$name 安装后未通过状态验证。"; return 1; }
    ui_success "$name 已安装：$(catalog_installed_version "$record")"
  fi
}

catalog_update() {
  local id="$1" record _id category name description packages handler installed candidate latest repository_status distribution_docker=0
  local plan_packages=()
  record="$(catalog_record "$id")" || { warn "软件目录中没有 '$id'。"; return 1; }
  IFS='|' read -r _id category name description packages handler <<<"$record"
  catalog_installed "$record" || { warn "$name 尚未安装，请先执行安装。"; return 1; }
  installed="$(catalog_installed_version "$record")"
  candidate="$(catalog_candidate_version "$record")"
  if [[ "$handler" == "docker_official" ]] && package_installed docker.io && ! package_installed docker-ce; then
    distribution_docker=1
  fi
  if software_official_repository_handler "$handler" && (( distribution_docker == 0 )); then
    repository_status="$(software_repository_status "$handler")"
  fi
  if [[ "$handler" == "official_release" ]] && software_release_managed "$id"; then
    ui_page "检查官方更新 / $name" "$id · 项目官方 GitHub Release"
    ui_panel_begin "官方稳定通道"
    ui_panel_kv "当前版本" "$installed" "$WHITE"
    ui_panel_kv "官方项目" "$(software_release_repository "$id")"
    ui_panel_kv "完整性" "$(software_release_integrity "$id" && printf 'SHA-256 正常' || printf '异常')" \
      "$(software_release_integrity "$id" && printf '%s' "$GREEN" || printf '%s' "$RED")"
    ui_panel_kv "检查方式" "GitHub latest stable Release"
    ui_panel_end
    confirm "查询官方版本并按需更新 $name？" || return 0
    require_root
    software_release_latest_invalidate "$id"
    software_release_load_latest "$id" || return 1
    latest="$SOFTWARE_RELEASE_LATEST_VERSION"
    catalog_cache_invalidate
    software_update_release "$id" || return 1
    catalog_cache_invalidate
    audit "action=software-update id=$id source=official-release from=$installed to=$latest"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "$name 官方更新预览完成。"
    elif [[ "$installed" == "$(software_release_version "$id")" ]]; then
      ui_success "$name 已经是官方最新稳定版 $installed。"
    else
      ui_success "$name 已更新：$installed → $(software_release_version "$id")"
    fi
    return 0
  elif [[ "$handler" == "official_release" ]]; then
    if [[ -z "$packages" ]] || ! package_installed "$packages"; then
      catalog_switch_source "$id"
      return
    fi
    handler=""
    candidate="$(package_candidate_version "$packages")"
  fi
  ui_page "检查更新 / $name" "$id · $category"
  ui_panel_begin "本地索引"
  ui_panel_kv "当前版本" "$installed" "$WHITE"
  ui_panel_kv "候选版本" "$candidate" "$YELLOW"
  if software_official_repository_handler "$handler" && (( distribution_docker == 0 )); then
    ui_panel_kv "仓库状态" "$(software_repository_status_label "$repository_status")" \
      "$(catalog_repository_status_color "$repository_status")"
  fi
  ui_panel_end
  if software_official_repository_handler "$handler" && (( distribution_docker == 0 )); then
    ui_note "检查前会验证官方仓库；配置缺失或不完整时会记录首次基线并修复。"
    confirm "验证官方仓库并检查 $name 更新？" || return 0
  else
    ui_note "候选版本来自本机 APT 索引；更新前会先刷新仓库元数据。"
    confirm "刷新软件索引并检查 $name？" || return 0
  fi
  require_root
  case "$handler" in
    docker_official)
      if (( distribution_docker == 1 )); then
        package_invalidate_index; package_update_index || return 1
      else
        software_prepare_docker_repository || return 1
      fi
      ;;
    caddy_official) software_prepare_caddy_repository || return 1 ;;
    *) package_invalidate_index; package_update_index || return 1 ;;
  esac
  catalog_cache_invalidate
  installed="$(catalog_installed_version "$record")"
  candidate="$(catalog_candidate_version "$record")"
  ui_page "更新软件 / $name" "$id · $category"
  ui_panel_begin "最新版本信息"
  ui_panel_kv "当前版本" "$installed" "$WHITE"
  ui_panel_kv "候选版本" "$candidate" "$YELLOW"
  ui_panel_end
  if [[ -z "$candidate" || "$candidate" == '—' || "$candidate" == '(none)' ]]; then
    warn "刷新后仍没有 $name 的候选版本，无法判断是否有更新；请检查来源诊断。"
    return 1
  fi
  if ! catalog_has_update "$record"; then
    ui_success "$name 已经是当前软件仓库中的最新版本。"
    return 0
  fi
  mapfile -t plan_packages < <(catalog_apt_target_packages update "$handler" "$packages")
  if ((${#plan_packages[@]} > 0)); then
    catalog_apt_plan_render update "${plan_packages[@]}" || return 1
  fi
  confirm "将 $name 更新到 $candidate？" || { warn "已取消。"; return 0; }
  catalog_cache_invalidate
  case "$handler" in
    docker_official) software_update_docker || return 1 ;;
    caddy_official) software_update_caddy || return 1 ;;
    "") package_upgrade "$packages" || return 1 ;;
    *) die "未知安装器：$handler" ;;
  esac
  catalog_cache_invalidate
  if [[ "$DRY_RUN" -eq 0 ]]; then
    catalog_installed "$record" || { warn "$name 更新后未通过状态验证。"; return 1; }
  fi
  audit "action=software-update id=$id from=$installed to=$candidate"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "$name 更新预览完成。"
  else
    ui_success "$name 已更新：$(catalog_installed_version "$record")"
  fi
}

catalog_remove() {
  local id="$1" record _id category name description packages handler release_managed=0
  local plan_packages=()
  record="$(catalog_record "$id")" || { warn "软件目录中没有 '$id'。"; return 1; }
  IFS='|' read -r _id category name description packages handler <<<"$record"
  catalog_installed "$record" || { info "$name 未安装。"; return 0; }
  if [[ "$handler" == official_release ]] && ! software_release_managed "$id" &&
    { [[ -z "$packages" ]] || ! package_installed "$packages"; }; then
    warn "$name 属于外部安装。可从来源切换确认接管，但不能直接删除原程序。"
    return 1
  fi
  ui_page "移除软件 / $name" "$id · $category"
  ui_panel_begin "变更摘要"
  ui_panel_kv "软件" "$name" "$CYAN"
  ui_panel_kv "当前版本" "$(catalog_installed_version "$record")"
  if [[ "$handler" == "official_release" ]]; then
    software_release_managed "$id" && release_managed=1
    ui_panel_kv "当前来源" "$(catalog_source_label "$record")" "$CYAN"
    if (( release_managed == 1 )); then
      ui_panel_kv "托管命令" "$(software_release_target "$id")"
      ui_panel_kv "完整性" "$(software_release_integrity "$id" && printf '正常' || printf '异常')"
    fi
    [[ -z "$packages" ]] || ui_panel_kv "底层系统包" "$packages"
  else
    ui_panel_kv "系统包" "${packages:-由官方安装器管理}"
  fi
  ui_panel_end
  if [[ "$handler" == "official_release" ]]; then
    ui_danger "将移除 keine 托管的官方命令；如同时安装了对应系统包，也会一并移除。"
  else
    ui_danger "只移除软件包，不删除它的数据目录和配置文件。"
  fi
  mapfile -t plan_packages < <(catalog_apt_target_packages remove "$handler" "$packages")
  if ((${#plan_packages[@]} > 0)); then
    catalog_apt_plan_render remove "${plan_packages[@]}" || return 1
  fi
  confirm "确认移除 $name？" || { warn "已取消。"; return 0; }
  require_root
  catalog_cache_invalidate
  case "$handler" in
    docker_official) software_remove_docker || return 1 ;;
    caddy_official) software_remove_caddy || return 1 ;;
    official_release)
      if (( release_managed == 1 )); then software_remove_release "$id" || return 1; fi
      if [[ -n "$packages" ]]; then package_remove "$packages" || return 1; fi
      ;;
    "") package_remove "$packages" || return 1 ;;
    *) die "未知安装器：$handler" ;;
  esac
  catalog_cache_invalidate
  if [[ "$DRY_RUN" -eq 0 ]] && catalog_installed "$record"; then
    warn "$name 移除后仍能被检测到；为避免误报，操作未标记为成功。"
    return 1
  fi
  audit "action=software-remove id=$id"
  ui_success "$name 移除完成。"
}
