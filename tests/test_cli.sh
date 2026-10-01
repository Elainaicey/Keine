#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
# shellcheck source=../bin/serverctl
. "$ROOT_DIR/bin/serverctl"

captured=""
identity_calls=0
platform_detect() { :; }
platform_detect_identity() { identity_calls=$((identity_calls + 1)); }
catalog_install() { captured="$1"; }
catalog_update() { captured="update:$1"; }
catalog_print() { captured="list:${1:-}"; }
software_catalog_menu() { captured="software-menu"; }
catalog_record() { [[ "$1" == "jq" ]] && printf 'jq|CLI|jq|JSON|jq|' ; }
catalog_item_menu() { captured="software:$1"; }
catalog_sources_view() { captured="sources"; }
catalog_official_updates_view() { captured="official-updates:$1"; }
security_exposure_analysis() { captured="exposure:$1"; }
toolkit_uninstall() { captured="uninstall"; }
toolkit_doctor() { captured="doctor"; }
system_triage() { captured="triage:$1"; }
system_package_health() { captured="updates:$1"; }
system_disk_usage() { captured="storage:$1"; }
service_exists() { return 0; }
services_logs() { captured="logs:$1"; }
services_select() { captured="service:$1"; }
services_apply_action() { captured="service:$1:$2"; }
services_journal_info() { captured="journal"; }
system_swap_manage() { captured="swap"; }
docker_compose_manage() { captured="compose:$1"; }
backups_delete_snapshot() { captured="backup-delete:$1"; }
backups_cleanup() { captured="backup-cleanup"; }
process_exists() { return 0; }
system_process_select() { captured="process:$1"; }
network_endpoint_probe() { captured="probe:$1:$2"; }
network_http_diagnose() { captured="http:$1"; }
network_path_trace() { captured="trace:$1"; }
network_interface_detail() { captured="interface:$1"; }
security_auth_activity() { captured="auth-activity:$1"; }
apps_service_detail() { captured="app:$1"; }

[[ "$(main --version)" == "Server Toolkit $SERVERCTL_VERSION" ]] || {
  printf 'FAIL: --version 标准选项输出错误\n' >&2
  exit 1
}

main install jq --dry-run
[[ "$captured" == "jq" && "$DRY_RUN" -eq 1 ]] || { printf 'FAIL: 单项安装参数解析错误\n' >&2; exit 1; }

main list python
[[ "$captured" == "list:python" ]] || { printf 'FAIL: list 参数解析错误\n' >&2; exit 1; }

main software
[[ "$captured" == "software-menu" ]] || { printf 'FAIL: software 没有进入软件中心\n' >&2; exit 1; }
main software jq
[[ "$captured" == "software:jq" ]] || { printf 'FAIL: software ID 没有进入软件详情\n' >&2; exit 1; }

main update jq
[[ "$captured" == "update:jq" ]] || { printf 'FAIL: update 参数解析错误\n' >&2; exit 1; }

main sources
[[ "$captured" == "sources" ]] || { printf 'FAIL: sources 命令没有进入来源浏览\n' >&2; exit 1; }

main official-updates
[[ "$captured" == "official-updates:0" ]] || { printf 'FAIL: official-updates 命令没有进入官方更新检查\n' >&2; exit 1; }

main exposure
[[ "$captured" == "exposure:0" ]] || { printf 'FAIL: exposure 命令没有进入公网暴露分析\n' >&2; exit 1; }

if (main install curl jq >/dev/null 2>&1); then
  printf 'FAIL: CLI 接受了多个软件 ID\n' >&2
  exit 1
fi

main doctor
[[ "$captured" == "doctor" ]] || { printf 'FAIL: doctor 命令没有进入运行环境与项目检查\n' >&2; exit 1; }

main triage
[[ "$captured" == "triage:0" ]] || { printf 'FAIL: triage 命令没有进入只读快速排查\n' >&2; exit 1; }

main updates
[[ "$captured" == "updates:0" ]] || { printf 'FAIL: updates 命令没有进入只读更新清单\n' >&2; exit 1; }

