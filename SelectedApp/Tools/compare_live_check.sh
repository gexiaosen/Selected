#!/bin/bash
# 生产数据端到端自检（按需审计驱动，**不进回归** —— 见 run_all.sh 头部的登记）
#
# 用**生产库**的真实三轮数据（默认取最近有完整三轮的日期）跑原生 compare，只读不写，
# 并断言报告结构完整（不是空壳）。
#
# 这是**结构自检**（不比对任何历史期望值）：夹具只是一天的快照，
#   证明不了生产库里那些"三轮不全 / 有缺口 / 含历史回放标记"的真实数据
#   不会让 compare 崩或产出空壳。
#
# 非 hermetic（需要本机真实生产库）⇒ **不能进回归**。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

source "$ROOT/SelectedApp/Tools/core_lib.sh"
DATA_DIR="${SELECTED_DATA_DIR:-$HOME/Library/Application Support/Selected}"
BIN_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/selected_compare_live.XXXXXX")"
BIN="${BIN:-$BIN_DIR/compare_live}"
DATE="${1:-}"
TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/selected_compare_live.XXXXXX")"
mkdir -p "$TMP"

if [ -z "$DATE" ]; then
    DATE=$(sqlite3 -readonly "$DATA_DIR/selected.sqlite3" \
        "select date from scan_rounds where status='ok' group by date having count(distinct slot)>=3 order by date desc limit 1;")
fi
[ -n "$DATE" ] || { echo "❌ 生产库没有完整三轮的日期"; exit 2; }
echo "== 生产数据端到端自检：日期 $DATE =="

echo ""
echo "== [1/2] 编译 =="
swiftc -O -parse-as-library -I "$CORE_MODULE_DIR" -enable-testing \
    "$ROOT/SelectedApp/Tools/CompareLive.swift" \
    $CORE_OBJS -o "$BIN" || exit 2

echo ""
echo "== [2/2] 跑原生 compare + 结构自检 =="
SELECTED_DATA_DIR="$DATA_DIR" "$BIN" "$DATE" "$TMP/native.json"
