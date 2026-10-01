#!/usr/bin/env bash

network_http_metric() {
  local snapshot="$1" name="$2" line value
  [[ "$name" =~ ^[a-z_]+$ ]] || return 1
  while IFS= read -r line; do
    if [[ "$line" == "$name="* ]]; then
      value="${line#*=}"
      value="${value%$'\r'}"
      printf '%s' "$value"
      return 0
    fi
  done <<<"$snapshot"
  return 1
}

network_http_milliseconds() {
  local seconds="${1:-0}"
  awk -v value="$seconds" 'BEGIN { if (value ~ /^[0-9]+([.][0-9]+)?$/) printf "%.0f ms", value * 1000; else printf "—" }'
}

network_http_status_style() {
  local status="${1:-0}"
  if [[ "$status" =~ ^2[0-9][0-9]$ || "$status" =~ ^3[0-9][0-9]$ ]]; then
    printf 'good'
  elif [[ "$status" =~ ^4[0-9][0-9]$ ]]; then
    printf 'warn'
  else
    printf 'bad'
  fi
}

network_http_cleanup() {
  local header_file="$1" error_file="$2" temp_dir="$3"
  [[ -z "$header_file" ]] || rm -f -- "$header_file"
  [[ -z "$error_file" ]] || rm -f -- "$error_file"
  [[ -z "$temp_dir" || ! -d "$temp_dir" || -L "$temp_dir" ]] || rmdir -- "$temp_dir" 2>/dev/null || true
}

