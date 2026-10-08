#!/usr/bin/env bash

web_engine_guard() {
  local engine="$1" config start configured
  config="$(web_engine_config "$engine")" || return 1
  command_exists "$engine" || { warn "请先在软件中心安装 $engine。"; return 1; }
  web_path_valid "$config" && [[ -f "$config" ]] || { warn "主配置不可读取：$config"; return 1; }
  service_exists "$engine.service" || { warn "未发现原生 $engine.service；容器或自定义进程请使用原部署方式管理。"; return 1; }
  start="$(runtime_with_timeout 5 systemctl show "$engine.service" -p ExecStart --value 2>/dev/null)" || return 1
  [[ -n "$start" ]] || { warn "无法确认服务使用的配置。"; return 1; }
  if [[ "$engine" == caddy ]]; then
    [[ "$start" != *--resume* ]] || { warn "Caddy 使用 API 恢复模式，不能直接改写 Caddyfile。"; return 1; }
    if [[ "$start" =~ --config[=[:space:]]+([^[:space:];\}]+) ]]; then configured="${BASH_REMATCH[1]}"
    else warn "无法确认 Caddy 服务的配置路径。"; return 1; fi
    command_exists jq || { warn "Caddy 配置识别需要 jq，可在软件中心单项安装。"; return 1; }
  else
    [[ ! "$start" =~ [[:space:]]-p[[:space:]] ]] || { warn "Nginx 使用自定义 prefix；请用原配置流程管理。"; return 1; }
    if [[ "$start" =~ [[:space:]]-c[[:space:]]+([^[:space:];\}]+) ]]; then configured="${BASH_REMATCH[1]}"
    else
      configured="$(nginx -V 2>&1 | sed -n 's/.*--conf-path=\([^ ]*\).*/\1/p')"
      [[ -n "$configured" ]] || { warn "无法确认 Nginx 默认配置路径。"; return 1; }
    fi
  fi
  [[ "$configured" == "$config" ]] || {
    warn "服务实际使用 $configured；请设置 KEINE_${engine^^}_CONFIG 为该路径后重试。"; return 1;
  }
}

web_engine_dump() {
  local engine="$1" config
  config="$(web_engine_config "$engine")" || return 1
  case "$engine" in
    nginx) runtime_with_timeout 12 nginx -T -c "$config" 2>/dev/null ;;
    caddy) runtime_with_timeout 12 caddy adapt --config "$config" --adapter caddyfile 2>/dev/null ;;
  esac
}

web_nginx_inventory() {
  # nginx -T expands real includes. Only extract public routing fields, never dump the whole configuration.
  awk '
    /^# configuration file / {file=$0; sub(/^# configuration file /,"",file); sub(/:$/,"",file); next}
    /^[[:space:]]*#/ {next}
    {gsub(/[{};]/,"\n"); n=split($0,lines,"\n")
      for(i=1;i<=n;i++) {
        line=lines[i]; sub(/^[[:space:]]+/,"",line)
        if(line ~ /^(server_name|listen|proxy_pass|ssl_certificate)[[:space:]]/) {
          field=line; sub(/[[:space:]].*$/,"",field); sub(/^[^[:space:]]+[[:space:]]+/,"",line)
          sub(/[[:space:]]*#.*/,"",line); gsub(/[|\r\t]/," ",line); gsub(/[|\r\t]/," ",file)
          print file "|" field "|" line
        }
      }
    }'
}

web_domain_available() {
  local engine="$1" domain="$2" ignore="${3:-}" dump name source kind value names=()
  dump="$(web_engine_dump "$engine")" || { warn "现有配置无法解析，停止创建站点。"; return 1; }
  if [[ "$engine" == nginx ]]; then
    while IFS='|' read -r source kind value; do
      [[ "$kind" == server_name && "$source" != "$ignore" ]] || continue
      IFS=' ' read -r -a names <<<"$value"
      for name in "${names[@]}"; do
        name="${name,,}"
        name="${name#\"}"; name="${name%\"}"; name="${name#\'}"; name="${name%\'}"
        if [[ "$name" == "$domain" || "$name" == ".$domain" ]]; then
          warn "域名已存在于 $source。已有站点保留原配置，请勿重复创建。"; return 1
        fi
      done
    done < <(web_nginx_inventory <<<"$dump")
  elif [[ -z "$ignore" ]]; then
    while IFS= read -r name; do
      [[ "${name,,}" != "$domain" ]] || { warn "Caddy 已配置这个域名。"; return 1; }
    done < <(jq -r '.. | objects | .host? // empty | arrays | .[]' <<<"$dump")
  fi
}

web_engine_validate() {
  local engine="$1" config output result=0
  config="$(web_engine_config "$engine")" || return 1
  case "$engine" in
    nginx)
      output="$(runtime_with_timeout 15 nginx -t -c "$config" 2>&1)" || result=$?
      if (( result != 0 )); then printf '%s\n' "$output" >&2; return 1; fi
      if grep -qi 'conflicting server name' <<<"$output"; then warn "Nginx 存在重复域名，停止加载。"; return 1; fi
      ;;
    caddy)
      output="$(runtime_with_timeout 15 caddy validate --config "$config" --adapter caddyfile 2>&1)" || result=$?
      if (( result != 0 )); then printf '%s\n' "$output" >&2; return 1; fi
      ;;
  esac
  ui_check pass "$engine 配置检查通过"
}

