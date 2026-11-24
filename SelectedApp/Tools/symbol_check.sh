#!/bin/bash
# 图标名有效性自检
#
# 失效形态：`Image(systemName:)` / `Label(_:systemImage:)` 遇到**不存在的符号名**时
#   **什么都不画** —— 不报错、不占位、编译过、测试全绿
#   （如 `clock.badge.gearshape` 在 macOS 26 上就不存在）。
# ⇒ 本自检把"图标名"从源码里抽出来，逐个问 AppKit「这个名字在本机画得出来吗」。
#
# ## 抽取规则（两类来源；抽取规则漂了 = 空转，故末尾有数量下限断言）
#   ① **字面量位**：`systemImage:` / `systemName:` / `icon:`（后者是 `ActionBarButton` 之类的参数）
#   ② **提供方体内**：7 处 `var icon` / `func icon(...)` 的 switch（按状态/类型给图标名）
#      —— 逐个用 awk 取函数体（**不能按行窗口取**：窗口会把中文文案、UserDefaults 键
#         （`sidebar.page`）一起卷进来 ⇒ 假红）
#   再按"符号名形状"过滤（小写字母数字 + 至少一个点）：中文文案、`etf_hedge`（下划线）、
#   `appearanceMode`（无点）、`scoring.intraday.enabled`（参数键，无 icon 语境）都被排除。
#
# 已知局限（明写在此，别读成"全覆盖"）：**动态拼接的名字测不到**
#   （如 `Image(systemName: someVar)`）—— 这类只能靠评审；本自检抓的是字面量。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT/SelectedApp/Sources/SelectedApp"
TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/selected_symbol_check.XXXXXX")"
BIN="${BIN:-$TMP/symbol_check}"

if [ ! -d "$SRC" ]; then
    echo "❌ symbol_names  源码目录不存在：${SRC}（路径漂了 → 自检会静默失效）"
    exit 2
fi

rm -rf "$TMP" && mkdir -p "$TMP"
NAMES="$TMP/names.txt"

# 两个来源必须分别可判：任一处抽不到东西 = 抽取规则或路径漂了 → 末尾数量下限会兜住
{
    # ① 字面量位
    # 这里**不要**顺手把引号剥掉：下面统一用 `grep -oE '"[^"]+"'` 取引号内的内容，
    #   先剥引号会让这一路的名字**全部被丢掉**。
    grep -rhoE '(systemImage|systemName|icon): *"[^"]+"' "$SRC" --include='*.swift'
    # ② 提供方体内（7 处，缩进各异 ⇒ 逐个写锚点；改声明写法时要同步改这里）
    grep -h 'var icon: String =' "$SRC/Views/Components+PageControls.swift"
    awk '/^    var icon: String \{/,/^    \}/'                        "$SRC/Views/SettingsCategories.swift"
    awk '/^        var icon: String \{/,/^        \}/'                "$SRC/Views/Tokens.swift"
    awk '/^    private func icon\(_ s: StageState\)/,/^    \}/'       "$SRC/Views/Components+PageControls.swift"
    awk '/^    private var icon: String\? \{/,/^    \}/'              "$SRC/Views/Components+Overlays.swift"
    awk '/^    static func icon\(_ type: String\)/,/^    \}/'         "$SRC/Views/Components+Overlays.swift"
    awk '/^    var icon: String \{/,/^    \}/'                        "$SRC/SelectedApp.swift"
} | grep -oE '"[^"]+"' | tr -d '"' \
  | grep -E '^[a-z][a-z0-9]*(\.[a-z0-9]+)+$' | sort -u > "$NAMES"

N=$(wc -l < "$NAMES" | tr -d ' ')
# 空转检测：实测当前 60+ 个；少于 40 = 抽取规则或目录漂了（看着全绿、其实没查）
if [ "$N" -lt 40 ]; then
    echo "❌ symbol_names  只抽到 ${N} 个图标名（<40）—— 抽取规则或路径漂了，自检空转"
    echo "     ⇒ 检查本脚本的两类抽取规则是否还匹配得上源码写法"
    exit 2
fi

# `-parse-as-library` 必须加：驱动用了 `@main`，不加会被当成"带顶层代码的脚本"而报错
swiftc -O -parse-as-library -o "$BIN" "$ROOT/SelectedApp/Tools/SymbolCheck.swift" || exit 2
"$BIN" "$NAMES"
RC=$?

rm -rf "$TMP"
exit $RC