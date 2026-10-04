#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/ui.sh"

# ui.sh 在加载后消费这些测试夹具变量。
# shellcheck disable=SC2034
KEINE_VERSION="0.3.0"
# shellcheck disable=SC2034
NO_COLOR=1
runtime_locale
runtime_colors
[[ "$(ui_display_width "系统")" -eq 4 ]] || { printf 'FAIL: 中文显示宽度计算错误\n' >&2; exit 1; }
[[ "$(ui_display_width $'\033[0;92m系统\033[0m')" -eq 4 ]] || { printf 'FAIL: ANSI 颜色影响中文显示宽度\n' >&2; exit 1; }
progress="$(ui_progress "内存" 50 100 MiB)"
grep -q '50%' <<<"$progress" || { printf 'FAIL: 资源进度条计算错误\n' >&2; exit 1; }
health_summary="$(ui_health_summary 12 2 1)"
grep -Eq '通过[[:space:]]+12.*关注[[:space:]]+2.*异常[[:space:]]+1' <<<"$health_summary" || {
  printf 'FAIL: 健康摘要布局错误\n' >&2
  exit 1
}
check_line="$(ui_check warn "需要关注")"
grep -q '! 需要关注' <<<"$check_line" || { printf 'FAIL: UI 检查状态组件错误\n' >&2; exit 1; }
# 由已经加载的 UI 模块消费，逐文件 ShellCheck 无法跟踪。
# shellcheck disable=SC2034
UI_WIDTH=64
narrow_metrics="$(ui_metric_row "内存" "46%" "good" "磁盘" "81%" "warn" "失败服务" "1" "bad")"
[[ "$(grep -c '●' <<<"$narrow_metrics")" -eq 3 ]] || { printf 'FAIL: 窄终端指标没有退化为逐行状态\n' >&2; exit 1; }
# 由已加载的 UI 函数消费。
# shellcheck disable=SC2034
UI_WIDTH=80
long_metrics="$(ui_metric_row "内存使用" "123456 MiB / 1024 MiB" "warn" "磁盘" "81%" "warn" "失败服务" "1" "bad")"
[[ "$(grep -c '●' <<<"$long_metrics")" -eq 3 ]] || { printf 'FAIL: 长指标没有退化为逐行状态\n' >&2; exit 1; }
long_pair="$(ui_action_pair 1 "重新验证官方软件仓库和候选版本及签名" "action" 2 "返回" "muted")"
[[ "$(grep -c '\[' <<<"$long_pair")" -eq 2 ]] || { printf 'FAIL: 过长双列操作没有退化为纵向布局\n' >&2; exit 1; }

banner="$(ui_banner)"
if [[ "$banner" != *KEINE* || "$banner" == *SERVER* || "$banner" == *TOOLKIT* ]]; then
  printf 'FAIL: 首页品牌不一致\n' >&2; exit 1
fi
keys="$(ui_item 4 测试; ui_action 4 测试; ui_state_item 4 测试 正常 good; ui_action 14 测试; ui_action R 测试)"
if grep -Eq '\[[[:space:]]|[[:space:]]\]' <<<"$keys"; then
  printf 'FAIL: 菜单键仍存在括号内空格\n' >&2; exit 1
fi
for row in "$(ui_item 4 测试)" "$(ui_action 14 测试)" "$(ui_state_item R 测试 正常 good)"; do
  [[ "${row:7:2}" == 测试 ]] || { printf 'FAIL: 菜单标签列未对齐\n' >&2; exit 1; }
done
footer="$(ui_menu_footer)"
[[ "$footer" == *'[0]'*返回* && "$footer" == *'[H]'*首页* && "$footer" == *'[Q]'*退出* ]] || { printf 'FAIL: 缺少统一菜单导航栏\n' >&2; exit 1; }
root_footer="$(ui_menu_footer 退出)"
[[ "$root_footer" == *'[0]'*退出* && "$root_footer" != *'[H]'* ]] || { printf 'FAIL: 首页重复显示首页入口\n' >&2; exit 1; }
# shellcheck disable=SC2034
UI_WIDTH=64
narrow_footer="$(ui_menu_footer)"
[[ "$(ui_display_width "$narrow_footer")" -le 64 && "$(grep -c '\[H\]' <<<"$narrow_footer")" == 1 ]] || {
  printf 'FAIL: 窄终端导航栏超宽或缺少首页入口\n' >&2; exit 1
}
# shellcheck disable=SC2034
UI_WIDTH=80
long_state="$(ui_state_item 12 'Prometheus Node Exporter' 已安装 good)"
[[ "$(grep -c . <<<"$long_state")" == 2 ]] || { printf 'FAIL: 长名称状态未退为纵向布局\n' >&2; exit 1; }
read_input() { printf '%s' "${UI_TEST_CHOICE:-$2}"; }
test_choice_assignment() {
  local choice=""
  ui_read_choice choice
  [[ "$choice" == 0 ]]
}
test_choice_assignment || { printf 'FAIL: 菜单默认输入未写入调用方\n' >&2; exit 1; }
# 菜单退出发生在当前 Shell，不能继续执行后续动作。
UI_TEST_CHOICE=q
quit_output="$(ui_read_choice choice; printf 'unexpected')"
[[ -z "$quit_output" ]] || { printf 'FAIL: 菜单退出后仍继续执行\n' >&2; exit 1; }
[[ "$(read_input 普通文本 '')" == q ]] || { printf 'FAIL: 普通输入被菜单快捷键拦截\n' >&2; exit 1; }
# 首页必须结束整个调用链，而不是在子菜单内部嵌套新首页。
# shellcheck disable=SC2317,SC2329
navigation_home() { printf home; exit 0; }
UI_TEST_CHOICE=h
home_output="$(ui_read_choice choice; printf unexpected)"
[[ "$home_output" == home ]] || { printf 'FAIL: 首页跳转后仍继续执行子菜单\n' >&2; exit 1; }
[[ "$(read_input 普通文本 '')" == h ]] || { printf 'FAIL: 普通文本 H 被导航拦截\n' >&2; exit 1; }
if [[ -t 0 || -r /dev/tty ]]; then
  home_output="$(pause; printf unexpected)"
  [[ "$home_output" == home ]] || { printf 'FAIL: 操作结果页不能直接回首页\n' >&2; exit 1; }
fi

UI_WIDTH_CACHE=()
ui_measure_width "系统"
[[ "$UI_TEXT_WIDTH" == 4 && "${UI_WIDTH_CACHE[系统]}" == 4 ]] || exit 1
wc() { printf 'FAIL: 返回菜单时重复测量已有标签\n' >&2; return 1; }
ui_measure_width "系统"
[[ "$UI_TEXT_WIDTH" == 4 ]] || exit 1
ui_measure_width ""
[[ "$UI_TEXT_WIDTH" == 0 ]] || exit 1

printf 'PASS: ui\n'
