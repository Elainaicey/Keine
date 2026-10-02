#!/usr/bin/env bash
# 功能模块通过运行时解析这些测试桩。
# shellcheck disable=SC2034,SC2317,SC2329
set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
prompt_test_root="$(mktemp -d)"
trap '[[ "$prompt_test_root" == /tmp/* ]] && rm -rf -- "$prompt_test_root"' EXIT
KEINE_STATE_ROOT="$prompt_test_root/keine-state"
KEINE_BACKUP_ROOT="$prompt_test_root/keine-backups"
. "$ROOT_DIR/src/core/runtime.sh"
. "$ROOT_DIR/src/core/ui.sh"
. "$ROOT_DIR/src/core/validation.sh"
. "$ROOT_DIR/src/core/changes.sh"
. "$ROOT_DIR/src/core/backup.sh"
. "$ROOT_DIR/src/core/configuration.sh"
. "$ROOT_DIR/src/features/terminal/framework.sh"
. "$ROOT_DIR/src/features/terminal/shells.sh"
. "$ROOT_DIR/src/features/terminal/prompts.sh"
. "$ROOT_DIR/src/features/terminal/menu.sh"

NO_COLOR=1
DRY_RUN=1
SUDO_USER=alice
runtime_colors

login_shell=zsh
target_home=/home/alice
getent() { [[ "$1" == "passwd" && "$2" == "alice" ]] && printf 'alice:x:1000:1000:Alice:%s:/bin/%s\n' "$target_home" "$login_shell"; }
id() { case "$1" in -un) printf 'root' ;; -gn) printf 'alice' ;; *) return 1 ;; esac; }
software_target_user() { printf 'alice'; }
software_target_home() { printf '%s' "$target_home"; }
require_root() { :; }
chown() { :; }
# 这些 Zsh 夹具只使用兼容语法；此替身不宣称验证原生 Zsh 运行行为。
zsh() { [[ "$1" == -f && "$2" == -n ]] && bash -n "$3"; }

paths="$(software_prompt_paths)"
[[ "$paths" == 'alice|/home/alice|/home/alice/.local/bin|/home/alice/.local/share/keine/prompts' ]] || die "提示符路径解析错误"
[[ "$(software_prompt_marker starship)" == '/home/alice/.local/share/keine/prompts/starship.managed' ]] || die "提示符标记路径错误"

output="$(software_prompt_activate starship alice /home/alice)"
grep -q 'zsh 提示符' <<<"$output" || die "Starship 激活预览不完整"
output="$(software_prompt_activate oh-my-posh alice /home/alice)"
grep -q 'oh-my-posh' <<<"$output" || die "Oh My Posh 激活预览不完整"
output="$(software_prompt_activate spaceship alice /home/alice)"
grep -q 'spaceship' <<<"$output" || die "Spaceship 激活预览不完整"

DRY_RUN=0
CHANGES_ENABLED=1
# 初始化代码是字面量测试夹具，不在测试 Shell 中展开。
# shellcheck disable=SC2016
printf '%s\n' 'export CUSTOM=keep' 'ZSH_THEME="old"' 'eval "$(starship init zsh)"' >"$prompt_test_root/zshrc"
terminal_normalize_zshrc "$prompt_test_root/zshrc" robbyrussell
grep -Fxq 'export CUSTOM=keep' "$prompt_test_root/zshrc" || die "切换破坏了用户配置"
grep -Fxq 'ZSH_THEME="robbyrussell"' "$prompt_test_root/zshrc" || die "框架主题未切换"
if grep -q 'starship init' "$prompt_test_root/zshrc"; then die "切换留下了重复引擎"; fi

