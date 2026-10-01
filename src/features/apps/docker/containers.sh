#!/usr/bin/env bash

docker_cleanup() {
  docker_require || return 1
  ui_page "Docker 安全清理" "清理未使用对象，但始终保留存储卷"
  docker_query system df || return 1
  ui_note "只清理已停止容器、未使用网络、悬空镜像和构建缓存；不会删除存储卷。"
  confirm "执行 docker system prune？" || return 0
  require_root
  run docker system prune -f || { warn "Docker 清理失败。"; return 1; }
  audit "action=docker-prune volumes=false"
  ui_success "Docker 未使用对象清理完成，存储卷已保留"
}

docker_container_action() {
  docker_require || return 1
  local container action state health restart_policy image created pid expected snapshot="" refresh=1
  ui_hint "输入 docker ps 中的容器名称或十六进制 ID。"
  container="$(read_input "容器名称或 ID" "")"; [[ -n "$container" ]] || return 0
  docker_container_ref_valid "$container" || { warn "容器名称或 ID 格式无效。"; return 1; }
  while true; do
    if (( refresh == 1 )); then
      snapshot="$(runtime_with_timeout 5 docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}未配置{{end}}|{{.HostConfig.RestartPolicy.Name}}|{{.Config.Image}}|{{.Created}}|{{.State.Pid}}' "$container" 2>/dev/null)" || {
        warn "无法读取容器：$container（可能不存在，或 Docker 查询超时）。"; return 1;
      }
      IFS='|' read -r state health restart_policy image created pid <<<"$snapshot"
      created="${created%%.*}"
      refresh=0
    fi
    ui_page "容器 / $container" "状态、端口、挂载、日志与生命周期"
    ui_panel_begin "容器信息"
    if [[ "$state" == "running" ]]; then ui_panel_kv "状态" "● $state" "$GREEN"; else ui_panel_kv "状态" "● $state" "$YELLOW"; fi
    ui_panel_kv "健康检查" "$health"
    ui_panel_kv "镜像" "${image:-未知}"
    ui_panel_kv "重启策略" "${restart_policy:-no}"
    ui_panel_kv "进程 PID" "$pid"
    ui_panel_kv "创建时间" "${created:-未知}"
    ui_panel_end
    ui_hint "当前为一次只读快照；R 刷新，端口与挂载按需查看。"
    ui_section "查看" "primary"
    ui_action 1 "查看日志" "action" "最近 150 条"
    ui_action 2 "资源快照" "action" "CPU、内存、网络和 IO"
    ui_action 3 "完整检查信息" "action" "输出 docker inspect JSON"
    ui_action P "端口与挂载" "action" "仅在打开时查询"
    ui_section "生命周期" "accent"
    ui_action 4 "启动" "success"
    ui_action 5 "停止" "danger"
    ui_action 6 "重启" "warning"
    if [[ "$state" == "paused" ]]; then
      ui_action 7 "恢复运行" "success"
    else
      ui_action 7 "暂停" "warning"
    fi
    ui_action 8 "修改重启策略" "action" "no、on-failure、unless-stopped 或 always"
    ui_action R "刷新容器状态" "accent"
    ui_action 0 "返回" "muted"
    action="$(read_input "请选择" "0")"
    case "$action" in
      1) runtime_with_timeout 5 docker logs --tail 150 "$container" 2>&1 || warn "读取日志失败或超时。"; pause ;;
      2) runtime_with_timeout 8 docker stats --no-stream "$container" || warn "资源采样失败或超时。"; pause ;;
      3) runtime_with_timeout 5 docker inspect "$container" || warn "读取检查信息失败或超时。"; pause ;;
      P|p)
        ui_page "容器 / $container / 端口与挂载" "一次性只读查询"
        runtime_with_timeout 5 docker port "$container" 2>/dev/null || ui_empty "没有发布端口或查询失败"
        runtime_with_timeout 5 docker inspect --format '{{range .Mounts}}{{.Type}}: {{.Source}} → {{.Destination}}{{println}}{{end}}' "$container" 2>/dev/null | sed '/^$/d' || warn "挂载查询失败。"
        pause
        ;;
      R|r) refresh=1; continue ;;
      4|5|6|7)
        local verb
        case "$action" in
          4) verb=start ;;
          5) verb=stop ;;
          6) verb=restart ;;
          7) if [[ "$state" == "paused" ]]; then verb=unpause; else verb=pause; fi ;;
        esac
        confirm "对容器 $container 执行 $verb？" || continue
        require_root
        refresh=1
        run docker "$verb" "$container" || { warn "容器 $verb 操作失败。"; pause; continue; }
        if [[ "$DRY_RUN" -eq 0 ]]; then
          case "$verb" in
            start|restart|unpause) expected=running ;;
            stop) expected=exited ;;
            pause) expected=paused ;;
          esac
          state="$(runtime_with_timeout 5 docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || true)"
          [[ "$state" == "$expected" ]] || { warn "操作后容器状态为 ${state:-未知}，预期为 $expected。"; pause; continue; }
        fi
        audit "action=docker-$verb container=$container"
        ui_success "容器 $container 已执行 $verb"
        pause
        ;;
      8)
        local policy policy_choice
        ui_hint "unless-stopped 适合常驻服务；no 表示 Docker 不自动拉起容器。"
        policy_choice="$(read_input "策略：1 no / 2 on-failure / 3 unless-stopped / 4 always" "3")"
        case "$policy_choice" in
          1) policy=no ;;
          2) policy=on-failure ;;
          3) policy=unless-stopped ;;
          4) policy=always ;;
          *) warn "未知重启策略"; continue ;;
        esac
        confirm "将容器 $container 的重启策略改为 $policy？" || continue
        require_root
        refresh=1
        run docker update --restart "$policy" "$container" || { warn "重启策略更新失败。"; pause; continue; }
        if [[ "$DRY_RUN" -eq 0 ]]; then
          restart_policy="$(runtime_with_timeout 5 docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$container" 2>/dev/null || true)"
          [[ "$restart_policy" == "$policy" ]] || { warn "更新后策略为 ${restart_policy:-未知}，预期为 $policy。"; pause; continue; }
        fi
        audit "action=docker-restart-policy container=$container policy=$policy"
        ui_success "容器 $container 的重启策略已更新为 $policy"
        pause
        ;;
      0) return 0 ;;
      *) warn "未知选项" ;;
    esac
  done
}
