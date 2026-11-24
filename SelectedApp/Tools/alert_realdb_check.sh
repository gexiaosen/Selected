#!/bin/bash
# 自选提醒 · **真实库**审计（按需，不进 run_all.sh）
#
# 为什么按需而不是进回归：它需要**用户本机真实库**
# （`~/Library/Application Support/Selected/selected.sqlite3`）—— 非 hermetic，
# 新机器 / CI 上都没有那个库。同 `compare_live_check.sh` 一类。
#
# 它覆盖 `AlertCheck`（进回归的那个）覆盖不到的：
#   ① **真实 30 MB 老库上的迁移** —— 空库里"建表"与"迁移"走同一条路，测不出老库拿不拿得到
#   ② **真实库里的提醒规则读写往返** —— 代码列 / REAL 精度 / 多规则 /
#      写后清干净，空库与测试库都证明不了
#
# 跑法（项目根目录）：
#     bash SelectedApp/Tools/alert_realdb_check.sh
#  或指定别的库（例如一份归档）：
#     SRC_DIR=~/Selected-backups/xxx bash SelectedApp/Tools/alert_realdb_check.sh
#
# 安全边界：**只读原库**。脚本把主文件 + `-wal` + `-shm` 拷到 $TMP 再跑，
#   跑完回读原库的 mtime 与 sqlite_master 作证（若原库被碰过会打印出来）。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

SRC_DIR="${SRC_DIR:-$HOME/Library/Application Support/Selected}"
TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/selected_alert_realdb.XXXXXX")"
DBDIR="$TMP/db"
BIN="${BIN:-$TMP/alert_realdb_check}"

if [ ! -f "$SRC_DIR/selected.sqlite3" ]; then
    echo "❌ 找不到真实库：$SRC_DIR/selected.sqlite3"
    echo "   （本项需要本机跑过 App；也可用 SRC_DIR=<某个归档目录> 指向备份）"
    exit 2
fi

# 原库指纹（跑完要对比）
BEFORE_MTIME="$(stat -f '%Sm' "$SRC_DIR/selected.sqlite3")"
BEFORE_ALERT_TABLES="$(sqlite3 "$SRC_DIR/selected.sqlite3" \
    "SELECT COALESCE(group_concat(name),'') FROM sqlite_master WHERE name LIKE 'watch_alert%';")"

rm -rf "$TMP" && mkdir -p "$DBDIR"
# 必须连 `-wal` 一起拷：最近的事务还在 WAL 里，只拷主文件会读到旧快照
for f in selected.sqlite3 selected.sqlite3-wal selected.sqlite3-shm; do
    [ -f "$SRC_DIR/$f" ] && cp "$SRC_DIR/$f" "$DBDIR/$f"
done
echo "== 已拷副本到 ${DBDIR}（原库：${SRC_DIR}）=="
ls -la "$DBDIR"

source "$ROOT/SelectedApp/Tools/core_lib.sh"

echo ""
echo "== 编译审计驱动 =="
swiftc -O -parse-as-library -I "$CORE_MODULE_DIR" -enable-testing \
    "$ROOT/SelectedApp/Tools/AlertRealDBCheck.swift" \
    $CORE_OBJS -o "$BIN" || exit 2

echo ""
echo "== 运行（库 = 生产库副本，全程不碰原库）=="
SELECTED_DATA_DIR="$DBDIR" "$BIN"
RC=$?

echo ""
echo "== 原库是否被动过 =="
AFTER_MTIME="$(stat -f '%Sm' "$SRC_DIR/selected.sqlite3")"
AFTER_ALERT_TABLES="$(sqlite3 "$SRC_DIR/selected.sqlite3" \
    "SELECT COALESCE(group_concat(name),'') FROM sqlite_master WHERE name LIKE 'watch_alert%';")"
if [ "$BEFORE_MTIME" = "$AFTER_MTIME" ] && [ "$BEFORE_ALERT_TABLES" = "$AFTER_ALERT_TABLES" ]; then
    echo "✅ 原库未被触碰（mtime 与告警表清单都不变）"
else
    echo "❌⚠ 原库指纹变了！"
    echo "   mtime: $BEFORE_MTIME → $AFTER_MTIME"
    echo "   告警表: [$BEFORE_ALERT_TABLES] → [$AFTER_ALERT_TABLES]"
    RC=1
fi

if [ $RC -ne 0 ]; then
    echo "❌ alert 真实库审计失败（exit ${RC}）"
    exit $RC
fi
echo "✅ alert 真实库审计通过（真实库迁移 + 引擎锚点真实数据链路）"
exit 0