target_home="$prompt_test_root/home"
login_shell=bash
mkdir -p "$target_home/.local/bin"
printf 'export CUSTOM=keep\n' >"$target_home/.bashrc"
printf 'export LOGIN_CUSTOM=keep\n' >"$target_home/.profile"
# 初始化器是离线替身，不访问网络、不调用真实引擎。
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\n[[ "$1 $2" == "init bash" ]] || exit 1\nprintf "export TEST_PROMPT_READY=yes\\n"\n' >"$target_home/.local/bin/starship"
chmod 0755 "$target_home/.local/bin/starship"
software_prompt_activate starship alice "$target_home" >/dev/null
software_prompt_active starship || die 'Bash 配置状态未识别'
grep -Fxq 'export CUSTOM=keep' "$target_home/.bashrc" || die 'Bash 自定义配置丢失'
[[ ! -e "$target_home/.zshrc" ]] || die 'Bash 安装写入了 Zsh 配置'
grep -Fxq '# END keine: Prompt' "$target_home/.bashrc" || die '提示符配置块未闭合'
bash --noprofile --rcfile "$target_home/.bashrc" -ic '[[ "$TEST_PROMPT_READY" == yes && "$KEINE_PROMPT_LOADED" == starship ]]' 2>/dev/null || die 'Bash 没有加载提示符初始化器'
bash -n "$target_home/.profile"
sh -n "$target_home/.profile"
software_prompt_activate starship alice "$target_home" >/dev/null
[[ "$(grep -c '^# BEGIN keine: Prompt$' "$target_home/.bashrc")" == 1 ]] || die '重复初始化配置'
[[ "$(grep -c '^# BEGIN keine: Bash login$' "$target_home/.profile")" == 1 ]] || die '重复 Bash 登录配置'
config_file_restore "$target_home/.bashrc" config_no_reload >/dev/null
config_file_restore "$target_home/.profile" config_no_reload >/dev/null
[[ "$(cat "$target_home/.bashrc")" == 'export CUSTOM=keep' && "$(cat "$target_home/.profile")" == 'export LOGIN_CUSTOM=keep' ]] || die '初始终端配置未精确恢复'
printf '# BEGIN keine: Prompt\nbroken\n' >"$prompt_test_root/incomplete"
if terminal_rc_content "$prompt_test_root/incomplete" bash >/dev/null; then die '接受了未闭合托管块'; fi

# 覆盖全新主目录的完整安装流程，而不只验证已有命令的配置切换。
package_install() { run true; }
software_run_as_target() { local user="$1" home="$2"; shift 2; run env HOME="$home" "$@"; }
software_prompt_download_installer() {
  local installer
  installer="$(mktemp)"
  cat >"$installer" <<'INSTALLER'
#!/usr/bin/env sh
while [ "$#" -gt 0 ]; do
  case "$1" in -b|-d) bin="$2"; shift 2 ;; *) shift ;; esac
done
printf '#!/usr/bin/env sh\ncase "$1" in\n  --version) printf "starship 1.0.0\\n" ;;\n  init) printf "export TEST_PROMPT_READY=yes\\n" ;;\n  *) exit 1 ;;\nesac\n' >"$bin/starship"
chmod 0755 "$bin/starship"
INSTALLER
  printf '%s' "$installer"
}
target_home="$prompt_test_root/fresh-home"
mkdir -p "$target_home"
printf 'export CUSTOM=first-install\n' >"$target_home/.bashrc"
terminal_apply starship >/dev/null
software_prompt_active starship || die '首次安装未完成提示符切换'
software_prompt_managed starship || die '首次安装没有记录引擎所有权'
bash --noprofile --rcfile "$target_home/.bashrc" -ic '[[ "$TEST_PROMPT_READY" == yes && "$KEINE_PROMPT_LOADED" == starship ]]' 2>/dev/null || die '首次安装的 Bash 初始化没有生效'
[[ "$(changes_file_status "$(changes_file_entry "$target_home/.local")")" == ready ]] || die '首次安装错误地被标记为外部修改'
[[ ! -d "$KEINE_BACKUP_ROOT" ]] || die '终端切换生成了自动历史快照'

