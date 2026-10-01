#!/usr/bin/env bash

changes_sysctl_key() {
  case "$1" in
    net.ipv4.tcp_congestion_control) printf bbr ;;
    net.core.default_qdisc) printf qdisc ;;
    net.ipv4.tcp_mtu_probing|net.ipv4.tcp_fastopen|net.ipv4.tcp_keepalive_time|net.ipv4.tcp_keepalive_intvl|net.ipv4.tcp_keepalive_probes|net.core.rmem_max|net.core.wmem_max)
      printf 'sysctl:%s' "$1" ;;
    *) return 1 ;;
  esac
}

changes_sysctl_arguments() {
  local verb="$1" arg key
  shift
  case "$verb" in
    -w)
      for arg in "$@"; do key="$(changes_sysctl_key "${arg%%=*}" || true)"; [[ -z "$key" ]] || printf '%s\n' "$key"; done
      ;;
    -p)
      [[ $# == 1 && -f "$1" && ! -L "$1" ]] || return 0
      while IFS= read -r arg; do
        [[ "$arg" != \#* && "$arg" == *=* ]] || continue
        arg="${arg%%=*}"; arg="${arg//[[:space:]]/}"
        key="$(changes_sysctl_key "$arg" || true)"; [[ -z "$key" ]] || printf '%s\n' "$key"
      done <"$1"
      ;;
    --system) printf 'bbr\nqdisc\n' ;;
  esac
}

changes_setting_value() {
  local key="$1" unit
  case "$key" in
    hostname) hostnamectl --static 2>/dev/null ;;
    timezone) timedatectl show -p Timezone --value 2>/dev/null ;;
    ntp) timedatectl show -p NTP --value 2>/dev/null ;;
    shell) getent passwd root | awk -F: '{print $7}' ;;
    bbr) sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null ;;
    qdisc) sysctl -n net.core.default_qdisc 2>/dev/null ;;
    sysctl:*) changes_sysctl_key "${key#sysctl:}" >/dev/null || return 1; sysctl -n "${key#sysctl:}" 2>/dev/null ;;
    warp) warp_connection_value ;;
    service:*)
      unit="${key#service:}"; valid_service_name "$unit" || return 1
      local enabled active
      enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
      [[ -n "$enabled" && "$enabled" != not-found ]] || return 1
      active=inactive; systemctl is-active --quiet "$unit" 2>/dev/null && active=active
      printf '%s|%s' "$enabled" "$active"
      ;;
    *) return 1 ;;
  esac
}

changes_setting_entry() {
  local key="$1" legacy
  [[ "$key" =~ ^[a-z]+(:[A-Za-z0-9@_.-]+)?$ ]] || return 1
  legacy="$(changes_root)/settings/$key"
  if [[ -d "$legacy" && ! -L "$legacy" ]]; then printf '%s' "$legacy"
  else printf '%s/settings/%s' "$(changes_root)" "${key//:/_}"; fi
}

changes_setting_key() {
  local entry="$1" key field
  [[ -d "$entry" && ! -L "$entry" ]] || return 1
  for field in before last; do [[ -f "$entry/$field" && ! -L "$entry/$field" ]] || return 1; done
  if [[ -f "$entry/key" && ! -L "$entry/key" ]]; then key="$(<"$entry/key")"
  else key="${entry##*/}"; fi
  [[ "$key" =~ ^[a-z]+(:[A-Za-z0-9@_.-]+)?$ ]] || return 1
  [[ "$(changes_setting_entry "$key")" == "$entry" ]] || return 1
  printf '%s' "$key"
}

changes_setting_prepare() {
  local key="$1" value entry
  changes_ready || return 0
  [[ "$key" =~ ^[a-z]+(:[A-Za-z0-9@_.-]+)?$ ]] || return 1
  value="$(changes_setting_value "$key")" || return 1
  changes_storage_ready || return 1
  entry="$(changes_setting_entry "$key")" || return 1
  if [[ -d "$entry" && ! -L "$entry" ]]; then
    [[ "$(changes_setting_key "$entry")" == "$key" ]] || return 1
    [[ "$value" == "$(<"$entry/last")" ]] || { warn "$key 在项目操作后被外部修改。"; return 1; }
  else
    [[ ! -e "$entry" && ! -L "$entry" ]] || return 1
    mkdir -- "$entry" && chmod 0700 "$entry" || return 1
    printf '%s\n' "$key" >"$entry/key"
    printf '%s\n' "$value" >"$entry/before"
    printf '%s\n' "$value" >"$entry/last"
  fi
}

changes_setting_commit() {
  local key="$1" entry value
  changes_ready || return 0
  entry="$(changes_setting_entry "$key")" || return 1
  [[ -d "$entry" && ! -L "$entry" ]] || return 0
  [[ "$(changes_setting_key "$entry")" == "$key" ]] || return 1
  value="$(changes_setting_value "$key")" || return 1
  printf '%s\n' "$value" >"$entry/last"
}

