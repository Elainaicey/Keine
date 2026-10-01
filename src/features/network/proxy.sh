#!/usr/bin/env bash

NETWORK_PROXY_FILE="${SERVER_TOOLKIT_PROXY_FILE:-/etc/server-toolkit-socks.conf}"

network_proxy_host_valid() {
  local host="${1:-}"
  if [[ "$host" == *:* ]]; then valid_ipv6_address "$host"
  elif [[ "$host" =~ ^[0-9.]+$ ]]; then valid_ipv4_address "$host"
  else
    [[ "$host" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$ && "$host" != *..* ]]
  fi
}

network_proxy_escape() {
  local value="$1"
  value="${value//\\/\\\\}"; value="${value//\"/\\\"}"
  printf '%s' "$value"
}

network_proxy_payload() {
  local host="$1" port="$2" mode="$3" username="${4:-}" password="${5:-}"
  local LC_ALL=C
  if ! network_proxy_host_valid "$host" || ! valid_port "$port"; then return 1; fi
  [[ "$mode" == socks5 || "$mode" == socks5h ]] || return 1
  [[ "$username" != *:* && "$username$password" != *[[:cntrl:]]* && ${#username} -le 255 && ${#password} -le 255 ]] || return 1
  [[ "$host" != *:* ]] || host="[$host]"
  printf '# Managed by Server Toolkit\nproxy = "%s://%s:%s"\n' "$mode" "$host" "$port"
  if [[ -n "$username" ]]; then printf 'proxy-user = "%s"\n' "$(network_proxy_escape "$username:$password")"; fi
  printf 'noproxy = "localhost,127.0.0.1,::1"\n'
}

network_proxy_content_valid() {
  # 只允许三项 curl 数据选项；不能通过篡改配置添加 URL、输出文件或执行功能。
  awk '
    /^#/ {next}
    {
      line=$0; key=line; sub(/[[:space:]]*=.*$/, "", key)
      if (key != "proxy" && key != "proxy-user" && key != "noproxy") {bad=1; next}
      if (seen[key]++) bad=1
      sub(/^[^=]*=[[:space:]]*/, "", line)
      if (substr(line,1,1) != "\"") {bad=1; next}
      escaped=0; closed=0
      for (i=2; i<=length(line); i++) {
        ch=substr(line,i,1)
        if (escaped) {if (ch != "\\" && ch != "\"") bad=1; escaped=0}
        else if (ch == "\\") escaped=1
        else if (ch == "\"") {if (i != length(line)) bad=1; closed=1; break}
      }
      if (!closed || escaped || line ~ /[[:cntrl:]]/) bad=1
      if (key == "proxy" && line !~ /^"socks5h?:\/\/(\[[0-9a-fA-F:]+\]|[a-zA-Z0-9.-]+):[0-9]+"$/) bad=1
    }
    END {exit (bad || !seen["proxy"])}
  '
}

network_proxy_config_valid() {
  [[ -f "$NETWORK_PROXY_FILE" && ! -L "$NETWORK_PROXY_FILE" ]] || return 1
  [[ "$(stat -c '%u' -- "$NETWORK_PROXY_FILE")" == 0 ]] || return 1
  local mode
  mode="$(stat -c '%a' -- "$NETWORK_PROXY_FILE")"
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 077) == 0 )) || return 1
  (( $(stat -c '%s' -- "$NETWORK_PROXY_FILE") <= 8192 )) || return 1
  network_proxy_content_valid <"$NETWORK_PROXY_FILE"
}

network_proxy_check() {
  local url="${1:-}" result
  require_root
  network_proxy_config_valid || { warn "代理配置缺失、权限不安全或包含非预期选项；请先重新配置。"; return 1; }
  command_exists curl || { warn "请先在软件中心安装 curl。"; return 1; }
  [[ -n "$url" ]] || url="$(read_input "验证 URL" "https://example.com")"
  valid_http_url "$url" || { warn "只接受不含凭据的 HTTP / HTTPS URL。"; return 1; }
  ui_page "SOCKS 出站验证" "显式使用保存的代理，不更改全机路由"
  if ! result="$(curl --disable --config "$NETWORK_PROXY_FILE" --noproxy '' --silent \
    --globoff --proto '=http,https' --proto-redir '=http,https' --head --location --max-redirs 5 \
    --connect-timeout 8 --max-time 25 --output /dev/null \
    --write-out 'HTTP %{http_code}\n耗时 %{time_total}s\n连接地址 %{remote_ip}\n' -- "$url" 2>/dev/null)"; then
    warn "代理请求失败；请检查地址、认证、DNS 模式与上游可达性。凭据和底层错误不会输出。"; return 1
  fi
  printf '%s\n' "$(terminal_safe_text "$result")"
  ui_note "收到 HTTP 响应仅说明代理请求完成；4xx / 5xx 是目标应用状态，连接地址不等于代理出口 IP。"
}

