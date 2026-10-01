#!/usr/bin/env bash

docker_require() { command_exists docker || { warn "Docker 未安装，可在软件管理中搜索 docker。"; return 1; }; }

docker_daemon_ready() {
  runtime_with_timeout 5 docker info >/dev/null 2>&1
}

docker_query() {
  LC_ALL=C runtime_with_timeout 5 docker "$@" || { warn "Docker 只读查询失败或超时；请检查 Daemon 与连接地址。"; return 1; }
}

docker_overview() {
  docker_require || return 1
  ui_page "Docker 概览" "Engine、运行中容器和磁盘占用"
  docker_query version --format 'Engine: {{.Server.Version}}' 2>/dev/null || { warn "无法连接 Docker Daemon。"; return 1; }
  printf '\n容器：\n'; docker_query ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' || return 1
  printf '\n磁盘占用：\n'; docker_query system df || return 1
}

docker_containers() {
  docker_require || return 1
  ui_page "全部容器" "名称、镜像、状态和端口映射"
  docker_query ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
}

docker_images() {
  docker_require || return 1
  ui_page "Docker 镜像" "仓库、标签、镜像 ID、大小和创建时间"
  docker_query images --format 'table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}'
}

docker_resources() {
  docker_require || return 1
  ui_page "容器资源" "单次采样 CPU、内存、网络和块设备 IO"
  runtime_with_timeout 8 docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}' 2>/dev/null || { warn "无法读取容器资源或采样超时。"; return 1; }
}

docker_health() {
  docker_require || return 1
  ui_page "Docker 健康检查" "Daemon、容器运行状态、健康检查与异常退出"
  if ! docker_daemon_ready; then
    ui_check fail "无法连接 Docker Daemon"
    ui_note "请检查 docker.service 状态或当前用户的 Docker Socket 权限。"
    return 1
  fi
  local total=0 running=0 unhealthy=0 restarting=0 exited=0 rows state status name image
  local attention=()
  rows="$(docker_query ps -a --format '{{.State}}|{{.Status}}|{{.Names}}|{{.Image}}')" || return 1
  while IFS='|' read -r state status name image; do
    [[ -n "$state" ]] || continue
    total=$((total + 1))
    case "$state" in
      running) running=$((running + 1)) ;;
      restarting) restarting=$((restarting + 1)) ;;
      exited) exited=$((exited + 1)) ;;
    esac
    [[ "$status" != *'(unhealthy)'* ]] || unhealthy=$((unhealthy + 1))
    if [[ "$state" == restarting || "$state" == exited || "$status" == *'(unhealthy)'* ]]; then
      attention+=("$name · $image · $status")
    fi
  done <<<"$rows"
  ui_stats "容器" "$total" "运行" "$running" "异常" "$((unhealthy + restarting))"
  ui_check pass "Docker Daemon 可用"
  if (( unhealthy > 0 )); then ui_check fail "$unhealthy 个容器健康检查失败"; else ui_check pass "没有 unhealthy 容器"; fi
  if (( restarting > 0 )); then ui_check warn "$restarting 个容器正在反复重启"; else ui_check pass "没有反复重启的容器"; fi
  if (( exited > 0 )); then ui_check warn "$exited 个容器处于退出状态"; else ui_check pass "没有已退出容器"; fi
  if (( unhealthy + restarting + exited > 0 )); then
    ui_section "需要关注的容器" "accent"
    for name in "${attention[@]}"; do printf '  %s\n' "$(terminal_safe_text "$name")"; done
  fi
}

docker_storage() {
  docker_require || return 1
  ui_page "Docker 存储与网络" "存储卷、虚拟网络与磁盘占用"
  ui_section "存储卷"
  docker_query volume ls || return 1
  ui_section "网络"
  docker_query network ls || return 1
  ui_section "磁盘占用"
  docker_query system df || return 1
  ui_note "未挂载卷不等于无用数据；清理功能不会自动删除任何存储卷。"
}
