#!/usr/bin/env bash
# Callback context and associative site fields are shared with engine/model.
# shellcheck disable=SC2034,SC2030,SC2031

web_lock() {
  command_exists flock || { warn "缺少 flock。"; return 1; }
  changes_storage_ready || return 1
  local path
  path="$(changes_root)/web.lock"
  [[ ! -L "$path" ]] || return 1
  exec {WEB_LOCK_FD}>"$path" || return 1
  flock -n "$WEB_LOCK_FD" || { warn "另一个站点配置操作正在进行。"; return 1; }
}

web_site_owned() (
  local path="$1" expected entry
  web_site_load "$path" || return 1
  expected="$(web_site_render)" || return 1
  [[ "$(<"$path")" == "$expected" ]] || { warn "站点已被手动编辑，保留外部修改：$path"; return 1; }
  entry="$(changes_file_entry "$path")"
  [[ -d "$entry" ]] || { warn "该站点缺少恢复记录。"; return 1; }
  case "$(changes_file_status "$entry")" in ready|unchanged) ;; *) warn "站点存在外部修改冲突。"; return 1 ;; esac
)

web_managed_paths() {
  local engine="${1:-}" path name
  for name in nginx caddy; do
    [[ -z "$engine" || "$engine" == "$name" ]] || continue
    for path in "$(web_sites_dir "$name")"/keine-*; do
      [[ -f "$path" && ! -L "$path" ]] || continue
      if (web_site_load "$path"); then printf '%s\n' "$path"; fi
    done
  done
}

web_acme_prepare() {
  local root entry created=0
  root="$(web_acme_root)"; entry="$(changes_file_entry "$root")"
  web_path_valid "$root" && [[ "$(readlink -m -- "$root")" == "$root" ]] || return 1
  if [[ ! -e "$root" ]]; then
    changes_prepare_file "$root" directory || return 1
    mkdir -p -- "$root" || return 1; chmod 0755 "$root" || return 1
    created=1
  fi
  [[ -d "$root" && ! -L "$root" ]] || return 1
  [[ "$(readlink -m -- "$root/.well-known/acme-challenge")" == "$root/.well-known/acme-challenge" ]] || return 1
  # Certbot may already have used the directory. Only record our explicitly created tree.
  if [[ -d "$entry" ]]; then changes_prepare_file "$root" directory || return 1; fi
  mkdir -p -- "$root/.well-known/acme-challenge" || return 1
  if (( created == 1 )); then chmod 0755 "$root/.well-known" "$root/.well-known/acme-challenge" || return 1; fi
  changes_commit_pending
}

web_caddy_import_ensure() {
  local config directory content mode
  config="$(web_engine_config caddy)"; directory="$(web_sites_dir caddy)"
  web_path_valid "$directory" && config_file_safe "$config" || return 1
  [[ "$(readlink -m -- "$directory")" == "$directory" ]] || return 1
  if [[ ! -d "$directory" ]]; then mkdir -p -- "$directory" && chmod 0755 "$directory" || return 1; fi
  grep -Fqx "import $directory/*.caddy" "$config" && return 0
  content="$(<"$config")"$'\n\n'"# keine reverse proxies"$'\n'"import $directory/*.caddy"
  mode="$(stat -c %a "$config")"
  config_file_write "$config" "$mode" "$content" web_engine_apply
}

