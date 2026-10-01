#!/usr/bin/env bash

# 当前发行版的按需升级，不改来源、不迁移发行版、不自动移除或重启。
SYSTEM_UPDATE_PLAN=""
SYSTEM_UPDATE_UPGRADED=0
SYSTEM_UPDATE_NEW=0
SYSTEM_UPDATE_KEPT=0

system_update_simulate() {
  SYSTEM_UPDATE_PLAN=""
  SYSTEM_UPDATE_UPGRADED=0; SYSTEM_UPDATE_NEW=0; SYSTEM_UPDATE_KEPT=0
  if ! SYSTEM_UPDATE_PLAN="$(LC_ALL=C apt-get -s -o Debug::NoLocking=true \
    -o APT::Get::AutomaticRemove=false upgrade --with-new-pkgs --no-remove 2>&1)"; then
    warn "无法生成安全更新计划；请先检查软件包健康和 APT 来源。"
    terminal_safe_text "$(tail -n 8 <<<"$SYSTEM_UPDATE_PLAN")"; printf '\n'
    return 1
  fi
  if grep -q '^Remv ' <<<"$SYSTEM_UPDATE_PLAN"; then
    warn "更新计划包含软件包移除，已阻止执行。"
    return 1
  fi
  IFS='|' read -r SYSTEM_UPDATE_UPGRADED SYSTEM_UPDATE_NEW SYSTEM_UPDATE_KEPT < <(
    awk '
      /^Inst / {if ($3 ~ /^\[/) upgraded++; else added++}
      /^[0-9]+ upgraded,/ {kept=$(NF-2)}
      END {print upgraded+0 "|" added+0 "|" kept+0}
    ' <<<"$SYSTEM_UPDATE_PLAN"
  )
}

system_update_plan_render() {
  local rows count package before after
  ui_stats "升级" "$SYSTEM_UPDATE_UPGRADED" "新增依赖" "$SYSTEM_UPDATE_NEW" "暂不更新" "$SYSTEM_UPDATE_KEPT"
  rows="$(awk '
    /^Inst / {
      package=$2; old="未安装"; rest=$0
      if ($3 ~ /^\[/) {old=$3; gsub(/[][]/, "", old)}
      sub(/^[^(]*\(/, "", rest); split(rest, parts, " ")
      print package "|" old "|" parts[1]
    }
  ' <<<"$SYSTEM_UPDATE_PLAN")"
  ui_section "事务预览" "primary"
  count=0
  while IFS='|' read -r package before after; do
    [[ -n "$package" ]] || continue
    count=$((count + 1))
    (( count <= 12 )) || break
    ui_kv "$package" "$before → $after"
  done <<<"$rows"
  (( count > 0 )) || ui_empty "当前计划没有需要安装的更新"
  (( SYSTEM_UPDATE_UPGRADED + SYSTEM_UPDATE_NEW <= 12 )) || ui_note "预览显示前 12 项；完整版本清单可在更新中心查看。"
  ui_note "新增项仅为升级所需依赖；不会自动移除软件、解除 hold 或重启 VPS。"
}

system_update_preflight() {
  local report
  platform_detect_identity
  case "${OS_ID:-}" in debian|ubuntu) ;; *) warn "仅支持 Debian / Ubuntu。"; return 1 ;; esac
  [[ -n "${OS_CODENAME:-}" ]] || { warn "无法确定当前发行版代号，拒绝自动更新。"; return 1; }
  if ! report="$(dpkg --audit 2>&1)"; then
    warn "无法读取 dpkg 状态，请先打开软件包健康中心。"; return 1
  fi
  if [[ -n "$report" ]]; then
    warn "存在未完成的软件包配置；请先在软件包健康中心检查并修复。"
    terminal_safe_text "$report"; printf '\n'
    return 1
  fi
  if ! LC_ALL=C apt-get -o Debug::NoLocking=true check >/dev/null 2>&1; then
    warn "软件包依赖检查未通过；请先修复，再执行系统更新。"; return 1
  fi
}

system_update_sources_check() {
  local policy conflicts
  policy="$(LC_ALL=C apt-cache policy 2>/dev/null)" || { warn "无法读取 APT 来源。"; return 1; }
  # stable 别名可能已指向下一发行版；不因源配置漂移而静默跨版。
  conflicts="$(awk -v codename="$OS_CODENAME" -v os="$OS_ID" '
    /release / {
      origin=""; name=""; line=$0; sub(/^.*release /, "", line)
      total=split(line, fields, ",")
      for (i=1; i<=total; i++) {
        if (fields[i] ~ /^o=/) origin=substr(fields[i],3)
        if (fields[i] ~ /^n=/) name=substr(fields[i],3)
      }
      if (origin == "Debian" || origin == "Ubuntu") {
        expected=(os == "debian" ? "Debian" : "Ubuntu")
        if (origin != expected || (name != codename && index(name,codename "-") != 1))
          print origin "/" name
      }
    }
  ' <<<"$policy" | sort -u)"
  [[ -z "$conflicts" ]] || {
    warn "发现其他发行版的系统来源：$(terminal_safe_text "$conflicts")。请先核实 APT 来源，当前代号为 $OS_CODENAME。"
    return 1
  }
}

system_update_apply() {
  local remaining report
  ui_page "系统更新 / 执行" "刷新 → 检查 → 预览 → 确认 → 验证"
  ui_context "${OS_NAME:-当前系统} · 保持当前发行版与已配置来源"
  ui_hint "建议先创建 VPS 实例快照，并保留服务商控制台；已有软件升级不能通过项目撤销。"
  confirm "刷新软件索引并生成系统更新计划？" || return 0
  require_root
  system_update_preflight || return 1
  package_invalidate_index
  catalog_cache_invalidate
  if ! apt_run update --error-on=any; then
    warn "软件索引未完整刷新，已停止更新；不会沿用不完整索引继续安装。"; return 1
  fi
  # 平台层共享索引状态，避免同一会话再次无条件刷新。
  # shellcheck disable=SC2034
  if [[ "$DRY_RUN" -eq 0 ]]; then PACKAGE_INDEX_UPDATED=1; fi
  system_update_sources_check || return 1
  system_update_simulate || return 1
  system_update_plan_render
  if (( SYSTEM_UPDATE_UPGRADED + SYSTEM_UPDATE_NEW == 0 )); then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "本地索引中没有待执行项；dry-run 不下载新索引，不能据此判断实际最新状态。"
    else
      ui_success "当前更新计划没有待执行项；hold 或依赖限制仍可能保留部分版本。"
    fi
    return 0
  fi
  ui_danger "软件包安装脚本仍可能重启自身服务、影响 SSH 或业务连接；needrestart 仅列出需求，原有配置默认保留。"
  confirm "按上述计划更新系统软件包？" || return 0
  if ! APT_NEEDRESTART_MODE=l apt_run upgrade --with-new-pkgs --no-remove -y -o APT::Get::AutomaticRemove=false; then
    catalog_cache_invalidate
    audit "action=system-update result=failed"
    warn "APT 更新未完成；已发生的升级不自动回滚，请检查软件包健康中心。"; return 1
  fi
  catalog_cache_invalidate
  [[ "$DRY_RUN" -eq 0 ]] || { info "仅预览命令，未更新系统软件包。"; return 0; }
  if ! report="$(dpkg --audit 2>&1)" || [[ -n "$report" ]] ||
    ! LC_ALL=C apt-get -o Debug::NoLocking=true check >/dev/null 2>&1; then
    audit "action=system-update result=verification-failed"
    warn "更新后的配置或依赖检查未通过；请打开软件包健康中心。"; return 1
  fi
  remaining="$(package_upgradable_count)"
  audit "action=system-update result=completed upgraded=$SYSTEM_UPDATE_UPGRADED new=$SYSTEM_UPDATE_NEW remaining=$remaining"
  ui_success "更新完成，软件包状态验证通过。"
  ui_kv "剩余候选" "$remaining 个（可能因 hold、分阶段更新或依赖限制保留）"
  if [[ -f /var/run/reboot-required ]]; then
    ui_check warn "系统要求重启；请自行安排维护窗口，本项目不会自动重启。"
  else
    ui_note "系统未提供重启标记；内核或库升级仍可能需要手动重启，可查看重启与内核状态。"
  fi
}

system_update_menu() {
  local choice held
  while true; do
    held="$(apt-mark showhold 2>/dev/null | awk 'NF {count++} END {print count+0}')"
    ui_page "系统更新" "当前发行版的补丁与软件包更新 · 按需执行"
    ui_panel_begin "更新范围"
    ui_panel_kv "系统" "${OS_NAME:-Debian / Ubuntu}"
    ui_panel_kv "本地候选" "$(package_upgradable_count) 个"
    ui_panel_kv "被保留" "$held 个"
    ui_panel_kv "索引时间" "$(system_package_index_age)"
    ui_panel_end
    ui_context "更新已安装的 APT 软件与所需依赖；不更新官方直装 CLI，也不迁移发行版。"
    ui_note "补丁由已配置来源提供；发行版停止安全支持后，普通更新不能替代迁移至受支持系统。"
    ui_section "更新与预览" "primary"
    ui_action 1 "刷新并更新系统" "warning" "完整索引检查、事务预览与二次确认"
    ui_action 2 "仅预览当前计划" "action" "不刷新索引、不修改系统"
    ui_action 3 "查看全部候选版本" "action" "已安装版本 → 候选版本"
    ui_section "维护与检查" "accent"
    ui_action 4 "管理 hold" "action" "保持或取消单个软件包的版本保留"
    ui_action 5 "查看 APT 来源" "action" "核实已配置仓库与发行版"
    ui_action 6 "重启与内核状态" "action" "只查看，不执行重启"
    ui_action 0 "返回" "muted"
    choice="$(read_input "请选择" "0")"
    case "$choice" in
      1) system_update_apply || true ;;
      2)
        if system_update_preflight && system_update_sources_check && system_update_simulate; then
          system_update_plan_render
          ui_note "只使用本地索引；实际更新前会重新刷新并生成计划。"
        fi
        ;;
      3) system_package_updates_view all ;;
      4) system_package_hold_manage || true ;;
      5) system_package_sources_view ;;
      6) system_reboot_status ;;
      0) return 0 ;;
      *) warn "未知选项：$choice"; continue ;;
    esac
    pause
  done
}
