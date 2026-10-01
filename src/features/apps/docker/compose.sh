#!/usr/bin/env bash

docker_compose_projects() {
  docker_require || return 1
  ui_page "Compose 项目" "Docker Compose 项目、配置文件与运行状态"
  if runtime_with_timeout 5 docker compose version >/dev/null 2>&1; then
    runtime_with_timeout 5 docker compose ls --all || warn "Compose 项目查询失败或超时。"
  else
    ui_empty "未安装 Docker Compose 插件"
  fi
}

docker_compose_project_valid() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$ ]]
}

docker_container_ref_valid() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$ ]]
}

docker_compose_context() {
  local project="$1" container workdir config_files file old_ifs
  local files=()
  docker_compose_project_valid "$project" || return 1
  container="$(runtime_with_timeout 5 docker ps -aq --filter "label=com.docker.compose.project=$project" 2>/dev/null | head -n 1)"
  [[ -n "$container" ]] || return 1
  workdir="$(runtime_with_timeout 5 docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$container" 2>/dev/null || true)"
  config_files="$(runtime_with_timeout 5 docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$container" 2>/dev/null || true)"
  [[ "$workdir" == /* && "$workdir" != *'/../'* && "$workdir" != */.. ]] || return 1
  [[ -n "$config_files" ]] || return 1
  printf '%s\n' "$workdir"
  old_ifs="$IFS"
  IFS=',' read -r -a files <<<"$config_files"
  IFS="$old_ifs"
  for file in "${files[@]}"; do
    file="${file#"${file%%[![:space:]]*}"}"
    file="${file%"${file##*[![:space:]]}"}"
    [[ "$file" == /* ]] || file="$workdir/$file"
    [[ "$file" == /* && "$file" != *'/../'* && "$file" != */.. ]] || return 1
    [[ -f "$file" ]] || return 1
    printf '%s\n' "$file"
  done
}

docker_compose_manage() {
  docker_require || return 1
  runtime_with_timeout 5 docker compose version >/dev/null 2>&1 || { warn "未安装 Docker Compose 插件，或查询超时。"; return 1; }
  local project="${1:-}" action total=0 running=0 index config_count refresh=1 states state
  local context=() compose=()
  if [[ -z "$project" ]]; then
    docker_compose_projects
    ui_menu_footer "返回"
    ui_read_choice project "项目名称"
  fi
  [[ "$project" == "0" ]] && return 0
  docker_compose_project_valid "$project" || { warn "Compose 项目名称格式无效。"; return 1; }
  mapfile -t context < <(docker_compose_context "$project")
  ((${#context[@]} >= 2)) || {
    warn "无法从容器标签解析 $project 的工作目录和 Compose 配置。"
    return 1
  }
  compose=(compose --project-name "$project" --project-directory "${context[0]}")
  for ((index = 1; index < ${#context[@]}; index++)); do
    compose+=(-f "${context[$index]}")
  done
  config_count=$((${#context[@]} - 1))
  while true; do
    if (( refresh == 1 )); then
      states="$(runtime_with_timeout 5 docker ps -a --filter "label=com.docker.compose.project=$project" --format '{{.State}}' 2>/dev/null)" || {
        warn "Compose 容器状态查询失败或超时。"; return 1;
      }
      total=0; running=0
      while IFS= read -r state; do
        [[ -n "$state" ]] || continue
        total=$((total + 1))
        [[ "$state" != running ]] || running=$((running + 1))
      done <<<"$states"
      refresh=0
    fi
    ui_page "Compose / $project"
    ui_panel_begin "项目上下文"
    ui_panel_kv "项目" "$project"
    ui_panel_kv "工作目录" "${context[0]}"
    ui_panel_kv "配置文件" "$config_count 个"
    ui_panel_kv "容器" "$running 运行 / $total 总计"
    ui_panel_end
    ui_section "配置来源" "primary"
    for ((index = 1; index < ${#context[@]}; index++)); do
      printf '  %b•%b %s\n' "$CYAN" "$NC" "${context[$index]}"
    done
    ui_section "查看" "primary"
    ui_action_pair 1 "查看服务状态" "action" 2 "查看项目日志" "action"
    ui_action 3 "查看服务与镜像" "action"
    ui_section "项目生命周期" "accent"
    ui_action_pair 4 "拉取镜像" "action" 5 "创建或更新并启动" "success"
    ui_action_pair 6 "停止并保留容器" "danger" 7 "重启项目服务" "warning"
    ui_action 8 "移除项目运行资源" "danger" "保留存储卷和镜像"
    ui_action R "刷新项目状态" "accent"
    ui_menu_footer "返回"
    ui_read_choice action
    case "$action" in
      1)
        ui_page "Compose / $project / 状态" "当前服务、容器与端口"
        runtime_with_timeout 5 docker "${compose[@]}" ps || warn "服务状态查询失败或超时。"
        pause
        ;;
      2) runtime_with_timeout 5 docker "${compose[@]}" logs --tail 200 2>&1 || warn "日志读取失败或超时。"; pause ;;
      3)
        ui_page "Compose / $project / 配置" "声明的服务与镜像"
        ui_section "服务" "primary"
        runtime_with_timeout 5 docker "${compose[@]}" config --services || warn "服务配置读取失败或超时。"
        ui_section "镜像" "accent"
        runtime_with_timeout 5 docker "${compose[@]}" config --images || warn "镜像配置读取失败或超时。"
        pause
        ;;
      4)
        confirm "拉取 $project 的最新镜像？" || continue
        require_root
        run docker "${compose[@]}" pull || { warn "Compose 镜像拉取失败。"; pause; continue; }
        audit "action=compose-pull project=$project"
        ui_success "Compose 镜像拉取完成"
        pause
        ;;
      5)
        confirm "创建或更新并启动 $project？" || continue
        require_root
        refresh=1
        run docker "${compose[@]}" up -d || { warn "Compose 项目启动失败。"; pause; continue; }
        audit "action=compose-up project=$project"
        ui_success "Compose 项目已经应用"
        pause
        ;;
      6)
        confirm "停止 $project 的全部服务并保留容器？" || continue
        require_root
        refresh=1
        run docker "${compose[@]}" stop || { warn "Compose 项目停止失败。"; pause; continue; }
        audit "action=compose-stop project=$project"
        ui_success "Compose 项目已停止"
        pause
        ;;
      7)
        confirm "重启 $project 的全部服务？" || continue
        require_root
        refresh=1
        run docker "${compose[@]}" restart || { warn "Compose 项目重启失败。"; pause; continue; }
        audit "action=compose-restart project=$project"
        ui_success "Compose 项目已重启"
        pause
        ;;
      8)
        ui_danger "将删除项目容器和默认网络，但明确保留存储卷与镜像。"
        confirm "确认执行 docker compose down？" || continue
        require_root
        refresh=1
        run docker "${compose[@]}" down || { warn "Compose 项目移除失败。"; pause; continue; }
        audit "action=compose-down project=$project volumes=false images=false"
        ui_success "Compose 项目运行资源已移除"
        pause
        ;;
      0) return 0 ;;
      R|r) refresh=1 ;;
      *) warn "未知选项" ;;
    esac
  done
}
