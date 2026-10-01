#!/usr/bin/env bash

# 应用服务入口：元数据、资产查询、安全操作和交互页面分别维护。
. "$ROOT_DIR/src/features/apps/services/metadata.sh"
. "$ROOT_DIR/src/features/apps/services/inspect.sh"
. "$ROOT_DIR/src/features/apps/services/health.sh"
. "$ROOT_DIR/src/features/apps/services/actions.sh"
. "$ROOT_DIR/src/features/apps/services/overview.sh"
. "$ROOT_DIR/src/features/apps/services/detail.sh"
. "$ROOT_DIR/src/features/apps/services/menu.sh"
