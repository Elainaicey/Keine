#!/usr/bin/env bash

SOFTWARE_GUIDES_CATALOG="${KEINE_SOFTWARE_GUIDES_CATALOG:-$CONFIG_DIR/software-guides.tsv}"

catalog_guide_record() {
  [[ -r "$SOFTWARE_GUIDES_CATALOG" ]] || return 1
  awk -F '|' -v wanted="$1" '!/^#/ && NF == 6 && $1 == wanted {print; found=1; exit} END {if (!found) exit 1}' \
    "$SOFTWARE_GUIDES_CATALOG"
}

catalog_guide_view() {
  local id="$1" record _id heading related boundary hint documentation choice index related_id related_record name
  local entries=()
  record="$(catalog_guide_record "$id")" || return 1
  IFS='|' read -r _id heading related boundary hint documentation <<<"$record"
  IFS=',' read -r -a entries <<<"$related"
  while true; do
    ui_page "软件指南 / $heading" "$id"
    ui_panel_begin "使用边界"
    ui_panel_kv "安装" "$boundary"
    ui_panel_kv "使用" "$hint"
    ui_panel_kv "官方文档" "$documentation" "$CYAN"
    ui_panel_end
    ui_section "相关软件" "accent"
    for index in "${!entries[@]}"; do
      related_id="${entries[$index]}"
      related_record="$(catalog_record "$related_id")" || continue
      IFS='|' read -r _ _ name _ <<<"$related_record"
      ui_action "$((index + 1))" "$name" "action" "$related_id"
    done
    ui_menu_footer "返回"
    ui_read_choice choice
    [[ "$choice" == 0 ]] && return 0
    if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && (( ${#choice} <= 2 && choice <= ${#entries[@]} )); then
      catalog_item_menu "${entries[$((choice - 1))]}"
    else
      warn "未知选项：$choice"; pause
    fi
  done
}

catalog_distribution_diagnostics() {
  local id="$1" record _id _category name _description packages _handler candidate installed output
  record="$(catalog_record "$id")" || return 1
  IFS='|' read -r _id _category name _description packages _handler <<<"$record"
  packages="${2:-$packages}"
  [[ "$packages" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || { warn "$name 没有有效发行版包映射。"; return 1; }
  candidate="$(catalog_package_candidate_version "$packages")"
  installed="$(catalog_package_installed_version "$packages")"
  ui_page "软件来源诊断 / $name" "只读取本机 APT 配置和索引，不发起联网请求"
  ui_panel_begin "发行版来源"
  ui_panel_kv "系统包" "$packages"
  ui_panel_kv "当前版本" "${installed:-—}"
  ui_panel_kv "候选版本" "${candidate:-未读取}"
  ui_panel_kv "索引确认" "$([[ "${PACKAGE_INDEX_UPDATED:-0}" == 1 ]] && printf '本次已刷新' || printf '本地缓存，未联网确认')"
  ui_panel_end
  if command_exists apt-cache; then
    output="$(LC_ALL=C runtime_with_timeout 5 apt-cache policy "$packages" 2>/dev/null || true)"
    ui_section "版本优先级与来源" "accent"
    if [[ -n "$output" ]]; then terminal_safe_text "$output"; printf '\n'; else ui_empty "本地索引没有版本记录"; fi
  fi
  ui_hint "无候选版本不等于网络故障：先 R 刷新，再核实包名、架构、源组件与系统支持情况。"
}