web_caddy_import_cleanup() {
  local config path
  while IFS= read -r path; do [[ -z "$path" ]] || return 0; done < <(web_managed_paths caddy)
  if [[ -d "$(web_sites_dir caddy)" ]] && [[ -n "$(find "$(web_sites_dir caddy)" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    ui_note "Caddy 站点目录仍有其他文件，保留 import。"; return 0
  fi
  config="$(web_engine_config caddy)"
  if [[ -d "$(changes_file_entry "$config")" ]]; then
    config_file_restore "$config" web_engine_apply || return 1
  fi
  rmdir -- "$(web_sites_dir caddy)" 2>/dev/null || true
}

web_site_write() (
  web_site_values_valid || { warn "站点参数无效。"; return 1; }
  local engine="${WEB_SITE[engine]}" path payload existing=0 import_present=0 directory
  local WEB_APPLY_ENGINE="$engine" WEB_APPLY_PATH WEB_APPLY_ENABLED="${WEB_SITE[enabled]}" WEB_APPLY_DOMAIN="${WEB_SITE[domain]}"
  path="$(web_site_path "$engine" "${WEB_SITE[domain]}")"; WEB_APPLY_PATH="$path"
  web_path_valid "$path" && config_file_safe "$path" || return 1
  require_root
  web_engine_guard "$engine" || return 1
  if [[ -e "$path" ]]; then web_site_owned "$path" || return 1; existing=1; fi
  web_domain_available "$engine" "${WEB_SITE[domain]}" "$([[ "$existing" == 1 ]] && printf '%s' "$path")" || return 1
  if [[ "${WEB_SITE[enabled]}" == 1 ]]; then
    web_ports_check "$engine" "${WEB_SITE[tls]}" || return 1
    if [[ "${WEB_SITE[tls]}" == pem ]]; then
      web_certificate_pair_valid "${WEB_SITE[domain]}" "${WEB_SITE[cert]}" "${WEB_SITE[key]}" || return 1
      if [[ "$engine" == caddy ]]; then
        local user
        user="$(systemctl show caddy.service -p User --value)" || return 1
        if [[ -n "$user" && "$user" != root ]]; then
          if ! runuser -u "$user" -- test -r "${WEB_SITE[cert]}" || ! runuser -u "$user" -- test -r "${WEB_SITE[key]}"; then
            warn "Caddy 服务用户无法读取证书；请使用 Caddy 自动 HTTPS，或提供该用户可读的独立证书文件。"; return 1
          fi
        fi
      fi
    fi
  fi
  payload="$(web_site_render)" || return 1
  (( DRY_RUN == 0 )) || { info "将生成并验证 $path；预览不写入站点、不申请证书。"; return 0; }
  changes_ready || return 1
  web_lock || return 1
  # Recheck after taking the lock; another process may have created the file.
  if [[ -e "$path" ]]; then
    (( existing == 1 )) || { warn "站点刚被其他操作创建，请刷新后重试。"; return 1; }
    web_site_owned "$path" || return 1
  fi
  if [[ "$engine" == caddy ]]; then
    grep -Fqx "import $(web_sites_dir caddy)/*.caddy" "$(web_engine_config caddy)" && import_present=1
    web_caddy_import_ensure || return 1
  else web_acme_prepare || return 1; fi
  directory="$(dirname -- "$path")"
  mkdir -p -- "$directory" || return 1
  if ! config_file_write "$path" 0644 "$payload" web_site_apply_callback web_engine_apply; then
    if [[ "$engine" == caddy && "$import_present" == 0 ]]; then web_caddy_import_cleanup || true; fi
    return 1
  fi
  audit "action=web-site-write engine=$engine domain=${WEB_SITE[domain]} enabled=${WEB_SITE[enabled]} tls=${WEB_SITE[tls]}"
  if systemctl is-active --quiet "$engine.service"; then ui_success "站点配置已验证并加载"
  else ui_note "配置已保存并通过检查；$engine 尚未启动。"; fi
)

web_site_restore() (
  local path="$1" engine
  web_site_load "$path" && web_site_owned "$path" || return 1
  engine="${WEB_SITE[engine]}"
  local WEB_APPLY_ENGINE="$engine"
  require_root
  web_engine_guard "$engine" || return 1
  (( DRY_RUN == 1 )) || web_lock || return 1
  config_file_restore "$path" web_engine_apply || return 1
  (( DRY_RUN == 0 )) || return 0
  if [[ "$engine" == caddy ]]; then web_caddy_import_cleanup || return 1; fi
  ui_success "站点已移除，证书和上游应用保留"
)

web_recovery_handles() {
  local path="$1"
  [[ "$path" == "$(web_sites_dir nginx)"/keine-*.conf ||
    "$path" == "$(web_sites_dir caddy)"/keine-*.caddy || "$path" == "$(web_engine_config caddy)" ]]
}

web_recovery_restore() (
  local path="$1" WEB_APPLY_ENGINE
  case "$path" in
    "$(web_sites_dir nginx)"/keine-*.conf) WEB_APPLY_ENGINE=nginx ;;
    *) WEB_APPLY_ENGINE=caddy ;;
  esac
  web_engine_guard "$WEB_APPLY_ENGINE" || return 1
  config_file_restore "$path" web_engine_apply
)

web_site_deploy_certificate() {
  local path="$1" cert="$2" key="$3"
  web_site_load "$path" && web_site_owned "$path" || return 1
  WEB_SITE[tls]=pem; WEB_SITE[cert]="$cert"; WEB_SITE[key]="$key"
  web_site_write
}

web_certificate_references() {
  local directory="${1%/*}" engine dump path
  # Managed disabled sites also retain references, so later activation remains valid.
  while IFS= read -r path; do
    if grep -Fq -- "$directory/" "$path"; then printf '%s\n' "$path"; fi
  done < <(web_managed_paths)
  for engine in nginx caddy; do
    command_exists "$engine" || continue
    dump="$(web_engine_dump "$engine")" || { warn "无法确认 $engine 的证书引用，停止删除。"; return 1; }
    if grep -Fq -- "$directory/" <<<"$dump"; then printf '%s 原生配置\n' "$engine"; fi
  done
}

web_reload_certificate_users() (
  local cert="$1" path engine failed=0
  local -A engines=()
  while IFS= read -r path; do
    web_site_load "$path" || continue
    [[ "${WEB_SITE[enabled]}" == 1 && "${WEB_SITE[cert]}" == "$cert" ]] || continue
    engines["${WEB_SITE[engine]}"]=1
  done < <(web_managed_paths)
  for engine in "${!engines[@]}"; do
    local WEB_APPLY_ENGINE="$engine"
    if ! web_engine_guard "$engine" || ! web_engine_apply; then
      warn "证书已更新，但 $engine 未能加载，请检查配置。"; failed=1
    fi
  done
  (( failed == 0 ))
)
