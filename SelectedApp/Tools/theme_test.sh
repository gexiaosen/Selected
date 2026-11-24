#!/bin/bash
# 主题/色板自检（Tokens.swift：明暗自适应 + 浅色口径冻结 + 对比度 + 表面层级 + 语义入口）
#
# 覆盖（全部离线）：
#   自适应     每个语义色/表面 token 在浅色与深色下解析值必须不同
#   浅色冻结   浅色档仍是改造前原色号（浅色观感不许被暗色改造动到）
#   可读性     8 个语义基础色在两种外观下对窗口底色 ≥3:1（含涨跌红绿不串色）
#   表面层级   row < sunken < chip < chipStrong 严格递增且都能看出
#   语义入口   pnl/灯级/信号/风险/状态/变化/得分 映射与基础色一一对应
#
# 为什么是自检：颜色只在 Swift 侧存在（没有另一侧实现可比），
# 且「写死静态色 → 暗色下与卡片糊成一片」是代码审查看不出来的静默回归。
#
# 本脚本要**链接 SelectedCore**：`Tokens.swift` 现在 `import SelectedCore`
#   （灯级收成枚举后，`Sem.light` 的入参是 Core 的 `MarketLightLevel`）。
# ⚠ 还要一起编 `Palette.swift`：色值在单独的数据文件里，
#   `Tokens.swift` 单独编译会因为找不到 `ThemeColors` / `Quad` / `ChartKey` 直接编译失败
#   —— 那会表现为"自检失败"，其实是"自检没跑成"，判据必须区分这两件事。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/SelectedApp/Tools/core_lib.sh"
SRC="$ROOT/SelectedApp/Sources/SelectedApp/Views"
BIN_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/selected_theme_test.XXXXXX")"
BIN="${BIN:-$BIN_DIR/theme_test}"

echo "== 编译并跑主题自检 =="
swiftc -O -parse-as-library -I "$CORE_MODULE_DIR" -enable-testing \
    "$SRC/Tokens.swift" \
    "$SRC/Palette.swift" \
    "$ROOT/SelectedApp/Tools/ThemeTest.swift" $CORE_OBJS -o "$BIN" || exit 2

"$BIN"
RC=$?

if [ "$RC" -eq 0 ]; then
    echo "✅ 全部通过（明暗自适应 + 对比度 + 语义入口）"
    exit 0
fi
echo "❌ 主题自检存在失败"
exit 1