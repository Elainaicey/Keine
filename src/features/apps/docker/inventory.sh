#!/usr/bin/env bash

docker_require() { command_exists docker || { warn "Docker 未安装，可在软件管理中搜索 docker。"; return 1; }; }

docker_daemon_ready() {
  runtime_with_timeout 5 docker info >/dev/null 2>&1
}

docker_overview() {
  docker_require || return 1
  ui_page "Docker 概览" "Engine、运行中容器和磁盘占用"
  docker version --format 'Engine: {{.Server.Version}}' 2>/dev/null || docker --version
  printf '\n容器：\n'; docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
  printf '\n磁盘占用：\n'; docker system df 2>/dev/null || true
}

docker_containers() {
  docker_require || return 1
  ui_page "全部容器" "名称、镜像、状态和端口映射"
  docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
}

docker_images() {
  docker_require || return 1
  ui_page "Docker 镜像" "仓库、标签、镜像 ID、大小和创建时间"
  docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}'
}

docker_resources() {
  docker_require || return 1
  ui_page "容器资源" "单次采样 CPU、内存、网络和块设备 IO"
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}' 2>/dev/null || warn "无法读取容器资源。"
}

docker_health() {
  docker_require || return 1
  ui_page "Docker 健康检查" "Daemon、容器运行状态、健康检查与异常退出"
  if ! docker_daemon_ready; then
    ui_check fail "无法连接 Docker Daemon"
    ui_note "请检查 docker.service 状态或当前用户的 Docker Socket 权限。"
    return 1
  fi
  local total running unhealthy restarting exited
  total="$(docker ps -aq 2>/dev/null | grep -c . || true)"
  running="$(docker ps -q 2>/dev/null | grep -c . || true)"
  unhealthy="$(docker ps -aq --filter health=unhealthy 2>/dev/null | grep -c . || true)"
  restarting="$(docker ps -aq --filter status=restarting 2>/dev/null | grep -c . || true)"
  exited="$(docker ps -aq --filter status=exited 2>/dev/null | grep -c . || true)"
  ui_stats "容器" "$total" "运行" "$running" "异常" "$((unhealthy + restarting))"
  ui_check pass "Docker Daemon 可用"
  if (( unhealthy > 0 )); then ui_check fail "$unhealthy 个容器健康检查失败"; else ui_check pass "没有 unhealthy 容器"; fi
  if (( restarting > 0 )); then ui_check warn "$restarting 个容器正在反复重启"; else ui_check pass "没有反复重启的容器"; fi
  if (( exited > 0 )); then ui_check warn "$exited 个容器处于退出状态"; else ui_check pass "没有已退出容器"; fi
  if (( unhealthy + restarting + exited > 0 )); then
    ui_section "需要关注的容器" "accent"
    printf '  %-24s %-30s %s\n' "名称" "镜像" "状态"
    {
      docker ps -a --filter health=unhealthy --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null
      docker ps -a --filter status=restarting --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null
      docker ps -a --filter status=exited --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null
    } | sort -u | awk -F '|' '{printf "  %-24s %-30s %s\n",$1,$2,$3}'
  fi
}

docker_storage() {
  docker_require || return 1
  ui_page "Docker 存储与网络" "存储卷、虚拟网络与磁盘占用"
  local volumes dangling networks
  volumes="$(docker volume ls -q 2>/dev/null | grep -c . || true)"
  dangling="$(docker volume ls -qf dangling=true 2>/dev/null | grep -c . || true)"
  networks="$(docker network ls -q 2>/dev/null | grep -c . || true)"
  ui_stats "存储卷" "$volumes" "未挂载" "$dangling" "网络" "$networks"
  ui_section "存储卷"
  docker volume ls 2>/dev/null || true
  ui_section "网络"
  docker network ls 2>/dev/null || true
  ui_section "磁盘占用"
  docker system df 2>/dev/null || true
  ui_note "未挂载卷不等于无用数据；清理功能不会自动删除任何存储卷。"
}
