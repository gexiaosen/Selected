#!/bin/bash
# 历史回放真实库自检 —— 隔离规则 / 口径标记 / 断点续传 / secid 口径
#
# 为什么要有它：这几条不变量都**只在真库上才成立**（要真 schema、真 PhaseStore 连接、
# 可切换的数据目录），而 XCTest 里换数据目录会写错库 —— `PhaseStore` / `SQLiteWriter`
# 的句柄是**进程级缓存**的。
#
# 全程**离线**：回放的两个分支（隔离规则 / 交易日历）都在发请求之前就返回，
#   所以这里不下载任何行情。真下载由 App 里的入口做。
# 库是**在 $TMP 里现造**的（`DBBootstrap.ensureReady`），不读也不碰生产库 ——
#   副本方案依赖"用户机器上恰好有一份真实数据"，CI/新克隆上会让护栏静默缺席。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

source "$ROOT/SelectedApp/Tools/core_lib.sh"
TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/selected_history_replay_check.XXXXXX")"
BIN="${BIN:-$TMP/history_replay_check}"
DBDIR="$TMP/db"

rm -rf "$TMP" && mkdir -p "$DBDIR"

echo "== [1/2] 编译自检驱动 =="
swiftc -O -parse-as-library -I "$CORE_MODULE_DIR" -enable-testing \
    "$ROOT/SelectedApp/Tools/HistoryReplayCheck.swift" \
    $CORE_OBJS -o "$BIN" || exit 2

echo ""
echo "== [2/2] 运行（库现造在 ${DBDIR}）=="
SELECTED_DATA_DIR="$DBDIR" "$BIN" all
RC=$?
if [ $RC -ne 0 ]; then
    echo "❌ history_replay 自检失败（exit ${RC}）"
    exit $RC
fi
echo "✅ history_replay   全部通过（隔离规则 + scan_mode DEFAULT + 断点续传 + secid 口径）"
exit 0
