#!/usr/bin/env bash
# vps-tcp-tune 5.4.11, commit 2dbe1c8f7330ae220a17e2562d69d1a5e55f55a5.
# Extracted calculation functions; MIT, Copyright (c) 2025 Eric Reed.
# Full notice: docs/THIRD-PARTY-NOTICES.md. UI is suppressed by the adapter.
# The original interactive read is preserved; the adapter always supplies AUTO_MODE=1.
# shellcheck disable=SC2162

# The original caller supplied these UI variables. No top-level upstream code is loaded.
: "${AUTO_MODE:=1}" "${gl_huang:=}" "${gl_bai:=}" "${gl_kjlan:=}" "${gl_lv:=}"

calculate_buffer_size() {
    local bandwidth=$1
    local region=${2:-asia}  # asia（亚太）或 overseas（美欧）
    local buffer_mb
    local bandwidth_level

    # 输入验证：确保 bandwidth 是正整数
    if ! [[ "$bandwidth" =~ ^[0-9]+$ ]] || [ "$bandwidth" -le 0 ] 2>/dev/null; then
        local fallback_mb=16
        [ "$region" = "overseas" ] && fallback_mb=64
        echo -e "${gl_huang}⚠️ 带宽值无效 (${bandwidth})，使用默认值 ${fallback_mb}MB${gl_bai}" >&2
        echo "$fallback_mb"
        return 0
    fi

    if [ "$region" = "overseas" ]; then
        # ===== 美国/欧洲档位（RTT ~200ms，buffer ≈ BDP × 2.5，上限 64MB）=====
        if [ "$bandwidth" -eq 100 ]; then
            buffer_mb=8
            bandwidth_level="预设档位（100 Mbps·远距离）"
        elif [ "$bandwidth" -eq 200 ]; then
            buffer_mb=16
            bandwidth_level="预设档位（200 Mbps·远距离）"
        elif [ "$bandwidth" -eq 300 ]; then
            buffer_mb=20
            bandwidth_level="预设档位（300 Mbps·远距离）"
        elif [ "$bandwidth" -eq 500 ]; then
            buffer_mb=32
            bandwidth_level="预设档位（500 Mbps·远距离）"
        elif [ "$bandwidth" -eq 700 ]; then
            buffer_mb=48
            bandwidth_level="预设档位（700 Mbps·远距离）"
        elif [ "$bandwidth" -eq 1000 ]; then
            buffer_mb=64
            bandwidth_level="预设档位（1 Gbps·远距离）"
        elif [ "$bandwidth" -eq 1500 ]; then
            buffer_mb=64
            bandwidth_level="预设档位（1.5 Gbps·远距离）"
        elif [ "$bandwidth" -eq 2000 ]; then
            buffer_mb=64
            bandwidth_level="预设档位（2 Gbps·远距离）"
        elif [ "$bandwidth" -eq 2500 ]; then
            buffer_mb=64
            bandwidth_level="预设档位（2.5 Gbps·远距离）"
        # 非预设值的区间兜底。两条规则：
        #   1) 实测值离某个预设档不足 10% 时按该档计算（千兆口实测通常是 9xx，应按 1 Gbps 档）
        #   2) 带宽越大缓冲区不减小（各区间不低于其左侧预设档的值）
        # 各区间取值均 ≥ 旧版同带宽的取值，不会比旧版小
        elif [ "$bandwidth" -lt 270 ]; then
            buffer_mb=16
            bandwidth_level="小带宽（< 270 Mbps·远距离）"
        elif [ "$bandwidth" -lt 450 ]; then
            buffer_mb=20
            bandwidth_level="270-449 Mbps·远距离（按 300 Mbps 档）"
        elif [ "$bandwidth" -lt 500 ]; then
            buffer_mb=32
            bandwidth_level="450-499 Mbps·远距离（按 500 Mbps 档）"
        elif [ "$bandwidth" -lt 900 ]; then
            buffer_mb=48
            bandwidth_level="中等带宽（500-899 Mbps·远距离）"
        elif [ "$bandwidth" -lt 1000 ]; then
            buffer_mb=64
            bandwidth_level="900-999 Mbps·远距离（按 1 Gbps 档）"
        elif [ "$bandwidth" -lt 2000 ]; then
            buffer_mb=64
            bandwidth_level="标准带宽（1-2 Gbps·远距离）"
        else
            buffer_mb=64
            bandwidth_level="高带宽（> 2 Gbps·远距离）"
        fi
    else
        # ===== 亚太地区档位（RTT ~50ms，原有逻辑不变）=====
        if [ "$bandwidth" -eq 100 ]; then
            buffer_mb=6
            bandwidth_level="预设档位（100 Mbps）"
        elif [ "$bandwidth" -eq 200 ]; then
            buffer_mb=8
            bandwidth_level="预设档位（200 Mbps）"
        elif [ "$bandwidth" -eq 300 ]; then
            buffer_mb=10
            bandwidth_level="预设档位（300 Mbps）"
        elif [ "$bandwidth" -eq 500 ]; then
            buffer_mb=12
            bandwidth_level="预设档位（500 Mbps）"
        elif [ "$bandwidth" -eq 700 ]; then
            buffer_mb=14
            bandwidth_level="预设档位（700 Mbps）"
        elif [ "$bandwidth" -eq 1000 ]; then
            buffer_mb=16
            bandwidth_level="预设档位（1 Gbps）"
        elif [ "$bandwidth" -eq 1500 ]; then
            buffer_mb=20
            bandwidth_level="预设档位（1.5 Gbps）"
        elif [ "$bandwidth" -eq 2000 ]; then
            buffer_mb=24
            bandwidth_level="预设档位（2 Gbps）"
        elif [ "$bandwidth" -eq 2500 ]; then
            buffer_mb=28
            bandwidth_level="预设档位（2.5 Gbps）"
        # 非预设值的区间兜底（规则同上：离预设档不足 10% 按该档；带宽越大缓冲区不减小；
        # 各区间取值均 ≥ 旧版同带宽的取值）
        elif [ "$bandwidth" -lt 270 ]; then
            buffer_mb=8
            bandwidth_level="小带宽（< 270 Mbps）"
        elif [ "$bandwidth" -lt 450 ]; then
            buffer_mb=10
            bandwidth_level="270-449 Mbps（按 300 Mbps 档）"
        elif [ "$bandwidth" -lt 630 ]; then
            buffer_mb=12
            bandwidth_level="450-629 Mbps（按 500 Mbps 档）"
        elif [ "$bandwidth" -lt 900 ]; then
            buffer_mb=14
            bandwidth_level="630-899 Mbps（按 700 Mbps 档）"
        elif [ "$bandwidth" -lt 1350 ]; then
            buffer_mb=16
            bandwidth_level="900-1349 Mbps（按 1 Gbps 档）"
        elif [ "$bandwidth" -lt 1800 ]; then
            buffer_mb=20
            bandwidth_level="1350-1799 Mbps（按 1.5 Gbps 档）"
        elif [ "$bandwidth" -lt 2250 ]; then
            buffer_mb=24
            bandwidth_level="1800-2249 Mbps（按 2 Gbps 档）"
        elif [ "$bandwidth" -lt 10000 ]; then
            buffer_mb=28
            bandwidth_level="2250 Mbps 以上（按 2.5 Gbps 档）"
        else
            buffer_mb=32
            bandwidth_level="极高带宽（> 10 Gbps）"
        fi
    fi

    # 显示计算结果（输出到stderr）
    local region_label="亚太地区"
    [ "$region" = "overseas" ] && region_label="美国/欧洲"
    echo "" >&2
    echo -e "${gl_kjlan}根据带宽和地区计算最优缓冲区:${gl_bai}" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo -e "  检测带宽: ${gl_huang}${bandwidth} Mbps${gl_bai}" >&2
    echo -e "  服务地区: ${gl_huang}${region_label}${gl_bai}" >&2
    echo -e "  带宽等级: ${bandwidth_level}" >&2
    echo -e "  推荐缓冲区: ${gl_lv}${buffer_mb} MB${gl_bai}" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "" >&2

    # 询问确认
    if [ "$AUTO_MODE" = "1" ]; then
        confirm=Y
    else
        read -e -p "$(echo -e "${gl_huang}是否使用推荐值 ${buffer_mb}MB？(Y/N) [Y]: ${gl_bai}")" confirm
        confirm=${confirm:-Y}
    fi

    case "$confirm" in
        [Yy])
            # 返回缓冲区大小（MB）
            echo "$buffer_mb"
            return 0
            ;;
        *)
            local default_mb=16
            [ "$region" = "overseas" ] && default_mb=32
            echo "" >&2
            echo -e "${gl_huang}已取消，将使用通用值 ${default_mb}MB${gl_bai}" >&2
            echo "$default_mb"
            return 1
            ;;
    esac
}

calculate_tw_buckets() {
    local floor_val=5000
    local candidate=0
    local ehash
    ehash=$(sysctl -n net.ipv4.tcp_ehash_entries 2>/dev/null)
    if [[ "$ehash" =~ ^[0-9]+$ ]] && [ "$ehash" -gt 0 ]; then
        # 内核 ≥ 6.1：直接读 ehash 表大小，得到准确的默认值
        candidate=$((ehash / 2))
    else
        # 旧内核（无 tcp_ehash_entries）或容器内读不到：保留当前运行值，避免调低
        local current
        current=$(sysctl -n net.ipv4.tcp_max_tw_buckets 2>/dev/null)
        if [[ "$current" =~ ^[0-9]+$ ]]; then
            candidate=$current
        fi
    fi
    if [ "$candidate" -gt "$floor_val" ]; then
        echo "$candidate"
    else
        echo "$floor_val"
    fi
}
