#!/usr/bin/env bash
# 测试替身与目录变量由随后 source 的 catalog 模块间接使用。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
SOFTWARE_CATALOG="$CONFIG_DIR/software.tsv"
CATALOG_TEST_ROOT="$(mktemp -d)"
trap '[[ "$CATALOG_TEST_ROOT" == /tmp/* ]] && rm -rf -- "$CATALOG_TEST_ROOT"' EXIT
KEINE_APT_SOURCES_DIR="$CATALOG_TEST_ROOT/sources"
KEINE_APT_KEYRING_DIR="$CATALOG_TEST_ROOT/keyrings"
KEINE_SHARE_KEYRING_DIR="$CATALOG_TEST_ROOT/share-keyrings"
OS_ID=debian
OS_NAME='Debian test'
OS_CODENAME=bookworm
ARCH=amd64

# shellcheck source=../src/core/runtime.sh
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/ui.sh"
runtime_colors
. "$ROOT_DIR/src/features/software.sh"

package_installed() { return 1; }
package_installed_version() { :; }
package_candidate_version() { printf '1.0.0'; }
package_has_update() { return 1; }
command_exists() { return 1; }
software_oh_my_zsh_installed() { return 1; }
software_oh_my_zsh_version() { :; }
software_prompt_installed() { return 1; }
software_prompt_version() { :; }
software_release_managed() { return 1; }
software_release_installed() { return 1; }
software_release_integrity() { return 1; }
software_release_supported() { return 0; }
software_release_version() { :; }
software_release_homepage() { printf 'https://example.com'; }
software_release_repository() { printf 'owner/repo'; }
software_release_target() { printf '/usr/local/bin/example'; }
software_release_latest_invalidate() { :; }
software_release_command() { printf example; }
software_target_user() { printf 'tester'; }
software_target_home() { printf '/home/tester'; }
software_oh_my_zsh_path() { printf '/home/tester/.oh-my-zsh'; }
# shellcheck source=../src/features/software/catalog.sh
. "$ROOT_DIR/src/features/software/catalog.sh"

record="$(catalog_record python-venv)"
IFS='|' read -r id _category _name _description packages handler <<<"$record"
[[ "$id" == "python-venv" && "$packages" == "python3-venv" && -z "$handler" ]] || die "python-venv 映射错误"

record="$(catalog_record podman)"
IFS='|' read -r id category _name _description packages handler <<<"$record"
[[ "$id" == "podman" && "$category" == "容器工具" && "$packages" == "podman" && -z "$handler" ]] || die "podman 映射错误"

catalog_total="$(catalog_rows | wc -l | tr -d '[:space:]')"
(( catalog_total > 0 )) || die "软件目录为空"
if catalog_record oh-my-zsh >/dev/null; then die "终端框架仍混入软件目录"; fi

record="$(catalog_record ripgrep)"
IFS='|' read -r id category _name _description packages handler <<<"$record"
[[ "$id" == "ripgrep" && "$category" == "文本与搜索" && "$packages" == "ripgrep" &&
  "$handler" == "official_release" ]] || die "ripgrep 官方 Release 映射错误"

[[ -z "$(catalog_category_rows 网络诊断 | awk -F '|' '$2 != "网络诊断" {print}')" ]] || die "分类查询返回了其他分类"
grep -Eq '^系统基础\|[0-9]+$' < <(catalog_categories) || die "分类统计缺少基础分类"

duplicates="$(catalog_rows | awk -F '|' '{count[$1]++} END {for (id in count) if (count[id] > 1) print id}')"
[[ -z "$duplicates" ]] || die "存在重复 ID：$duplicates"

[[ "$(catalog_effect_label docker)" == "后台服务" ]] || die "Docker 运行形态标签错误"
effect_summary="$(catalog_effect_summary docker)"
[[ "$effect_summary" == *"本地 Socket"* && "$effect_summary" == *"docker.service"* ]] ||
  die "Docker 运行影响摘要不完整：$effect_summary"
catalog_effect_has_persistent_impact docker || die "没有识别 Docker 的持久运行影响"
if catalog_effect_has_persistent_impact jq; then
  die "无后台元数据的软件被错误标记为持久运行"
