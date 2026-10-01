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
    missing) ui_callout good "尚未配置属于正常安装前状态" "选择安装后，Server Toolkit 会创建签名和软件源，再获取官方稳定版。" ;;
    incomplete) ui_callout warn "仓库配置不完整" "安装或修复会先备份现有普通文件，再重新写入可信配置。" ;;
    unsafe) ui_callout bad "仓库路径存在安全风险" "请人工核实并移除符号链接；工具不会自动覆盖。" ;;
  esac
}

catalog_item_menu() {
  local id="$1" record _id category name description packages handler choice state source_label installed candidate repository_status installed_flag distribution_docker effect_note
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
    ui_page "软件管理 / $name" "$id · $category"
    ui_panel_begin "软件信息"
    ui_panel_kv "状态" "$(catalog_state_badge "$state")"
    ui_panel_kv "当前版本" "$installed"
    ui_panel_kv "目标 / 候选版本" "$candidate" "$CYAN"
    ui_panel_kv "说明" "$description"
    ui_panel_kv "来源" "$source_label"
    effect_note=""
    if catalog_effect_has_persistent_impact "$id"; then
      ui_panel_kv "运行形态" "$(catalog_effect_summary "$id")" "$YELLOW"
      effect_note="$(catalog_effect_note "$id")"
    else
      ui_panel_kv "运行形态" "未声明额外持久组件" "$MUTED"
    fi
    if [[ "$handler" == "official_release" ]]; then
      ui_panel_kv "官方项目" "$(software_release_repository "$id")"
      ui_panel_kv "项目主页" "$(software_release_homepage "$id")"
      ui_panel_kv "命令路径" "$(software_release_target "$id")"
      if software_release_managed "$id"; then
        ui_panel_kv "完整性" "$(software_release_integrity "$id" && printf 'SHA-256 正常' || printf '异常')" \
          "$(software_release_integrity "$id" && printf '%s' "$GREEN" || printf '%s' "$RED")"
      else
        ui_panel_kv "完整性" "安装时校验 GitHub SHA-256 digest"
      fi
      [[ -z "$packages" ]] || ui_panel_kv "发行版备选" "$packages"
    elif software_official_repository_handler "$handler" && (( distribution_docker == 0 )); then
      ui_panel_kv "仓库状态" "$(software_repository_status_label "$repository_status")" \
        "$(catalog_repository_status_color "$repository_status")"
      ui_panel_kv "安装策略" "按需配置官方稳定仓库并验证候选版本"
    elif (( distribution_docker == 1 )); then
      ui_panel_kv "系统包" "docker.io"
      ui_panel_kv "更新策略" "沿用当前 Debian / Ubuntu 软件仓库"
    else
      ui_panel_kv "系统包" "${packages:-由官方安装器管理}"
    fi
    ui_panel_end
    [[ -z "$effect_note" ]] || ui_hint "运行影响：$effect_note"
    ui_section "可用操作" "primary"
    if [[ "$state" == "unavailable" ]]; then
      ui_action 1 "安装" "disabled" "当前系统软件源未提供"
      ui_action 2 "更新" "disabled" "需要先安装"
      ui_action 3 "移除" "disabled" "当前未安装"
    elif [[ "$state" == "absent" || "$state" == "setup" ]]; then
      if [[ "$state" == "setup" ]]; then
        ui_action 1 "配置仓库并安装" "success" "自动配置签名与 stable 仓库，再安装官方最新版本"
      else
        ui_action 1 "安装" "success" "安装候选版本 $candidate"
      fi
      ui_action 2 "更新" "disabled" "需要先安装"
      ui_action 3 "移除" "disabled" "当前未安装"
    elif [[ "$state" == "source-warning" && "$installed_flag" -eq 0 ]]; then
      ui_action 1 "修复仓库并安装" "warning" "备份现有配置后重新建立官方来源"
      ui_action 2 "更新" "disabled" "需要先安装"
      ui_action 3 "移除" "disabled" "当前未安装"
    else
      ui_action 1 "安装" "disabled" "已经安装"
      if [[ "$handler" == "official_release" ]] && software_release_managed "$id"; then
        ui_action 2 "检查官方更新" "action" "查询 latest stable Release 并验证 SHA-256"
      elif [[ "$state" == "update" ]]; then
        ui_action 2 "更新" "warning" "$installed → $candidate"
      else
        ui_action 2 "检查更新" "action" "刷新索引并重新检查"
      fi
      if [[ "$state" == external ]]; then ui_action 3 "移除" "disabled" "外部程序未接管，不删除原文件"
      else ui_action 3 "移除" "danger" "保留配置和业务数据"; fi
    fi
    if [[ "$handler" == "official_release" ]]; then
      if [[ "$state" == external || ( "$state" != absent && "$state" != unavailable && -n "$packages" ) ]]; then
        ui_action 4 "切换来源 / 确认接管" "accent" "官方稳定版与现有安装；外部同路径文件先备份"
      else
        ui_action 4 "切换来源" "disabled" "当前没有可切换的第二来源"
      fi
      if software_release_managed "$id"; then
        if [[ "$state" == "damaged" ]]; then
          ui_action 5 "修复官方安装" "danger" "备份现有命令并重新安装可信版本"
        else
          ui_action 5 "重新安装官方版" "warning" "重新下载、校验并部署当前最新稳定版"
        fi
      else
        ui_action 5 "修复官方安装" "disabled" "当前不由官方 Release 安装器管理"
      fi
    elif software_official_repository_handler "$handler" && (( distribution_docker == 0 )); then
      ui_action 4 "来源诊断" "accent" "检查官方地址、签名、软件源文件和候选版本"
      if [[ "$repository_status" == "configured" ]]; then
        ui_action 5 "重新验证仓库" "action" "刷新索引并确认当前系统存在候选版本"
      elif [[ "$repository_status" == "unsafe" ]]; then
        ui_action 5 "修复官方仓库" "disabled" "符号链接路径需要先人工核实"
      elif [[ "$state" == "setup" ]]; then
        ui_action 5 "修复官方仓库" "disabled" "安装时将自动完成配置"
      else
        ui_action 5 "修复官方仓库" "warning" "备份现有文件并重新配置稳定来源"
      fi
    fi
    ui_action 0 "返回软件中心" "muted"
    choice="$(read_input "请选择" "0")"
    case "$choice" in
      1)
        if [[ "$state" == "absent" || "$state" == "setup" || ( "$state" == "source-warning" && "$installed_flag" -eq 0 ) ]]; then
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
          ui_danger "如命令完整性异常，现有文件会先备份，再由通过 SHA-256 校验的官方版本替换。"
          if confirm "重新安装 $name 的官方稳定版？"; then
            require_root
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
      *) warn "未知选项" ;;
    esac
  done
}

