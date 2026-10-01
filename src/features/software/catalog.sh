#!/usr/bin/env bash

# 软件目录属于软件功能域；入口只负责按依赖顺序加载查询、展示、操作和页面模块。
. "$ROOT_DIR/src/features/software/catalog/cache.sh"
. "$ROOT_DIR/src/features/software/catalog/query.sh"
. "$ROOT_DIR/src/features/software/catalog/plan.sh"
. "$ROOT_DIR/src/features/software/catalog/effects.sh"
. "$ROOT_DIR/src/features/software/catalog/presentation.sh"
. "$ROOT_DIR/src/features/software/catalog/actions.sh"
. "$ROOT_DIR/src/features/software/catalog/browse.sh"
. "$ROOT_DIR/src/features/software/catalog/views.sh"
