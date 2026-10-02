#!/usr/bin/env bash

catalog_repository_file_check() {
  local label="$1" path="$2" state
  state="$(software_repository_file_state "$path")"
  case "$state" in
    ready) ui_check pass "$label 可读且非空 · $path" ;;
    missing) ui_check warn "$label 尚未创建 · $path" ;;
    unsafe) ui_check fail "$label 是符号链接，出于安全原因拒绝覆盖 · $path" ;;
    *) ui_check fail "$label 存在但不是有效普通文件 · $path" ;;
  esac
}

catalog_repository_diagnostics() {
  local id="$1" record _id category name _description _packages handler status candidate source_file key_file
  record="$(catalog_record "$id")" || return 1
  IFS='|' read -r _id category name _description _packages handler <<<"$record"
  software_official_repository_handler "$handler" || { warn "$name 不使用项目官方 APT 仓库。"; return 1; }
  status="$(software_repository_status "$handler")"
  candidate="$(software_repository_candidate "$handler")"
  source_file="$(software_repository_source_file "$handler")"
  key_file="$(software_repository_key_file "$handler")"
  ui_page "软件来源诊断 / $name" "$id · $category · 一次性只读检查"
  ui_panel_begin "官方仓库"
  ui_panel_kv "状态" "$(software_repository_status_label "$status")" "$(catalog_repository_status_color "$status")"
  ui_panel_kv "官方地址" "$(software_repository_uri "$handler")" "$CYAN"
  ui_panel_kv "系统" "${OS_NAME:-${OS_ID:-未知}}"
  ui_panel_kv "代号 / 架构" "${OS_CODENAME:-未知} · ${ARCH:-未知}"
  ui_panel_kv "候选版本" "${candidate:-(none)}"
  ui_panel_end
  ui_section "文件检查" "accent"
  catalog_repository_file_check "软件源" "$source_file"
  catalog_repository_file_check "签名密钥" "$key_file"
  printf '\n'
  case "$status" in
    configured)
      if [[ -n "$candidate" && "$candidate" != "(none)" ]]; then
        ui_callout good "仓库文件结构与本地候选版本可用" \
          "安装或更新时会刷新索引，由 APT 验证仓库签名；若上游轮换密钥导致失败，可使用强制修复官方仓库操作。"
      else
        ui_callout bad "仓库文件结构完整，但没有候选版本" "请核实系统代号、架构、网络与上游支持范围。"
      fi
      ;;
    missing) ui_callout good "尚未配置属于正常安装前状态" "选择安装后，keine 会创建签名和软件源，再获取官方稳定版。" ;;
    incomplete) ui_callout warn "仓库配置不完整" "安装或修复会保存首次原始状态，再写入可信配置；历史快照请手动创建。" ;;
    unsafe) ui_callout bad "仓库路径存在安全风险" "请人工核实并移除符号链接；工具不会自动覆盖。" ;;
  esac
}

catalog_item_information() {
  local id="$1" record _id category name description packages handler effect_note
  record="$(catalog_record "$id")" || return 1
  IFS='|' read -r _id category name description packages handler <<<"$record"
  ui_page "软件信息 / $name" "$id · $category"
  ui_panel_begin "来源与安装"
  ui_panel_kv "说明" "$description"
  if [[ "$handler" == official_release ]]; then
    ui_panel_kv "官方项目" "$(software_release_repository "$id")"
    ui_panel_kv "项目主页" "$(software_release_homepage "$id")"
    ui_panel_kv "命令路径" "$(software_release_target "$id")"
    if software_release_managed "$id"; then
      if software_release_integrity "$id"; then ui_panel_kv "完整性" "SHA-256 正常" "$GREEN"
      else ui_panel_kv "完整性" "异常" "$RED"; fi
    else
      ui_panel_kv "完整性" "安装时校验 GitHub SHA-256 digest"
    fi
    [[ -z "$packages" ]] || ui_panel_kv "发行版备选" "$packages"
  else
    ui_panel_kv "系统包" "${packages:-由官方安装器管理}"
    ui_panel_kv "版本依据" "本机 APT 索引，不代表上游最新" "$MUTED"
  fi
  ui_panel_end
  if catalog_effect_has_persistent_impact "$id"; then
    ui_section "运行影响" warning
    ui_kv "组件" "$(catalog_effect_summary "$id")" "$YELLOW"
    effect_note="$(catalog_effect_note "$id")"
    [[ -z "$effect_note" ]] || ui_hint "$effect_note"
  fi
}

