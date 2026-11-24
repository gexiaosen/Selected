#!/bin/bash
# schema 迁移自检 —— 老库升级 / 幂等 / 失败不推进 / 数据不丢
#
# 为什么要有它：
#   数据库是「**唯一不可再生的资产**」，而 `DBBootstrap.swift` 的迁移路径必须有
#   真库覆盖 —— 单元测试碰不到它，迁移写错了只在用户的老库上发作。
#
#   更要紧的是「全新库」路径**测不到迁移**：`schema_sql` 全是
#   `CREATE TABLE IF NOT EXISTS`，对已存在的表什么都不做 ⇒ 只有造一个
#   「有数据、缺列、版本号 = N-1」的**老库**才能测到 `ALTER TABLE`。
#
# 全程**离线**：库是在 $TMP 里现造的，不读也不碰生产库。
# 库是**每次现造**的（`rm -rf` 后重建），不留状态。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

source "$ROOT/SelectedApp/Tools/core_lib.sh"
TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/selected_migration_check.XXXXXX")"
BIN="${BIN:-$TMP/migration_check}"
DBDIR="$TMP/db"

rm -rf "$TMP" && mkdir -p "$DBDIR"

echo "== [1/2] 编译自检驱动 =="
swiftc -O -parse-as-library -I "$CORE_MODULE_DIR" -enable-testing \
    "$ROOT/SelectedApp/Tools/MigrationCheck.swift" \
    $CORE_OBJS -o "$BIN" || exit 2

echo ""
echo "== [2/2] 运行（库现造在 ${DBDIR}，全程离线）=="
# SELECTED_DATA_DIR 指向 $DBDIR：**绝不能**让它落到生产库
#   （`~/Library/Application Support/Selected/`）—— 驱动会在那里建表并改版本号。
OUT=$(SELECTED_DATA_DIR="$DBDIR" "$BIN" 2>&1)
RC=$?
printf '%s\n' "$OUT"
if [ $RC -ne 0 ]; then
    echo "❌ 迁移自检失败（exit ${RC}）"
    exit $RC
fi
# 项数**从驱动输出里取**，不手写 —— 与 `classify_test.sh` 同一个理由
#   （写死项数会让 spec 里的数字漂移而没人能发现）。
CNT=$(printf '%s\n' "$OUT" | grep -oE '检查 [0-9]+ 项' | tail -1 | grep -oE '[0-9]+')
echo "✅ migration  全部通过（老库升级 + 幂等 + 失败不推进 + 数据不丢：${CNT:-?} 项断言）"
exit 0