network_http_diagnose() (
  local url="${1:-}" metrics="" error_file="" header_file="" temp_dir="" curl_status=0
  local status effective remote_ip remote_port local_ip http_version redirects
  local dns_time connect_time tls_time first_byte_time total_time verify_result status_style scheme request_scheme downgraded=0
  if [[ -z "$url" ]]; then
    ui_hint "输入完整 http:// 或 https:// URL；最多跟随 8 次同协议族重定向。"
    url="$(read_input "URL" "https://github.com")"
  fi
  valid_http_url "$url" || { warn "URL 必须使用 http:// 或 https://，且不能包含凭据、空白或控制字符。"; return 1; }
  command_exists curl || { warn "未安装 curl，可先在软件中心安装。"; return 1; }
  temp_dir="$(mktemp -d)" || { warn "无法创建 HTTP 诊断临时目录。"; return 1; }
  header_file="$temp_dir/headers"
  error_file="$temp_dir/curl-error"
  trap 'network_http_cleanup "$header_file" "$error_file" "$temp_dir"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  request_scheme="${url%%://*}"
  request_scheme="${request_scheme,,}"
  if metrics="$(curl --disable --silent --show-error --globoff \
    --proto '=http,https' --proto-redir '=http,https' \
    --disallow-username-in-url \
    --location --max-redirs 8 --connect-timeout 5 --max-time 20 \
    --head \
    --user-agent "Server-Toolkit/$KEINE_VERSION" \
    --output /dev/null --dump-header "$header_file" \
    --write-out $'http_code=%{http_code}\nurl_effective=%{url_effective}\nremote_ip=%{remote_ip}\nremote_port=%{remote_port}\nlocal_ip=%{local_ip}\nhttp_version=%{http_version}\nnum_redirects=%{num_redirects}\ntime_namelookup=%{time_namelookup}\ntime_connect=%{time_connect}\ntime_appconnect=%{time_appconnect}\ntime_starttransfer=%{time_starttransfer}\ntime_total=%{time_total}\nssl_verify_result=%{ssl_verify_result}\n' \
    -- "$url" 2>"$error_file")"; then
    curl_status=0
  else
    curl_status=$?
  fi

  status="$(network_http_metric "$metrics" http_code 2>/dev/null || printf '000')"
  effective="$(network_http_metric "$metrics" url_effective 2>/dev/null || printf '%s' "$url")"
  remote_ip="$(network_http_metric "$metrics" remote_ip 2>/dev/null || true)"
  remote_port="$(network_http_metric "$metrics" remote_port 2>/dev/null || true)"
  local_ip="$(network_http_metric "$metrics" local_ip 2>/dev/null || true)"
  http_version="$(network_http_metric "$metrics" http_version 2>/dev/null || true)"
  redirects="$(network_http_metric "$metrics" num_redirects 2>/dev/null || printf '0')"
  dns_time="$(network_http_metric "$metrics" time_namelookup 2>/dev/null || printf '0')"
  connect_time="$(network_http_metric "$metrics" time_connect 2>/dev/null || printf '0')"
  tls_time="$(network_http_metric "$metrics" time_appconnect 2>/dev/null || printf '0')"
  first_byte_time="$(network_http_metric "$metrics" time_starttransfer 2>/dev/null || printf '0')"
  total_time="$(network_http_metric "$metrics" time_total 2>/dev/null || printf '0')"
  verify_result="$(network_http_metric "$metrics" ssl_verify_result 2>/dev/null || printf '0')"
  status_style="$(network_http_status_style "$status")"
  scheme="${effective%%://*}"
  scheme="${scheme,,}"
  if [[ "$request_scheme" == "https" && "$scheme" == "http" ]]; then
    downgraded=1
    status_style="warn"
  fi

  ui_page "HTTP / HTTPS 诊断" "HEAD 单次请求 · 不下载响应体 · 不保存 Cookie"
  ui_panel_begin "响应"
  ui_panel_kv "请求 URL" "$(terminal_safe_text "$url")"
  ui_panel_kv "最终 URL" "$(terminal_safe_text "$effective")" "$CYAN"
  ui_panel_kv "HTTP 状态" "$status" "$(ui_color_for_state "$status_style")"
  ui_panel_kv "协议" "HTTP/${http_version:-未知}"
  ui_panel_kv "重定向" "${redirects:-0} 次"
  ui_panel_kv "远端" "${remote_ip:-未知}:${remote_port:-未知}"
  ui_panel_kv "本地地址" "${local_ip:-未知}"
  ui_panel_kv "响应体" "不下载（HEAD）" "$MUTED"
  if (( downgraded == 1 )); then
    ui_panel_kv "TLS 校验" "重定向后降级为 HTTP" "$RED"
  elif [[ "$scheme" == "https" ]]; then
    if [[ "$verify_result" == "0" ]]; then
      ui_panel_kv "TLS 校验" "通过" "$GREEN"
    else
      ui_panel_kv "TLS 校验" "失败 · code $verify_result" "$RED"
    fi
  else
    ui_panel_kv "TLS 校验" "不适用（HTTP）" "$MUTED"
  fi
  ui_panel_end
  ui_metric_row \
    "DNS" "$(network_http_milliseconds "$dns_time")" "primary" \
    "连接" "$(network_http_milliseconds "$connect_time")" "primary" \
    "首字节" "$(network_http_milliseconds "$first_byte_time")" "primary"
  if [[ "$scheme" == "https" ]]; then
    ui_kv "TLS 握手" "$(network_http_milliseconds "$tls_time")"
  else
    ui_kv "TLS 握手" "不适用（最终为 HTTP）" "$MUTED"
  fi
  ui_kv "总耗时" "$(network_http_milliseconds "$total_time")"

  ui_section "响应链" "accent"
  if [[ -s "$header_file" ]]; then
    grep -Ei '^(HTTP/|location:|server:|content-type:)' "$header_file" 2>/dev/null |
      sed -n '1,32p' | while IFS= read -r line; do printf '  %s\n' "$(terminal_safe_text "$line")"; done || true
  else
    ui_empty "没有收到响应头"
  fi
  if [[ "$status" == "000" ]]; then
    ui_callout bad "请求未建立有效 HTTP 响应" "$(terminal_safe_text "$(sed -n '1p' "$error_file")")"
  elif (( curl_status != 0 )); then
    ui_callout warn "已收到 HTTP $status，但传输未完整结束" "请求可能触发超时、协议限制或重定向边界。"
  elif (( downgraded == 1 )); then
    ui_callout warn "端点从 HTTPS 降级到 HTTP" "最终响应未受到 TLS 保护，请核实重定向配置。"
  elif [[ "$status" == "405" || "$status" == "501" ]]; then
    ui_callout warn "端点不支持 HEAD 请求" "该结果不表示普通 GET 请求不可用，请结合应用接口行为核实。"
  elif [[ "$status_style" == "good" ]]; then
    ui_callout good "端点返回 HTTP $status" "请结合业务预期判断重定向和响应时间。"
  else
    ui_callout warn "端点返回 HTTP $status" "网络与 TLS 可能正常，但应用层状态需要继续核实。"
  fi
  [[ "$status" != "000" ]]
)
