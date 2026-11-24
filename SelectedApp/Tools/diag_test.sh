#!/bin/bash
# 数据源诊断读取侧自检
#
# 为什么单独一个脚本：诊断卡片的 bug 全是"看着能用、其实没生效"——
#   · 「按事件筛选」若在**已加载的 200 条里**过滤（而不是查库），用户点「错误」
#     看到的只是"这一窗里恰好有的错误"；
#   · 游标分页方向写反（替换而非追加）= "翻 4 页只有 266 条"（每页都在重复第一页）；
#   · 分类条数（筛选条上的「错误 2,065」）与实际库不一致。
# 三个都不会让任何编译/现有测试变红，只能靠断言钉住（详见 Tools/DiagCheck.swift 的注释）。
#
# 全部在**隔离的临时库**上跑（SELECTED_DATA_DIR），绝不触碰生产库。
#   schema 由 DBBootstrap.ensureReady() 走生产同款路径建（不手抄建表语句）。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/selected_diag_check.XXXXXX")"
BIN="${BIN:-$TMP/diag_check}"

echo "== [1/3] 编译自检程序 =="
rm -rf "$TMP" && mkdir -p "$TMP"
source "$ROOT/SelectedApp/Tools/core_lib.sh"
swiftc -O -parse-as-library -I "$CORE_MODULE_DIR" -enable-testing \
    "$ROOT/SelectedApp/Tools/DiagCheck.swift" \
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