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

# Recognize only nft's standard pretty-printed Fail2ban input chain. Unknown
# chains, policies or rule shapes remain native; a table name alone proves nothing.
platform_nft_input_kind() {
  awk '
    BEGIN { depth=0; native=0; auxiliary=0; in_chain=0 }
    {
      line=$0; sub(/^[[:space:]]+/,"",line); sub(/[[:space:]]+$/,"",line)
      if (depth==0 && line ~ /^table /) {
        f2b_table=(line ~ /^table (inet|ip|ip6) f2b-table \{$/)
      }
      if (depth==1 && line ~ /^chain /) {
        in_chain=1; input=0; safe=1; header=0
        candidate=(f2b_table && line=="chain f2b-chain {")
      } else if (in_chain && depth==2 && line!="}") {
        if (line ~ /hook[[:space:]]+input([[:space:];]|$)/) {
          input=1; header++
          if (line !~ /^type filter hook input priority (filter - 1|-1); policy accept;$/) safe=0
        } else if (line!="") {
          # Only terminal source-set bans; no jumps, accept, NAT or broad deny.
          rule=line
          sub(/^(tcp|udp|sctp) dport ([0-9]+(-[0-9]+)?|\{[0-9,[:space:]-]+\}) /,"",rule)
          sub(/^meta l4proto (tcp|udp|sctp|\{[a-z,[:space:]]+\}) /,"",rule)
          if (rule !~ /^(ip|ip6) saddr @(addr-set-|addr6-set-)[a-zA-Z0-9_-]+ (drop|reject( with (icmp|icmpv6|icmpx) (type )?[a-z-]+)?)$/) safe=0
        }
      }
      # Strings/comments do not contribute structural braces.
      braces=line; gsub(/"([^"\\]|\\.)*"/,"",braces); sub(/#.*/,"",braces)
      opens=gsub(/\{/,"{",braces); closes=gsub(/\}/,"}",braces)
      next_depth=depth+opens-closes
      if (in_chain && next_depth==1) {
        if (input) {
          if (candidate && safe && header==1) auxiliary=1; else native=1
        }
        in_chain=0
      }
      if (!in_chain && line ~ /hook[[:space:]]+input/ && !(depth==2 && next_depth==1)) native=1
      depth=next_depth
    }
    END {
      if (depth!=0 || in_chain || native) print "native"
      else if (auxiliary) print "fail2ban"
      else print "none"
    }'
}

platform_firewall_backend() {
  local rules kind
  if platform_firewall_active; then printf 'ufw'; return
  elif platform_firewall_service_active firewalld.service; then printf 'firewalld'; return
  elif platform_firewall_service_active nftables.service; then printf 'nftables'; return
  elif package_installed netfilter-persistent; then printf 'iptables'; return
  elif command_exists iptables && runtime_with_timeout 3 iptables -w 2 -S INPUT 2>/dev/null |
    grep -E '^(-A INPUT |-P INPUT (DROP|REJECT))' >/dev/null; then printf 'iptables'; return; fi
  if command_exists nft; then
    if ! rules="$(runtime_with_timeout 3 nft list ruleset 2>/dev/null)"; then
      # A failed read must not become permission to enable a competing manager.
      printf 'nftables'; return
    fi
    kind="$(platform_nft_input_kind <<<"$rules")"
    if [[ "$kind" == native ]] || { [[ "$kind" == fail2ban ]] && ! platform_firewall_service_active fail2ban.service; }; then
      printf 'nftables'; return
    fi
  fi
  if command_exists ufw; then printf 'ufw-inactive'; else printf 'unknown'; fi
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
