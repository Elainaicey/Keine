#!/usr/bin/env bash

system_storage_allowed_root() {
  case "${1:-}" in
    /var|/home|/opt|/srv|/tmp) return 0 ;;
    *) return 1 ;;
  esac
}

system_storage_pick_root() {
  local choice storage_target="$1" selected_root
  [[ "$storage_target" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 1
  ui_action_pair 1 "/var" "action" 2 "/home" "action"
  ui_action_pair 3 "/opt" "action" 4 "/srv" "action"
  ui_action 5 "/tmp" "action"
  ui_menu_footer "取消"
  ui_read_choice choice
  case "$choice" in
    1) selected_root=/var ;;
    2) selected_root=/home ;;
    3) selected_root=/opt ;;
    4) selected_root=/srv ;;
    5) selected_root=/tmp ;;
    0) return 1 ;;
    *) warn "未知范围：$choice"; return 1 ;;
  esac
  printf -v "$storage_target" '%s' "$selected_root"
}

system_storage_category_rows() {
  local path label bytes
  while IFS='|' read -r label path; do
    [[ -e "$path" ]] || continue
    bytes="$(du -sx -B1 "$path" 2>/dev/null | awk 'NR==1 {print $1}')"
    [[ "$bytes" =~ ^[0-9]+$ ]] || continue
    printf '%s|%s|%s\n' "$label" "$path" "$bytes"
  done <<EOF
系统日志|/var/log
APT 缓存|/var/cache/apt
Docker 数据|/var/lib/docker
项目备份|$BACKUP_ROOT
应用目录|/opt
用户目录|/home
临时目录|/tmp
EOF
}

system_storage_categories_view() {
  local label path bytes count=0
  ui_page "存储中心 / 分类占用" "常见系统、项目和业务目录的当前磁盘占用"
  while IFS='|' read -r label path bytes; do
    ui_kv "$label" "$(backup_human_bytes "$bytes") · $path"
    count=$((count + 1))
  done < <(system_storage_category_rows)
  (( count > 0 )) || ui_empty "没有读取到分类占用"
  ui_note "目录占用为当前时刻快照；跨文件系统内容不会重复计算。"
}

system_storage_largest_directories() {
  local root bytes path count=0
  system_storage_pick_root root || return 0
  system_storage_allowed_root "$root" || { warn "扫描目录不在允许范围内。"; return 1; }
  ui_page "存储中心 / 最大目录" "$root · 同一文件系统 · 最多显示 30 项"
  while IFS=$'\t' read -r bytes path; do
    [[ "$bytes" =~ ^[0-9]+$ && -n "$path" ]] || continue
    printf '  %b' "$CYAN"
    ui_pad "$(backup_human_bytes "$bytes")" 14
    printf '%b%s\n' "$NC" "$(terminal_safe_text "$path")"
    count=$((count + 1))
  done < <(du -x -B1 --max-depth=2 "$root" 2>/dev/null | sort -nr | head -n 30)
  (( count > 0 )) || ui_empty "没有读取到目录占用"
}

system_storage_largest_files() {
  local root bytes path count=0
  system_storage_pick_root root || return 0
  system_storage_allowed_root "$root" || { warn "扫描目录不在允许范围内。"; return 1; }
  ui_page "存储中心 / 最大文件" "$root · 同一文件系统 · 最多显示 30 项"
  while IFS='|' read -r bytes path; do
    [[ "$bytes" =~ ^[0-9]+$ && -n "$path" ]] || continue
    printf '  %b' "$CYAN"
    ui_pad "$(backup_human_bytes "$bytes")" 14
    printf '%b%s\n' "$NC" "$(terminal_safe_text "$path")"
    count=$((count + 1))
  done < <(find "$root" -xdev -type f -printf '%s|%p\n' 2>/dev/null | sort -t '|' -k1,1nr | head -n 30)
  (( count > 0 )) || ui_empty "没有读取到普通文件"
}

