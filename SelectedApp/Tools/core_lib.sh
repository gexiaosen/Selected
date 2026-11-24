#!/bin/bash
# 公共前置：把 SelectedCore 编成**一次**，各自检脚本直接链接它。
#
# 为什么
# ---------------------------------------------------------------------------
# 若每个脚本**手工列出**它需要的几个 `.swift`，会有几个坑：
#   · **新增共享文件漏补清单** → 十几个套件同时编译失败
#   · **清单内文件必须零依赖** → 在低层文件里写一句跨层编排，12 个套件全红
#   · **路径漂移后静默失效**：写死旧路径时，`grep` 类护栏脚本会**静默通过**，
#     看着全绿其实什么都没查。
#
# 现在改为：`swift build` 产出 SelectedCore 的对象 + `.swiftmodule`，
# 脚本只编译**自己那一个**驱动文件并链接这些对象。
#   ① 清单消失 —— 新增 Core 文件无需改任何脚本
#   ② 单脚本编译从 ~20 个文件降到 1 个（实测 ~1.2s）
#   ③ 分层由编译器保证 —— 驱动文件只能看到 Core 的公开/`@testable` 符号
#
# 工具链 / SPM 布局坑（CI 首跑连抓两个）：
#   · runner 的 Swift 6.3.3 不产 `.build/debug/SelectedCore.o`
#     （单个合并对象，本机 6.4 产）⇒ 12 个套件齐挂。
#   · `.build/debug` **是符号链接**（本机 → out/Products/Debug，
#     runner → arm64-apple-macosx/debug）⇒ `find .build/debug …` **不跟随根符号链接**，
#     对着空气找 ⇒ 自适应发现也 0 命中。
#   ⇒ 正确姿势：先 `pwd -P` 规范化，再 `find -L` 找 `*SelectedCore*` 的 .o
#     （排除 *Tests*）；module 目录同样可异地。仍找不到 ⇒ 失败时 dump 布局。
#
# 用法（脚本里）
# ---------------------------------------------------------------------------
#     ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
#     source "$ROOT/SelectedApp/Tools/core_lib.sh"      # ← 会按需构建 Core
#     ...
#     swiftc -O -parse-as-library -I "$CORE_MODULE_DIR" -enable-testing \
#         "$ROOT/SelectedApp/Tools/XxxTest.swift" $CORE_OBJS -o "$BIN" || exit 2
#
# `$CORE_OBJS` **不要加引号**：它是对象路径列表（单对象时只有一个词）。
#
# 驱动文件顶部必须写 `@testable import SelectedCore`：
# `swift build` 的 debug 配置带 `-enable-testing`，`@testable` 让 internal 符号也可见，
# 所以脚本用得到 Core 的**内部** API（这是原同一模块编译时的既有能力，不能退化）。
#
# 注意：`core_lib.sh` 在 **source 时**就完成构建（不提供函数，避免各脚本写法不一）。
# 需要 `ROOT` 已定义；构建失败直接 `exit 2`。

: "${ROOT:?core_lib.sh 需要调用方先定义 ROOT}"

CORE_APP="$ROOT/SelectedApp"
CORE_MODULE_DIR="$CORE_APP/.build/debug"
# `.build/debug` 是**符号链接**（两种工具链指两个不同真实目录）⇒ 先规范化。
#   find 不跟随根符号链接（红③的直接根因）；规范化后一切检查/find 都落在真实目录。
if [ -d "$CORE_MODULE_DIR" ]; then
    CORE_MODULE_DIR="$(cd "$CORE_MODULE_DIR" && pwd -P)"
fi
CORE_DEBUG_ROOT="$CORE_MODULE_DIR"   # 固定锚点：规范化后的 debug 树根（永不被重指派）
CORE_OBJ="$CORE_MODULE_DIR/SelectedCore.o"
CORE_MODULE="$CORE_MODULE_DIR/SelectedCore.swiftmodule"
# 最终交给 swiftc 的对象列表
CORE_OBJS=""

_core_discover() {
    CORE_OBJS=""
    if [ -f "$CORE_OBJ" ]; then
        CORE_OBJS="$CORE_OBJ"
    else
        # per-file 对象（任何深度）；排除 *Tests*（SelectedCoreTests 的对象不能链进驱动）
        CORE_OBJS=$(find -L "$CORE_DEBUG_ROOT" -name '*.o' -path '*SelectedCore*' \
                    ! -path '*Tests*' 2>/dev/null | tr '\n' ' ')
    fi
    if [ ! -e "$CORE_MODULE" ]; then
        _m=$(find -L "$CORE_DEBUG_ROOT" -name 'SelectedCore.swiftmodule' 2>/dev/null | head -1)
        if [ -n "$_m" ]; then
            # 两个变量都要更新：CORE_MODULE 供存在性检查，CORE_MODULE_DIR 供 -I
            # （红④：只改 DIR 不改 MODULE ⇒ 检查永远对着旧路径 ⇒ 误判"module 缺失"）
            CORE_MODULE="$_m"
            CORE_MODULE_DIR="$(dirname "$_m")"
        fi
    fi
}

_core_discover

_core_stale=""
[ -z "$CORE_OBJS" ] && _core_stale="产物缺失"
[ -e "$CORE_MODULE" ] || _core_stale="${_core_stale:+$_core_stale + }module 缺失"
if [ -z "$_core_stale" ] && [ -f "$CORE_OBJ" ]; then
    [ -n "$(find "$CORE_APP/Sources/SelectedCore" -name '*.swift' -newer "$CORE_OBJ" -print -quit 2>/dev/null)" ] \
        && _core_stale="源码有变更"
fi

if [ -n "$_core_stale" ]; then
    echo "== [0] 构建 SelectedCore（${_core_stale}）=="
    if ! ( cd "$CORE_APP" && swift build --disable-sandbox ); then
        echo "❌ SelectedCore 构建失败（对账/自检无法继续）"
        exit 2
    fi
    _core_discover
fi

if [ -z "$CORE_OBJS" ] || [ ! -e "$CORE_MODULE" ]; then
    echo "❌ 构建后仍找不到 SelectedCore 的对象/module（对象数：$(printf '%s' "$CORE_OBJS" | wc -w)）"
    echo "   —— CORE_DEBUG_ROOT=$CORE_DEBUG_ROOT"
    echo "   —— 顶层 40 项："
    ls -la "$CORE_DEBUG_ROOT" 2>&1 | head -40
    echo "   —— 树前三层全部条目（前 60，供判型）："
    find -L "$CORE_DEBUG_ROOT" -maxdepth 3 2>&1 | head -60
    exit 2
fi
