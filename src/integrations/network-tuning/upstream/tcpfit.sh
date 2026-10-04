#!/usr/bin/env bash
# TCPFit 0.5.9, commit 38fbf5af30daf87735f2ffbc5e0905033ee2b86e.
# Extracted calculation functions; MIT, Copyright (c) 2026 Kylin010.
# Full notice: docs/THIRD-PARTY-NOTICES.md. No upstream entry point is executed.

calc_bdp(){ awk -v b="$1" -v r="$2" 'BEGIN{printf "%d", b*1000000/8*(r/1000)}'; }

calc_tcp_mem(){
  local ram_mb="$1"
  awk -v m="$ram_mb" 'BEGIN{
    pg=m*1024/4;                      # 总内存页数
    low=int(pg/16); pres=int(pg/8); max=int(pg/4);
    if(low<4096) low=4096; if(pres<8192) pres=8192; if(max<16384) max=16384;
    printf "%d %d %d", low, pres, max
  }'
}

calc_buf_max(){   # calc_buf_max <BDP字节> <内存MB>
  awk -v b="$1" -v m="$2" 'BEGIN{
    v   = b*2 + 2097152
    cap = m*32768              # tcp_mem上限(内存1/4)的 1/8 = 内存/32, 单位字节
    if(cap > 268435456) cap = 268435456      # 绝对上限 256MB
    if(v > cap) v = cap
    if(v < 4194304) v = 4194304              # 下限 4MB, 低于此连百兆都跑不满
    printf "%d", v
  }'
}

calc_buf_default(){
  local role="$1" bdp="$2"
  case "$role" in
    proxy) echo 1048576 ;;
    bulk)  awk -v b="$bdp" 'BEGIN{v=b; if(v<1048576)v=1048576; if(v>8388608)v=8388608; printf "%d", v}' ;;
    *)     echo 2097152 ;;
  esac
}
