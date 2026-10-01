#!/usr/bin/env bash

system_package_upgradable_rows() {
  LC_ALL=C apt list --upgradable 2>/dev/null | awk '
    NR == 1 {next}
    NF >= 3 {
      package=$1
      sub(/\/.*/, "", package)
      candidate=$2
      architecture=$3
      current="—"
      line=$0
      if (line ~ /\[upgradable from: /) {
        sub(/^.*\[upgradable from: /, "", line)
        sub(/\].*$/, "", line)
        current=line
      }
      print package "|" current "|" candidate "|" architecture
    }
  '
}

system_package_security_rows() {
  LC_ALL=C apt-get -s -o Debug::NoLocking=true upgrade --with-new-pkgs --no-remove 2>/dev/null |
    awk 'tolower($0) ~ /^inst / && tolower($0) ~ /security/ {print $2}' |
    LC_ALL=C sort -u
}

system_package_autoremove_rows() {
  apt-get -s -o Debug::NoLocking=true autoremove 2>/dev/null |
    awk '/^Remv / {print $2}' |
    LC_ALL=C sort -u
}

system_package_source_rows() {
  local file line
  local files=(/etc/apt/sources.list /etc/apt/sources.list.d/*.list)
  for file in "${files[@]}"; do
    [[ -r "$file" ]] || continue
    while IFS= read -r line; do
      line="${line#"${line%%[![:space:]]*}"}"
      [[ "$line" == deb\ * || "$line" == deb-src\ * ]] || continue
      printf '%s|%s\n' "$file" "$line"
    done <"$file"
  done
  for file in /etc/apt/sources.list.d/*.sources; do
    [[ -r "$file" ]] || continue
    awk -v source="$file" '
      function emit() {
        if (!disabled && uris != "") {
          printf "%s|URIs: %s", source, uris
          if (suites != "") printf " · Suites: %s", suites
          if (components != "") printf " · Components: %s", components
          printf "\n"
        }
        disabled=0; uris=""; suites=""; components=""
      }
      /^[[:space:]]*$/ {emit(); next}
      /^Enabled:[[:space:]]*no/ {disabled=1; next}
      /^URIs:/ {uris=$0; sub(/^URIs:[[:space:]]*/, "", uris); next}
      /^Suites:/ {suites=$0; sub(/^Suites:[[:space:]]*/, "", suites); next}
      /^Components:/ {components=$0; sub(/^Components:[[:space:]]*/, "", components); next}
      END {emit()}
    ' "$file"
  done
}

system_package_index_age() {
  local latest now age hours
  latest="$(find /var/lib/apt/lists -maxdepth 1 -type f -printf '%T@\n' 2>/dev/null |
    sort -nr | head -n 1 | cut -d. -f1)"
  [[ "$latest" =~ ^[0-9]+$ ]] || { printf '尚无本地索引'; return 0; }
  now="$(date +%s)"
  age=$((now - latest))
  (( age < 0 )) && age=0
  hours=$((age / 3600))
  if (( hours < 1 )); then
    printf '1 小时内'
  elif (( hours < 48 )); then
    printf '%s 小时前' "$hours"
  else
    printf '%s 天前' "$((hours / 24))"
  fi
}