main storage
[[ "$captured" == "storage:0" ]] || { printf 'FAIL: storage 命令没有进入只读存储概览\n' >&2; exit 1; }

main swap
[[ "$captured" == "swap" ]] || { printf 'FAIL: swap 命令没有进入生命周期管理\n' >&2; exit 1; }

main process 1234
[[ "$captured" == "process:1234" ]] || { printf 'FAIL: process 命令没有进入进程详情\n' >&2; exit 1; }

if (main process '1;reboot' >/dev/null 2>&1); then
  printf 'FAIL: CLI 接受了危险 PID\n' >&2
  exit 1
fi

for removed_command in health toolkit-doctor users user timer; do
  if (main "$removed_command" >/dev/null 2>&1); then
    printf 'FAIL: 已精简命令仍可调用：%s\n' "$removed_command" >&2
    exit 1
  fi
done

main probe example.com 443
[[ "$captured" == "probe:example.com:443" ]] || { printf 'FAIL: probe 命令分发错误\n' >&2; exit 1; }

main http https://example.com/health
[[ "$captured" == "http:https://example.com/health" ]] || { printf 'FAIL: http 命令分发错误\n' >&2; exit 1; }

main trace example.com
[[ "$captured" == "trace:example.com" ]] || { printf 'FAIL: trace 命令分发错误\n' >&2; exit 1; }

main interface ens3
[[ "$captured" == "interface:ens3" ]] || { printf 'FAIL: interface 命令分发错误\n' >&2; exit 1; }

main auth-activity
[[ "$captured" == "auth-activity:24" ]] || { printf 'FAIL: auth-activity 命令分发错误\n' >&2; exit 1; }

identity_calls=0
main app nginx
[[ "$captured" == "app:nginx" && "$identity_calls" -eq 1 ]] || {
  printf 'FAIL: app 命令没有先初始化平台身份再进入应用详情\n' >&2
  exit 1
}

if (main app unknown-app >/dev/null 2>&1); then
  printf 'FAIL: app 命令接受了未知应用 ID\n' >&2
  exit 1
fi

if (main interface '../eth0' >/dev/null 2>&1); then
  printf 'FAIL: interface 命令接受了危险接口名\n' >&2
  exit 1
fi

main logs nginx.service
[[ "$captured" == "logs:nginx.service" ]] || { printf 'FAIL: logs 命令没有读取指定服务\n' >&2; exit 1; }

main service nginx.service
[[ "$captured" == "service:nginx.service" ]] || { printf 'FAIL: service 命令没有打开服务管理\n' >&2; exit 1; }

main service nginx.service restart
[[ "$captured" == "service:nginx.service:restart" ]] || { printf 'FAIL: service 生命周期动作分发错误\n' >&2; exit 1; }

main journal
[[ "$captured" == "journal" ]] || { printf 'FAIL: journal 命令没有进入日志管理\n' >&2; exit 1; }

main compose edge-proxy
[[ "$captured" == "compose:edge-proxy" ]] || { printf 'FAIL: compose 命令没有进入项目管理\n' >&2; exit 1; }

main backup-delete 20260723-120000-42
[[ "$captured" == "backup-delete:20260723-120000-42" ]] || { printf 'FAIL: backup-delete 命令没有删除指定快照\n' >&2; exit 1; }

main backup-cleanup
[[ "$captured" == "backup-cleanup" ]] || { printf 'FAIL: backup-cleanup 命令没有进入清理流程\n' >&2; exit 1; }

if (main backup-delete '../etc' >/dev/null 2>&1); then
  printf 'FAIL: backup-delete 接受了危险快照编号\n' >&2
  exit 1
fi

if (main logs '../nginx' >/dev/null 2>&1); then
  printf 'FAIL: logs 接受了危险服务名\n' >&2
  exit 1
fi

main uninstall
[[ "$captured" == "uninstall" ]] || { printf 'FAIL: uninstall 命令没有进入卸载流程\n' >&2; exit 1; }

printf 'PASS: cli\n'
