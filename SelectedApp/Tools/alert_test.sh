#!/bin/bash
# 自选提醒（用户自定义告警）真实库自检 —— 建表 / 保存读回 / 触发与去重 /
# 状态继承 / 降级迁移 / 脏行容错
#
# 为什么要在**真库**上：
#   · 「降级 → 迁移 → 幂等」要 `DROP TABLE` 再跑迁移，而 XCTest 里换数据目录会写错库
#     （`SQLiteWriter` / `AlertReader` 的句柄是**进程级缓存**的）；
#   · 最要紧的两条不变量（未变规则**继承**触发状态 / 改阈值**重新武装**）
#     需要"写 → 读回 → 再写 → 再读回"的完整往返。
#
# 全程**离线**：本驱动不调 `StockQuotes.fetch*`（那是网络）；
#   行情用 `StockQuotes.parseBatch` 吃真实抓取的响应原文构造（走生产解析器）。
# 库是**在 $TMP 里现造**的（`DBBootstrap.ensureReady`），不读也不碰生产库。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

source "$ROOT/SelectedApp/Tools/core_lib.sh"
TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/selected_alert_check.XXXXXX")"
BIN="${BIN:-$TMP/alert_check}"
DBDIR="$TMP/db"

rm -rf "$TMP" && mkdir -p "$DBDIR"

echo "== [1/2] 编译自检驱动 =="
swiftc -O -parse-as-library -I "$CORE_MODULE_DIR" -enable-testing \
    "$ROOT/SelectedApp/Tools/AlertCheck.swift" \
    $CORE_OBJS -o "$BIN" || exit 2

echo ""
echo "== [2/2] 运行（库现造在 ${DBDIR}）=="
SELECTED_DATA_DIR="$DBDIR" "$BIN"
RC=$?
if [ $RC -ne 0 ]; then
    echo "❌ alert 自检失败（exit ${RC}）"
    exit $RC
fi
echo "✅ alert   全部通过（建表 + 保存读回 + 触发去重 + 状态继承 + 降级迁移）"
exit 0