catalog_categories_view() {
  local entries=() category count choice index selected
  mapfile -t entries < <(catalog_categories)
  while true; do
    ui_page "软件管理 / 分类浏览" "按用途浏览 ${#entries[@]} 个分类"
    ui_section "软件分类" "primary"
    for index in "${!entries[@]}"; do
      IFS='|' read -r category count <<<"${entries[$index]}"
      ui_item "$((index + 1))" "$category" "$count 个软件"
    done
    ui_action 0 "返回软件中心" "muted"
    choice="$(read_input "请选择分类" "0")"
    [[ "$choice" == "0" ]] && return 0
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#entries[@]} )); then
      warn "无效分类编号：$choice"
      pause
      continue
    fi
    selected="${entries[$((choice - 1))]}"
    IFS='|' read -r category count <<<"$selected"
    catalog_browse_view category "$category" "软件管理 / $category" "$count 个独立软件 · 单项管理"
  done
}

catalog_installed_view() {
  catalog_browse_view installed "" "软件管理 / 已安装" "仅显示目录中已经安装的条目"
}

catalog_updates_view() {
  catalog_browse_view updates "" "软件管理 / 仓库更新" "APT 候选版本有更新 · 官方 Release 请单独检查"
}

catalog_sources_view() {
  local choice kind title
  while true; do
    ui_page "软件管理 / 来源浏览" "按维护渠道查看软件，系统组件与上游工具采用不同策略"
    ui_section "来源类型" "primary"
    ui_action 1 "发行版软件仓库" "action" "Debian / Ubuntu 维护，系统兼容优先"
    ui_action 2 "项目官方 Release" "success" "独立 CLI · amd64/arm64 · SHA-256 校验"
    ui_action 3 "项目官方 APT 仓库" "accent" "Docker、Caddy 等长期运行服务"
    ui_action 0 "返回软件中心" "muted"
    choice="$(read_input "请选择来源" "0")"
    case "$choice" in
      1) kind="distribution"; title="发行版软件仓库" ;;
      2) kind="official-release"; title="项目官方 Release" ;;
      3) kind="official-repository"; title="项目官方 APT 仓库" ;;
      0) return 0 ;;
      *) warn "未知来源编号：$choice"; pause; continue ;;
    esac
    catalog_browse_view source "$kind" "软件来源 / $title" "按维护渠道筛选 · 一次只管理一个软件"
  done
}

