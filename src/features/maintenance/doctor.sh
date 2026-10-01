#!/usr/bin/env bash

TOOLKIT_DOCTOR_PASS=0
TOOLKIT_DOCTOR_WARN=0
TOOLKIT_DOCTOR_FAIL=0

toolkit_version_valid() {
  [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

toolkit_mode_safe() {
  local mode="${1:-}" mode_value
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  mode_value=$((8#$mode))
  (( (mode_value & 0022) == 0 ))
}

toolkit_directory_mode_safe() {
  local path="$1" mode
  [[ -d "$path" && ! -L "$path" ]] || return 1
  mode="$(stat -c '%a' "$path" 2>/dev/null || true)"
  toolkit_mode_safe "$mode"
}

toolkit_catalog_shape_valid() {
  local catalog="$1" fields
  [[ -r "$catalog" && -f "$catalog" && ! -L "$catalog" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" && "$line" != \#* ]] || continue
    fields="$(awk -F '|' '{print NF}' <<<"$line")"
    [[ "$fields" == "6" ]] || return 1
  done <"$catalog"
}

toolkit_catalog_row_count() {
  local catalog="$1"
  [[ -r "$catalog" ]] || return 1
  awk -F '|' '!/^#/ && NF == 6 {total++} END {print total + 0}' "$catalog"
}

toolkit_release_catalog_valid() {
  local release_path="$1" software_path="$2"
  toolkit_catalog_shape_valid "$release_path" || return 1
  toolkit_catalog_shape_valid "$software_path" || return 1
  awk -F '|' '
    FNR == NR {
      if ($0 !~ /^#/ && NF == 6) software[$1]=$6
      next
    }
    $0 !~ /^#/ && NF == 6 {
      if (seen[$1]++ || software[$1] != "official_release") failed=1
      if ($1 !~ /^[a-z0-9][a-z0-9-]*$/) failed=1
      if ($2 !~ /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/) failed=1
      if ($3 !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) failed=1
      if ($4 !~ /[.]tar[.]gz$/ || $5 !~ /[.]tar[.]gz$/) failed=1
      if ($6 != "https://github.com/" $2) failed=1
    }
    END {
      for (id in software) {
        if (software[id] == "official_release" && !seen[id]) failed=1
      }
      exit failed
    }
  ' "$software_path" "$release_path"
}

toolkit_effect_catalog_valid() {
  local effects_path="$1" software_path="$2"
  toolkit_catalog_shape_valid "$effects_path" || return 1
  toolkit_catalog_shape_valid "$software_path" || return 1
  awk -F '|' '
    FNR == NR {
      if ($0 !~ /^#/ && NF == 6) software[$1]=1
      next
    }
    $0 !~ /^#/ && NF == 6 {
      if (!software[$1] || seen[$1]++) failed=1
      if ($1 !~ /^[a-z0-9][a-z0-9-]*$/) failed=1
      if ($2 != "service" && $2 != "scheduled" && $2 != "service+scheduled" && $2 != "boot-hook") failed=1
      if ($3 != "-" && $3 !~ /^[A-Za-z0-9@_.-]+\.(service|socket|timer)(,[A-Za-z0-9@_.-]+\.(service|socket|timer))*$/) failed=1
      if ($4 != "none" && $4 != "timer" && $4 != "cron" && $4 != "timer-or-cron") failed=1
      if ($5 != "none" && $5 != "local-socket" && $5 != "tcp-listener" &&
          $5 != "tcp-udp-listener" && $5 != "outbound") failed=1
      if ($6 == "") failed=1
    }
    END { exit failed }
  ' "$software_path" "$effects_path"
}

toolkit_doctor_result() {
  local state="$1" message="$2" hint="${3:-}"
  case "$state" in
    pass) TOOLKIT_DOCTOR_PASS=$((TOOLKIT_DOCTOR_PASS + 1)) ;;
    warn) TOOLKIT_DOCTOR_WARN=$((TOOLKIT_DOCTOR_WARN + 1)) ;;
    fail) TOOLKIT_DOCTOR_FAIL=$((TOOLKIT_DOCTOR_FAIL + 1)) ;;
    *) return 1 ;;
  esac
  ui_check "$state" "$message"
  [[ -z "$hint" ]] || printf '    %b↳ %s%b\n' "$MUTED" "$hint" "$NC"
}

toolkit_doctor() {
  local version entry resolved_bin expected_bin metadata parent_dir stale_count mode dependency missing=0
  local software_total release_total effect_total
  local dependency_missing=0
  local required_files=(
    VERSION
    bin/serverctl
    config/apps.tsv
    config/software.tsv
    config/software-effects.tsv
    config/official-releases.tsv
    scripts/install.sh
    src/core/runtime.sh
    src/core/validation.sh
    src/core/ui.sh
    src/core/platform.sh
    src/core/backup.sh
    src/features/dashboard.sh
    src/features/dashboard/overview.sh
    src/features/dashboard/menu.sh
    src/features/system.sh
    src/features/system/diagnostics.sh
    src/features/system/processes.sh
    src/features/system/packages.sh
    src/features/system/updates.sh
    src/features/system/storage.sh
    src/features/system/triage.sh
    src/features/system/settings.sh
    src/features/system/menu.sh
    src/features/network.sh
    src/features/network/diagnostics.sh
    src/features/network/http.sh
    src/features/network/overview.sh
    src/features/network/tuning.sh
    src/features/network/menu.sh
    src/features/security.sh
    src/features/security/overview.sh
    src/features/security/exposure.sh
    src/features/security/activity.sh
    src/features/security/fail2ban.sh
    src/features/security/certificates.sh
    src/features/security/firewall.sh
    src/features/security/ssh.sh
    src/features/security/menu.sh
    src/features/services.sh
    src/features/services/overview.sh
    src/features/services/journal.sh
    src/features/services/units.sh
    src/features/services/audit.sh
    src/features/services/menu.sh
    src/features/software.sh
    src/features/software/catalog.sh
    src/features/software/catalog/cache.sh
    src/features/software/catalog/query.sh
    src/features/software/catalog/plan.sh
    src/features/software/catalog/effects.sh
    src/features/software/catalog/presentation.sh
    src/features/software/catalog/actions.sh
    src/features/software/catalog/views.sh
    src/features/software/repositories/state.sh
    src/features/software/repositories/docker.sh
    src/features/software/repositories/caddy.sh
    src/features/software/releases.sh
    src/features/terminal/framework.sh
    src/features/terminal/prompts.sh
    src/features/terminal/menu.sh
    src/features/terminal.sh
    src/features/maintenance/menu.sh
    src/core/changes.sh
    src/core/changes/packages.sh
    src/core/changes/settings.sh
    src/core/navigation.sh
    src/features/recovery.sh
    src/integrations/warp.sh
    src/integrations.sh
    config/navigation.tsv
    config/terminal.tsv
    config/integrations.tsv
    src/features/apps.sh
    src/features/apps/menu.sh
    src/features/apps/services.sh
    src/features/apps/services/metadata.sh
    src/features/apps/services/inspect.sh
    src/features/apps/services/health.sh
    src/features/apps/services/actions.sh
    src/features/apps/services/overview.sh
    src/features/apps/services/detail.sh
    src/features/apps/services/menu.sh
    src/features/apps/docker.sh
    src/features/apps/docker/inventory.sh
    src/features/apps/docker/compose.sh
    src/features/apps/docker/containers.sh
    src/features/apps/docker/menu.sh
    src/features/apps/docker/volumes.sh
    src/features/backups.sh
    src/features/maintenance.sh
    src/features/maintenance/doctor.sh
  )
  local required_commands=(bash awk sed grep find tar sha256sum stat)
  TOOLKIT_DOCTOR_PASS=0; TOOLKIT_DOCTOR_WARN=0; TOOLKIT_DOCTOR_FAIL=0
  ui_page "运行环境与项目检查" "运行依赖、安装入口、核心模块、数据目录、权限与升级残留"

  ui_section "版本与程序结构" "primary"
  version="$(tr -d '[:space:]' <"$ROOT_DIR/VERSION" 2>/dev/null || true)"
  if toolkit_version_valid "$version" && [[ "$version" == "$SERVERCTL_VERSION" ]]; then
    toolkit_doctor_result pass "版本文件有效 · $version"
  else
    toolkit_doctor_result fail "版本文件无效或运行时版本不一致" "VERSION=$version · runtime=$SERVERCTL_VERSION"
  fi
  for entry in "${required_files[@]}"; do
    if [[ -f "$ROOT_DIR/$entry" && ! -L "$ROOT_DIR/$entry" ]]; then
      continue
    fi
    toolkit_doctor_result fail "缺少或拒绝符号链接文件：$entry"
    missing=$((missing + 1))
  done
  if (( missing == 0 )); then
    toolkit_doctor_result pass "${#required_files[@]} 个关键文件完整"
  fi
  software_total="$(toolkit_catalog_row_count "$SOFTWARE_CATALOG" 2>/dev/null || printf '0')"
  release_total="$(toolkit_catalog_row_count "$OFFICIAL_RELEASE_CATALOG" 2>/dev/null || printf '0')"
  effect_total="$(toolkit_catalog_row_count "$SOFTWARE_EFFECTS_CATALOG" 2>/dev/null || printf '0')"
  if toolkit_catalog_shape_valid "$SOFTWARE_CATALOG" &&
    toolkit_release_catalog_valid "$OFFICIAL_RELEASE_CATALOG" "$SOFTWARE_CATALOG" &&
    toolkit_effect_catalog_valid "$SOFTWARE_EFFECTS_CATALOG" "$SOFTWARE_CATALOG" &&
    (( software_total > 0 && release_total > 0 && effect_total >= 32 )); then
    toolkit_doctor_result pass "声明式目录有效 · 软件 $software_total · 官方 Release $release_total · 运行影响 $effect_total"
  else
    toolkit_doctor_result fail "声明式目录缺失、关联无效或低于当前基线" \
      "软件 $software_total · 官方 Release $release_total · 运行影响 $effect_total"
  fi

  ui_section "安装入口与权限" "accent"
  metadata="$ROOT_DIR/config/installation.conf"
  if [[ -r "$metadata" ]]; then
    expected_bin="${SERVER_TOOLKIT_BIN_PATH:-/usr/local/bin/serverctl}"
    if [[ -L "$expected_bin" ]]; then
      resolved_bin="$(readlink -f "$expected_bin" 2>/dev/null || true)"
      if [[ "$resolved_bin" == "$ROOT_DIR/bin/serverctl" ]]; then
        toolkit_doctor_result pass "命令入口正确 · $expected_bin"
      else
        toolkit_doctor_result fail "命令入口指向其他位置" "$expected_bin → ${resolved_bin:-无法解析}"
      fi
    else
      toolkit_doctor_result fail "命令入口不是符号链接或不存在 · $expected_bin"
    fi
    if [[ "${SERVER_TOOLKIT_INSTALL_DIR:-$ROOT_DIR}" == "$ROOT_DIR" ]]; then
      toolkit_doctor_result pass "安装元数据与当前目录一致"
    else
      toolkit_doctor_result fail "安装元数据中的目录与当前目录不一致"
    fi
  else
    toolkit_doctor_result warn "没有安装元数据" "源码工作区可忽略；正式安装建议重新运行安装器"
  fi
  mode="$(stat -c '%a' "$ROOT_DIR" 2>/dev/null || printf '未知')"
  if toolkit_directory_mode_safe "$ROOT_DIR"; then
    toolkit_doctor_result pass "程序目录没有组/其他用户写权限 · $mode"
  else
    toolkit_doctor_result fail "程序目录权限过宽或目录不安全 · $mode" "建议目录归 root 所有，并移除 group/other 写权限"
  fi

  ui_section "运行依赖与数据路径" "primary"
  for dependency in "${required_commands[@]}"; do
    command_exists "$dependency" || {
      toolkit_doctor_result fail "缺少运行依赖：$dependency"
      dependency_missing=$((dependency_missing + 1))
    }
  done
  if command_exists apt-get; then
    toolkit_doctor_result pass "APT 运行时可用"
  else
    toolkit_doctor_result fail "缺少 APT；当前平台不受支持"
  fi
  if command_exists systemctl; then
    toolkit_doctor_result pass "systemd 运行时可用"
  else
    toolkit_doctor_result fail "缺少 systemctl；当前平台不受支持"
  fi
  if (( dependency_missing == 0 )); then toolkit_doctor_result pass "基础命令依赖完整"; fi
  if command_exists curl; then
    toolkit_doctor_result pass "curl 可用于项目和官方软件更新"
  else
    toolkit_doctor_result warn "缺少 curl" "控制台可启动，但无法获取项目更新和部分官方软件"
  fi
  for entry in "$BACKUP_ROOT" "$DOCKER_VOLUME_BACKUP_ROOT" "$STATE_ROOT" "$(dirname "$AUDIT_LOG")"; do
    if safe_toolkit_path "$entry" && [[ ! -L "$entry" ]]; then
      toolkit_doctor_result pass "托管路径安全 · $entry"
    else
      toolkit_doctor_result fail "托管路径不安全 · $entry"
    fi
  done

  ui_section "升级残留" "accent"
  parent_dir="$(dirname "$ROOT_DIR")"
  stale_count="$(find "$parent_dir" -mindepth 1 -maxdepth 1 -type d \
    \( -name '.server-toolkit-stage.*' -o -name '.server-toolkit-old.*' -o -name '.server-toolkit-failed.*' \) \
    -mmin +30 -printf '.' 2>/dev/null | wc -c | tr -d '[:space:]')"
  if [[ "$stale_count" =~ ^[0-9]+$ ]] && (( stale_count > 0 )); then
    toolkit_doctor_result warn "发现 $stale_count 个超过 30 分钟的安装残留目录" "请先确认没有安装进程，再人工检查 $parent_dir"
  else
    toolkit_doctor_result pass "没有陈旧的安装暂存目录"
  fi

  ui_section "检查结论" "primary"
  ui_health_summary "$TOOLKIT_DOCTOR_PASS" "$TOOLKIT_DOCTOR_WARN" "$TOOLKIT_DOCTOR_FAIL"
  if (( TOOLKIT_DOCTOR_FAIL > 0 )); then
    ui_danger "项目存在 $TOOLKIT_DOCTOR_FAIL 项完整性问题；可从主仓库重新部署当前版本。"
    return 1
  elif (( TOOLKIT_DOCTOR_WARN > 0 )); then
    ui_note "项目核心结构可用，但有 $TOOLKIT_DOCTOR_WARN 项需要确认。"
  else
    ui_success "Server Toolkit 运行环境与项目检查通过"
  fi
  ui_note "此检查只读，不会自动删除残留或修改安装。"
}
