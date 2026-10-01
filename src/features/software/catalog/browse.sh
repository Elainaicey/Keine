#!/usr/bin/env bash

catalog_browse_rows() {
  local mode="$1" filter="$2" record
  case "$mode" in
    search) catalog_rows "$filter" ;;
    category) catalog_category_rows "$filter" ;;
    installed)
      while IFS= read -r record; do
        catalog_installed "$record" && printf '%s\n' "$record"
      done < <(catalog_rows)
      ;;
    updates)
      while IFS= read -r record; do
        catalog_has_update "$record" && printf '%s\n' "$record"
      done < <(catalog_rows)
      ;;
    source)
      awk -F '|' -v kind="$filter" '!/^#/ && NF == 6 {
        source=($6 == "official_release" ? "official-release" :
          ($6 == "docker_official" || $6 == "caddy_official" ? "official-repository" : "distribution"))
        if (source == kind) print
      }' "$SOFTWARE_CATALOG"
      ;;
    *) die "未知的软件浏览模式：$mode" ;;
  esac
}

catalog_browse_view() {
  local mode="$1" filter="$2" title="$3" subtitle="${4:-}"
  local rows=() page=0 page_size=6 total pages start end index shown=0
  local record id name state_label state_style state current candidate choice filter_preview
  local rows_generation=-1
  while true; do
    catalog_cache_build
    if (( rows_generation != CATALOG_CACHE_GENERATION )); then
      mapfile -t rows < <(catalog_browse_rows "$mode" "$filter")
      rows_generation="$CATALOG_CACHE_GENERATION"
    fi
    total="${#rows[@]}"
    if (( total == 0 )); then
      ui_page "$title" "$subtitle"
      ui_empty "当前条件下没有软件条目"
      ui_menu_footer "返回"
      ui_read_choice choice
      [[ "$choice" == 0 ]] && return 0
      warn "没有可选择的软件。"
      continue
    fi
    pages=$(((total + page_size - 1) / page_size))
    (( page < pages )) || page=$((pages - 1))
    start=$((page * page_size))
    end=$((start + page_size))
    (( end <= total )) || end="$total"
    ui_page "$title" "$subtitle"
    if [[ "$mode" == "search" ]]; then
      filter_preview="$(terminal_safe_text "$filter")"
      (( ${#filter_preview} <= 40 )) || filter_preview="${filter_preview:0:39}…"
      ui_context "$filter_preview"
    fi
    ui_context "$total 项 · $((page + 1))/$pages 页"
    printf '\n'
    shown=0
    for (( index=start; index<end; index++ )); do
      record="${rows[$index]}"
      IFS='|' read -r id _ name _ <<<"$record"
      current="$(catalog_installed_version "$record")"
      candidate="$(catalog_candidate_version "$record")"
      state="$(catalog_state "$record" "$candidate")"
      IFS='|' read -r state_label state_style <<<"$(catalog_state_info "$state")"
      ui_state_item "$((index - start + 1))" "$name" "$state_label" "$state_style"
      case "$state" in
        update) printf '       %b%s · %s → %s%b\n' "$MUTED" "$id" "$current" "$candidate" "$NC" ;;
        current|managed|external|damaged) printf '       %b%s · %s%b\n' "$MUTED" "$id" "$current" "$NC" ;;
        absent) printf '       %b%s · %s%b\n' "$MUTED" "$id" "$candidate" "$NC" ;;
        *) printf '       %b%s%b\n' "$MUTED" "$id" "$NC" ;;
      esac
      shown=$((shown + 1))
    done
    ui_section "操作" "accent"
    (( page > 0 )) && ui_action P "上一页" "action"
    (( page + 1 < pages )) && ui_action N "下一页" "action"
    ui_action R "刷新索引" "accent"
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      0) return 0 ;;
      N|n) if (( page + 1 < pages )); then page=$((page + 1)); else warn "已经是最后一页。"; pause; fi ;;
      P|p) if (( page > 0 )); then page=$((page - 1)); else warn "已经是第一页。"; pause; fi ;;
      R|r) catalog_refresh_index || true; pause ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= shown )); then
          IFS='|' read -r id _ <<<"${rows[$((start + choice - 1))]}"
          catalog_item_menu "$id"
        elif catalog_record "$choice" >/dev/null 2>&1; then
          catalog_item_menu "$choice"
        else
          warn "无效编号或软件 ID：$choice"
          pause
        fi
        ;;
    esac
  done
}
