#!/usr/bin/env bash

apps_service_package_version() {
  local app_id="$1" package_name
  package_name="$(apps_service_package "$app_id")" || return 1
  [[ -n "$package_name" ]] || return 1
  if (( APPS_SERVICE_CACHE_READY == 1 )); then
    printf '%s' "${APPS_PACKAGE_VERSION_CACHE[$package_name]:-}"
    return 0
  fi
  dpkg-query -W -f='${Version}' "$package_name" 2>/dev/null
}

apps_service_binary_version() {
  local app_id="$1" version=""
  case "$app_id" in
    docker)
      command_exists docker && version="$(runtime_with_timeout 2 docker --version 2>/dev/null | head -n 1 || true)"
      ;;
    nginx)
      command_exists nginx && version="$(runtime_with_timeout 2 nginx -v 2>&1 | head -n 1 || true)"
      ;;
    caddy)
      command_exists caddy && version="$(runtime_with_timeout 2 caddy version 2>/dev/null | head -n 1 || true)"
      ;;
    apache)
      command_exists apache2 && version="$(runtime_with_timeout 2 apache2 -v 2>/dev/null | head -n 1 || true)"
      ;;
    haproxy)
      command_exists haproxy && version="$(runtime_with_timeout 2 haproxy -v 2>/dev/null | head -n 1 || true)"
      ;;
    redis)
      command_exists redis-server && version="$(runtime_with_timeout 2 redis-server --version 2>/dev/null | head -n 1 || true)"
      ;;
    memcached)
      command_exists memcached && version="$(runtime_with_timeout 2 memcached -h 2>/dev/null | head -n 1 || true)"
      ;;
    postgresql)
      if command_exists psql; then version="$(runtime_with_timeout 2 psql --version 2>/dev/null | head -n 1 || true)"; fi
      ;;
    mariadb)
      if command_exists mariadb; then version="$(runtime_with_timeout 2 mariadb --version 2>/dev/null | head -n 1 || true)"; fi
      ;;
    mosquitto)
      command_exists mosquitto && version="$(runtime_with_timeout 2 mosquitto -h 2>&1 | head -n 1 || true)"
      ;;
  esac
  [[ -n "$version" ]] || return 1
  terminal_safe_text "$version"
}

apps_service_version() {
  local app_id="$1" package_version binary_version
  package_version="$(apps_service_package_version "$app_id" 2>/dev/null || true)"
  if [[ -n "$package_version" ]]; then
    printf '%s' "$package_version"
    return 0
  fi
  binary_version="$(apps_service_binary_version "$app_id" 2>/dev/null || true)"
  if [[ -n "$binary_version" ]]; then
    printf '%s' "$binary_version"
  else
    printf '未知'
  fi
}

apps_service_pids() {
  local service="$1" control_group pid_file pid snapshot
  valid_service_name "$service" || return 1
  snapshot="$(unit_properties_snapshot "$service" ControlGroup MainPID || true)"
  control_group="$(unit_snapshot_value "$snapshot" ControlGroup 2>/dev/null || true)"
  if [[ -n "$control_group" && "$control_group" == /* && "$control_group" != *'/../'* &&
    -d "/sys/fs/cgroup$control_group" ]]; then
    while IFS= read -r pid_file; do
      while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] && printf '%s\n' "$pid"
      done <"$pid_file"
    done < <(find "/sys/fs/cgroup$control_group" -type f -name cgroup.procs -print 2>/dev/null)
  else
    pid="$(unit_snapshot_value "$snapshot" MainPID 2>/dev/null || true)"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] && printf '%s\n' "$pid"
  fi
}

apps_service_listener_rows() {
  local service="$1" line pid matched
  local pids=()
  command_exists ss || return 1
  mapfile -t pids < <(apps_service_pids "$service" | sort -nu)
  ((${#pids[@]} > 0)) || return 0
  while IFS= read -r line; do
    matched=0
    for pid in "${pids[@]}"; do
      if [[ "$line" == *"pid=$pid,"* || "$line" == *"pid=$pid)"* ]]; then
        matched=1
        break
      fi
    done
    if (( matched == 1 )); then
      printf '%s\n' "$(terminal_safe_text "$line")"
    fi
  done < <(ss -H -lntup 2>/dev/null || true)
}

apps_service_listener_count() {
  apps_service_listener_rows "$1" | grep -c . || true
}

apps_service_existing_path_count() {
  local app_id="$1" path count=0
  while IFS= read -r path; do
    [[ -e "$path" || -L "$path" ]] && count=$((count + 1))
  done < <(apps_service_config_paths "$app_id")
  printf '%s' "$count"
}

apps_service_data_existing_count() {
  local app_id="$1" path count=0
  while IFS= read -r path; do
    [[ -e "$path" || -L "$path" ]] && count=$((count + 1))
  done < <(apps_service_data_paths "$app_id")
  printf '%s' "$count"
}

apps_service_configuration_view() {
  local app_id="$1" label path file found=0 listed=0
  label="$(apps_service_label "$app_id")"
  ui_page "$label / 配置资产" "只读展示声明路径和最多两层配置文件"
  while IFS= read -r path; do
    if [[ -f "$path" || -L "$path" ]]; then
      found=$((found + 1))
      ui_status "$path" "文件" "neutral"
    elif [[ -d "$path" && ! -L "$path" ]]; then
      found=$((found + 1))
      ui_status "$path" "目录" "neutral"
      while IFS= read -r -d '' file; do
        (( listed >= 80 )) && break
        printf '    %b◇%b %s\n' "$MUTED" "$NC" "$(terminal_safe_text "$file")"
        listed=$((listed + 1))
      done < <(find "$path" -maxdepth 2 -type f -print0 2>/dev/null | sort -z)
    else
      ui_status "$path" "不存在" "muted"
    fi
  done < <(apps_service_config_paths "$app_id")
  (( found > 0 )) || ui_empty "没有找到已声明的配置路径"
  (( listed < 80 )) || ui_hint "配置文件较多，仅显示前 80 项。"
  ui_note "页面不会显示配置内容，避免在终端中暴露密码、令牌或证书私钥。"
}

apps_service_data_view() {
  local app_id="$1" label path found=0 size
  label="$(apps_service_label "$app_id")"
  ui_page "$label / 数据资产" "手动计算固定数据路径占用，不扫描其他目录"
  ui_note "目录较大时 du 会产生短时磁盘 IO；本操作只在打开此页面时执行一次。"
  while IFS= read -r path; do
    if [[ -e "$path" || -L "$path" ]]; then
      found=$((found + 1))
      size="$(du -shx "$path" 2>/dev/null | awk '{print $1}' || printf '未知')"
      ui_kv "$path" "$size"
    else
      ui_status "$path" "不存在" "muted"
    fi
  done < <(apps_service_data_paths "$app_id")
  (( found > 0 )) || ui_empty "没有找到已声明的数据路径"
  ui_note "数据目录属于对应应用；keine 不提供猜测性删除。"
}

apps_service_listeners_view() {
  local app_id="$1" service label rows
  service="$(apps_service_unit "$app_id")"
  label="$(apps_service_label "$app_id")"
  rows="$(apps_service_listener_rows "$service")"
  ui_page "$label / 监听端口" "根据 systemd cgroup 进程关联本机 TCP/UDP 监听"
  if [[ -n "$rows" ]]; then
    printf '%s\n' "$rows"
  else
    ui_empty "没有关联到监听端口"
  fi
  ui_note "容器端口和由其他 Unit 托管的子实例可能需要在 Docker 或服务中心继续查看。"
}
