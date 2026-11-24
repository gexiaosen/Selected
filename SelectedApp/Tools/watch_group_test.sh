#!/bin/bash
# 「复制到分组」的分组归属自检
#
# 覆盖（全部离线，跑在**临时空库**上）：
#   ① add 之后归属 = {默认组}
#   ② copyTo 加一份归属，原来那份保留（= 一只股票同时在多个分组）
#   ③ 主分组（`watchlist.group_id`）始终 = 归属里**最小**的那个
#   ④ moveWithin **只**从 from 移除，其它归属保留（"组内操作"语义）
#   ⑤ moveWithin(from == to) 幂等
#   ⑥ 重跑 `ensureReady` **不重置**多归属（`backfillWatchGroupMembers` 的 NOT EXISTS）
#   ⑦ remove 之后归属清空（防"重新加进来带着幽灵归属"）
#   ⑧ groupDelete：多归属的票仍在自选，只属于该组的才删
#   ⑨ 删组后主分组回落到剩下的那个
#   ⑩ 删较小非默认组：多分组主归属同步迁至剩余最小组，独属票级联清提醒与时间窗
#   ⑪ WatchStore.remove 同事务清理提醒
#   ⑫ DBBootstrap.ensureReady 启动清理孤儿提醒
#
# 为什么是自检：`watch_group_members` 是 **Swift-only** 表，没有另一侧实现可比
# （详见 WatchGroupCheck.swift 头部注释）。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/SelectedApp/Tools/core_lib.sh"
BIN_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/selected_watch_group_test.XXXXXX")"
BIN="${BIN:-$BIN_DIR/watch_group_test}"

echo "== 编译并跑分组归属自检 =="
swiftc -O -parse-as-library -I "$CORE_MODULE_DIR" -enable-testing \
    "$ROOT/SelectedApp/Tools/WatchGroupCheck.swift" \
    $CORE_OBJS -o "$BIN" || exit 2

# 必须给一个**空目录**：断言里有"归属恰好等于某个集合"这类精确比较，
#   上一轮的残留会直接污染它。
# 用绝对路径 `/bin/rm`：PATH 里可能有 safe-delete 垫片（把删除换成"挪进废纸篓"
#   并**返回 0**），那样 `rm -rf` 会静默失败、残留跨轮次累积。
DATA="$(mktemp -d "${TMPDIR:-/tmp}/watch_group_check.XXXXXX")"
trap '/bin/rm -rf "$DATA"' EXIT

SELECTED_DATA_DIR="$DATA" "$BIN"
RC=$?

if [ "$RC" -eq 0 ]; then
    echo "✅ 全部通过（分组归属：复制 / 组内移动 / 迁移幂等 / 删组）"
    exit 0
fi
echo "❌ 分组归属自检存在失败"
exit 1
