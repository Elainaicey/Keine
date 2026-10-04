#!/usr/bin/env bash

security_native_command() {
  case "$1" in 4) printf iptables ;; 6) printf ip6tables ;; *) return 1 ;; esac
}

security_native_file() {
  [[ "$1" == 4 || "$1" == 6 ]] || return 1
  printf '%s/rules.v%s' "${KEINE_IPTABLES_DIR:-/etc/iptables}" "$1"
}

security_native_valid_row() {
  local family="$1" row="$2" protocol ports source extra
  IFS='|' read -r protocol ports source extra <<<"$row"
  [[ -z "$extra" && "$row" == "$protocol|$ports|$source" ]] || return 1
  [[ "$protocol" == tcp || "$protocol" == udp ]] && valid_port_range "$ports" || return 1
  valid_firewall_source "$source" || return 1
  case "$family:$source" in 4:*:*) return 1 ;; 6:any|6:*:*) ;; 6:*) return 1 ;; 4:*) ;; *) return 1 ;; esac
}

security_native_rule_line() {
  local family="$1" row="$2" protocol ports source
  security_native_valid_row "$family" "$row" || return 1
  IFS='|' read -r protocol ports source <<<"$row"
  printf -- '-A INPUT -p %s -m %s --dport %s' "$protocol" "$protocol" "$ports"
  [[ "$source" == any ]] || printf ' -s %s' "$source"
  printf ' -m comment --comment keine-port_%s_%s_%s -j ACCEPT' "$protocol" "$ports" "$source"
}

security_native_rows() {
  local family="$1" mode="${2:-file}" line tag protocol ports source extra row
  local pattern='--comment "?keine-port_([^"[:space:]]+)"?([[:space:]]|$)'
  local -A seen=()
  while IFS= read -r line; do
    [[ "$line" == *keine-port_* ]] || continue
    [[ "$line" == '-A INPUT '* && "$line" =~ $pattern ]] || return 1
    tag="${BASH_REMATCH[1]}"
    IFS=_ read -r protocol ports source extra <<<"$tag"
    row="$protocol|$ports|$source"
    [[ -z "$extra" ]] && security_native_valid_row "$family" "$row" || return 1
    [[ -z "${seen[$row]:-}" ]] || return 1
    if [[ "$mode" == file && "$line" != "$(security_native_rule_line "$family" "$row")" ]]; then return 1; fi
    seen["$row"]=1
    printf '%s\n' "$row"
  done
}

security_native_rule_command() {
  local family="$1" action="$2" row="$3" command protocol ports source
  local arguments=()
  security_native_valid_row "$family" "$row" || return 1
  command="$(security_native_command "$family")" || return 1
  IFS='|' read -r protocol ports source <<<"$row"
  case "$action" in
    add) arguments=(-w 5 -I INPUT 1) ;;
    delete) arguments=(-w 5 -D INPUT) ;;
    check) arguments=(-w 5 -C INPUT) ;;
    *) return 1 ;;
  esac
  arguments+=(-p "$protocol" -m "$protocol" --dport "$ports")
  [[ "$source" == any ]] || arguments+=(-s "$source")
  arguments+=(-m comment --comment "keine-port_${protocol}_${ports}_${source}" -j ACCEPT)
  runtime_with_timeout 8 "$command" "${arguments[@]}"
}

security_native_live_rows() {
  local family="$1" command snapshot rows row
  command="$(security_native_command "$family")" || return 1
  snapshot="$(runtime_with_timeout 8 "$command" -w 5 -S INPUT 2>/dev/null)" || return 1
  rows="$(security_native_rows "$family" runtime <<<"$snapshot")" || return 1
  while IFS= read -r row; do
    [[ -z "$row" ]] || security_native_rule_command "$family" check "$row" >/dev/null 2>&1 || return 1
  done <<<"$rows"
  [[ -z "$rows" ]] || printf '%s\n' "$rows"
  return 0
}

security_native_render() {
  local family="$1" rows="$2" row block=""
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    block+="$(security_native_rule_line "$family" "$row")"$'\n' || return 1
  done <<<"$rows"
  # 只替换带归属标记的 INPUT 放行项，其余表、链、默认策略与规则逐行保留。
  awk -v block="$block" '
    $0=="*filter" {filters++; in_filter=1; inserted=0}
    in_filter && !inserted && ($0 ~ /^-A / || $0=="COMMIT") {
      printf "%s", block; inserted=1
    }
    index($0,"keine-port_") {next}
    {print}
    $0=="COMMIT" && in_filter {in_filter=0; commits++}
    END {if (filters!=1 || commits!=1) exit 1}
  '
}

