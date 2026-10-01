#!/usr/bin/env bash

. "$ROOT_DIR/src/integrations/warp.sh"
. "$ROOT_DIR/src/integrations/network-tuning.sh"

integration_dispatch() {
  # 声明式注册不等于执行授权；适配器仍必须写入明确白名单。
  case "$1" in warp) warp_menu ;; network-tuning) network_tuning_adapter_menu ;; *) warn "尚未实现的原生适配器：$1"; return 1 ;; esac
}

integrations_menu() {
  local rows=() record id name _backend _probe _handler description index choice
  while true; do
    mapfile -t rows < <(awk -F '|' '!/^#/ && NF==6' "$CONFIG_DIR/integrations.tsv")
    ui_page "原生集成" "复用主机既有安装，不要求项目所有权"
    for index in "${!rows[@]}"; do
      IFS='|' read -r id name _backend _probe _handler description <<<"${rows[$index]}"
      ui_item "$((index+1))" "$name" "$description"
    done
    ui_action 0 "返回" "muted"
    choice="$(read_input "请选择" "0")"
    [[ "$choice" != 0 ]] || return 0
    if [[ ! "$choice" =~ ^[1-9][0-9]?$ ]] || (( choice > ${#rows[@]} )); then warn "编号无效。"; pause; continue; fi
    record="${rows[$((choice-1))]}"; IFS='|' read -r id name _backend _probe _handler description <<<"$record"
    integration_dispatch "$id" || true
  done
}
