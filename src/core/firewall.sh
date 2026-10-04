#!/usr/bin/env bash

platform_cloud_provider() {
  local value="" path
  for path in /sys/class/dmi/id/chassis_asset_tag /run/cloud-init/cloud-id; do
    [[ ! -r "$path" ]] || value+="$(<"$path") "
  done
  case "${value,,}" in
    *oraclecloud.com*|oracle\ *|*\ oracle\ *) printf 'oracle' ;;
    *azure*) printf 'azure' ;;
    *aws*) printf 'aws' ;;
    *) printf 'unknown' ;;
  esac
}

platform_firewall_service_active() {
  command_exists systemctl && systemctl is-active --quiet "$1" 2>/dev/null
}

platform_ufw_preflight() {
  local backend
  if [[ "$(platform_cloud_provider)" == oracle ]]; then
    warn "Oracle Cloud 镜像保留原生防火墙；UFW 可能破坏启动卷通信规则。请使用安全中心的原生防火墙入口。"
    return 1
  fi
  if package_installed iptables-persistent || package_installed netfilter-persistent; then
    warn "UFW 与已安装的 iptables-persistent / netfilter-persistent 冲突；保留现有规则，请使用原生防火墙。"
    return 1
  fi
  if platform_firewall_service_active firewalld.service || platform_firewall_service_active nftables.service; then
    warn "系统已有 firewalld / nftables 服务管理规则，不能直接切换为 UFW。"
    return 1
  fi
  backend="$(platform_firewall_backend)"
  case "$backend" in
    iptables|nftables|firewalld) warn "检测到现有原生防火墙规则，请在主机防火墙入口管理，避免 UFW 覆盖。"; return 1 ;;
  esac
}

platform_firewall_backend() {
  if platform_firewall_active; then printf 'ufw'
  elif platform_firewall_service_active firewalld.service; then printf 'firewalld'
  elif platform_firewall_service_active nftables.service; then printf 'nftables'
  elif package_installed netfilter-persistent; then printf 'iptables'
  elif command_exists iptables && runtime_with_timeout 3 iptables -w 2 -S INPUT 2>/dev/null |
    grep -E '^(-A INPUT |-P INPUT (DROP|REJECT))' >/dev/null; then printf 'iptables'
  elif command_exists nft && runtime_with_timeout 3 nft list ruleset 2>/dev/null | grep 'hook input' >/dev/null; then printf 'nftables'
  elif command_exists ufw; then printf 'ufw-inactive'
  else printf 'unknown'; fi
}

platform_firewall_label() {
  case "$1" in
    ufw) printf 'UFW · 已启用' ;;
    iptables) printf 'iptables · 原生管理' ;;
    nftables) printf 'nftables · 原生规则' ;;
    firewalld) printf 'firewalld · 运行中' ;;
    ufw-inactive) printf 'UFW · 未启用' ;;
    *) printf '未确认' ;;
  esac
}

platform_ssh_ports() {
  local port connection="${SSH_CONNECTION:-}" settings=""
  if command_exists sshd; then settings="$(runtime_with_timeout 3 sshd -T 2>/dev/null || true)"; fi
  {
    awk '$1=="port" && $2 ~ /^[0-9]+$/ {print $2}' <<<"$settings"
    port="${connection##* }"
    if valid_port "$port"; then printf '%s\n' "$port"; fi
    detect_ssh_port
    printf '\n'
  } | sort -nu
}

platform_package_preflight() {
  local package
  for package in "$@"; do
    if [[ "$package" == ufw ]]; then platform_ufw_preflight || return 1; fi
  done
}
