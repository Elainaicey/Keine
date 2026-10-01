#!/usr/bin/env bash
# 功能模块通过运行时解析这些测试桩。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/features/terminal/prompts.sh"

NO_COLOR=1
DRY_RUN=1
SUDO_USER=alice
runtime_colors

getent() { [[ "$1" == "passwd" && "$2" == "alice" ]] && printf 'alice:x:1000:1000:Alice:/home/alice:/bin/zsh\n'; }
id() { case "$1" in -un) printf 'root' ;; -gn) printf 'alice' ;; *) return 1 ;; esac; }
software_target_user() { printf 'alice'; }
software_target_home() { printf '/home/alice'; }
backup_file() { :; }

paths="$(software_prompt_paths)"
[[ "$paths" == 'alice|/home/alice|/home/alice/.local/bin|/home/alice/.local/share/server-toolkit/prompts' ]] || die "提示符路径解析错误"
[[ "$(software_prompt_marker starship)" == '/home/alice/.local/share/server-toolkit/prompts/starship.managed' ]] || die "提示符标记路径错误"

output="$(software_prompt_activate starship alice /home/alice)"
grep -q '活动 Zsh 提示符' <<<"$output" || die "Starship 激活预览不完整"
output="$(software_prompt_activate oh-my-posh alice /home/alice)"
grep -q 'oh-my-posh' <<<"$output" || die "Oh My Posh 激活预览不完整"
output="$(software_prompt_activate spaceship alice /home/alice)"
grep -q 'spaceship' <<<"$output" || die "Spaceship 激活预览不完整"

prompt_test_root="$(mktemp -d)"
trap '[[ "$prompt_test_root" == /tmp/* ]] && rm -rf -- "$prompt_test_root"' EXIT
DRY_RUN=0
# 初始化代码是字面量测试夹具，不在测试 Shell 中展开。
# shellcheck disable=SC2016
printf '%s\n' 'export CUSTOM=keep' 'ZSH_THEME="old"' 'eval "$(starship init zsh)"' >"$prompt_test_root/zshrc"
terminal_normalize_zshrc "$prompt_test_root/zshrc" robbyrussell
grep -Fxq 'export CUSTOM=keep' "$prompt_test_root/zshrc" || die "切换破坏了用户配置"
grep -Fxq 'ZSH_THEME="robbyrussell"' "$prompt_test_root/zshrc" || die "框架主题未切换"
if grep -q 'starship init' "$prompt_test_root/zshrc"; then die "切换留下了重复引擎"; fi

printf 'PASS: prompts\n'