catalog_item_menu() {
  local id="$1" record _id category name description packages handler choice state source_label installed candidate repository_status installed_flag distribution_docker
  record="$(catalog_record "$id")" || return 1
  IFS='|' read -r _id category name description packages handler <<<"$record"
  while true; do
    catalog_cache_build
    installed="$(catalog_installed_version "$record")"
    candidate="$(catalog_candidate_version "$record")"
    state="$(catalog_state "$record" "$candidate")"
    source_label="$(catalog_source_label "$record")"
    installed_flag=0
    distribution_docker=0
    if catalog_installed "$record"; then installed_flag=1; fi
    repository_status=""
    if software_official_repository_handler "$handler"; then
      repository_status="$(software_repository_status "$handler")"
    fi
    if [[ "$handler" == "docker_official" ]] && package_installed docker.io && ! package_installed docker-ce; then
      source_label="系统软件仓库（现有安装）"
      distribution_docker=1
    fi
    ui_page "软件中心 / $name" "$id · $category"
    ui_panel_begin "软件信息"
    ui_panel_kv "状态" "$(catalog_state_badge "$state")"
    ui_panel_kv "当前版本" "$installed"
    ui_panel_kv "候选版本" "$candidate" "$CYAN"
    ui_panel_kv "说明" "$description"
    ui_panel_kv "来源" "$source_label"
    if catalog_effect_has_persistent_impact "$id"; then
      ui_panel_kv "运行形态" "$(catalog_effect_summary "$id")" "$YELLOW"
    fi
    if software_official_repository_handler "$handler" && (( distribution_docker == 0 )); then
      ui_panel_kv "仓库状态" "$(software_repository_status_label "$repository_status")" \
        "$(catalog_repository_status_color "$repository_status")"
    fi
    ui_panel_end
    ui_section "软件操作" "primary"
    if [[ "$state" == "unavailable" ]]; then
      ui_action 1 "重新检查并安装" "warning"
    elif [[ "$state" == "absent" || "$state" == "setup" || "$state" == "index-needed" ]]; then
      if [[ "$state" == "setup" ]]; then
        ui_action 1 "配置仓库并安装" "success"
      elif [[ "$state" == index-needed ]]; then
        ui_action 1 "刷新索引并安装" "warning"
      else
        ui_action 1 "安装" "success"
      fi
    elif [[ "$state" == "source-warning" && "$installed_flag" -eq 0 ]]; then
      ui_action 1 "修复仓库并安装" "warning"
    else
      if [[ "$handler" == "official_release" ]] && software_release_managed "$id"; then
        ui_action 2 "检查官方更新" "action"
      elif [[ "$state" == "update" ]]; then
        ui_action 2 "更新" "warning" "$installed → $candidate"
      else
        ui_action 2 "检查更新" "action"
      fi
      if [[ "$state" != external ]]; then ui_action 3 "移除" "danger"; fi
    fi
    ui_section "来源与信息" "accent"
    if [[ "$handler" == "official_release" ]]; then
      if [[ "$state" == external || ( "$state" != absent && "$state" != unavailable && -n "$packages" ) ]]; then
        ui_action 4 "切换来源 / 接管" "accent"
      fi
      if software_release_managed "$id"; then
        if [[ "$state" == "damaged" ]]; then
          ui_action 5 "修复官方安装" "danger"
        else
          ui_action 5 "重新安装官方版" "warning"
        fi
      fi
    elif software_official_repository_handler "$handler" && (( distribution_docker == 0 )); then
      ui_action 4 "来源诊断" "accent"
      if [[ "$repository_status" == "configured" ]]; then
        ui_action 5 "重新验证仓库" "action"
      elif [[ "$repository_status" != unsafe && "$state" != setup ]]; then
        ui_action 5 "修复官方仓库" "warning"
      fi
    else
      ui_action 4 "来源诊断" "accent"
    fi
    ui_action D "安装信息" "action"
    if catalog_guide_record "$id" >/dev/null; then
      if [[ "$id" == nginx ]]; then ui_action G "相关软件 / Certbot" "accent"
      else ui_action G "指南与相关软件" "accent"; fi
    fi
    ui_action R "刷新索引" "accent"
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      1)
        if [[ "$state" == "absent" || "$state" == "setup" || "$state" == index-needed || ( "$state" == unavailable && "$handler" != official_release ) || ( "$state" == "source-warning" && "$installed_flag" -eq 0 ) ]]; then
          catalog_install "$id" || true
        elif [[ "$state" == "unavailable" ]]; then
          warn "当前系统软件源未提供 $name。"
        else
          warn "$name 已经安装。"
        fi
        pause
        ;;
      2)
        if (( installed_flag == 1 )); then catalog_update "$id" || true; else warn "请先安装 $name。"; fi
        pause
        ;;
      3)
        if (( installed_flag == 1 )); then catalog_remove "$id" || true; else warn "$name 尚未安装。"; fi
        pause
        ;;
      4)
        if software_official_repository_handler "$handler" && (( distribution_docker == 0 )); then
          catalog_repository_diagnostics "$id" || true
        elif [[ "$handler" == official_release && ( "$state" == external || ( "$state" != absent && "$state" != unavailable && -n "$packages" ) ) ]]; then
          catalog_switch_source "$id" || true
        elif [[ -z "$handler" || "$distribution_docker" == 1 ]]; then
          if (( distribution_docker == 1 )); then catalog_distribution_diagnostics "$id" docker.io || true
          else catalog_distribution_diagnostics "$id" || true; fi
        else
          warn "$name 当前没有可切换的第二来源。"
        fi
        pause
        ;;
      5)
        if software_official_repository_handler "$handler" && (( distribution_docker == 0 )) && \
          [[ "$repository_status" != "unsafe" && "$state" != "setup" ]]; then
          catalog_repair_repository "$id" || true
        elif [[ "$handler" == "official_release" ]] && software_release_managed "$id"; then
          ui_page "修复官方安装 / $name" "$id · 重新下载并验证官方稳定版"
          ui_danger "修复会覆盖命令并保留首次基线；如需保存当前版本，请先手动备份。外部修改冲突不会被覆盖。"
          if confirm "重新安装 $name 的官方稳定版？"; then
            require_root
            catalog_cache_invalidate
            software_release_latest_invalidate "$id"
            if software_repair_release "$id"; then
              audit "action=software-release-repair id=$id"
              [[ "$DRY_RUN" -eq 1 ]] || ui_success "$name 官方安装已修复。"
            fi
          fi
        elif software_official_repository_handler "$handler" && (( distribution_docker == 0 )); then
          warn "$name 的仓库修复当前不可执行，请先查看来源诊断。"
        else
          warn "$name 当前不由官方 Release 安装器管理。"
        fi
        pause
        ;;
      0) return 0 ;;
      D|d) catalog_item_information "$id" || true; pause ;;
      G|g) catalog_guide_view "$id" || true ;;
      R|r) catalog_refresh_index || true; pause ;;
      *) warn "未知选项" ;;
    esac
  done
}

