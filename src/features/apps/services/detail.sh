#!/usr/bin/env bash

apps_service_detail() {
  local app_id="$1" label service action state enabled version main_pid restarts state_color
  local catalog_id catalog_record_data="" candidate="" software_state="" memory tasks cpu_time started result snapshot
  local lifecycle_verb lifecycle_label lifecycle_style boot_verb boot_label boot_style
  local version_generation=-1
  label="$(apps_service_label "$app_id")" || return 1
  service="$(apps_service_unit "$app_id")"
  catalog_id="$(apps_service_catalog_id "$app_id")"
  if [[ -n "$catalog_id" ]]; then catalog_record_data="$(catalog_record "$catalog_id" 2>/dev/null || true)"; fi
  apps_service_cache_build
  if (( APPS_SERVICE_CACHE_ERROR == 1 )); then warn "无法读取应用服务快照，请稍后 R 重试。"; return 1; fi
  apps_service_cached_exists "$service" || { warn "没有找到应用服务：$service"; return 1; }
  while true; do
    apps_service_cache_build
    state="$(apps_service_cached_state "$service")"
    enabled="$(apps_service_cached_enabled "$service")"
    if (( version_generation != APPS_SERVICE_CACHE_GENERATION )); then
      version="$(apps_service_version "$app_id")"
      if [[ -n "$catalog_record_data" ]]; then
        candidate="$(catalog_candidate_version "$catalog_record_data")"
        software_state="$(catalog_state "$catalog_record_data" "$candidate")"
      fi
      version_generation="$APPS_SERVICE_CACHE_GENERATION"
    fi
    snapshot="${APPS_SERVICE_SNAPSHOT_CACHE[$service]:-}"
    main_pid="$(unit_snapshot_value "$snapshot" MainPID 2>/dev/null || true)"
    restarts="$(unit_snapshot_value "$snapshot" NRestarts 2>/dev/null || true)"
    memory="$(unit_snapshot_value "$snapshot" MemoryCurrent 2>/dev/null || true)"
    tasks="$(unit_snapshot_value "$snapshot" TasksCurrent 2>/dev/null || true)"
    cpu_time="$(unit_snapshot_value "$snapshot" CPUUsageNSec 2>/dev/null || true)"
    started="$(unit_snapshot_value "$snapshot" ActiveEnterTimestamp 2>/dev/null || true)"
    result="$(unit_snapshot_value "$snapshot" Result 2>/dev/null || true)"
    case "$state" in active) state_color="$GREEN" ;; failed) state_color="$RED" ;; *) state_color="$YELLOW" ;; esac
    if [[ "$state" == "active" ]]; then
      lifecycle_verb="stop"; lifecycle_label="停止服务"; lifecycle_style="danger"
    else
      lifecycle_verb="start"; lifecycle_label="启动服务"; lifecycle_style="success"
    fi
    case "$enabled" in
      enabled|enabled-runtime)
        boot_verb="disable"; boot_label="禁用开机启动"; boot_style="warning"
        ;;
      disabled)
        boot_verb="enable"; boot_label="启用开机启动"; boot_style="success"
        ;;
      *)
        boot_verb=""; boot_label="开机策略不可切换"; boot_style="disabled"
        ;;
    esac

    ui_page "应用 / $label"
    if (( APPS_SERVICE_CACHE_ERROR == 1 )); then ui_callout warn "服务快照读取不完整" "R 重试；没有读取的属性不代表实际为零或未安装。"; fi
    ui_panel_begin "运行信息"
    ui_panel_kv "状态" "● $state" "$state_color"
    ui_panel_kv "版本" "$version"
    ui_panel_kv "服务" "$service"
    ui_panel_kv "开机启动" "$enabled"
    ui_panel_kv "主进程 PID" "${main_pid:-—}"
    ui_panel_kv "重启次数" "${restarts:-—}"
    ui_panel_kv "进入状态时间" "${started:-—}"
    ui_panel_kv "最近结果" "${result:-—}"
    if [[ -n "$catalog_record_data" ]]; then
      ui_panel_kv "软件候选版本" "$candidate"
      ui_panel_kv "软件安装状态" "$(catalog_state_badge "$software_state")"
    fi
    ui_panel_end
    ui_metric_row \
      "内存" "$(services_format_bytes "$memory")" "primary" \
      "任务" "${tasks:-—}" "primary" \
      "累计 CPU" "$(services_format_cpu_time "$cpu_time")" "primary"

    ui_section "观察与诊断" "primary"
    ui_action_pair 1 "运行健康" "action" 2 "监听端口" "action"
    ui_action_pair 3 "配置资产" "action" 4 "数据与占用" "warning"
    ui_action 5 "最近日志" "action"

    ui_section "配置" "accent"
    if apps_service_config_validation_supported "$app_id"; then
      ui_action 6 "检查配置" "action"
    else
      ui_action 6 "检查配置" "disabled" "不支持"
    fi
    if apps_service_reload_supported "$app_id"; then
      ui_action 7 "检查并 reload" "warning"
    else
      ui_action 7 "检查并 reload" "disabled" "不支持"
    fi

    ui_section "生命周期" "primary"
    ui_action_pair 8 "$lifecycle_label" "$lifecycle_style" 9 "重启服务" "$([[ "$state" == "active" ]] && printf 'warning' || printf 'disabled')"
    ui_action_pair 10 "$boot_label" "$boot_style" 11 "完整 systemd 管理" "action"
    if [[ -n "$catalog_id" ]]; then
      ui_action 12 "软件版本与更新" "action"
    else
      ui_action 12 "软件版本与更新" "disabled" "未关联"
    fi
    if [[ "$app_id" == "docker" ]]; then ui_action 13 "Docker 专属中心" "action"; fi
    if [[ "$app_id" == nginx || "$app_id" == caddy ]]; then
      ui_action 14 "反向代理管理" "action"
      ui_action 15 "HTTPS / 证书中心" "action"
    fi
    ui_action R "刷新运行信息" "accent"
    ui_menu_footer "返回"
    ui_read_choice action
    case "$action" in
      1) apps_service_health "$app_id" ;;
      2) apps_service_listeners_view "$app_id" ;;
      3) apps_service_configuration_view "$app_id" ;;
      4) apps_service_data_view "$app_id" ;;
      5) services_logs "$service" ;;
      6)
        if apps_service_config_validation_supported "$app_id"; then apps_service_config_validate "$app_id" || true
        else warn "该应用没有可用的配置检查。"; fi
        ;;
      7)
        if apps_service_reload_supported "$app_id"; then apps_service_reload "$app_id" || true
        else warn "该应用没有安全 reload 流程。"; fi
        ;;
      8) apps_service_lifecycle_action "$app_id" "$lifecycle_verb" || true; continue ;;
      9)
        if [[ "$state" == "active" ]]; then apps_service_lifecycle_action "$app_id" restart || true
        else warn "$label 当前未运行，请先启动服务。"; fi
        continue
        ;;
      10)
        if [[ -n "$boot_verb" ]]; then apps_service_lifecycle_action "$app_id" "$boot_verb" || true
        else warn "$service 的开机策略为 $enabled，不能通过通用流程切换。"; fi
        continue
        ;;
      11) services_select "$service"; apps_service_cache_invalidate; continue ;;
      12)
        if [[ -n "$catalog_id" ]]; then catalog_item_menu "$catalog_id"
        else warn "该应用没有可验证的软件目录来源。"; fi
        apps_service_cache_invalidate
        continue
        ;;
      13) if [[ "$app_id" == "docker" ]]; then docker_menu; else warn "未知选项"; fi; continue ;;
      14) if [[ "$app_id" == nginx || "$app_id" == caddy ]]; then web_engine_menu "$app_id"; else warn "未知选项"; fi; continue ;;
      15) if [[ "$app_id" == nginx || "$app_id" == caddy ]]; then security_certificates_menu; else warn "未知选项"; fi; continue ;;
      R|r) catalog_cache_invalidate; continue ;;
      0) return 0 ;;
      *) warn "未知选项：$action"; continue ;;
    esac
    pause
  done
}
