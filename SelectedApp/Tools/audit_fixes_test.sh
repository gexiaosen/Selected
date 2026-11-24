#!/bin/bash
# 审计修复回归自检
#
# 为什么单独一个脚本：这类修复横跨 UI / Store / Scheduler / DataSources / DB 五层，
# 而 `swift test` 只覆盖 SelectedCore 纯逻辑层，其余改动仅经过
# `swift build` 的类型检查。「现有测试仍通过」只能证明**没改坏**，证明不了**新行为生效**。
# 本脚本把每条修复里可判定的部分钉成断言（只验 Swift 侧契约）。
#
# 覆盖：数据目录空串 / writeAsync 死锁 / 标签保护 / 幽灵行 /
#       PyRandom 边界 / applyDiff 非字典保留 / 假值兜底 / JSONValue 下标 / json 对象校验
#
# 全部在临时库上跑（SELECTED_DATA_DIR 隔离），绝不触碰生产库。
# 临时库由驱动自己走生产启动路径建（`AuditFixesTest bootstrap` →
#   `DBBootstrap.ensureReady()`）。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/selected_audit_fixes.XXXXXX")"
BIN="${BIN:-$TMP/audit_fixes_test}"

echo "== [1/3] 编译自检程序 =="
rm -rf "$TMP" && mkdir -p "$TMP"
source "$ROOT/SelectedApp/Tools/core_lib.sh"
swiftc -O -parse-as-library -I "$CORE_MODULE_DIR" -enable-testing \
    "$ROOT/SelectedApp/Tools/AuditFixesTest.swift" \
    $CORE_OBJS -o "$BIN" || exit 2

echo ""
echo "== [2/3] 准备临时库（走生产启动路径，与真实 App 同构）=="
SELECTED_DATA_DIR="$TMP" "$BIN" bootstrap || exit 2

echo ""
echo "== [3/3] 运行自检 =="
SELECTED_DATA_DIR="$TMP" "$BIN"
RC=$?

rm -rf "$TMP"
exit $RC