system_package_updates_view() {
  local mode="${1:-all}" package current candidate architecture count=0
  local -A security_packages=()
  if [[ "$mode" == "security" ]]; then
    while IFS= read -r package; do
      [[ -n "$package" ]] && security_packages["$package"]=1
    done < <(system_package_security_rows)
    ui_page "系统软件包 / 安全更新" "根据 APT 模拟升级结果识别 security 仓库候选版本"
  else
    ui_page "系统软件包 / 可用更新" "当前 APT 索引中的已安装软件包候选版本"
  fi
  while IFS='|' read -r package current candidate architecture; do
    [[ -n "$package" ]] || continue
    if [[ "$mode" == "security" && -z "${security_packages[$package]:-}" ]]; then
      continue
    fi
    count=$((count + 1))
    printf '  %b◆%b %b%s%b  %b%s%b\n' "$MAGENTA" "$NC" "$CYAN$BOLD" "$package" "$NC" "$MUTED" "$architecture" "$NC"
    printf '    %b版本%b  %s %b→%b %s\n' "$BLUE" "$NC" "$current" "$MAGENTA" "$NC" "$candidate"
    (( count >= 100 )) && break
  done < <(system_package_upgradable_rows)
  (( count > 0 )) || ui_empty "$([[ "$mode" == "security" ]] && printf '没有识别到安全更新' || printf '没有可用更新')"
  (( count < 100 )) || ui_note "仅显示前 100 项。"
  ui_note "清单基于本地索引；通过 系统管理 → 系统更新 刷新、预览并确认更新。"
}

system_package_sources_view() {
  local file entry count=0 last_file=""
  ui_page "系统软件包 / APT 来源" "仅展示当前启用的传统 list 与 deb822 sources 条目"
  while IFS='|' read -r file entry; do
    [[ -n "$file" && -n "$entry" ]] || continue
    if [[ "$file" != "$last_file" ]]; then
      ui_section "$file" "primary"
      last_file="$file"
    fi
    printf '  %b›%b %s\n' "$MAGENTA" "$NC" "$(terminal_safe_text "$entry")"
    count=$((count + 1))
  done < <(system_package_source_rows)
  (( count > 0 )) || ui_empty "没有找到启用的 APT 来源"
  ui_note "共 $count 个启用条目；本页面不会修改 sources.list。"
}

system_package_hold_manage() {
  local held package choice verb
  held="$(apt-mark showhold 2>/dev/null || true)"
  ui_page "系统软件包 / 保留状态" "使用 apt-mark 管理一个明确的软件包"
  ui_section "当前 hold" "primary"
  if [[ -n "$held" ]]; then printf '%s\n' "$held"; else ui_empty "没有被保留的软件包"; fi
  ui_hint "输入精确 Debian 软件包名，例如 linux-image-amd64；输入 0 返回。"
  package="$(read_input "软件包名" "0")"
  [[ "$package" == "0" ]] && return 0
  valid_package_name "$package" || { warn "软件包名格式无效。"; return 1; }
  package_installed "$package" || { warn "$package 尚未安装。"; return 1; }
  if grep -Fxq "$package" <<<"$held"; then
    ui_action 1 "取消保留" "warning" "允许 APT 后续更新该软件包"
    ui_action 0 "返回" "muted"
    choice="$(read_input "请选择" "0")"
    [[ "$choice" == "1" ]] || return 0
    verb="unhold"
  else
    ui_action 1 "设为保留" "warning" "阻止 APT 自动更新该软件包"
    ui_action 0 "返回" "muted"
    choice="$(read_input "请选择" "0")"
    [[ "$choice" == "1" ]] || return 0
    verb="hold"
  fi
  confirm "对 $package 执行 apt-mark $verb？" || return 0
  require_root
  run apt-mark "$verb" "$package" || { warn "修改 hold 状态失败。"; return 1; }
  if [[ "$DRY_RUN" -eq 0 ]]; then
    if [[ "$verb" == "hold" ]]; then
      apt-mark showhold 2>/dev/null | grep -Fxq "$package" || { warn "$package 未进入 hold 状态。"; return 1; }
    elif apt-mark showhold 2>/dev/null | grep -Fxq "$package"; then
      warn "$package 仍处于 hold 状态。"
      return 1
    fi
  fi
  audit "action=package-$verb package=$package"
  ui_success "$package 已执行 $verb。"
}

