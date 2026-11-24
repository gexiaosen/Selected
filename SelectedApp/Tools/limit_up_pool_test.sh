#!/bin/bash
# 涨停统计真实库自检 —— 建表 / 整日重插 / 查询 / 覆盖天数
#
# 为什么要在**真库**上：最要紧的那条（"整日重插不是追加"）要读回旧数据来证明
# "旧的被清掉、且没留下幽灵涨停股"，而 XCTest 里换数据目录会写错库
# （`SQLiteWriter` 的句柄是**进程级缓存**的）。
#
# 全程**离线**：本驱动不调 `LimitUpPoolSource`（那是网络）。
#   解析由 `swift test` 的 `LimitUpPoolTests` 用真实响应片段覆盖。
# 库是**在 $TMP 里现造**的（`DBBootstrap.ensureReady`），不读也不碰生产库。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

source "$ROOT/SelectedApp/Tools/core_lib.sh"
TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/selected_limit_up_pool_check.XXXXXX")"
BIN="${BIN:-$TMP/limit_up_pool_check}"
DBDIR="$TMP/db"

rm -rf "$TMP" && mkdir -p "$DBDIR"

echo "== [1/2] 编译自检驱动 =="
swiftc -O -parse-as-library -I "$CORE_MODULE_DIR" -enable-testing \
    "$ROOT/SelectedApp/Tools/LimitUpPoolCheck.swift" \
    $CORE_OBJS -o "$BIN" || exit 2

echo ""
echo "== [2/2] 运行（库现造在 ${DBDIR}）=="
SELECTED_DATA_DIR="$DBDIR" "$BIN"
RC=$?
if [ $RC -ne 0 ]; then
    echo "❌ limit_up_pool 自检失败（exit ${RC}）"
    exit $RC
fi
echo "✅ limit_up_pool   全部通过（建表 + 整日重插 + 查询 + 清空）"
exit 0