catalog_official_updates_view() {
  local interactive="${1:-1}" record id _category name _description _packages handler current latest input checked=0 updates=0 failed=0
  ui_page "软件管理 / 官方更新检查" "逐项查询已托管 CLI 的 latest stable Release，不自动安装"
  ui_note "只检查由 Server Toolkit 官方 Release 安装器管理的软件；GitHub API 可能需要数秒。"
  while IFS= read -r record; do
    IFS='|' read -r id _category name _description _packages handler <<<"$record"
    [[ "$handler" == "official_release" ]] || continue
    software_release_managed "$id" || continue
    checked=$((checked + 1))
    current="$(software_release_version "$id")"
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
  ui_note "输入软件 ID 可单独更新、修复或切换来源。"
  input="$(read_input "软件 ID；输入 0 返回" "0")"
  [[ "$input" == "0" ]] && return 0
  if catalog_record "$input" >/dev/null 2>&1; then catalog_item_menu "$input"; else warn "未知软件 ID：$input"; pause; fi
}

catalog_refresh_index() {
  ui_page "软件管理 / 刷新索引" "从已配置的软件仓库获取最新版本元数据"
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
    stats="$(catalog_statistics)"
    IFS='|' read -r total installed updates <<<"$stats"
    ui_page "软件管理" "独立软件的搜索、版本检查、安装、更新与移除"
    ui_stats "目录" "$total" "已安装" "$installed" "仓库更新" "$updates"
    ui_section "快捷操作" "primary"
    ui_action A "按分类浏览" "action" "在分类内查看版本、状态与可用操作"
    ui_action I "仅看已安装" "success" "快速进入已安装软件的更新与移除"
    ui_action U "查看仓库更新" "warning" "只列出 APT 候选版本更新"
    ui_action O "检查官方更新" "success" "查询已托管 CLI 的 latest stable Release"
    ui_action S "按来源浏览" "action" "区分发行版、官方仓库与官方下载"
    ui_action R "刷新软件索引" "accent" "从已配置仓库获取最新元数据"
    ui_section "搜索软件" "accent"
    ui_context "输入精确 ID 打开详情，或输入名称、分类、用途进行搜索。"
    ui_empty "示例：python、网络、备份、nginx、docker"
    printf '\n'
    input="$(read_input "搜索 / ID / A / I / U / O / S / R；输入 0 返回" "0")"
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
          catalog_browse_view search "$input" "软件搜索" "按 ID、名称、分类或用途匹配"
        fi
        ;;
    esac
  done
}
