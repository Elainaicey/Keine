#!/usr/bin/env bash

# 系统领域入口：诊断、进程、软件包、存储、设置和菜单分别维护。
. "$ROOT_DIR/src/features/system/diagnostics.sh"
. "$ROOT_DIR/src/features/system/processes.sh"
. "$ROOT_DIR/src/features/system/packages.sh"
. "$ROOT_DIR/src/features/system/updates.sh"
. "$ROOT_DIR/src/features/system/storage.sh"
. "$ROOT_DIR/src/features/system/triage.sh"
. "$ROOT_DIR/src/features/system/settings.sh"
. "$ROOT_DIR/src/features/system/menu.sh"
