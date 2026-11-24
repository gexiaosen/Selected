#!/bin/bash
# 写库基础设施验证
#
# 覆盖：类型往返 / 事务回滚 / 并发写 / 与**另一个进程**的互操作
#       （Swift 写→他进程读、他进程写→Swift 读、两进程同时写同一库）
#
# 互操作的"另一侧"是 **`sqlite3` CLI**：这几步验的是**跨进程可见性 + busy_timeout**，
#   跟"另一侧是什么语言"无关 —— 用 CLI 一样能证（而且更轻）。
#
# 全部在临时库上跑（SELECTED_DATA_DIR 隔离），绝不触碰生产库。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/selected_writer_test.XXXXXX")"
BIN="${BIN:-$TMP/writer_test}"
DB="$TMP/selected.sqlite3"

echo "== [1/6] 编译验证程序 =="
rm -rf "$TMP" && mkdir -p "$TMP"
source "$ROOT/SelectedApp/Tools/core_lib.sh"
swiftc -O -parse-as-library -I "$CORE_MODULE_DIR" -enable-testing \
    "$ROOT/SelectedApp/Tools/WriterTest.swift" \
    $CORE_OBJS -o "$BIN" || exit 2

echo ""
echo "== [2/6] 建库（走生产启动路径 DBBootstrap.ensureReady）+ _writer_test =="
SELECTED_DATA_DIR="$TMP" "$BIN" bootstrap || exit 2
echo "   journal_mode = $(sqlite3 "$DB" 'PRAGMA journal_mode;')"

echo ""
echo "== [3/6] Swift 写入（类型往返 + 只读层可见性）=="
SELECTED_DATA_DIR="$TMP" "$BIN" write || exit 1
SELECTED_DATA_DIR="$TMP" "$BIN" read || exit 1

echo ""
echo "== [4/6] 另一进程读 Swift 写的数据（跨进程互操作）=="
got=$(sqlite3 "$DB" "SELECT txt || '|' || num || '|' || intg || '|' || flag || '|' || COALESCE(nullable,'NULL') FROM _writer_test WHERE id=1;")
want="中文文本 A|3.14159|42|1|NULL"
if [ "$got" = "$want" ]; then
    echo "   ✅ 另一进程读到 Swift 写入的第 1 行：$got"
else
    echo "   ❌ 第 1 行不符：实得「${got}」期望「${want}」"; exit 1
fi
n=$(sqlite3 "$DB" "SELECT COUNT(*) FROM _writer_test;")
[ "$n" = "3" ] || { echo "   ❌ 期望 3 行，实得 $n"; exit 1; }
echo "   ✅ 共 3 行"

echo ""
echo "== [5/6] 另一进程写 → Swift 读（只读层与写连接都要看到）=="
sqlite3 "$DB" "INSERT OR REPLACE INTO _writer_test(id, txt, num) VALUES(7, 'from-cli', 2.5);"
echo "   另一进程写入 id=7"
SELECTED_DATA_DIR="$TMP" "$BIN" rollback || exit 1
n=$(sqlite3 "$DB" "SELECT COUNT(*) FROM _writer_test WHERE id=7;")
[ "$n" = "1" ] || { echo "   ❌ id=7 应仍在（Swift 的 rollback 测试不应影响它），实得 $n"; exit 1; }
echo "   ✅ 另一进程写的数据未被 Swift 事务影响"

echo ""
echo "== [6/6] 两进程同时写同一库（模拟引擎服务并发）=="
# 另一进程持续写 40 条，同时 Swift 侧并发写 60 条 → 验证 busy_timeout 生效、无丢失
# **必须是一个 `sqlite3` 进程（单连接）**：每条 `INSERT` 各起一个进程会因拿不到写锁
#   而静默丢行（实测 40 条只落 39 条，且 `sqlite3` 不报错退出码仍为 0）。
#   单连接连写 40 条才不会因反复拿放写锁丢行。
(
    # `.timeout` 必须有：`sqlite3` CLI 默认 busy_timeout = 0 → 撞上 Swift 的写锁时
    #   直接报 SQLITE_BUSY 并跳过该行**（退出码仍是 0！）→ 实测 40 条只落 7～39 条。
    {
        echo ".timeout 30000"
        for i in $(seq 0 39); do
            echo "INSERT OR REPLACE INTO _writer_test(id, txt) VALUES($((2000+i)), 'cli-$i');"
        done
    } | sqlite3 "$DB"
    echo "   另一进程写入 40 条"
) &
CLI_PID=$!
SELECTED_DATA_DIR="$TMP" "$BIN" concurrent || { kill $CLI_PID 2>/dev/null; exit 1; }
wait $CLI_PID
cli=$(sqlite3 "$DB" "SELECT COUNT(*) FROM _writer_test WHERE id>=2000;")
sw=$(sqlite3 "$DB" "SELECT COUNT(*) FROM _writer_test WHERE id>=1000 AND id<2000;")
[ "$cli" = "40" ] || { echo "   ❌ 另一进程侧应 40 条，实得 $cli"; exit 1; }
[ "$sw" = "0" ] || { echo "   ❌ Swift 并发测试数据应已清理，实得 $sw"; exit 1; }
echo "   ✅ 并发写无丢失（另一进程 $cli 条完整；Swift 侧 60 条已自行校验并清理）"

echo ""
echo "✅ 写库基础设施验证全部通过"
