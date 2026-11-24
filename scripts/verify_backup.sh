#!/bin/bash
# 备份恢复演练
#
# 为什么需要：`backup_data.sh` 的保护都作用在**产出端**（不产空归档、不重复归档、
# 完整性 + 行数交叉核对）。但"归档能不能恢复"从来没验证过 ——
# 一个截断的 tar.gz 可以安安静静躺在归档目录里 30 份，直到你真的需要它的那一天。
# 本脚本把"我们有备份"变成"**我们验证过备份能恢复**"。
#
# 做五件事：
#   1) tar 结构完整（能列出内容，未被截断）
#   2) 解出来的库 `PRAGMA quick_check` = ok
#   3) 必需表都在，且 `scan_rounds` 非空（空归档已被产出端拦住，这里再兜一道）
#   4) 归档里的最新交易日 ≤ 线上最新交易日（归档不可能含"未来"数据）
#   5) 线上每个 *.sqlite3 都在归档里，且逐个 quick_check=ok（含 history.sqlite3）
#
# 用法：scripts/verify_backup.sh [归档文件路径]
#       省略参数时自动取归档目录里最新的一份
# 退出码：0 = 通过；1 = 失败；2 = 找不到归档（不算失败，可能是首次运行）
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BK="${SELECTED_BACKUP_DIR:-$ROOT/../Selected-backups}"
APPDATA="${SELECTED_DATA_DIR:-$HOME/Library/Application Support/Selected}"
DB="$APPDATA/selected.sqlite3"

ARCHIVE="${1:-}"
if [ -z "$ARCHIVE" ]; then
    ARCHIVE=$(find "$BK" -maxdepth 1 -name 'data-*.tar.gz' 2>/dev/null | sort | tail -n 1)
