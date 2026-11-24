#!/bin/bash
# 自选 / 持仓表头排序自检（纯函数，不碰库、不碰 UI）
#
# 覆盖 9 条，逐条列在 Tools/WatchSortCheck.swift 头部。
# 为什么值得一个套件：这套排序的三条口径（nil 沉底不翻面、同值必须稳定、
# 排序值与显示值同一个算式）全是"看一眼截图看不出来、但一改就错"的类型 ——
# 而自选表在快照库里是**空的**，出图链路根本验不到它。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/SelectedApp/Tools/core_lib.sh"
BIN_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/selected_watch_sort_test.XXXXXX")"
BIN="${BIN:-$BIN_DIR/watch_sort_test}"

echo "== 编译并跑表头排序自检 =="
swiftc -O -parse-as-library -I "$CORE_MODULE_DIR" -enable-testing \
    "$ROOT/SelectedApp/Tools/WatchSortCheck.swift" \
    $CORE_OBJS -o "$BIN" || exit 2

"$BIN"
RC=$?

if [ "$RC" -eq 0 ]; then
    echo "✅ 全部通过（升/降/取消 · nil 沉底 · 同值稳定 · 与显示同算式）"
    exit 0
fi
echo "❌ 表头排序自检存在失败"
exit 1