system_package_autoremove() {
  local packages count
  packages="$(system_package_autoremove_rows)"
  count="$(awk 'NF {count++} END {print count+0}' <<<"$packages")"
  ui_page "系统软件包 / 清理残留依赖" "只处理 APT 标记为自动安装且不再需要的软件包"
  if (( count == 0 )); then
    ui_success "当前没有可自动移除的软件包。"
    return 0
  fi
  ui_panel_begin "清理预览"
  ui_panel_kv "软件包" "$count 个" "$YELLOW"
  ui_panel_end
  sed -n '1,80p' <<<"$packages"
  (( count <= 80 )) || ui_note "仅显示前 80 项，共 $count 项。"
  ui_danger "APT 的自动标记可能受历史安装方式影响；请确认清单中没有仍被业务使用的软件。"
  confirm "执行 apt-get autoremove？" || return 0
  require_root
  apt_run autoremove -y || { warn "APT 自动清理失败。"; return 1; }
  if [[ "$DRY_RUN" -eq 0 && -n "$(system_package_autoremove_rows)" ]]; then
    warn "清理后仍存在可自动移除的软件包。"
    return 1
  fi
  audit "action=package-autoremove count=$count"
  ui_success "APT 残留依赖清理完成。"
}

system_package_repair() {
  local audit simulation
  audit="$(dpkg --audit 2>/dev/null || true)"
  simulation="$(apt-get -s -o Debug::NoLocking=true -f install 2>&1 || true)"
  ui_page "系统软件包 / 修复状态" "重新配置中断的软件包并修复依赖关系"
  ui_section "dpkg 审计" "primary"
  if [[ -n "$audit" ]]; then printf '%s\n' "$audit"; else ui_success "dpkg 没有报告未完成配置。"; fi
  ui_section "APT 修复模拟" "accent"
  if [[ -n "$simulation" ]]; then sed -n '1,80p' <<<"$simulation"; else ui_empty "APT 没有返回修复计划"; fi
  if [[ -z "$audit" ]] && apt-get -o Debug::NoLocking=true check >/dev/null 2>&1; then
    ui_success "软件包数据库和依赖关系均正常。"
    return 0
  fi
  ui_danger "修复可能配置、安装或移除软件包；请先检查上方 APT 模拟结果。"
  confirm "继续修复软件包状态？" || return 0
  require_root
  run dpkg --configure -a || { warn "dpkg 重新配置失败。"; return 1; }
  apt_run -f install -y || { warn "APT 依赖修复失败。"; return 1; }
  if [[ "$DRY_RUN" -eq 0 ]]; then
    [[ -z "$(dpkg --audit 2>/dev/null || true)" ]] || { warn "修复后 dpkg 仍报告异常。"; return 1; }
    apt-get -o Debug::NoLocking=true check >/dev/null 2>&1 || { warn "修复后 APT 依赖检查仍未通过。"; return 1; }
  fi
  audit "action=package-repair"
  ui_success "软件包状态修复完成。"
}

system_package_cache_clean() {
  local before after
  before="$(du -sh /var/cache/apt/archives 2>/dev/null | awk '{print $1}' || printf '未知')"
  ui_page "系统软件包 / 清理缓存" "删除已经下载的 APT 软件包文件，不移除已安装软件"
  ui_panel_begin "清理计划"
  ui_panel_kv "目标" "/var/cache/apt/archives"
  ui_panel_kv "当前占用" "$before" "$YELLOW"
  ui_panel_end
  confirm "清理 APT 下载缓存？" || return 0
  require_root
  apt_run clean || { warn "APT 缓存清理失败。"; return 1; }
  after="$(du -sh /var/cache/apt/archives 2>/dev/null | awk '{print $1}' || printf '未知')"
  audit "action=package-cache-clean before=$before after=$after"
  ui_success "APT 缓存已清理：$before → $after"
}

