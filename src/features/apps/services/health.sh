#!/usr/bin/env bash

APP_HEALTH_PASS=0
APP_HEALTH_WARN=0
APP_HEALTH_FAIL=0

apps_service_runtime_check() {
  local app_id="$1" output
  case "$app_id" in
    docker)
      command_exists docker && runtime_with_timeout 5 docker info >/dev/null 2>&1
      ;;
    nginx)
      command_exists nginx && nginx -t >/dev/null 2>&1
      ;;
    caddy)
      command_exists caddy && [[ -f /etc/caddy/Caddyfile ]] &&
        caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1
      ;;
    apache)
      command_exists apache2ctl && apache2ctl configtest >/dev/null 2>&1
      ;;
    haproxy)
      command_exists haproxy && [[ -f /etc/haproxy/haproxy.cfg ]] &&
        haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1
      ;;
    redis)
      command_exists redis-cli || return 2
      output="$(runtime_with_timeout 4 redis-cli -h 127.0.0.1 ping 2>/dev/null || true)"
      [[ "$output" == "PONG" || "$output" == *"NOAUTH"* ]]
      ;;
    postgresql)
      command_exists pg_isready || return 2
      pg_isready -q -t 3
      ;;
    mariadb)
      command_exists mariadb-admin || return 2
      runtime_with_timeout 4 mariadb-admin --protocol=socket --silent ping >/dev/null 2>&1
      ;;
    *) return 2 ;;
  esac
}

apps_service_health_result() {
  local state="$1" message="$2" hint="${3:-}"
  case "$state" in
    pass) APP_HEALTH_PASS=$((APP_HEALTH_PASS + 1)) ;;
    warn) APP_HEALTH_WARN=$((APP_HEALTH_WARN + 1)) ;;
    fail) APP_HEALTH_FAIL=$((APP_HEALTH_FAIL + 1)) ;;
    *) return 1 ;;
  esac
  ui_check "$state" "$message"
  [[ -z "$hint" ]] || ui_hint "$hint"
}

apps_service_health() {
  local app_id="$1" label service state enabled listeners recent_errors runtime_status
  local restarts result exit_status started memory tasks cpu_time snapshot
  APP_HEALTH_PASS=0
  APP_HEALTH_WARN=0
  APP_HEALTH_FAIL=0
  label="$(apps_service_label "$app_id")"
  service="$(apps_service_unit "$app_id")"
  state="$(service_state "$service")"
  enabled="$(systemctl is-enabled "$service" 2>/dev/null || true)"
  enabled="${enabled:-disabled}"
  listeners="$(apps_service_listener_count "$service")"
  recent_errors="$(journalctl --quiet -u "$service" --since "-1 hour" -p err --no-pager 2>/dev/null | grep -c . || true)"
  snapshot="$(unit_properties_snapshot "$service" NRestarts Result ExecMainStatus \
    ActiveEnterTimestamp MemoryCurrent TasksCurrent CPUUsageNSec || true)"
  restarts="$(unit_snapshot_value "$snapshot" NRestarts 2>/dev/null || true)"
  result="$(unit_snapshot_value "$snapshot" Result 2>/dev/null || true)"
  exit_status="$(unit_snapshot_value "$snapshot" ExecMainStatus 2>/dev/null || true)"
  started="$(unit_snapshot_value "$snapshot" ActiveEnterTimestamp 2>/dev/null || true)"
  memory="$(unit_snapshot_value "$snapshot" MemoryCurrent 2>/dev/null || true)"
  tasks="$(unit_snapshot_value "$snapshot" TasksCurrent 2>/dev/null || true)"
  cpu_time="$(unit_snapshot_value "$snapshot" CPUUsageNSec 2>/dev/null || true)"

  ui_page "$label / 运行健康" "服务、应用响应、资源、监听与最近错误的一次性诊断"
  ui_context "$service · 开机 $enabled · ${started:-尚未进入 active}"
  ui_section "检查结果" "primary"
  if [[ "$state" == "active" ]]; then
    apps_service_health_result pass "systemd 服务处于 active"
  else
    apps_service_health_result fail "systemd 服务状态为 $state" "可在应用详情直接启动或进入完整 systemd 诊断。"
  fi
  if apps_service_runtime_check "$app_id"; then
    runtime_status=0
    apps_service_health_result pass "应用级只读检查通过"
  else
    runtime_status=$?
    if [[ "$runtime_status" -eq 2 ]]; then
      apps_service_health_result warn "该应用没有可安全执行的无认证响应检查"
    else
      apps_service_health_result fail "应用级只读检查失败" "服务 active 不代表配置或本地响应一定正常。"
    fi
  fi
  if [[ "$listeners" =~ ^[0-9]+$ ]] && (( listeners > 0 )); then
    apps_service_health_result pass "关联到 $listeners 个监听套接字"
  else
    apps_service_health_result warn "没有通过 systemd cgroup 关联到监听套接字"
  fi
  if [[ "$recent_errors" =~ ^[0-9]+$ ]] && (( recent_errors >= 20 )); then
    apps_service_health_result fail "最近 1 小时有 $recent_errors 条 err 级日志"
  elif [[ "$recent_errors" =~ ^[0-9]+$ ]] && (( recent_errors > 0 )); then
    apps_service_health_result warn "最近 1 小时有 $recent_errors 条 err 级日志"
  else
    apps_service_health_result pass "最近 1 小时没有 err 级日志"
  fi
  if [[ "$restarts" =~ ^[0-9]+$ ]] && (( restarts >= 5 )); then
    apps_service_health_result warn "当前激活周期已自动重启 $restarts 次" "频繁重启通常需要结合 Result 与 Journal 继续定位。"
  else
    apps_service_health_result pass "自动重启次数：${restarts:-0}"
  fi
  if [[ -n "$result" && "$result" != "success" && "$result" != "done" ]]; then
    apps_service_health_result warn "最近执行结果：$result · 退出状态 ${exit_status:-—}"
  fi

  ui_section "当前资源" "accent"
  ui_metric_row \
    "内存" "$(services_format_bytes "$memory")" "primary" \
    "任务" "${tasks:-—}" "primary" \
    "累计 CPU" "$(services_format_cpu_time "$cpu_time")" "primary"

  ui_section "诊断结论" "primary"
  ui_health_summary "$APP_HEALTH_PASS" "$APP_HEALTH_WARN" "$APP_HEALTH_FAIL"
  if (( APP_HEALTH_FAIL > 0 )); then
    ui_callout "bad" "$label 检测到 $APP_HEALTH_FAIL 项异常" "建议先查看最近日志和失败诊断，再决定是否重启。"
  elif (( APP_HEALTH_WARN > 0 )); then
    ui_callout "warn" "$label 有 $APP_HEALTH_WARN 项需要核实" "返回应用详情可继续查看端口、配置、日志和服务状态。"
  else
    ui_callout "good" "$label 当前检查项正常" "这是一次性快照，不会持续采样或创建后台监控。"
  fi
  ui_note "检查只在打开页面时运行一次，不会自动修复、重启或创建定时任务。"
}
