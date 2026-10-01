#!/usr/bin/env bash

# 安全中心入口：按依赖顺序加载各安全领域，菜单只负责顶层编排。
. "$ROOT_DIR/src/features/security/overview.sh"
. "$ROOT_DIR/src/features/security/exposure.sh"
. "$ROOT_DIR/src/features/security/activity.sh"
. "$ROOT_DIR/src/features/security/fail2ban.sh"
. "$ROOT_DIR/src/features/security/fail2ban-policy.sh"
. "$ROOT_DIR/src/features/security/certificates.sh"
. "$ROOT_DIR/src/features/security/firewall.sh"
. "$ROOT_DIR/src/features/security/ssh.sh"
. "$ROOT_DIR/src/features/security/ssh-policy.sh"
. "$ROOT_DIR/src/features/security/menu.sh"
