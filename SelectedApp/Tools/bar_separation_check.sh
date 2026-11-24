#!/bin/bash
# 护栏 `bar_separation` 的入口：编译并运行比例条图形档的分离度检查。
#
# 纯 Swift 实现（全仓零 Python，CI 不依赖预装 python3）。
#   成功路径直接输出汇总行（含实算组数）—— 不要写 `|| echo <数字>` 兜底，
#   那会在抽取失败时打印一个虚构的计数。
#
# 退出码：0 达标 / 1 不达标（逐行列出）/ 2 结构变化或工具链缺失（护栏空转，必须报红）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT/SelectedApp/Sources/SelectedApp/Views"
TOOL="$ROOT/SelectedApp/Tools/BarSeparationCheck.swift"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "缺 swiftc：护栏 bar_separation 无法执行（不是「通过」，是「没跑」）"
    exit 2
fi

# ⚠ 与 `sem_contrast` 同一套装置：读**真类型**（`ThemeColors.bar(_:)` / `neutral(dark:).card` /
#   `Tok.rowAlphas`），不用正则抽源码。`Tokens.swift` 依赖 SelectedCore ⇒ 走 core_lib。
source "$ROOT/SelectedApp/Tools/core_lib.sh"

BIN="$(mktemp -d)/bar_separation_check"
MATH="$ROOT/SelectedApp/Tools/ColorMath.swift"
if ! swiftc -O -parse-as-library -I "$CORE_MODULE_DIR" "$SRC/Tokens.swift" "$SRC/Palette.swift" "$MATH" "$TOOL" \
        $CORE_OBJS -o "$BIN" 2>&1; then
    echo "自检驱动编译失败：${TOOL}（或它依赖的 Palette.swift / Tokens.swift 结构变了）"
    exit 2
fi

"$BIN" "$@"