network_proxy_configure() {
  local host port choice mode=socks5h username password="" payload
  if [[ -e "$NETWORK_PROXY_FILE" ]] && ! grep -Fqx '# Managed by Server Toolkit' "$NETWORK_PROXY_FILE"; then
    warn "目标文件不属于项目，拒绝覆盖。"; return 1
  fi
  ui_page "SOCKS 出站配置" "连接已有 SOCKS5 代理；不开放服务、不修改系统路由"
  ui_hint "地址与端口分开填写，例如 127.0.0.1 / 1080；IPv6 地址不加方括号。"
  host="$(read_input "代理主机" "127.0.0.1")"; port="$(read_input "代理端口" "1080")"
  if ! network_proxy_host_valid "$host" || ! valid_port "$port"; then warn "代理地址或端口格式无效。"; return 1; fi
  ui_action 1 "代理端解析 DNS" "action" "socks5h；目标域名交给代理解析"
  ui_action 2 "本机解析 DNS" "action" "socks5；使用 VPS 当前系统解析器"
  choice="$(read_input "DNS 模式" "1")"
  case "$choice" in 1) ;; 2) mode=socks5 ;; *) warn "DNS 模式无效。"; return 1 ;; esac
  username="$(read_input "用户名；无需认证留空" "")"
  [[ -z "$username" ]] || password="$(network_read_secret "代理密码")" || return 1
  payload="$(network_proxy_payload "$host" "$port" "$mode" "$username" "$password")" || {
    warn "凭据不能包含控制字符，用户名不能含冒号；用户名与密码各不超过 255 字节。"; return 1;
  }
  ui_kv "代理地址" "$host:$port"; ui_kv "DNS 模式" "$mode"; ui_kv "认证" "$([[ -n "$username" ]] && printf '已设置，凭据隐藏' || printf '无需认证')"
  ui_hint "保存为 root 专用 curl 配置；不注入 ALL_PROXY、不影响 APT、SSH、Xray 或现有服务。SOCKS5 本身不加密，公网认证建议使用受信任隧道。"
  confirm "保存此 SOCKS 客户端配置？" || return 0
  network_config_write "$NETWORK_PROXY_FILE" 0600 "$payload" network_config_no_reload || return 1
  unset password payload
  audit 'action=network-socks-configure'
  ui_success "配置已保存；可通过 serverctl proxy-check URL 或 curl --config $NETWORK_PROXY_FILE URL 显式使用。"
}

network_proxy_menu() {
  local choice endpoint
  while true; do
    ui_page "SOCKS 出站代理" "已有代理的配置、验证、使用与撤销"
    endpoint="未配置"
    if [[ -r "$NETWORK_PROXY_FILE" ]]; then
      if network_proxy_config_valid; then endpoint="$(sed -n 's/^proxy = "\(.*\)"$/\1/p' "$NETWORK_PROXY_FILE" | head -n 1)"
      else endpoint="配置需检查，内容不显示"; fi
    fi
    ui_kv "代理端点" "$(terminal_safe_text "${endpoint:-配置需检查}")"
    ui_note "该配置仅在显式指定时使用；不创建后台进程，也不接管节点软件的出站配置。"
    ui_action 1 "配置 / 切换代理" "action" "主机、端口、认证与 DNS 位置"
    ui_action 2 "验证代理连接" "action" "一次 HTTP / HTTPS HEAD 请求"
    ui_action 3 "移除项目配置" "warning" "恢复首次修改前状态"
    ui_action 0 "返回" "muted"
    choice="$(read_input "请选择" "0")"
    case "$choice" in
      1) network_proxy_configure || true ;; 2) network_proxy_check || true ;;
      3) if confirm "移除项目 SOCKS 配置并恢复原始文件？"; then network_config_restore "$NETWORK_PROXY_FILE" network_config_no_reload && audit 'action=network-socks-restore'; fi ;;
      0) return 0 ;; *) warn "未知选项"; continue ;;
    esac
    pause
  done
}
