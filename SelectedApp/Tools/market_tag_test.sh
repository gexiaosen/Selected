#!/bin/bash
# 市场标识与多市场行情解析自检 —— 徽章/前缀 + 港股/北交所行情
#
# 覆盖（全部离线）：
#   徽章表      科/创/上/深/北/基/港 + 交易所前缀（含 B 股、科创 ETF 属"基"优先）
#   市场推断    sh/sz/bj/hk；两条防回归边界：6 位深市码不得判成港股、920 号段必须是北交所
#   代码归一    digits / fullCode / isFundCode
#   行情解析    实录原文三条（沪A/港股/北交所）逐字段；港股"量比/市净率/换手率
#               必须留空"（腾讯港股字段布局与 A 股不同位，宁缺勿错）
#
# 为什么是自检：徽章与行情前缀是 Swift 侧单一实现（无其他侧对应展示逻辑可比），
# 断言在 MarketTagTest.swift 内，失败即非零退出。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/SelectedApp/Tools/core_lib.sh"
BIN_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/selected_market_tag_test.XXXXXX")"
BIN="${BIN:-$BIN_DIR/market_tag_test}"

echo "== 编译并跑市场标识自检 =="
swiftc -O -parse-as-library -I "$CORE_MODULE_DIR" -enable-testing \
    "$ROOT/SelectedApp/Tools/MarketTagTest.swift" \
    $CORE_OBJS -o "$BIN" || exit 2

"$BIN"
RC=$?

if [ "$RC" -eq 0 ]; then
    echo "✅ 全部通过（市场徽章/前缀 + 多市场行情解析）"
    exit 0
fi
echo "❌ 市场标识自检存在失败"
exit 1