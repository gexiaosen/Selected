#!/bin/bash
# 图表缩放/铺满数学自检（ChartZoomMath）
#
# 覆盖：铺满不变量（两个间距模式 × 6 组根数/视口）、单调性、尾部留白规则、自适应间距规则。
# 为什么是自检：这是图表库内部的纯数学，App/引擎两侧都无对应实现，
# 但「缩到最小正好铺满、右侧不留空白」这条不变量容易回归，必须离线钉死。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT/SelectedApp/LocalPackages/swift-trading-view/Sources/SwiftTradingView/Model"
BIN_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/selected_chart_zoom_test.XXXXXX")"
BIN="${BIN:-$BIN_DIR/chart_zoom_test}"

echo "== 编译并跑图表缩放数学自检 =="
swiftc -O -parse-as-library \
    "$SRC/ChartZoomMath.swift" \
    "$ROOT/SelectedApp/Tools/ChartZoomTest.swift" -o "$BIN" || exit 2

"$BIN"
RC=$?

if [ "$RC" -eq 0 ]; then
    echo "✅ 全部通过（缩放/铺满数学）"
    exit 0
fi
echo "❌ 图表缩放数学自检存在失败"
exit 1