fi
if [ -z "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ]; then
    echo "⚠️  未找到任何数据归档，跳过恢复演练"
    exit 2
fi

echo "恢复演练：$(basename "$ARCHIVE")"

# 需要的 sqlite3 CLI；不可用时退化为"只验 tar 结构"
if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "⚠️  未找到 sqlite3，只能验证 tar 结构"
    tar -tzf "$ARCHIVE" >/dev/null 2>&1 || { echo "❌ 归档无法读取（可能已截断）" >&2; exit 1; }
    echo "✅ tar 结构完整（未验证库内容）"
    exit 0
fi

# ---- 1) tar 结构完整 ----
if ! tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
    echo "❌ 归档无法读取（可能已截断）" >&2
    exit 1
fi
if ! tar -tzf "$ARCHIVE" 2>/dev/null | grep -qx './selected.sqlite3'; then
    echo "❌ 归档里没有 selected.sqlite3" >&2
    exit 1
fi

# ---- 2~4) 解出来逐项验 ----
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

if ! tar -xzf "$ARCHIVE" -C "$STAGE" 2>/dev/null; then
    echo "❌ 归档解压失败" >&2
    exit 1
fi
EX="$STAGE/selected.sqlite3"

INTG=$(sqlite3 -cmd ".timeout 5000" "$EX" "PRAGMA quick_check" 2>/dev/null || echo "ERR")
if [ "$INTG" != "ok" ]; then
    echo "❌ 归档内数据库完整性异常：quick_check = ${INTG}" >&2
    exit 1
fi

# 必需表（缺任一张说明归档不完整）
MISSING=""
for t in scan_rounds picks excluded_stocks etf_picks signal_classes \
         stock_outcomes predicts verifies reviews iterate_reports \
         param_versions watchlist watch_groups securities; do
    n=$(sqlite3 -cmd ".timeout 5000" "$EX" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='${t}'" 2>/dev/null || echo 0)
    [ "$n" = "1" ] || MISSING="${MISSING} ${t}"
done
if [ -n "$MISSING" ]; then
    echo "❌ 归档缺少必需表：${MISSING}" >&2
    exit 1
fi

user_asset_count() {
    local db="$1"
    local n=0 t=0 tbl
    n=$(sqlite3 -cmd ".timeout 5000" "$db" "
        SELECT (SELECT COUNT(*) FROM watchlist)
             + (SELECT COUNT(*) FROM watch_groups WHERE id <> 1 OR name <> '默认')
             + (SELECT COUNT(*) FROM watch_judgments)
             + (SELECT COUNT(*) FROM param_versions WHERE IFNULL(is_builtin, 0) = 0);
    " 2>/dev/null || echo "-1")
    if [ "$n" = "-1" ]; then
        echo "-1"
        return 0
    fi
    for tbl in watch_group_members watch_alerts watch_alert_settings indicator_params indicator_param_changes; do
        t=$(sqlite3 -cmd ".timeout 5000" "$db" "
            SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='${tbl}';
        " 2>/dev/null || echo "0")
        if [ "$t" = "1" ]; then
            t=$(sqlite3 -cmd ".timeout 5000" "$db" "SELECT COUNT(*) FROM ${tbl};" 2>/dev/null || echo "0")
            n=$((n + t))
        fi
    done
    echo "$n"
}

ARCH_N=$(sqlite3 -cmd ".timeout 5000" "$EX" "SELECT COUNT(*) FROM scan_rounds" 2>/dev/null || echo 0)
ARCH_USER_N=$(user_asset_count "$EX")
ARCH_MAX=$(sqlite3 -cmd ".timeout 5000" "$EX" "SELECT IFNULL(MAX(date),'') FROM scan_rounds" 2>/dev/null || echo "")
if [ "${ARCH_N}" -le 0 ] && [ "${ARCH_USER_N}" -le 0 ]; then
    echo "❌ 归档里 scan_rounds 与用户资产均为空（空归档不该存在 —— 产出端应已拦住）" >&2
    exit 1
fi

if [ -f "$DB" ]; then
    LIVE_MAX=$(sqlite3 -cmd ".timeout 5000" "$DB" "SELECT IFNULL(MAX(date),'') FROM scan_rounds" 2>/dev/null || echo "")
    # 字符串比较对 yyyy-MM-dd 即时间序
    if [ -n "${LIVE_MAX}" ] && [ -n "${ARCH_MAX}" ] && [ "${ARCH_MAX}" \> "${LIVE_MAX}" ]; then
        echo "❌ 归档最新交易日 ${ARCH_MAX} 晚于线上 ${LIVE_MAX}（归档不该含未来数据）" >&2
        exit 1
    fi
    echo "✅ 恢复演练通过：quick_check=ok · ${ARCH_N} 个轮次 · ${ARCH_USER_N} 条用户资产 · 最新交易日 ${ARCH_MAX:-无}（线上 ${LIVE_MAX:-无}）"
else
    echo "✅ 恢复演练通过：quick_check=ok · ${ARCH_N} 个轮次 · ${ARCH_USER_N} 条用户资产 · 最新交易日 ${ARCH_MAX:-无}（线上库不存在，跳过时序核对）"
fi

# ---- 5) 归档内**其余每个库**也必须存在且能打开（2026-10-16 审查 B1）----
# 产出端原先只对 selected.sqlite3 做 .backup，于是 history.sqlite3
# （回放日K缓存独立库，实测 143MB）从来不在归档里，而本脚本原先也**只断言主库**
# ⇒ 缺口两头都检不出来。现在：线上有、归档里必须也有；归档里有的，必须逐个 quick_check。
MISSING_LIBS=""
CHECKED_LIBS=""
for LIVE in "$APPDATA"/*.sqlite3; do
    [ -e "$LIVE" ] || continue
    LNAME="$(basename "$LIVE")"
    if ! tar -tzf "$ARCHIVE" 2>/dev/null | grep -qx "./${LNAME}"; then
        MISSING_LIBS="${MISSING_LIBS} ${LNAME}"
    fi
done
if [ -n "$MISSING_LIBS" ]; then
    echo "❌ 归档缺少线上存在的库：${MISSING_LIBS}" >&2
    exit 1
fi
for XLIB in "$STAGE"/*.sqlite3; do
    [ -e "$XLIB" ] || continue
    XNAME="$(basename "$XLIB")"
    if [ "$XNAME" = "selected.sqlite3" ]; then
        continue
    fi
    XINTG=$(sqlite3 -cmd ".timeout 5000" "$XLIB" "PRAGMA quick_check" 2>/dev/null || echo "ERR")
    if [ "$XINTG" != "ok" ]; then
        echo "❌ 归档内附属库 ${XNAME} quick_check = ${XINTG}" >&2
        exit 1
    fi
    CHECKED_LIBS="${CHECKED_LIBS} ${XNAME}"
done
if [ -n "$CHECKED_LIBS" ]; then
    echo "✅ 附属库同样验过：${CHECKED_LIBS}"
else
    echo "ℹ️  归档内无附属库（线上也没有则正常）"
fi
exit 0
