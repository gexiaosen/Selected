#!/bin/bash
# 列表池缓存自检（场内基金 funds + 港股 hk_list：整表替换 / 7 天 TTL / 主源降级 / 老库缺表）
#
# 两个池 × 7 场景（全部离线：主源不可用走 SELECTED_STOCK_LIST_HTTP=off 注入）：
#   schema     随包 schema_sql 能建出该表（列名与顺序）
#   roundtrip  整表替换往返（退市/更名不残留 / 顺序=代码升序 / 空表判定）
#   ttl-hit    当日缓存命中（不触网、不产生池事件）
#   ttl-miss   过期缓存 + 主源不可用 → 回退过期缓存并留痕
#   empty      空表 + 主源不可用 → 返回空并留痕 fatal（不崩）
#   fresh      TTL 边界（6 天新鲜 / 7 天过期 / nil 与脏日期视为过期）
#   no-table   老库未迁移（缺表）→ 读回空、整表替换抛错（不静默成功）
#
# 为什么是自检：两个池都只服务自选页搜索，引擎侧没有消费方可比对，
# 故为 Swift 自检（断言在 PoolListTest.swift 内，失败即非零退出）。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

source "$ROOT/SelectedApp/Tools/core_lib.sh"
TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/selected_pool_list_test.XXXXXX")"
BIN="${BIN:-$TMP/pool_list_test}"

# schema 同步校验由 `swift test` 里的 `SchemaExportTests` 负责
#   （"Swift 生成器重新生成的 JSON 与仓内文件逐字节相同"），这里不再重复。

echo "== [1/1] 编译并跑 2 池 × 7 场景（离线）=="
rm -rf "$TMP" && mkdir -p "$TMP"
swiftc -O -parse-as-library -I "$CORE_MODULE_DIR" -enable-testing \
    "$ROOT/SelectedApp/Tools/PoolListTest.swift" \
    $CORE_OBJS -o "$BIN" || exit 2

FAILED=0
for P in fund hk; do
    for S in schema roundtrip ttl-hit ttl-miss empty fresh no-table; do
        D="$TMP/${P}_${S}"
        if env SELECTED_STOCK_LIST_HTTP=off SELECTED_DATA_DIR="$D" \
                "$BIN" --pool "$P" --scenario "$S" \
                --schema "$ROOT/engine/params/db_schema_export.json"; then
            echo "   ✅ ${P}.${S}"
        else
            echo "   ❌ ${P}.${S}"
            FAILED=1
        fi
    done
done

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "✅ 全部通过（Swift 列表池缓存自检，2 池 × 7 场景）"
    exit 0
fi
echo "❌ 列表池缓存自检存在失败"
exit 1