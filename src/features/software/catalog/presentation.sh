#!/usr/bin/env bash

catalog_state_info() {
  case "$1" in
    absent) printf '未安装|muted' ;;
    setup) printf '待配置|primary' ;;
    source-warning) printf '来源需修复|warning' ;;
    unavailable) printf '仓库不可用|danger' ;;
    update) printf '可更新|warning' ;;
    current) printf '已是最新|success' ;;
    managed) printf '已安装|success' ;;
    external) printf '外部安装|primary' ;;
    damaged) printf '完整性异常|danger' ;;
    *) printf '未知|muted' ;;
  esac
}

catalog_state_badge() {
  local label style
  IFS='|' read -r label style <<<"$(catalog_state_info "$1")"
  ui_badge "$label" "$(ui_color_for_state "$style")"
}

catalog_repository_status_color() {
  case "${1:-}" in
    configured) printf '%s' "$GREEN" ;;
    missing) printf '%s' "$CYAN" ;;
    incomplete) printf '%s' "$YELLOW" ;;
    unsafe) printf '%s' "$RED" ;;
    *) printf '%s' "$MUTED" ;;
  esac
}

catalog_statistics() {
  local record id _category _name _description _packages handler package total=0 installed=0 updates=0
  catalog_cache_build
  while IFS= read -r record; do
    total=$((total + 1))
    if catalog_installed "$record"; then
      installed=$((installed + 1))
      IFS='|' read -r id _category _name _description _packages handler <<<"$record"
      if [[ "$handler" == "official_release" ]] && software_release_managed "$id"; then
        continue
      fi
      package="$(catalog_primary_package "$record")"
      catalog_cache_package_has_update "$package" && updates=$((updates + 1))
    fi
  done < <(catalog_rows)
  printf '%s|%s|%s' "$total" "$installed" "$updates"
}

catalog_print_record() {
  local record="$1" id _category name description _packages _handler state installed candidate
  catalog_cache_build
  IFS='|' read -r id _category name description _packages _handler <<<"$record"
  installed="$(catalog_installed_version "$record")"
  candidate="$(catalog_candidate_version "$record")"
  state="$(catalog_state "$record" "$candidate")"
  printf '  %b›%b %b' "$MAGENTA" "$NC" "$CYAN$BOLD"
  ui_pad "$id" 20
  printf '%b%b' "$NC" "$BLUE$BOLD"
  ui_pad "$name" 22
  printf '%b\n' "$(catalog_state_badge "$state")"
  printf '    %b%s%b\n' "$MUTED" "$description" "$NC"
  if [[ "$state" == "update" ]]; then
    printf '    %b版本%b  %b%s%b %b→%b %b%s%b\n' "$BLUE" "$NC" "$WHITE" "$installed" "$NC" "$MAGENTA" "$NC" "$YELLOW" "$candidate" "$NC"
  elif [[ "$state" == "current" ]]; then
    printf '    %b版本%b  %b%s%b\n' "$BLUE" "$NC" "$GREEN" "$installed" "$NC"
  elif [[ "$state" == "managed" ]]; then
    printf '    %b当前版本%b  %b%s%b  %b· 可检查官方更新%b\n' "$BLUE" "$NC" "$GREEN" "$installed" "$NC" "$MUTED" "$NC"
  elif [[ "$state" == "setup" ]]; then
    printf '    %b安装方式%b  %b确认后自动配置官方 APT 仓库%b\n' "$BLUE" "$NC" "$CYAN" "$NC"
  elif [[ "$state" == "source-warning" ]]; then
    printf '    %b来源状态%b  %b官方仓库配置需要核实或修复%b\n' "$BLUE" "$NC" "$YELLOW" "$NC"
  elif [[ "$state" == "unavailable" ]]; then
    printf '    %b可用性%b  %b当前系统软件源未提供此软件包%b\n' "$BLUE" "$NC" "$YELLOW" "$NC"
  else
    printf '    %b仓库版本%b  %b%s%b\n' "$BLUE" "$NC" "$WHITE" "$candidate" "$NC"
  fi
}

catalog_print() {
  local query="${1:-}" record category last_category="" count=0
  catalog_cache_build
  while IFS= read -r record; do
    IFS='|' read -r _ category _ <<<"$record"
    if [[ "$category" != "$last_category" ]]; then
      [[ -z "$last_category" ]] || printf '\n'
      ui_section "$category" "accent"
      last_category="$category"
    fi
    catalog_print_record "$record"
    count=$((count + 1))
  done < <(catalog_rows "$query")
  (( count > 0 )) || { warn "没有找到与 '$query' 匹配的软件。"; return 1; }
}

catalog_print_category() {
  local category="$1" record count=0
  catalog_cache_build
  while IFS= read -r record; do
    catalog_print_record "$record"
    count=$((count + 1))
  done < <(catalog_category_rows "$category")
  (( count > 0 )) || { warn "分类 '$category' 中没有软件。"; return 1; }
}
