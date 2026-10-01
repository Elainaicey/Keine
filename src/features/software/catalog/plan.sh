#!/usr/bin/env bash

CATALOG_PLAN_INSTALLS=0
CATALOG_PLAN_UPGRADES=0
CATALOG_PLAN_REMOVALS=0
CATALOG_PLAN_KEPT=0
CATALOG_PLAN_DISK=""
CATALOG_PLAN_OUTPUT=""

catalog_apt_target_packages() {
  local action="$1" handler="$2" declared="$3" package
  local candidates=()
  case "$handler" in
    docker_official)
      candidates=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io docker-compose-v2)
      ;;
    caddy_official) candidates=(caddy) ;;
    ""|official_release)
      [[ -n "$declared" ]] && candidates=("$declared")
      ;;
    *) return 0 ;;
  esac
  for package in "${candidates[@]}"; do
    if [[ "$action" == "install" ]]; then
      if [[ "$handler" == "docker_official" ]]; then
        [[ "$package" == docker-ce || "$package" == docker-ce-cli || "$package" == containerd.io ||
          "$package" == docker-buildx-plugin || "$package" == docker-compose-plugin ]] || continue
      fi
    elif ! package_installed "$package"; then
      continue
    fi
    printf '%s\n' "$package"
  done
}

catalog_apt_plan_simulate() {
  local action="$1" package line command_action
  local packages=()
  shift
  packages=("$@")
  ((${#packages[@]} > 0)) || return 1
  command_exists apt-get || return 2
  CATALOG_PLAN_INSTALLS=0
  CATALOG_PLAN_UPGRADES=0
  CATALOG_PLAN_REMOVALS=0
  CATALOG_PLAN_KEPT=0
  CATALOG_PLAN_DISK=""
  CATALOG_PLAN_OUTPUT=""
  case "$action" in
    install) command_action=(install) ;;
    update) command_action=(install --only-upgrade) ;;
    remove) command_action=(remove) ;;
    *) return 1 ;;
  esac
  CATALOG_PLAN_OUTPUT="$(LC_ALL=C apt-get -s -o Debug::NoLocking=true \
    "${command_action[@]}" -- "${packages[@]}" 2>&1)" || return 1
  while IFS= read -r line; do
    case "$line" in
      'Inst '*)
        package="${line#Inst }"; package="${package%% *}"
        if package_installed "$package"; then
          CATALOG_PLAN_UPGRADES=$((CATALOG_PLAN_UPGRADES + 1))
        else
          CATALOG_PLAN_INSTALLS=$((CATALOG_PLAN_INSTALLS + 1))
        fi
        ;;
      'Remv '*) CATALOG_PLAN_REMOVALS=$((CATALOG_PLAN_REMOVALS + 1)) ;;
      *' not upgraded.'*)
        if [[ "$line" =~ ([0-9]+)[[:space:]]+not[[:space:]]+upgraded ]]; then
          CATALOG_PLAN_KEPT="${BASH_REMATCH[1]}"
        fi
        ;;
      'After this operation,'*|'Need to get '*|'0 B of archives.'*) CATALOG_PLAN_DISK="$line" ;;
    esac
  done <<<"$CATALOG_PLAN_OUTPUT"
}

catalog_apt_plan_items() {
  local line kind package payload version shown=0 limit="${1:-12}"
  while IFS= read -r line; do
    case "$line" in
      'Inst '*) kind="安装 / 更新"; package="${line#Inst }" ;;
      'Remv '*) kind="移除"; package="${line#Remv }" ;;
      *) continue ;;
    esac
    payload="${package#* }"
    package="${package%% *}"
    version=""
    if [[ "$kind" == "安装 / 更新" && "$payload" == *" ("* ]]; then
      version="${payload#* (}"; version="${version%% *}"
    elif [[ "$kind" == "安装 / 更新" && "$payload" == \(* ]]; then
      version="${payload#(}"; version="${version%% *}"
    elif [[ "$kind" == "移除" && "$payload" == \[* ]]; then
      version="${payload#[}"; version="${version%%]*}"
    fi
    printf '%s|%s|%s\n' "$kind" "$package" "$version"
    shown=$((shown + 1))
    (( shown >= limit )) && break
  done <<<"$CATALOG_PLAN_OUTPUT"
}

catalog_apt_plan_render() {
  local action="$1" label kind package version shown=0 total_changes
  shift
  command_exists apt-get || {
    ui_note "当前环境无法生成 APT 事务预览；实际执行仍会经过 APT 自身校验。"
    return 0
  }
  if ! catalog_apt_plan_simulate "$action" "$@"; then
    ui_callout bad "APT 无法生成安全事务预览" \
      "请先核实软件源、依赖与候选版本；未执行任何软件变更。"
    return 1
  fi
  case "$action" in install) label="安装事务预览" ;; update) label="更新事务预览" ;; remove) label="移除事务预览" ;; esac
  total_changes=$((CATALOG_PLAN_INSTALLS + CATALOG_PLAN_UPGRADES + CATALOG_PLAN_REMOVALS))
  ui_section "$label" "accent"
  ui_metric_row \
    "新安装" "$CATALOG_PLAN_INSTALLS" "good" \
    "更新" "$CATALOG_PLAN_UPGRADES" "primary" \
    "移除" "$CATALOG_PLAN_REMOVALS" "$([[ "$CATALOG_PLAN_REMOVALS" -gt 0 ]] && printf 'bad' || printf 'muted')"
  (( CATALOG_PLAN_KEPT == 0 )) || ui_hint "$CATALOG_PLAN_KEPT 个软件包暂不更新。"
  while IFS='|' read -r kind package version; do
    [[ -n "$package" ]] || continue
    shown=$((shown + 1))
    ui_status "$package" "$kind${version:+ · $version}" \
      "$([[ "$kind" == "移除" ]] && printf 'bad' || printf 'primary')"
  done < <(catalog_apt_plan_items 12)
  (( total_changes <= shown )) || ui_hint "其余 $((total_changes - shown)) 个依赖变更已折叠；APT 执行时仍会输出完整清单。"
  [[ -z "$CATALOG_PLAN_DISK" ]] || ui_hint "$(terminal_safe_text "$CATALOG_PLAN_DISK")"
  if [[ "$action" != "remove" && "$CATALOG_PLAN_REMOVALS" -gt 0 ]]; then
    ui_callout bad "安装或更新计划意外包含移除项" \
      "为避免联带卸载，Server Toolkit 已阻止本次操作。"
    return 1
  fi
  if [[ "$action" == "remove" && "$CATALOG_PLAN_REMOVALS" -gt 1 ]]; then
    ui_callout warn "将联带移除 $CATALOG_PLAN_REMOVALS 个软件包" \
      "请核对上方清单；配置文件和业务数据不会由工具额外清理。"
  elif (( total_changes == 0 )); then
    ui_note "APT 模拟结果没有需要执行的软件包变更。"
  fi
}