security_native_sync() {
  local family="$1" expected="$2" current row index
  local added=()
  current="$(security_native_live_rows "$family")" || { warn "无法验证当前原生规则，停止修改。"; return 1; }
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    security_native_valid_row "$family" "$row" || return 1
    if ! grep -Fxq -- "$row" <<<"$current"; then added+=("$row"); fi
  done <<<"$expected"
  for ((index=${#added[@]}-1; index>=0; index--)); do
    security_native_rule_command "$family" add "${added[$index]}" || return 1
  done
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    if ! grep -Fxq -- "$row" <<<"$expected"; then security_native_rule_command "$family" delete "$row" || return 1; fi
  done <<<"$current"
  current="$(security_native_live_rows "$family")" || return 1
  [[ "$(LC_ALL=C sort <<<"$current")" == "$(LC_ALL=C sort <<<"$expected")" ]]
}

security_native_preflight() {
  local family="$1" command path entry
  require_root
  command="$(security_native_command "$family")" || return 1
  path="$(security_native_file "$family")"
  if ! command_exists "$command" || ! command_exists "$command-restore"; then warn "缺少 IPv$family 原生防火墙命令。"; return 1; fi
  if platform_firewall_active || platform_firewall_service_active firewalld.service || platform_firewall_service_active nftables.service; then
    warn "现有 UFW / firewalld / nftables 管理器正在接管规则，请使用对应入口。"; return 1
  fi
  if ! package_installed netfilter-persistent || ! systemctl is-enabled --quiet netfilter-persistent.service 2>/dev/null; then
    warn "需要已配置的 netfilter-persistent 开机加载服务；不自动替换现有防火墙。"; return 1
  fi
  if [[ ! -f "$path" ]] || ! config_file_safe "$path"; then warn "缺少安全的原生规则文件：$path"; return 1; fi
  security_native_rows "$family" <"$path" >/dev/null || { warn "托管规则被外部修改，请先核实。"; return 1; }
  entry="$(changes_file_entry "$path")"
  if [[ ! -d "$entry" ]] && grep -q 'keine-port_' "$path"; then
    warn "规则归属记录缺失，拒绝接管已有标记。"; return 1
  fi
  runtime_with_timeout 8 "$command-restore" --test -w 5 <"$path" || { warn "原生规则文件未通过语法检查。"; return 1; }
}

security_native_protect_removal() {
  local current="$1" expected="$2" row protocol ports source low high ssh_port
  local ssh_ports=()
  mapfile -t ssh_ports < <(platform_ssh_ports)
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    grep -Fxq -- "$row" <<<"$expected" && continue
    IFS='|' read -r protocol ports source <<<"$row"
    [[ "$protocol" == tcp ]] || continue
    low="${ports%%:*}"; high="${ports##*:}"
    for ssh_port in "${ssh_ports[@]}"; do
      if valid_port "$ssh_port" && (( 10#$ssh_port >= 10#$low && 10#$ssh_port <= 10#$high )); then
        warn "该规则覆盖当前 SSH 端口 $ssh_port，保留此规则。"; return 1
      fi
    done
  done <<<"$current"
}

# 回调使用调用方的局部事务上下文；config_file_write/restore 在同一调用栈的子 Shell 中执行。
security_native_apply_callback() {
  local command path rows
  command="$(security_native_command "$native_family")"
  path="$(security_native_file "$native_family")"
  rows="$(security_native_rows "$native_family" <"$path")" || return 1
  runtime_with_timeout 8 "$command-restore" --test -w 5 <"$path" || return 1
  security_native_sync "$native_family" "$rows"
}

security_native_rollback_callback() {
  security_native_sync "$native_family" "$native_previous"
}

security_native_lock() {
  local directory
  directory="$(dirname -- "$(security_native_file "$1")")"
  command_exists flock || { warn "缺少 flock，无法保护并发规则写入。"; return 1; }
  exec {native_lock_fd}<"$directory" || return 1
  flock -n "$native_lock_fd" || { warn "另一个 keine 防火墙操作尚未完成。"; return 1; }
}

security_native_write() (
  local native_family="$1" expected="$2" native_previous path content mode persisted native_lock_fd
  security_native_preflight "$native_family" || return 1
  security_native_lock "$native_family" || return 1
  path="$(security_native_file "$native_family")"
  native_previous="$(security_native_live_rows "$native_family")" || return 1
  persisted="$(security_native_rows "$native_family" <"$path")" || return 1
  if [[ "$(LC_ALL=C sort <<<"$native_previous")" != "$(LC_ALL=C sort <<<"$persisted")" ]]; then
    warn "托管运行规则与持久文件不一致，请先检查外部修改。"; return 1
  fi
  security_native_protect_removal "$native_previous" "$expected" || return 1
  content="$(security_native_render "$native_family" "$expected" <"$path")" || return 1
  mode="$(stat -c '%a' "$path")" || return 1
  config_file_write "$path" "$mode" "$content" security_native_apply_callback security_native_rollback_callback || return 1
  audit "action=native-firewall-write family=$native_family"
  if (( DRY_RUN == 1 )); then info "原生端口规则预览完成。"
  else ui_success "IPv$native_family 端口规则已保存并生效"; fi
)

security_native_restore() (
  local native_family="$1" native_previous path entry expected native_lock_fd persisted
  security_native_preflight "$native_family" || return 1
  security_native_lock "$native_family" || return 1
  path="$(security_native_file "$native_family")"
  entry="$(changes_file_entry "$path")"
  [[ -f "$entry/original" ]] || { warn "没有可恢复的原生规则基线。"; return 1; }
  expected="$(security_native_rows "$native_family" <"$entry/original")" || return 1
  native_previous="$(security_native_live_rows "$native_family")" || return 1
  persisted="$(security_native_rows "$native_family" <"$path")" || return 1
  if [[ "$(LC_ALL=C sort <<<"$native_previous")" != "$(LC_ALL=C sort <<<"$persisted")" ]]; then
    warn "托管运行规则被外部修改，停止恢复。"; return 1
  fi
  security_native_protect_removal "$native_previous" "$expected" || return 1
  config_file_restore "$path" security_native_apply_callback security_native_rollback_callback
)

security_native_add() {
  local family raw source rows spec protocol ports row choice
  ui_page "原生防火墙 / 放行端口"
  ui_action 4 "IPv4" action
  ui_action 6 "IPv6" action
  ui_menu_footer "取消"
  ui_read_choice choice "地址族" 4
  case "$choice" in 0) return 0 ;; 4|6) family="$choice" ;; *) warn "地址族无效。"; return 1 ;; esac
  security_native_preflight "$family" || return 1
  ui_hint "端口：443/tcp, 80/tcp, 10000:10100/udp"
  raw="$(read_input "放行端口" '443/tcp')"
  security_firewall_expand_specs "$raw" tcp >/dev/null || { warn "端口格式无效。"; return 1; }
  source="$(read_input "来源 IP / CIDR / any" any)"
  rows="$(security_native_rows "$family" <"$(security_native_file "$family")")" || return 1
  while IFS= read -r spec; do
    protocol="${spec##*/}"; ports="${spec%/*}"; row="$protocol|$ports|$source"
    security_native_valid_row "$family" "$row" || { warn "来源地址与 IPv$family 不匹配或格式无效。"; return 1; }
    grep -Fxq -- "$row" <<<"$rows" || rows="${row}${rows:+$'\n'$rows}"
  done < <(security_firewall_expand_specs "$raw" tcp)
  ui_kv "放行" "IPv$family · $source → $raw"
  ui_note "规则优先放行本机 INPUT；容器转发及云安全列表需另行配置。"
  confirm "添加并保存以上放行规则？" || return 0
  security_native_write "$family" "$rows"
}

security_native_delete() {
  local family path rows row index=0 choice selected expected protocol ports source
  local options=()
  ui_page "原生防火墙 / 删除托管规则"
  for family in 4 6; do
    path="$(security_native_file "$family")"
    [[ -r "$path" ]] || continue
    rows="$(security_native_rows "$family" <"$path")" || { warn "IPv$family 托管规则格式异常。"; return 1; }
    while IFS= read -r row; do
      [[ -n "$row" ]] || continue
      IFS='|' read -r protocol ports source <<<"$row"
      options+=("$family|$row"); index=$((index+1))
      ui_item "$index" "IPv$family · $ports/$protocol" "$source"
    done <<<"$rows"
  done
  (( index > 0 )) || { ui_empty "没有由 keine 添加的端口规则"; return 0; }
  ui_menu_footer "取消"
  ui_read_choice choice
  [[ "$choice" != 0 ]] || return 0
  if [[ ! "$choice" =~ ^[1-9][0-9]{0,3}$ ]] || (( choice > index )); then warn "编号无效。"; return 1; fi
  selected="${options[$((choice-1))]}"; family="${selected%%|*}"; row="${selected#*|}"
  path="$(security_native_file "$family")"
  expected="$(security_native_rows "$family" <"$path" | grep -Fxv -- "$row" || true)"
  confirm "删除 IPv$family 规则 ${row//|/ · }？" || return 0
  security_native_write "$family" "$expected"
}