fi
catalog_effect_has_persistent_impact lynis || die "Lynis 定时审计影响未声明"
catalog_effect_has_persistent_impact postgresql-contrib || die "PostgreSQL 扩展的服务依赖影响未声明"

while IFS='|' read -r id category name description packages handler; do
  [[ "$id" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "无效 ID：$id"
  [[ -n "$category" && -n "$name" && -n "$description" ]] || die "目录字段为空：$id"
  case "$handler" in
    "") [[ -n "$packages" && "$packages" != *' '* ]] || die "普通软件必须精确映射一个包：$id" ;;
    docker_official|caddy_official|oh_my_zsh|starship_prompt|oh_my_posh_prompt|spaceship_prompt) [[ -z "$packages" ]] || die "专用安装器不应同时声明包：$id" ;;
    official_release) software_release_record="$(awk -F '|' -v wanted="$id" '!/^#/ && $1 == wanted {print}' "$CONFIG_DIR/official-releases.tsv")"; [[ -n "$software_release_record" ]] || die "缺少官方 Release 元数据：$id" ;;
    *) die "未知安装器：$id -> $handler" ;;
  esac
done < <(catalog_rows)

release_total=0
while IFS='|' read -r id repository command amd64_asset arm64_asset homepage; do
  [[ "$id" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "无效 Release ID：$id"
  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "无效 GitHub 仓库：$id"
  [[ "$command" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "无效 Release 命令：$id"
  [[ "$amd64_asset" == *.tar.gz && "$arm64_asset" == *.tar.gz ]] || die "Release 资产格式无效：$id"
  [[ "$homepage" == "https://github.com/$repository" ]] || die "Release 项目主页与仓库不一致：$id"
  record="$(catalog_record "$id")" || die "Release 元数据没有软件条目：$id"
  IFS='|' read -r _ _ _ _ _ handler <<<"$record"
  [[ "$handler" == "official_release" ]] || die "Release 元数据没有使用专用 handler：$id"
  release_total=$((release_total + 1))
done < <(awk -F '|' '!/^#/ && NF == 6' "$CONFIG_DIR/official-releases.tsv")
(( release_total > 0 )) || die "官方 Release 目录为空"

package_candidate_version() { if [[ "$1" == "jq" ]]; then printf '(none)'; else printf '1.0.0'; fi; }
record="$(catalog_record jq)"
[[ "$(catalog_state "$record")" == "index-needed" ]] || die "未刷新的索引被误报为仓库不可用"
PACKAGE_INDEX_UPDATED=1
[[ "$(catalog_state "$record")" == "unavailable" ]] || die "刷新后仍无候选版本没有明确显示"
PACKAGE_INDEX_UPDATED=0
package_candidate_version() { printf '1.0.0'; }

grep -q '^certbot-nginx|' < <(catalog_rows python3-certbot-nginx) || die "搜索不支持真实包名"
grep -q '^certbot-nginx|' < <(catalog_rows https) || die "HTTPS 搜索缺少 Certbot 插件"
guide_total=0
while IFS='|' read -r guide_id heading related boundary hint documentation; do
  catalog_record "$guide_id" >/dev/null || die "指南引用了不存在的软件：$guide_id"
  [[ -n "$heading" && -n "$boundary" && -n "$hint" && "$documentation" == https://* ]] || die "软件指南字段不完整"
  IFS=',' read -r -a related_ids <<<"$related"
  for related_id in "${related_ids[@]}"; do catalog_record "$related_id" >/dev/null || die "指南关联 ID 不存在：$related_id"; done
  guide_total=$((guide_total + 1))
done < <(awk -F '|' '!/^#/ && NF == 6' "$CONFIG_DIR/software-guides.tsv")
(( guide_total > 0 )) || die "软件指南为空"

record="$(catalog_record docker)"
package_candidate_version() { [[ "$1" == "docker-ce" ]] && printf '(none)' || printf '1.0.0'; }
[[ "$(catalog_state "$record")" == "setup" ]] || die "未配置的 Docker 官方仓库没有标记为待配置"
[[ "$(catalog_candidate_version "$record")" == "安装时获取官方稳定版" ]] || die "Docker 安装前候选版本提示不正确"
package_candidate_version() { printf '1.0.0'; }


captured=""
operation_events=""
installed_state=0
confirm() { operation_events+="confirm>"; return 0; }
require_root() { operation_events+="root>"; }
audit() { :; }
catalog_installed() { [[ "$installed_state" -eq 1 ]]; }
catalog_installed_version() { printf '1.0.0'; }
package_invalidate_index() { operation_events+="invalidate>"; }
package_update_index() { operation_events+="refresh>"; }
catalog_apt_plan_render() { operation_events+="plan>"; }
package_install_latest() { operation_events+="install>"; captured="package:$1"; installed_state=1; }
software_install_docker() { captured="handler:docker"; installed_state=1; }
software_install_caddy() { captured="handler:caddy"; installed_state=1; }
software_install_oh_my_zsh() { captured="handler:oh-my-zsh"; installed_state=1; }
software_install_starship() { captured="handler:starship"; installed_state=1; }
software_install_oh_my_posh() { captured="handler:oh-my-posh"; installed_state=1; }
software_install_spaceship() { captured="handler:spaceship"; installed_state=1; }
software_install_release() { captured="handler:release:$1"; installed_state=1; }

catalog_install jq >/dev/null
[[ "$captured" == "package:jq" ]] || die "普通软件没有精确分发到单个包"
[[ "$operation_events" == "root>invalidate>refresh>plan>install>" ]] ||
  die "APT 安装没有直接刷新、校验并执行：$operation_events"
# 未建立本地索引时仍直接刷新与校验，无额外确认。
installed_state=0
operation_events=""
package_candidate_version() { if [[ "$operation_events" == *refresh* ]]; then printf '1.0.0'; else printf '(none)'; fi; }
catalog_install jq >/dev/null
[[ "$captured" == "package:jq" && "$operation_events" == "root>invalidate>refresh>plan>install>" ]] || die "缺失本地索引阻止了直接安装流程"
package_candidate_version() { printf '1.0.0'; }
operation_events=""
installed_state=0
catalog_install docker >/dev/null
[[ "$captured" == "handler:docker" && "$operation_events" == "root>invalidate>" ]] || die "Docker 安装仍要求重复确认或分发错误"
installed_state=0
operation_events=""
catalog_install gh >/dev/null
[[ "$captured" == "handler:release:gh" && "$operation_events" == "root>invalidate>" ]] || die "官方直装仍要求重复确认或分发错误"

# 移除确认后，权限、索引、候选版本和危险事务仍必须阻止安装。
installed_state=0
captured=""
require_root() { return 1; }
if catalog_install jq >/dev/null 2>&1; then die "缺少权限仍继续安装"; fi
[[ -z "$captured" ]] || die "权限失败后仍执行了安装器"
require_root() { operation_events+="root>"; }
package_update_index() { return 1; }
if catalog_install jq >/dev/null 2>&1; then die "索引刷新失败仍继续安装"; fi
[[ -z "$captured" ]] || die "刷新失败后仍执行了安装器"
package_update_index() { operation_events+="refresh>"; }
package_candidate_version() { printf '(none)'; }
if catalog_install jq >/dev/null 2>&1; then die "没有候选版本仍继续安装"; fi
[[ -z "$captured" ]] || die "缺失候选版本后仍执行了安装器"
package_candidate_version() { printf '1.0.0'; }
catalog_apt_plan_render() { return 1; }
if catalog_install jq >/dev/null 2>&1; then die "事务检查失败仍继续安装"; fi
[[ -z "$captured" ]] || die "危险事务仍执行了安装器"
catalog_apt_plan_render() { operation_events+="plan>"; }

installed_state=0
package_install_latest() { return 1; }
if catalog_install jq >/dev/null 2>&1; then
  die "普通软件安装失败没有向上返回"
fi
package_install_latest() { captured="package:$1"; installed_state=1; }

installed_state=1
package_installed() { [[ "$1" == "jq" ]]; }
package_installed_version() { printf '1.0.0'; }
package_candidate_version() { printf '1.1.0'; }
package_has_update() { [[ "$1" == "jq" ]]; }
package_invalidate_index() { :; }
package_update_index() { :; }
package_upgrade() { captured="update:$1"; }
catalog_update jq >/dev/null
[[ "$captured" == "update:jq" ]] || die "普通软件没有分发到单项更新流程"

printf 'PASS: catalog\n'
