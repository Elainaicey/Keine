#!/usr/bin/env bash

NETWORK_TUNING_FILE="${KEINE_NETWORK_TUNING_FILE:-/etc/sysctl.d/98-keine-network.conf}"
NETWORK_TUNING_CATALOG="${KEINE_NETWORK_TUNING_CATALOG:-$CONFIG_DIR/network-tuning.tsv}"
NETWORK_TUNING_GROUP_ENTRIES=()
NETWORK_TUNING_PREVIOUS_VALUES=()

network_tuning_rows() { awk -F '|' '!/^#/ && NF==6' "$NETWORK_TUNING_CATALOG"; }

network_tuning_record() {
  awk -F '|' -v wanted="$1" '!/^#/ && NF==6 && $1==wanted {print; found=1; exit} END{if(!found)exit 1}' "$NETWORK_TUNING_CATALOG"
}

network_tuning_value_valid() {
  local key="$1" value="$2" record _key _label minimum maximum _reference _description
  [[ "$value" =~ ^[0-9]{1,9}$ ]] || return 1
  record="$(network_tuning_record "$key")" || return 1
  IFS='|' read -r _key _label minimum maximum _reference _description <<<"$record"
  [[ "$minimum" =~ ^[0-9]{1,9}$ && "$maximum" =~ ^[0-9]{1,9}$ ]] || return 1
  (( 10#$value >= 10#$minimum && 10#$value <= 10#$maximum ))
}

network_tuning_apply_file() {
  local key value
  local arguments=()
  [[ -f "$NETWORK_TUNING_FILE" ]] || return 0
  while IFS='=' read -r key value; do
    [[ "$key" != \#* && -n "$key" ]] || continue
    key="${key//[[:space:]]/}"; value="${value//[[:space:]]/}"
    network_tuning_value_valid "$key" "$value" || { warn "托管参数文件包含无效项目：$key"; return 1; }
    arguments+=("$key=$value")
  done <"$NETWORK_TUNING_FILE"
  ((${#arguments[@]} > 0)) || return 0
  network_sysctl_apply_values "${arguments[@]}"
}

network_sysctl_apply_values() {
  local key value previous result=0 setting
  local arguments=("$@") old_values=() keys=()
  for value in "${arguments[@]}"; do
    key="${value%%=*}"
    changes_sysctl_key "$key" >/dev/null || return 1
    changes_sysctl_value_valid "$key" "${value#*=}" || return 1
    previous="$(changes_sysctl_read "$key")" || return 1
    keys+=("$key"); old_values+=("$key=$previous")
  done
  # 在任何运行值写入前检查所有基线，避免部分执行或失败回退覆盖外部调优。
  for key in "${keys[@]}"; do
    setting="$(changes_sysctl_key "$key")"
    changes_setting_prepare "$setting" || return 1
  done
  if ! run sysctl -w "${arguments[@]}"; then result=1; fi
  for value in "${arguments[@]}"; do
    [[ "$(changes_sysctl_read "${value%%=*}" || true)" == "${value#*=}" ]] || result=1
  done
  if (( result != 0 )); then
    warn "参数应用失败，尝试恢复本次操作前的运行值。"
    previous="$CHANGES_RESTORING"; CHANGES_RESTORING=1
    run sysctl -w "${old_values[@]}" || warn "运行参数回退失败，请从服务商控制台检查。"
    CHANGES_RESTORING="$previous"
    for key in "${keys[@]}"; do setting="$(changes_sysctl_key "$key")"; changes_setting_commit "$setting" || true; done
    return 1
  fi
}

network_tuning_sources() {
  local file rows count=0
  ui_page "网络参数 / 持久来源" "只读取声明参数的系统文件，不执行其他脚本"
  for file in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf; do
    [[ -f "$file" ]] || continue
    rows="$(awk -F '=' 'FNR==NR {if(!/^#/ && split($0,fields,"\\|")==6) keys[fields[1]]=1; next}
      !/^[[:space:]]*#/ {key=$1; gsub(/[[:space:]]/,"",key); if(keys[key] || key ~ /^-?(net[.]|vm[.]|fs[.]file-max$|kernel[.](sched_autogroup_enabled|numa_balancing)$)/) print $0}' \
      "$NETWORK_TUNING_CATALOG" "$file")"
    [[ -n "$rows" ]] || continue
    ui_section "$file" "primary"
    while IFS= read -r rows; do
      printf '  %s\n' "$(terminal_safe_text "$rows")"; count=$((count + 1))
      (( count < 60 )) || break
    done <<<"$rows"
    (( count < 60 )) || break
  done
  (( count > 0 )) || ui_empty "没有找到这些参数的显式持久配置"
  ui_note "重复键可能在开机时覆盖；运行值以 sysctl 为准。不会删除第三方文件或重新加载其全部配置。"
}

network_tuning_set() {
  if declare -F tuning_strategy_guard >/dev/null; then tuning_strategy_guard || return 1; fi
  local key="$1" record _key label minimum maximum reference description current value payload
  record="$(network_tuning_record "$key")" || return 1
  IFS='|' read -r _key label minimum maximum reference description <<<"$record"
  current="$(sysctl -n "$key" 2>/dev/null)" || { warn "当前内核不提供此参数。"; return 1; }
  ui_page "网络参数 / $label" "$key"
  ui_kv "当前值" "$current"; ui_kv "允许范围" "$minimum – $maximum"
  ui_hint "$description；参考值 $reference 不是所有 VPS 的最优值。"
  value="$(read_input "新值；输入 0 返回仅适用于不允许 0 的参数" "$current")"
  [[ "$value" != 0 || "$minimum" == 0 ]] || return 0
  network_tuning_value_valid "$key" "$value" || { warn "参数须为范围内的整数。"; return 1; }
  value="$((10#$value))"
  if [[ -e "$NETWORK_TUNING_FILE" ]] && ! config_project_marker "$NETWORK_TUNING_FILE"; then
    warn "目标文件不属于项目，拒绝覆盖。"; return 1
  fi
  ui_note "只写入本项目独立文件；第三方持久配置可能在重启时覆盖，请先查看参数来源。"
  confirm "设置 $key=$value 并记录原始运行值？" || return 0
  payload="$({
    printf '# Managed by keine\n'
    if [[ -f "$NETWORK_TUNING_FILE" ]]; then
      awk -F '=' -v wanted="$key" '!/^#/ {key=$1; gsub(/[[:space:]]/,"",key); if(key != wanted && NF==2) print}' "$NETWORK_TUNING_FILE"
    fi
    printf '%s = %s\n' "$key" "$value"
  })"
  config_file_write "$NETWORK_TUNING_FILE" 0644 "$payload" network_tuning_apply_file || return 1
  audit "action=network-parameter key=$key value=$value"
  ui_success "参数配置完成。"
}

network_tuning_restore_runtime() {
  local entry
  for entry in "${NETWORK_TUNING_GROUP_ENTRIES[@]}"; do changes_restore_setting "$entry" 1 || return 1; done
}

network_tuning_restore_rollback() {
  ((${#NETWORK_TUNING_PREVIOUS_VALUES[@]} == 0)) || run sysctl -w "${NETWORK_TUNING_PREVIOUS_VALUES[@]}"
}

network_tuning_restore() {
  local keys=()
  mapfile -t keys < <(network_tuning_rows | cut -d '|' -f 1)
  network_sysctl_restore_group "$NETWORK_TUNING_FILE" "${keys[@]}"
}

network_sysctl_restore_group() {
  local file="$1" key setting entry current before last
  shift
  NETWORK_TUNING_GROUP_ENTRIES=(); NETWORK_TUNING_PREVIOUS_VALUES=()
  for key in "$@"; do
    setting="$(changes_sysctl_key "$key")"; entry="$(changes_setting_entry "$setting")" || return 1
    [[ -d "$entry" && ! -L "$entry" ]] || continue
    current="$(changes_setting_value "$setting")" || return 1
    before="$(<"$entry/before")"; last="$(<"$entry/last")"
    [[ "$current" == "$before" || "$current" == "$last" ]] || { warn "$key 已被外部修改，拒绝覆盖。"; return 1; }
    NETWORK_TUNING_GROUP_ENTRIES+=("$entry"); NETWORK_TUNING_PREVIOUS_VALUES+=("$key=$current")
  done
  confirm "移除项目网络参数文件，并恢复首次修改前的运行值？" || return 0
  config_file_restore "$file" network_tuning_restore_runtime network_tuning_restore_rollback || return 1
  for entry in "${NETWORK_TUNING_GROUP_ENTRIES[@]}"; do changes_restore_setting "$entry" || return 1; done
  audit 'action=network-parameters-restore'
  ui_success "项目网络参数已撤销；第三方配置文件未修改。"
}

network_parameters_menu() {
  local rows=() record key label _minimum _maximum _reference _description index choice value
  while true; do
    mapfile -t rows < <(network_tuning_rows)
    ui_page "网络 / 网络调优"
    ui_section "内核与连接参数" "primary"
    for index in "${!rows[@]}"; do
      record="${rows[$index]}"; IFS='|' read -r key label _minimum _maximum _reference _description <<<"$record"
      value="$(sysctl -n "$key" 2>/dev/null || printf '内核不支持')"
      ui_item "$((index + 1))" "$label" "$value"
    done
    ui_section "来源与恢复" "accent"
    ui_action S "持久参数来源" "action"
    ui_action R "撤销项目参数" "warning"
    ui_action B "BBR 拥塞控制" "action"
    ui_action I "IP 地址优先级" "action"
    ui_action A "独立调优方案" "action"
    ui_menu_footer "返回"
    ui_read_choice choice
    case "$choice" in
      0) return 0 ;; S|s) network_tuning_sources ;; R|r) network_tuning_restore || true ;;
      B|b) network_bbr_manage || true ;; I|i) network_set_address_preference || true ;;
      A|a) network_tuning_adapter_menu; continue ;;
      *) if [[ "$choice" =~ ^[1-9]$ ]] && (( choice <= ${#rows[@]} )); then
           IFS='|' read -r key _ <<<"${rows[$((choice-1))]}"; network_tuning_set "$key" || true
         else warn "参数编号无效。"; fi ;;
    esac
    pause
  done
}