# 模拟云主机从普通用户 sudo/su 到 root，保留来源用户和其 PATH。
ordinary_home="$target_home"
root_home="$prompt_test_root/root-home"
mkdir -p "$root_home"
printf 'export ROOT_CUSTOM=keep\n' >"$root_home/.bashrc"
. "$ROOT_DIR/src/features/terminal/framework.sh"
getent() {
  [[ "$1" == passwd ]] || return 1
  case "$2" in
    root) printf 'root:x:0:0:Root:%s:/bin/bash\n' "$root_home" ;;
    alice) printf 'alice:x:1000:1000:Alice:%s:/bin/bash\n' "$ordinary_home" ;;
    *) return 1 ;;
  esac
}
SUDO_USER=alice
[[ "$(software_target_user)" == root && "$(software_target_home)" == "$root_home" ]] || die '云主机 root 目标识别错误'
paths="$(software_prompt_paths)"
[[ "$paths" == "root|$root_home|$root_home/.local/bin|$root_home/.local/share/keine/prompts" ]] || die 'root 提示符资源仍指向普通用户'
# 测试不依赖宿主机是否另外安装了系统级引擎。
readlink() {
  if [[ "$1" == -f && "${3:-}" != "$prompt_test_root/"* ]]; then return 1; fi
  command readlink "$@"
}
inherited_path="$ordinary_home/.local/bin:$PATH"
if PATH="$inherited_path" terminal_prompt_command starship "$root_home/.local/bin" >/dev/null; then
  die 'root 借用了普通用户 PATH 中的提示符引擎'
fi
mkdir -p "$root_home/.cargo/bin"
cp "$ordinary_home/.local/bin/starship" "$root_home/.cargo/bin/starship"
native_command="$(PATH="$inherited_path:$root_home/.cargo/bin" terminal_prompt_command starship "$root_home/.local/bin")"
[[ "$native_command" == "$root_home/.cargo/bin/starship" ]] || die '本用户的原生 Cargo 安装无法复用'
rm -f -- "$root_home/.cargo/bin/starship"
ordinary_rc="$(cat "$ordinary_home/.bashrc")"
output="$(terminal_apply starship)"
[[ "$output" == *'已为 root 的 bash 配置 starship'* && "$output" != *'已经安装，无需操作'* ]] || die '首次安装结果提示不准确'
[[ "$(cat "$ordinary_home/.bashrc")" == "$ordinary_rc" ]] || die 'root 切换修改了普通用户配置'
software_prompt_active starship || die 'root 的 Bash 提示符没有完成配置'
software_prompt_managed starship || die 'root 引擎没有独立所有权标记'
grep -Fq "$root_home/.local/bin/starship init bash" "$root_home/.bashrc" || die 'root 初始化引用了其他用户程序'
# 断言必须由新启动的 Bash 展开，而不是当前测试 Shell。
# shellcheck disable=SC2016
env HOME="$root_home" KEINE_PROMPT_LOADED=starship KEINE_PROMPT_UID=1000 KEINE_PROMPT_PID=1 \
  bash --noprofile --rcfile "$root_home/.bash_profile" -ic \
  '[[ "$TEST_PROMPT_READY" == yes && "$KEINE_PROMPT_UID" == "$EUID" && "$KEINE_PROMPT_PID" == "$$" && "$ROOT_CUSTOM" == keep ]]' \
  2>/dev/null || die '继承普通用户的初始化标记后，root 登录未加载提示符'
output="$(terminal_apply starship)"
[[ "$output" == *'已为 root 的 bash 配置 starship'* ]] || die 'root 已有引擎重新切换失败'
[[ "$(grep -c '^# BEGIN keine: Bash login$' "$root_home/.bash_profile")" == 1 ]] || die 'root 重复切换叠加了登录配置'

# 上游安装器返回成功但没产出程序时，不能登记成功或写入提示符配置。
root_home="$prompt_test_root/incomplete-home"
mkdir -p "$root_home"
software_prompt_download_installer() { local installer; installer="$(mktemp)"; printf '#!/bin/sh\nexit 0\n' >"$installer"; printf '%s' "$installer"; }
if output="$(terminal_apply starship 2>&1)"; then die '空安装结果被误报成功'; fi
[[ "$output" != *'已为 root'* && ! -e "$root_home/.bashrc" && ! -e "$(software_prompt_marker starship)" ]] || die '失败安装留下了成功提示或配置标记'

printf 'PASS: prompts\n'