catalog_categories_view() {
  local entries=() category count choice index selected
  mapfile -t entries < <(catalog_categories)
  while true; do
    ui_page "软件中心 / 分类"
    for index in "${!entries[@]}"; do
      IFS='|' read -r category count <<<"${entries[$index]}"
      case "$category" in
        系统基础) ui_section "日常工具" "primary" ;;
        网络诊断) ui_section "运维与防护" "accent" ;;
        Web与代理) ui_section "应用与开发" "warning" ;;
      esac
      ui_item "$((index + 1))" "$category" "$count 项"
    done
    ui_menu_footer "返回"
    ui_read_choice choice
    [[ "$choice" == "0" ]] && return 0
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#entries[@]} )); then
      warn "无效分类编号：$choice"
      pause
      continue
    fi
    selected="${entries[$((choice - 1))]}"
    IFS='|' read -r category count <<<"$selected"
    catalog_browse_view category "$category" "软件中心 / $category" ""
  done
}

catalog_installed_view() {
  catalog_browse_view installed "" "软件中心 / 已安装" ""
}

catalog_updates_view() {
  catalog_browse_view updates "" "软件中心 / 仓库更新" ""
}

catalog_sources_view() {
  local choice kind title
  while true; do
    ui_page "软件中心 / 来源"
    ui_section "来源类型" "primary"
    ui_action 1 "发行版软件仓库" "action"
    ui_action 2 "项目官方 Release" "success"
    ui_action 3 "项目官方 APT 仓库" "accent"
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      1) kind="distribution"; title="发行版软件仓库" ;;
      2) kind="official-release"; title="项目官方 Release" ;;
      3) kind="official-repository"; title="项目官方 APT 仓库" ;;
      0) return 0 ;;
      *) warn "未知来源编号：$choice"; pause; continue ;;
    esac
    catalog_browse_view source "$kind" "软件来源 / $title" ""
  done
}

