#!/bin/bash
# 分类标签（指数成份 / 基本面）真实库自检
# —— 建表 / 整表替换 / 反查 / **下界护栏** / 清空
#
# 为什么要有它：最要紧的那条不变量（"抓回来的数量不够就**不写库**"）只在**真库**上才成立 ——
# 它要读回旧数据来证明"一条没动"，而 XCTest 里换数据目录会写错库
# （`SQLiteWriter` / `SQLiteReader` 的句柄是**进程级缓存**的）。
#
# 全程**离线**：两个 Store 的 `refresh` 抓取闭包都由驱动注入，
#   本脚本不打任何网络请求。真实抓取由 App 设置页的「刷新」按钮做。
# 库是**在 $TMP 里现造**的（`DBBootstrap.ensureReady`），不读也不碰生产库。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

source "$ROOT/SelectedApp/Tools/core_lib.sh"
TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/selected_classify_check.XXXXXX")"
BIN="${BIN:-$TMP/classify_check}"
DBDIR="$TMP/db"

rm -rf "$TMP" && mkdir -p "$DBDIR"

echo "== [1/2] 编译自检驱动 =="
swiftc -O -parse-as-library -I "$CORE_MODULE_DIR" -enable-testing \
    "$ROOT/SelectedApp/Tools/ClassifyCheck.swift" \
    $CORE_OBJS -o "$BIN" || exit 2

echo ""
echo "== [2/2] 运行（库现造在 ${DBDIR}）=="
OUT=$(SELECTED_DATA_DIR="$DBDIR" "$BIN" 2>&1)
RC=$?
printf '%s\n' "$OUT"
if [ $RC -ne 0 ]; then
    echo "❌ classify 自检失败（exit ${RC}）"
    exit $RC
fi
# 项数**从驱动输出里取**，不写死：`run_all.sh` 抓摘要用的是
#   `grep -E '全部通过|检查 [0-9]+ 项|❌' | tail -1`，本行不带真实项数会把
#   驱动自报的"—— 检查 N 项，失败 0 项"盖掉，spec 里的项数就会漂移而没人发现。
# 改断言数不用改这里；spec 只需写"全绿（项数见输出）"。
CNT=$(printf '%s\n' "$OUT" | grep -oE '检查 [0-9]+ 项' | tail -1 | grep -oE '[0-9]+')
echo "✅ classify   全部通过（指数成份 + 基本面：建表 + 整表替换 + 反查 + 下界护栏 + 清空；${CNT:-?} 项断言）"
exit 0
