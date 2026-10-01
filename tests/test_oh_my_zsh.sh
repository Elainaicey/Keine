#!/usr/bin/env bash
# 测试桩会由功能模块间接调用。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/features/terminal/framework.sh"

NO_COLOR=1
DRY_RUN=1
runtime_colors

fake_passwd='alice:x:1000:1000:Alice:/home/alice:/bin/bash'
getent() { [[ "$1" == "passwd" && "$2" == "alice" ]] && printf '%s\n' "$fake_passwd"; }
id() {
  case "$1" in
    -un) printf 'root' ;;
    -gn) printf 'alice' ;;
    *) return 1 ;;
  esac
}
SUDO_USER=alice

[[ "$(software_target_user)" == "alice" ]] || die "没有优先选择 sudo 发起用户"
[[ "$(software_target_home alice)" == "/home/alice" ]] || die "目标用户主目录解析错误"
[[ "$(software_oh_my_zsh_path)" == "/home/alice/.oh-my-zsh" ]] || die "Oh My Zsh 目标路径错误"

software_oh_my_zsh_official_remote 'https://github.com/ohmyzsh/ohmyzsh.git' || die "官方 HTTPS 仓库未通过校验"
software_oh_my_zsh_official_remote 'git@github.com:ohmyzsh/ohmyzsh.git' || die "官方 SSH 仓库未通过校验"
if software_oh_my_zsh_official_remote 'https://example.com/ohmyzsh.git'; then
  die "来源不明的仓库通过了校验"
fi

output="$(software_oh_my_zsh_configure alice /home/alice)"
grep -q '添加 keine 托管' <<<"$output" || die "配置预览没有说明托管范围"

printf 'PASS: oh-my-zsh\n'