changes_before_command() {
  local command="$1" verb="${2:-}" arg path key
  changes_ready || return 0
  case "$command:$verb" in
    hostnamectl:set-hostname) changes_setting_prepare hostname ;;
    timedatectl:set-timezone) changes_setting_prepare timezone ;;
    timedatectl:set-ntp) changes_setting_prepare ntp ;;
    chsh:-s) changes_setting_prepare shell ;;
    systemctl:start|systemctl:stop|systemctl:restart|systemctl:enable|systemctl:disable)
      for arg in "${@:3}"; do
        if [[ "$arg" == *.service ]]; then changes_setting_prepare "service:$arg" || return 1; fi
      done
      ;;
    sysctl:--system|sysctl:-w|sysctl:-p)
      while IFS= read -r key; do changes_setting_prepare "$key" || return 1; done < <(changes_sysctl_arguments "$verb" "${@:3}")
      ;;
    ufw:*)
      case "$verb" in allow|deny|limit|default|enable|disable|delete|logging|--force)
        for path in /etc/ufw/ufw.conf /etc/ufw/user.rules /etc/ufw/user6.rules /etc/default/ufw; do changes_prepare_file "$path" || return 1; done
        ;;
      esac
      ;;
  esac
}

changes_after_command() {
  local command="$1" verb="${2:-}" arg key
  changes_ready || return 0
  case "$command:$verb" in
    hostnamectl:set-hostname) changes_setting_commit hostname ;;
    timedatectl:set-timezone) changes_setting_commit timezone ;;
    timedatectl:set-ntp) changes_setting_commit ntp ;;
    chsh:-s) changes_setting_commit shell ;;
    systemctl:start|systemctl:stop|systemctl:restart|systemctl:enable|systemctl:disable)
      for arg in "${@:3}"; do [[ "$arg" != *.service ]] || changes_setting_commit "service:$arg" || return 1; done
      ;;
    sysctl:--system|sysctl:-w|sysctl:-p)
      while IFS= read -r key; do changes_setting_commit "$key" || return 1; done < <(changes_sysctl_arguments "$verb" "${@:3}")
      ;;
  esac
}

changes_restore_setting() {
  local entry="$1" retain="${2:-0}" key before current unit enabled active
  [[ "$retain" == 0 || "$retain" == 1 ]] || return 1
  key="$(changes_setting_key "$entry")" || return 1
  before="$(<"$entry/before")"
  current="$(changes_setting_value "$key")" || return 1
  [[ "$current" == "$before" || "$current" == "$(<"$entry/last")" ]] || { warn "保留外部修改过的设置：$key"; return 1; }
  if [[ "$current" != "$before" ]]; then
    case "$key" in
      hostname) run hostnamectl set-hostname "$before" || return 1 ;;
      timezone) run timedatectl set-timezone "$before" || return 1 ;;
      ntp) [[ "$before" == yes || "$before" == no ]] && run timedatectl set-ntp "$before" || return 1 ;;
      shell) [[ "$before" == /* ]] && run chsh -s "$before" root || return 1 ;;
      bbr) [[ "$before" =~ ^[a-z0-9_]+$ ]] && run sysctl -w "net.ipv4.tcp_congestion_control=$before" || return 1 ;;
      qdisc) [[ "$before" =~ ^[a-z0-9_]+$ ]] && run sysctl -w "net.core.default_qdisc=$before" || return 1 ;;
      sysctl:*)
        changes_sysctl_key "${key#sysctl:}" >/dev/null || return 1
        [[ "$before" =~ ^[0-9]{1,10}$ ]] || return 1
        run sysctl -w "${key#sysctl:}=$before" || return 1
        ;;
      warp)
        case "$before" in connected) run warp-cli connect ;; disconnected) run warp-cli disconnect ;; *) return 1 ;; esac || return 1
        if (( DRY_RUN == 0 )); then
          local attempt
          for (( attempt=0; attempt<3; attempt++ )); do [[ "$(warp_connection_value || true)" != "$before" ]] || break; sleep 1; done
        fi
        ;;
      service:*)
        unit="${key#service:}"; valid_service_name "$unit" || return 1
        IFS='|' read -r enabled active <<<"$before"
        case "$enabled" in enabled) run systemctl enable "$unit" ;; disabled) run systemctl disable "$unit" ;; static|indirect|generated) : ;; *) return 1 ;; esac || return 1
        case "$active" in active) run systemctl start "$unit" ;; inactive|failed) run systemctl stop "$unit" ;; *) return 1 ;; esac || return 1
        ;;
    esac
    (( DRY_RUN == 1 )) || [[ "$(changes_setting_value "$key")" == "$before" ]] || return 1
  fi
  if (( DRY_RUN == 0 )) && [[ "$retain" == 0 ]]; then rm -rf -- "$entry"; fi
}