system_package_health() {
  local interactive="${1:-1}" audit updates security_updates held autoremove sources cache_size apt_state choice
  while true; do
    audit="$(dpkg --audit 2>/dev/null || true)"
    updates="$(system_package_upgradable_rows | awk 'NF {count++} END {print count+0}')"
    security_updates="$(system_package_security_rows | awk 'NF {count++} END {print count+0}')"
    held="$(apt-mark showhold 2>/dev/null | awk 'NF {count++} END {print count+0}')"
    autoremove="$(system_package_autoremove_rows | awk 'NF {count++} END {print count+0}')"
    sources="$(system_package_source_rows | awk 'NF {count++} END {print count+0}')"
    cache_size="$(du -sh /var/cache/apt/archives 2>/dev/null | awk '{print $1}' || printf '未知')"
    if apt-get -o Debug::NoLocking=true check >/dev/null 2>&1; then apt_state="正常"; else apt_state="异常"; fi

    ui_page "系统软件包健康中心" "dpkg、更新、安全补丁、hold、软件源、缓存与残留依赖"
    ui_stats "可更新" "$updates" "安全更新" "$security_updates" "自动清理" "$autoremove"
    ui_panel_begin "状态摘要"
    ui_panel_kv "dpkg" "$([[ -z "$audit" ]] && printf '正常' || printf '存在未完成配置')" "$([[ -z "$audit" ]] && printf '%s' "$GREEN" || printf '%s' "$RED")"
    ui_panel_kv "APT 依赖" "$apt_state" "$([[ "$apt_state" == "正常" ]] && printf '%s' "$GREEN" || printf '%s' "$RED")"
    ui_panel_kv "被保留" "$held 个"
    ui_panel_kv "启用来源" "$sources 个"
    ui_panel_kv "索引时间" "$(system_package_index_age)"
    ui_panel_kv "下载缓存" "$cache_size"
    ui_panel_kv "重启需求" "$([[ -f /var/run/reboot-required ]] && printf '需要安排重启' || printf '当前不需要')"
    ui_panel_end

    if [[ "$interactive" -eq 0 ]]; then
      system_package_updates_view all
      return 0
    fi

    ui_section "查看与管理" "primary"
    ui_action 1 "查看全部更新" "action" "$updates 个候选版本"
    ui_action 2 "查看安全更新" "warning" "$security_updates 个安全仓库候选版本"
    ui_action 3 "管理 hold" "action" "$held 个被保留软件包"
    ui_action 4 "查看 APT 来源" "action" "$sources 个启用条目"
    ui_action 5 "检查并修复状态" "$([[ -z "$audit" && "$apt_state" == "正常" ]] && printf 'success' || printf 'danger')" "dpkg 配置与依赖关系"
    ui_action 6 "清理残留依赖" "$([[ "$autoremove" -eq 0 ]] && printf 'disabled' || printf 'warning')" "$autoremove 个自动安装软件包"
    ui_action 7 "清理下载缓存" "warning" "当前占用 $cache_size"
    ui_action 8 "刷新 APT 索引" "accent" "重新读取所有配置的软件源"
    ui_action 9 "系统更新" "warning" "刷新、事务预览与人工确认"
    ui_action 0 "返回系统管理" "muted"
    choice="$(read_input "请选择" "0")"
    case "$choice" in
      1) system_package_updates_view all ;;
      2) system_package_updates_view security ;;
      3) system_package_hold_manage || true ;;
      4) system_package_sources_view ;;
      5) system_package_repair || true ;;
      6)
        if [[ "$autoremove" -eq 0 ]]; then info "当前没有可自动移除的软件包."; else system_package_autoremove || true; fi
        ;;
      7) system_package_cache_clean || true ;;
      8)
        confirm "立即刷新全部 APT 软件索引？" || { pause; continue; }
        require_root
        package_invalidate_index
        package_update_index && ui_success "APT 索引刷新完成。"
        catalog_cache_invalidate
        ;;
      9) system_update_menu; continue ;;
      0) return 0 ;;
      *) warn "未知选项：$choice"; continue ;;
    esac
    pause
  done
}