catalog_official_updates_view() {
  local interactive="${1:-1}" record id _category name _description _packages handler current latest input checked=0 updates=0 failed=0
  ui_page "软件中心 / 官方更新" "GitHub Release · 仅检查托管软件"
  while IFS= read -r record; do
    IFS='|' read -r id _category name _description _packages handler <<<"$record"
    [[ "$handler" == "official_release" ]] || continue
    software_release_managed "$id" || continue
    checked=$((checked + 1))
    current="$(software_release_version "$id")"
    software_release_latest_invalidate "$id"
    if ! software_release_load_latest "$id"; then
      printf '  %b×%b %-18s %b查询失败%b\n' "$RED" "$NC" "$id" "$RED" "$NC"
      failed=$((failed + 1))
    else
      latest="$SOFTWARE_RELEASE_LATEST_VERSION"
      if dpkg --compare-versions "$latest" gt "$current"; then
      printf '  %b↑%b %-18s %b%s%b %b→%b %b%s%b\n' \
        "$YELLOW" "$NC" "$id" "$WHITE" "$current" "$NC" "$MAGENTA" "$NC" "$YELLOW" "$latest" "$NC"
      updates=$((updates + 1))
      elif software_release_integrity "$id"; then
      printf '  %b✓%b %-18s %b%s · 已是最新%b\n' "$GREEN" "$NC" "$id" "$GREEN" "$current" "$NC"
      else
      printf '  %b!%b %-18s %b%s · 完整性异常%b\n' "$RED" "$NC" "$id" "$RED" "$current" "$NC"
      failed=$((failed + 1))
      fi
    fi
  done < <(catalog_rows)
  (( checked > 0 )) || ui_empty "尚未安装由官方 Release 管理的软件"
  ui_panel_begin "检查结果"
  ui_panel_kv "已检查" "$checked 项"
  ui_panel_kv "可更新" "$updates 项" "$YELLOW"
  ui_panel_kv "异常 / 失败" "$failed 项" "$([[ "$failed" -eq 0 ]] && printf '%s' "$GREEN" || printf '%s' "$RED")"
  ui_panel_end
  [[ "$interactive" -eq 1 ]] || return 0
  ui_menu_footer "返回"
  ui_read_choice input "软件 ID"
  [[ "$input" == "0" ]] && return 0
  if catalog_record "$input" >/dev/null 2>&1; then catalog_item_menu "$input"; else warn "未知软件 ID：$input"; pause; fi
}

catalog_refresh_index() {
  ui_page "软件中心 / 刷新索引"
  confirm "现在刷新 APT 软件索引？" || return 0
  require_root
  package_invalidate_index
  package_update_index || return 1
  catalog_cache_invalidate
  ui_success "软件索引刷新完成。"
}

software_catalog_menu() {
  local input="" stats total installed updates
  while true; do
    catalog_cache_build
    [[ -n "$CATALOG_STATISTICS_CACHE" ]] || CATALOG_STATISTICS_CACHE="$(catalog_statistics)"
    stats="$CATALOG_STATISTICS_CACHE"
    IFS='|' read -r total installed updates <<<"$stats"
    ui_page "软件中心"
    ui_stats "目录" "$total" "已安装" "$installed" "仓库更新" "$updates"
    ui_section "浏览" "primary"
    ui_item A "分类浏览"
    ui_item I "已安装"
    ui_item S "软件来源"
    ui_section "更新" "accent"
    ui_action U "仓库更新" "warning"
    ui_action O "官方更新" "success"
    ui_action R "刷新索引" "accent"
    ui_menu_footer "返回"
    ui_read_choice input "选择或搜索"
    case "$input" in
      0) return 0 ;;
      A|a|all) catalog_categories_view ;;
      I|i|installed) catalog_installed_view ;;
      U|u) catalog_updates_view ;;
      O|o) catalog_official_updates_view 1; pause ;;
      S|s|source|sources) catalog_sources_view ;;
      R|r) catalog_refresh_index || true; pause ;;
      "") ;;
      *)
        if catalog_record "$input" >/dev/null 2>&1; then
          catalog_item_menu "$input"
        else
          catalog_browse_view search "$input" "软件中心 / 搜索" ""
        fi
        ;;
    esac
  done
}
