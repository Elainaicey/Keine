#!/usr/bin/env bash
# 解析结果由调用方读取；不执行公钥文本，保留未编辑选项的原始字节。
# shellcheck disable=SC2034

security_ssh_key_split() {
  local line="$1" token="" rest char quote=0 escaped=0 index
  SSH_KEY_STATE=enabled SSH_KEY_OPTIONS="" SSH_KEY_TYPE="" SSH_KEY_BLOB="" SSH_KEY_COMMENT=""
  [[ "$line" != '# keine-disabled '* ]] || { SSH_KEY_STATE=disabled; line="${line#\# keine-disabled }"; }
  [[ ${#line} -le 16384 && "$line" != *$'\n'* && "$line" != *$'\r'* ]] || return 1
  line="${line#"${line%%[!$' \t']*}"}"
  for ((index=0; index<${#line}; index++)); do
    char="${line:index:1}"
    if (( escaped == 1 )); then escaped=0
    elif [[ "$char" == \\ && "$quote" == 1 && "${line:index+1:1}" == '"' ]]; then escaped=1
    elif [[ "$char" == '"' ]]; then quote=$((1-quote))
    elif [[ "$char" == ' ' || "$char" == $'\t' ]] && (( quote == 0 )); then break; fi
    token+="$char"
  done
  (( quote == 0 && escaped == 0 )) || return 1
  rest="${line:index}"
  case "$token" in
    ssh-*|ecdsa-*|sk-*) IFS=$' \t' read -r SSH_KEY_TYPE SSH_KEY_BLOB SSH_KEY_COMMENT <<<"$line" ;;
    *) SSH_KEY_OPTIONS="$token"; IFS=$' \t' read -r SSH_KEY_TYPE SSH_KEY_BLOB SSH_KEY_COMMENT <<<"$rest" ;;
  esac
  [[ -n "$SSH_KEY_TYPE" && -n "$SSH_KEY_BLOB" ]] || return 1
  security_ssh_key_fingerprint "$SSH_KEY_TYPE $SSH_KEY_BLOB" >/dev/null
}

security_ssh_key_option_tokens() {
  local value="$1" token="" char quote=0 escaped=0 index
  SSH_KEY_TOKENS=()
  [[ -n "$value" ]] || return 0
  for ((index=0; index<${#value}; index++)); do
    char="${value:index:1}"
    if (( escaped == 1 )); then escaped=0
    elif [[ "$char" == \\ && "$quote" == 1 && "${value:index+1:1}" == '"' ]]; then escaped=1
    elif [[ "$char" == '"' ]]; then quote=$((1-quote))
    elif [[ "$char" == ',' && "$quote" == 0 ]]; then
      [[ -n "$token" ]] || return 1
      SSH_KEY_TOKENS+=("$token"); token=""; continue
    fi
    token+="$char"
  done
  (( quote == 0 && escaped == 0 )) && [[ -n "$token" ]] || return 1
  SSH_KEY_TOKENS+=("$token")
}

security_ssh_key_details() {
  local line="$1" token name
  security_ssh_key_split "$line" && security_ssh_key_option_tokens "$SSH_KEY_OPTIONS" || return 1
  SSH_KEY_SOURCE="不限" SSH_KEY_TCP="随服务配置" SSH_KEY_AGENT="随服务配置" SSH_KEY_X11="随服务配置" SSH_KEY_EXTRA=""
  for token in "${SSH_KEY_TOKENS[@]}"; do
    name="${token%%=*}"; name="${name,,}"
    case "$name" in
      from) SSH_KEY_SOURCE="${token#*=}"; SSH_KEY_SOURCE="${SSH_KEY_SOURCE#\"}"; SSH_KEY_SOURCE="${SSH_KEY_SOURCE%\"}" ;;
      no-port-forwarding) SSH_KEY_TCP=禁止 ;;
      no-agent-forwarding) SSH_KEY_AGENT=禁止 ;;
      no-x11-forwarding) SSH_KEY_X11=禁止 ;;
      *) SSH_KEY_EXTRA+="${SSH_KEY_EXTRA:+, }$name" ;;
    esac
  done
  # restrict 和正向例外的顺序也影响结果；这里不猜测复杂原生选项的有效权限。
  if [[ -n "$SSH_KEY_EXTRA" ]]; then
    SSH_KEY_TCP+="*"; SSH_KEY_AGENT+="*"; SSH_KEY_X11+="*"
  fi
}

security_ssh_key_option_update() {
  local line="$1" field="$2" value="$3" token name options="" replacement="" count=0
  security_ssh_key_split "$line" && security_ssh_key_option_tokens "$SSH_KEY_OPTIONS" || return 1
  case "$field" in
    from)
      security_ssh_key_sources_valid "$value" || return 1
      [[ -z "$value" ]] || replacement="from=\"$value\"" ;;
    no-port-forwarding|no-agent-forwarding|no-x11-forwarding)
      [[ "$value" == yes || "$value" == no ]] || return 1
      [[ "$value" != yes ]] || replacement="$field"
      # restrict/正向例外可改变开关含义，保留原样，要求原生管理而非错误承诺解除限制。
      for token in "${SSH_KEY_TOKENS[@]}"; do
        case "${token,,}" in restrict|port-forwarding|agent-forwarding|x11-forwarding)
          warn "此公钥含 restrict 或原生转发例外，请通过原生配置调整转发。"; return 1 ;;
        esac
      done ;;
    comment)
      [[ ${#value} -le 200 && "$value" != *[[:cntrl:]]* ]] || return 1
      SSH_KEY_COMMENT="$value" ;;
    *) return 1 ;;
  esac
  for token in "${SSH_KEY_TOKENS[@]}"; do
    name="${token%%=*}"; name="${name,,}"
    if [[ "$field" != comment && "$name" == "$field" ]]; then count=$((count+1)); continue; fi
    options+="${options:+,}$token"
  done
  (( count <= 1 )) || { warn "该选项重复出现，停止修改。"; return 1; }
  options+="${options:+${replacement:+,}}$replacement"
  [[ "$SSH_KEY_STATE" != disabled ]] || printf '# keine-disabled '
  printf '%s%s %s%s' "${options:+$options }" "$SSH_KEY_TYPE" "$SSH_KEY_BLOB" "${SSH_KEY_COMMENT:+ $SSH_KEY_COMMENT}"
}

security_ssh_key_detail_view() {
  local line="$1"
  security_ssh_key_details "$line" || { warn "无法安全解析条目选项。"; return 1; }
  ui_kv "备注" "$(terminal_safe_text "${SSH_KEY_COMMENT:-未备注}")"
  ui_kv "算法" "$SSH_KEY_TYPE"
  ui_kv "来源" "$(terminal_safe_text "$SSH_KEY_SOURCE")"
  ui_kv "转发" "TCP $SSH_KEY_TCP / Agent $SSH_KEY_AGENT / X11 $SSH_KEY_X11"
  if [[ -n "$SSH_KEY_EXTRA" ]]; then
    ui_kv "其他选项" "$(terminal_safe_text "$SSH_KEY_EXTRA")"
    ui_hint "* 还有原生选项约束；开关不代表最终权限。"
  fi
}

security_ssh_keys_edit() {
  local number="$1" expected="$2" path line updated field choice value payload
  path="$(security_ssh_key_path)"
  line="$(sed -n "${number}p" "$path")"
  security_ssh_key_detail_view "$line" || return 1
  ui_action 1 "修改来源 IP" "action"
  ui_action 2 "TCP 转发" "action"
  ui_action 3 "Agent 转发" "action"
  ui_action 4 "X11 转发" "action"
  ui_action 5 "修改备注" "action"
  ui_menu_footer "取消"; ui_read_choice choice
  case "$choice" in
    0) return 0 ;;
    1)
      field=from
      value="$(read_input "允许来源（IP/CIDR，逗号分隔；- 解除；留空取消）" "")"
      [[ -n "$value" ]] || return 0
      [[ "$value" != - ]] || value="" ;;
    2|3|4)
      case "$choice" in 2) field=no-port-forwarding ;; 3) field=no-agent-forwarding ;; 4) field=no-x11-forwarding ;; esac
      ui_action 1 "禁止" "action"; ui_action 2 "解除本条限制" "action"
      ui_menu_footer "取消"; ui_read_choice choice
      case "$choice" in 1) value=yes ;; 2) value=no ;; 0) return 0 ;; *) return 1 ;; esac ;;
    5)
      field=comment; value="$(read_input "新备注（- 清空；留空取消）" "")"
      [[ -n "$value" ]] || return 0
      [[ "$value" != - ]] || value="" ;;
    *) return 1 ;;
  esac
  updated="$(security_ssh_key_option_update "$line" "$field" "$value")" || { warn "未修改：输入无效或选项不能安全编辑。"; return 1; }
  [[ "$updated" != "$line" ]] || { info "条目未变化。"; return 0; }
  ui_section "修改后" "primary"
  security_ssh_key_detail_view "$updated" || return 1
  ui_hint "仅影响这把公钥的新连接；来源为服务器看到的客户端出口 IP。"
  security_ssh_key_confirm "保存修改？请保留当前连接并验证新登录。" || return 0
  # 从 stdin 读取替换行，避免 awk -v 对反斜杠再次转义。
  payload="$(printf '%s\n' "$updated" | awk -v n="$number" 'NR==FNR {replacement=$0;next} FNR==n {print replacement;next} {print}' - "$path")"
  security_ssh_key_write "$payload" "$expected" 0 1 || return 1
  audit "action=ssh-key-edit user=$(security_ssh_user) field=$field"
  if (( DRY_RUN == 0 )); then ui_success "公钥已更新，请验证新连接。"; fi
}