web_engine_apply() {
  local engine="$WEB_APPLY_ENGINE"
  web_engine_validate "$engine" || return 1
  if systemctl is-active --quiet "$engine.service"; then
    run systemctl reload "$engine.service" || return 1
    systemctl is-active --quiet "$engine.service" || return 1
  fi
}

web_site_apply_callback() {
  local dump domain
  if [[ "$WEB_APPLY_ENABLED" == 1 ]]; then
    dump="$(web_engine_dump "$WEB_APPLY_ENGINE")" || return 1
    if [[ "$WEB_APPLY_ENGINE" == nginx ]]; then
      grep -Fxq "# configuration file $WEB_APPLY_PATH:" <<<"$dump" || {
        warn "主配置没有包含站点目录；未加载新站点。请检查 http 中的 include。"; return 1;
      }
    else
      domain="$(jq -r --arg domain "$WEB_APPLY_DOMAIN" '[.. | objects | .host? // empty | arrays | .[] | select(. == $domain)] | length' <<<"$dump")" || return 1
      [[ "$domain" != 0 ]] || { warn "Caddy 主配置没有加载新站点。"; return 1; }
    fi
  fi
  web_engine_apply
}

web_ports_check() {
  local engine="$1" tls="$2" port listeners
  command_exists ss || { warn "缺少 ss，无法检查监听冲突。"; return 1; }
  for port in 80 443; do
    [[ "$port" != 443 || "$tls" != http ]] || continue
    listeners="$(ss -H -ltnp "sport = :$port" 2>/dev/null)" || return 1
    [[ -n "$listeners" ]] || continue
    if grep -vF "\"$engine\"" <<<"$listeners" | grep -q .; then
      warn "$port 端口由其他进程占用；请先处理监听冲突。"; return 1
    fi
  done
  if [[ "$engine" == caddy && "$tls" != http ]]; then
    listeners="$(ss -H -lunp 'sport = :443' 2>/dev/null)" || return 1
    if [[ -n "$listeners" ]] && grep -vF '"caddy"' <<<"$listeners" | grep -q .; then
      warn "UDP 443 被其他进程占用，与 Caddy HTTP/3 监听冲突。"; return 1
    fi
  fi
}

web_endpoint_check() {
  local domain="$1" upstream="$2" addresses status
  ui_section "部署检查" primary
  addresses="$(runtime_with_timeout 5 getent ahosts "$domain" 2>/dev/null | awk '!seen[$1]++ {print $1}' || true)"
  if [[ -n "$addresses" ]]; then ui_kv "域名解析" "${addresses//$'\n'/ · }"
  else ui_check warn "尚未解析到地址；签发 HTTP 证书前需完成解析。"; fi
  if command_exists curl; then
    status="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 6 "$upstream/" 2>/dev/null)" || status=000
    if [[ "$status" != 000 ]]; then ui_kv "上游响应" "HTTP $status"
    else ui_check warn "上游暂不可达，或 HTTPS 校验失败。"; fi
  fi
  ui_hint "公网访问还取决于云端安全组与主机防火墙。"
}

web_existing_view() {
  local engine="$1" dump file kind value
  ui_page "$engine / 已有配置"
  dump="$(web_engine_dump "$engine")" || { warn "无法读取原生配置；请先检查主配置路径和语法。"; return 1; }
  ui_kv "主配置" "$(web_engine_config "$engine")"
  ui_note "已有配置只读识别；保留原文件、规则和证书管理方式。"
  if [[ "$engine" == nginx ]]; then
    while IFS='|' read -r file kind value; do
      ui_kv "$kind" "$(terminal_safe_text "$value")"
      [[ "$kind" != server_name ]] || ui_hint "$(terminal_safe_text "$file")"
    done < <(web_nginx_inventory <<<"$dump")
  else
    command_exists jq || { warn "请先安装 jq。"; return 1; }
    jq -r '.. | objects | select(has("host") or .handler? == "reverse_proxy") |
      if has("host") then "域名  " + (.host | join(", "))
      else "上游  " + ([.upstreams[]?.dial] | join(", ")) end' <<<"$dump" |
      while IFS= read -r value; do printf '  %s\n' "$(terminal_safe_text "$value")"; done
    ui_hint "Caddy import 已展开；复杂路由保持原生管理。"
  fi
}
