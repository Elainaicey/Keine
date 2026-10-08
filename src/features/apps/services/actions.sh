#!/usr/bin/env bash

apps_service_config_validate() {
  local app_id="$1" label config
  label="$(apps_service_label "$app_id")"
  ui_page "$label / 配置检查" "调用应用官方只读检查命令，不重新加载服务"
  case "$app_id" in
    nginx)
      command_exists nginx || { warn "没有找到 nginx 命令。"; return 1; }
      config="$(web_engine_config nginx)" || return 1
      nginx -t -c "$config" || { warn "Nginx 配置检查失败。"; return 1; }
      ;;
    caddy)
      command_exists caddy || { warn "没有找到 caddy 命令。"; return 1; }
      config="$(web_engine_config caddy)" || return 1
      [[ -f "$config" ]] || { warn "没有找到 Caddyfile：$config"; return 1; }
      caddy validate --config "$config" || { warn "Caddy 配置检查失败。"; return 1; }
      ;;
    apache)
      command_exists apache2ctl || { warn "没有找到 apache2ctl 命令。"; return 1; }
      apache2ctl configtest || { warn "Apache 配置检查失败。"; return 1; }
      ;;
    haproxy)
      command_exists haproxy || { warn "没有找到 haproxy 命令。"; return 1; }
      config=/etc/haproxy/haproxy.cfg
      [[ -f "$config" ]] || { warn "没有找到 HAProxy 配置：$config"; return 1; }
      haproxy -c -f "$config" || { warn "HAProxy 配置检查失败。"; return 1; }
      ;;
    docker)
      command_exists dockerd || { warn "没有找到 dockerd 命令。"; return 1; }
      config=/etc/docker/daemon.json
      [[ -f "$config" ]] || { ui_note "没有 daemon.json；Docker 使用内置默认配置。"; return 0; }
      dockerd --validate --config-file "$config" || { warn "Docker daemon.json 检查失败。"; return 1; }
      ;;
    *)
      warn "$label 当前没有安全、无副作用的官方配置检查命令。"
      return 1
      ;;
  esac
  ui_success "$label 配置检查通过"
}

apps_service_lifecycle_action() {
  local app_id="$1" verb="$2" service
  case "$verb" in start|stop|restart|enable|disable) ;; *) warn "不支持的应用生命周期操作：$verb"; return 1 ;; esac
  service="$(apps_service_unit "$app_id")" || { warn "未知应用：$app_id"; return 1; }
  service_exists "$service" || { warn "应用服务未安装：$service"; return 1; }
  local result=0
  services_apply_action "$service" "$verb" || result=$?
  apps_service_cache_invalidate
  return "$result"
}

apps_service_reload() {
  local app_id="$1" label service state can_reload exec_reload snapshot
  apps_service_reload_supported "$app_id" || { warn "该应用未声明安全 reload 流程。"; return 1; }
  label="$(apps_service_label "$app_id")"
  service="$(apps_service_unit "$app_id")"
  state="$(service_state "$service")"
  [[ "$state" == "active" ]] || { warn "$label 当前未运行，不能 reload。"; return 1; }
  snapshot="$(unit_properties_snapshot "$service" CanReload ExecReload || true)"
  can_reload="$(unit_snapshot_value "$snapshot" CanReload 2>/dev/null || true)"
  exec_reload="$(unit_snapshot_value "$snapshot" ExecReload 2>/dev/null || true)"
  if [[ "$can_reload" != "yes" && -z "$exec_reload" ]]; then
    warn "$service 没有声明 systemd reload 能力。"
    return 1
  fi
  apps_service_config_validate "$app_id" || {
    warn "配置检查失败，已阻止 reload。"
    return 1
  }
  ui_page "$label / 安全重新加载" "配置已通过检查；reload 不主动终止现有服务进程"
  confirm "重新加载 $label 配置？" || return 0
  require_root
  apps_service_cache_invalidate
  run systemctl reload "$service" || { warn "$label reload 失败。"; return 1; }
  if [[ "$DRY_RUN" -eq 0 ]]; then
    systemctl is-active --quiet "$service" || { warn "reload 后 $label 未保持运行。"; return 1; }
  fi
  audit "action=app-reload app=$app_id service=$service"
  ui_success "$label 配置已重新加载"
}
