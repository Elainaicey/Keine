#!/usr/bin/env bash

# 官方 APT 软件源属于软件领域；入口只按依赖顺序加载状态与具体实现。
. "$ROOT_DIR/src/features/software/repositories/state.sh"
. "$ROOT_DIR/src/features/software/repositories/docker.sh"
. "$ROOT_DIR/src/features/software/repositories/caddy.sh"
