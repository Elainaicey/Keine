#!/usr/bin/env bash

# 网络入口：概览、调优、深度诊断与菜单分别维护。
. "$ROOT_DIR/src/features/network/configuration.sh"
. "$ROOT_DIR/src/features/network/dns.sh"
. "$ROOT_DIR/src/features/network/proxy.sh"
. "$ROOT_DIR/src/features/network/parameters.sh"
. "$ROOT_DIR/src/features/network/overview.sh"
. "$ROOT_DIR/src/features/network/tuning.sh"
. "$ROOT_DIR/src/features/network/diagnostics.sh"
. "$ROOT_DIR/src/features/network/http.sh"
. "$ROOT_DIR/src/features/network/menu.sh"
