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
output="$(ui_banner; ui_page "测试中心"; ui_item 1 "测试操作" "测试说明"; ui_state_item 2 "Nginx" "active" "good" "nginx.service"; ui_panel_begin "信息"; ui_panel_kv "版本" "0.3.0"; ui_panel_end; ui_action 3 "更新" "warning"; ui_action_pair 4 "启动" "success" 5 "停止" "danger"; ui_metric_row "内存" "46%" "good" "磁盘" "81%" "warn" "失败服务" "1" "bad"; ui_callout "warn" "需要关注" "进入详情继续核实"; ui_hint "格式示例"; ui_note "测试提示")"
grep -q 'KEINE' <<<"$output" || { printf 'FAIL: UI 横幅缺失\n' >&2; exit 1; }
grep -q '测试操作' <<<"$output" || { printf 'FAIL: UI 菜单项缺失\n' >&2; exit 1; }
grep -q '╭─ 信息' <<<"$output" || { printf 'FAIL: UI 信息面板缺失\n' >&2; exit 1; }
grep -q '\[ 2\].*Nginx.*active' <<<"$output" || { printf 'FAIL: UI 状态菜单项缺失\n' >&2; exit 1; }
grep -q '\[3\].*更新' <<<"$output" || { printf 'FAIL: UI 语义操作缺失\n' >&2; exit 1; }
grep -q '\[4\].*启动.*\[5\].*停止' <<<"$output" || { printf 'FAIL: UI 双列操作缺失\n' >&2; exit 1; }
grep -q '内存.*46%.*磁盘.*81%.*失败服务.*1' <<<"$output" || { printf 'FAIL: UI 响应式指标组件缺失\n' >&2; exit 1; }
grep -q '需要关注' <<<"$output" || { printf 'FAIL: UI 状态提示组件缺失\n' >&2; exit 1; }
grep -q '格式示例' <<<"$output" || { printf 'FAIL: UI 紧凑输入提示缺失\n' >&2; exit 1; }
[[ "$(ui_display_width "系统")" -eq 4 ]] || { printf 'FAIL: 中文显示宽度计算错误\n' >&2; exit 1; }
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

printf 'PASS: ui\n'
