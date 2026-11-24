#!/bin/bash
# 无头参数调优：把线上库**克隆**到临时目录，在副本上跑两档池的
# PhaseTune.tune()，各产一份 JSON —— 供跨池对比分析"更优解"。
#
# 线上库**全程只读**（`sqlite3 .clone` 是读侧动作）；一切改写只发生在副本上。
# 不进 run_all.sh / CI：它依赖"本机恰好有一份真实数据"，是**一次性分析工具**。
#
# 用法: ./tune_run.sh [输出目录]     （默认 outputs/tune_runs/<时间戳>/）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${1:-$ROOT/outputs/tune_runs/$STAMP}"
LIVE_DB="$HOME/Library/Application Support/Selected/selected.sqlite3"
TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/selected_tune_run.XXXXXX")"
DBDIR="$TMP/db"
BIN="$TMP/tune_run"

[ -f "$LIVE_DB" ] || { echo "❌ 找不到线上库：$LIVE_DB" >&2; exit 1; }
mkdir -p "$OUT"

echo "== [1/4] 克隆线上库到临时副本（线上只读）=="
rm -rf "$TMP" && mkdir -p "$DBDIR"
sqlite3 "$LIVE_DB" ".clone $DBDIR/selected.sqlite3" || { echo "❌ clone 失败" >&2; exit 1; }
LIVE_MTIME_BEFORE="$(stat -f %m "$LIVE_DB")"
echo "   副本：$DBDIR/selected.sqlite3（$(du -h "$DBDIR/selected.sqlite3" | cut -f1)）"

echo ""
echo "== [2/4] 编译调优驱动 =="
source "$ROOT/SelectedApp/Tools/core_lib.sh"
swiftc -O -parse-as-library -I "$CORE_MODULE_DIR" -enable-testing \
    "$ROOT/SelectedApp/Tools/TuneRun.swift" $CORE_OBJS -o "$BIN" || exit 2

echo ""
echo "== [3/4] 两档池（seed=42 固定）=="
# 为什么是两档而不是多档窗口对比：live 复盘日很少，不同 LIMIT 在小表上
#   取到同一张池，窗口对比会退化。⇒ 「live 窄池」+「含回放宽池」两档：
#   宽池（收盘价口径）的绝对值不作结论，只用来看**改动方向**是否跨池稳定
#   （跨池一致 = 可信信号；只在宽池赢 = 口径噪声）。
echo "-- A. live 池（120 天窗口，实际 13 个 live 日）--"
( cd "$ROOT" && SELECTED_DATA_DIR="$DBDIR" "$BIN" 120 "$OUT/tune_live.json" ) \
    || { echo "❌ live 池失败" >&2; exit 1; }
echo "-- B. 含回放宽池（120 天）--"
( cd "$ROOT" && SELECTED_DATA_DIR="$DBDIR" "$BIN" 120 "$OUT/tune_replay120.json" --replay ) \
    || { echo "❌ replay 池失败" >&2; exit 1; }

echo ""
echo "== [4/4] 线上库零写入校验 =="
LIVE_MTIME_AFTER="$(stat -f %m "$LIVE_DB")"
if [ "$LIVE_MTIME_BEFORE" != "$LIVE_MTIME_AFTER" ]; then
    echo "❌ 线上库 mtime 变了（不该发生）" >&2; exit 1
fi
echo "   ✅ mtime 不变：$LIVE_DB"
echo ""
echo "完成。产出："
ls -la "$OUT"/*.json