system_storage_mounts_view() {
  local readonly_mounts verification
  ui_page "存储中心 / 挂载检查" "当前挂载、只读状态与 /etc/fstab 验证"
  ui_section "当前挂载" "primary"
  if command_exists findmnt; then
    findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null | sed -n '1,100p'
  else
    ui_empty "缺少 findmnt"
    return 1
  fi
  ui_section "异常只读挂载" "accent"
  readonly_mounts="$(findmnt -rn -o TARGET,OPTIONS 2>/dev/null |
    awk '$2 ~ /(^|,)ro(,|$)/ && $1 !~ "^/(proc|sys|dev|run)(/|$)" {print}')"
  if [[ -n "$readonly_mounts" ]]; then printf '%s\n' "$readonly_mounts"; else ui_empty "没有检测到异常只读挂载"; fi
  ui_section "fstab 验证" "primary"
  verification="$(findmnt --verify --verbose 2>&1 || true)"
  if grep -Eq '^[[:space:]]*0 parse errors, 0 errors, 0 warnings' <<<"$verification"; then
    ui_success "/etc/fstab 验证通过。"
  elif [[ -n "$verification" ]]; then
    printf '%s\n' "$verification" | sed -n '1,100p'
    ui_note "findmnt 返回了提示或错误；修改 fstab 前请确认设备标识和挂载点。"
  else
    ui_empty "findmnt 没有返回验证结果"
  fi
}

system_storage_deleted_files() {
  local deleted
  ui_page "存储中心 / 已删除占用" "文件已删除但仍被进程打开时，空间不会立即释放"
  if ! command_exists lsof; then
    ui_empty "未安装 lsof，可从软件管理中心安装后重试"
    return 0
  fi
  deleted="$(lsof -nP +L1 2>/dev/null | sed -n '1,80p' || true)"
  if [[ -n "$deleted" ]]; then
    printf '%s\n' "$deleted"
    ui_note "确认业务影响后重启或重新加载持有文件的服务，空间才会释放。"
  else
    ui_success "没有检测到已删除但仍占用空间的文件。"
  fi
}

system_storage_overview() {
  local readonly_mounts
  ui_page "存储中心" "文件系统、inode、分类占用、挂载与异常占用"
  ui_section "块设备" "primary"
  if command_exists lsblk; then
    lsblk -o NAME,TYPE,FSTYPE,SIZE,FSAVAIL,FSUSE%,MOUNTPOINTS 2>/dev/null
  else
    ui_empty "缺少 lsblk"
  fi
  ui_section "文件系统空间" "accent"
  df -hT -x tmpfs -x devtmpfs 2>/dev/null || true
  ui_section "inode 使用" "primary"
  df -hi -x tmpfs -x devtmpfs 2>/dev/null || true
  if command_exists findmnt; then
    readonly_mounts="$(findmnt -rn -o TARGET,OPTIONS 2>/dev/null |
      awk '$2 ~ /(^|,)ro(,|$)/ && $1 !~ "^/(proc|sys|dev|run)(/|$)" {count++} END {print count+0}')"
    ui_context "异常只读挂载：${readonly_mounts:-0} 项"
  fi
}

system_disk_usage() {
  local interactive="${1:-1}" choice
  while true; do
    system_storage_overview
    [[ "$interactive" -eq 1 ]] || return 0
    ui_section "按需分析" "accent"
    ui_action_pair 1 "分类占用" "action" 2 "最大目录" "action"
    ui_action_pair 3 "最大文件" "action" 4 "挂载与 fstab" "action"
    ui_action 5 "已删除占用" "action"
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      1) system_storage_categories_view ;;
      2) system_storage_largest_directories ;;
      3) system_storage_largest_files ;;
      4) system_storage_mounts_view || true ;;
      5) system_storage_deleted_files ;;
      0) return 0 ;;
      *) warn "未知选项：$choice"; continue ;;
    esac
    pause
  done
}
