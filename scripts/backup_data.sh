#!/bin/bash
# Selected 备份脚本
# 版本记录与源码备份已由 git（本地 + GitHub）接管，本脚本只做两件事：
#   1) 选股数据库归档：tar.gz 备份应用真实数据（~/Library/Application Support/Selected），
#      滚动保留最近 KEEP_DATA 份——数据库是唯一不可再生资产
#   2) 产物滚动清理：dist 备份/install 备份超量移入废纸篓（正常流程已不再新增，兜底旧残留）
# 用法: ./scripts/backup_data.sh     （由 build_app.sh 打包后自动调用）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BK="${SELECTED_BACKUP_DIR:-$ROOT/../Selected-backups}"
TRASH="$HOME/.Trash"
APPDATA="${SELECTED_DATA_DIR:-$HOME/Library/Application Support/Selected}"
KEEP_DATA=5    # 数据归档保留份数（实测每份 ~76M，5 份 ≈ 380M；原写「0.5M/份」低估 150 倍）

[ -d "$BK" ] || mkdir -p "$BK"

# `sqlite3` CLI 是**硬依赖**，缺了就直接退出（不要试图兜底）。
#
# 不做 Python 兜底，它**买不到任何东西**：`snapshot_db` 返回后**紧接着两行**就无条件调用
#   `sqlite3`（`PRAGMA integrity_check` 与 `scan_rounds` 行数比对），本脚本另有 13 处 `sqlite3`，
#   `verify_backup.sh` 还有 12 处。CLI 缺失时兜底"成功"只会让失败**更晚、更难懂**。
#   ⇒ fail-fast：**在开头就报清楚**，而不是产出半成品归档。
if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "❌ 需要 sqlite3 CLI（macOS 自带；本脚本的完整性校验与行数比对都依赖它）" >&2
    exit 1
fi

# SQLite 在线快照：$1=源库 $2=目标库
# 必须走备份 API —— WAL 模式下未 checkpoint 的写入不在主库文件里，直接拷主库会**静默丢数据**。
snapshot_db() {
    local src="$1" dst="$2"
    sqlite3 -cmd ".timeout 5000" "$src" ".backup '$dst'"
}

# 统计用户配置与资产行数（即使尚未跑过选股扫描，有自选/分组/提醒/指标参数/自建参数版本也算有效资产）。
# ⚠ watch_group_members / watch_alerts / watch_alert_settings / indicator_params /
#   indicator_param_changes 为 Swift-only 表；未跑过 App 初始化的老库可能缺表，需先探测存在性。
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

# 1) 选股数据库归档
if [ -d "$APPDATA" ]; then
    TS=$(date +%Y%m%d-%H%M%S)
    STAGE=$(mktemp -d)
    DB="$APPDATA/selected.sqlite3"
    SIGFILE="$BK/.last-backup-signature"
    # ⚠ 主库不存在是**硬失败**（2026-10-16 审查 B1）：原先下面只有 `if [ -f "$DB" ]`、没有 else，
    #   于是主库缺失时整段被跳过，但**再下面仍无条件 `tar`** 并打印「数据归档: data-….tar.gz」——
    #   产出一份不含任何库的空壳归档，还成为最新归档赢过滚动窗口。
    #   「报备份成功而实际没备」比不备更糟：数据库是唯一不可再生资产。
    if [ ! -f "$DB" ]; then
        echo "❌ 主库不存在：${DB} —— 不产出归档" >&2
        echo "   先确认数据目录是否被移动/重命名（或 App 从未启动过），再重新打包。" >&2
        rm -rf "$STAGE"
        exit 1
    fi
    # 非数据库文件直接复制（数据库单独做一致性快照，避免拷到半截 WAL 状态）
    rsync -a --exclude '*.sqlite3' --exclude '*.sqlite3-wal' --exclude '*.sqlite3-shm' \
        --exclude 'logs' "$APPDATA/" "$STAGE/" 2>/dev/null
    if [ -f "$DB" ]; then
        if ! snapshot_db "$DB" "$STAGE/selected.sqlite3"; then
            echo "❌ 数据库快照失败（sqlite3 .backup 出错；见上方输出）" >&2
            rm -rf "$STAGE"
            exit 1
        fi
        # 归档前自检：完整性 + 关键表行数与线上一致（不一致宁可不产出归档）
        # 注意：变量后紧跟中文时必须用 ${} 定界 —— macOS bash 3.2 会把多字节字符
        # 的首字节算进变量名（表现为 unbound variable）
        INTG=$(sqlite3 -cmd ".timeout 5000" "$STAGE/selected.sqlite3" "PRAGMA integrity_check" 2>/dev/null || echo "ERR")
        LIVE_N=$(sqlite3 -cmd ".timeout 5000" "$DB" "SELECT COUNT(*) FROM scan_rounds" 2>/dev/null || echo "-1")
        BAK_N=$(sqlite3 -cmd ".timeout 5000" "$STAGE/selected.sqlite3" "SELECT COUNT(*) FROM scan_rounds" 2>/dev/null || echo "-2")
        LIVE_USER_N=$(user_asset_count "$DB")
        BAK_USER_N=$(user_asset_count "$STAGE/selected.sqlite3")
        if [ "$INTG" != "ok" ] || [ "$LIVE_N" != "$BAK_N" ] || [ "$LIVE_USER_N" != "$BAK_USER_N" ] || [ "$BAK_N" -lt 0 ] || [ "$BAK_USER_N" -lt 0 ]; then
            echo "❌ 备份自检失败：integrity=${INTG}，线上轮次=${LIVE_N} / 备份轮次=${BAK_N}，用户资产=${LIVE_USER_N} / ${BAK_USER_N}（不产出归档）" >&2
            rm -rf "$STAGE"
            exit 1
        fi
        echo "  数据库快照自检通过：integrity=ok，scan_rounds=${BAK_N}，用户资产=${BAK_USER_N}（含 WAL）"

        # ---- 空库保护 ----
        # 上面的自检只比"备份与线上是否一致"：库被误删/迁移失败后重建时，
        # 线上真的是 0 行 → `0 == 0` 通过 → **照样产出一份空归档，并把最老的好归档挤掉**。
        # 滚动只留 5 份，连续几次空构建就能把有历史价值的备份全冲走。
        # 判据：即将归档核心轮次与用户配置资产同时为 0、而归档目录里已经有历史归档 → 几乎必然是"库出了问题"，
        # 不是"用户主动清空了全部数据"（同时不误拦「还没开始选股，但已录入自选/分组/提醒/参数」的用户库）。此时拒绝产出（宁可不备份，也不能覆盖好的）。
        # 用 find 而不是 `ls data-*.tar.gz`：本脚本是 `set -euo pipefail`，
        #   而 `ls` 无匹配时返回非零 → 管道整体失败 → **脚本会静默中止**。
        #   find 无匹配时仍返回 0。
        EXISTING=$(find "$BK" -maxdepth 1 -name 'data-*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')
        if [ "${BAK_N}" = "0" ] && [ "${BAK_USER_N}" = "0" ] && [ "${EXISTING}" -gt 0 ]; then
            echo "❌ 拒绝归档空库：即将备份的库 scan_rounds=0 且用户资产=0，而归档目录已有 ${EXISTING} 份历史归档。" >&2
            echo "   这通常意味着数据库被重建或迁移失败，而不是真的没有数据。" >&2
            echo "   如确认要归档空库，请先手动移走 $BK/data-*.tar.gz 后再运行。" >&2
            rm -rf "$STAGE"
            exit 1
        fi

        # ---- 附属库也必须快照（2026-10-16 审查 B1）----
        # 上面 rsync 排除了**所有** *.sqlite3，而这里原先只对 selected.sqlite3 做 .backup，
        # 于是 history.sqlite3（回放日K缓存独立库，README:150 明确列出、实测 143MB）
        # **不在任何归档里**；verify_backup.sh 又只断言主库必需表 ⇒ 这个缺口检测不到。
        # 后果不是"少备一点"，而是恢复后要从**已被限流的东财出口 IP** 重下全市场日K。
        for EXTRA_DB in "$APPDATA"/*.sqlite3; do
            [ -e "$EXTRA_DB" ] || continue
            EXTRA_NAME="$(basename "$EXTRA_DB")"
            [ "$EXTRA_NAME" = "selected.sqlite3" ] && continue
            if ! snapshot_db "$EXTRA_DB" "$STAGE/$EXTRA_NAME"; then
                echo "❌ 附属库快照失败：${EXTRA_NAME}（sqlite3 .backup 出错；见上方输出）" >&2
                rm -rf "$STAGE"
                exit 1
            fi
            EXTRA_INTG=$(sqlite3 -cmd ".timeout 5000" "$STAGE/$EXTRA_NAME" "PRAGMA integrity_check" 2>/dev/null || echo "ERR")
            if [ "$EXTRA_INTG" != "ok" ]; then
                echo "❌ 附属库完整性自检失败：${EXTRA_NAME} → ${EXTRA_INTG}（不产出归档）" >&2
                rm -rf "$STAGE"
                exit 1
            fi
            echo "  附属库快照自检通过：${EXTRA_NAME}（$(du -h "$STAGE/$EXTRA_NAME" | cut -f1)，含 WAL）"
        done

        # ---- 内容去重 ----
        # build_app.sh 每次构建都调用本脚本，而数据往往没有变化 → 5 份滚动窗口里
        # 大半是内容相同的快照，真正有历史价值的那份被挤掉。
        # 签名取"行数 + 最大自增 id/时间戳"，能同时捕获新增与就地更新；
        # 任一表不存在（老库）时 sqlite3 会报错 → 签名为空 → 此时**不做去重**（宁可多备一份）。
        SIGNOW=$(sqlite3 -cmd ".timeout 5000" "$STAGE/selected.sqlite3" "
            SELECT (SELECT COUNT(*) FROM scan_rounds) || '|' ||
                   IFNULL((SELECT MAX(id) FROM scan_rounds), 0) || '|' ||
                   (SELECT COUNT(*) FROM picks) || '|' ||
                   IFNULL((SELECT MAX(id) FROM picks), 0) || '|' ||
                   (SELECT COUNT(*) FROM stock_outcomes) || '|' ||
                   IFNULL((SELECT MAX(updated_at) FROM stock_outcomes), '') || '|' ||
                   (SELECT COUNT(*) FROM reviews) || '|' ||
                   IFNULL((SELECT MAX(updated_at) FROM reviews), '') || '|' ||
                   (SELECT COUNT(*) FROM signal_classes) || '|' ||
                   (SELECT COUNT(*) FROM param_versions) || '|' ||
                   IFNULL((SELECT MAX(created_at) FROM param_versions), 0) || '|' ||
                   (SELECT COUNT(*) FROM watchlist) || '|' ||
                   IFNULL((SELECT MAX(added_at) FROM watchlist), '') || '|' ||
                   IFNULL((SELECT TOTAL(IFNULL(group_id,0)) FROM watchlist), 0) || '|' ||
                   IFNULL((SELECT SUM(IFNULL(is_holding,0)) FROM watchlist), 0) || '|' ||
                   IFNULL((SELECT TOTAL(IFNULL(cost_price,0)) FROM watchlist), 0) || '|' ||
                   IFNULL((SELECT TOTAL(IFNULL(shares,0)) FROM watchlist), 0) || '|' ||
                   (SELECT COUNT(*) FROM watch_groups) || '|' ||
                   IFNULL((SELECT MAX(created_at) FROM watch_groups), '') || '|' ||
                   (SELECT COUNT(*) FROM watch_judgments) || '|' ||
                   IFNULL((SELECT MAX(created_at) FROM watch_judgments), '') || '|' ||
                   (SELECT COUNT(*) FROM counters) || '|' ||
                   IFNULL((SELECT GROUP_CONCAT(hex(key) || ':' || hex(IFNULL(value,'')), ',') FROM (SELECT key, value FROM counters ORDER BY key)), '')
        " 2>/dev/null || true)
        if [ -n "${SIGNOW}" ]; then
            # 补充 Swift-only 用户表指纹（逐表探测存在性，避免未初始化过这些表的老库把 SIGNOW 整段打空）
            for _tbl_expr in \
                "watch_group_members|SELECT COUNT(*) || ':' || IFNULL(GROUP_CONCAT(hex(code) || '.' || group_id, ','), '') FROM (SELECT code, group_id FROM watch_group_members ORDER BY code, group_id)" \
                "watch_alerts|SELECT COUNT(*) || ':' || IFNULL(MAX(updated_at), '') || ':' || IFNULL(MAX(last_fired_at), '') FROM watch_alerts" \
                "watch_alert_settings|SELECT COUNT(*) || ':' || IFNULL(MAX(updated_at), '') || ':' || IFNULL(GROUP_CONCAT(hex(code) || '.' || hex(time_window), ','), '') FROM (SELECT code, time_window FROM watch_alert_settings ORDER BY code)" \
                "indicator_params|SELECT COUNT(*) || ':' || IFNULL(MAX(updated_at), '') || ':' || IFNULL(GROUP_CONCAT(hex(key) || '.' || printf('%.17g', value), ','), '') FROM (SELECT key, value FROM indicator_params ORDER BY key)" \
                "indicator_param_changes|SELECT COUNT(*) || ':' || IFNULL(MAX(ts), '') FROM indicator_param_changes"
            do
                _tbl="${_tbl_expr%%|*}"
                _sql="${_tbl_expr#*|}"
                _exists=$(sqlite3 -cmd ".timeout 5000" "$STAGE/selected.sqlite3" \
                    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='${_tbl}'" 2>/dev/null || echo "0")
                if [ "$_exists" = "1" ]; then
                    _part=$(sqlite3 -cmd ".timeout 5000" "$STAGE/selected.sqlite3" "$_sql" 2>/dev/null || echo "err")
                else
                    _part="absent"
                fi
                SIGNOW="${SIGNOW}|${_tbl}=${_part}"
            done

            # ⚠ 签名必须在 WAL 合并后的 `$STAGE/*.sqlite3` 上统计体积与校验和（而非直接 stat `$APPDATA`）：
            #   未 checkpoint 的写入（如 history.sqlite3 或未入上方 SIGNOW 的表）仅停在 -wal 里时，
            #   `$APPDATA/*.sqlite3` 文件大小不变；且 `$STAGE` 文件经 .backup 合并后对内容就地改动也能反映出来。
            DBSIZ=""; for f in "$STAGE"/*.sqlite3; do
                [ -e "$f" ] || continue
                if command -v shasum >/dev/null 2>&1; then
                    _hash=$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')
                else
                    _hash=$(cksum "$f" 2>/dev/null | awk '{print $1}')
                fi
                DBSIZ="${DBSIZ}|$(basename "$f"):$(stat -f%z "$f" 2>/dev/null || echo 0):${_hash}"
            done
            SIGNOW="${SIGNOW}${DBSIZ}"
        fi
        # ⚠ 去重的前提是**上一次那份归档真的还在**（2026-10-23 实测缺陷）：
        #   原先只比签名文件，于是归档被移走/删掉之后，脚本会永远打印"内容未变，跳过本次归档"，
        #   而恢复演练那边只会说"未找到归档，跳过 —— 不算失败" ⇒ 安全网空了却仍然报成功。
        #   签名对得上但目录里一份 `data-*.tar.gz` 都没有 ⇒ 不去重，当场补一份。
        HAVEARCHIVE="$(ls -1 "$BK"/data-*.tar.gz 2>/dev/null | head -1 || true)"
        if [ -n "${SIGNOW}" ] && [ -f "$SIGFILE" ] && [ "$(cat "$SIGFILE" 2>/dev/null || true)" = "${SIGNOW}" ] && [ -n "$HAVEARCHIVE" ]; then

            echo "  内容未变，跳过本次归档（保留滚动窗口给真正不同的状态）"
            rm -rf "$STAGE"
            # 不能在这里 `exit 0` —— 后面的"恢复演练"要对**已有**归档跑，
            #   跳过本次归档不等于跳过验证。
            SKIP_ARCHIVE=1
        elif [ -n "${SIGNOW}" ] && [ -f "$SIGFILE" ] && [ "$(cat "$SIGFILE" 2>/dev/null || true)" = "${SIGNOW}" ]; then
            echo "  ⚠ 签名说「已归档过」，但 $BK 里一份 data-*.tar.gz 都没有 —— 不去重，补一份"
        fi
    fi
    if [ "${SKIP_ARCHIVE:-0}" = "0" ]; then
        tar -czf "$BK/data-$TS.tar.gz" -C "$STAGE" . 2>/dev/null
        rm -rf "$STAGE"
        echo "数据归档: data-$TS.tar.gz ($(du -h "$BK/data-$TS.tar.gz" | cut -f1))"
        # 记录本次签名（仅成功产出归档后写；去重只在两侧都有签名时生效）
        if [ -n "${SIGNOW:-}" ]; then printf '%s' "$SIGNOW" > "$SIGFILE" 2>/dev/null || true; fi
    fi
    # 滚动保留
    all=$(ls -1d "$BK"/data-*.tar.gz 2>/dev/null | sort || true)
    total=$(printf '%s\n' "$all" | grep -c . || true)
    if [ "$total" -gt "$KEEP_DATA" ]; then
        del=$((total-KEEP_DATA))
        # ⚠ 循环体最后一句不能是 `A && B && C` 这种链（2026-10-16 审查 B1 实测）：
        #   本脚本是 `set -euo pipefail`，链子一旦断在非零，`while` 就返回非零、
        #   **整脚本当场中止** —— 于是滚到第 31 份时脚本死在这里，
        #   而排在最后的「恢复演练」永远不会执行（坏的归档从此无人验证）。
        #   实测触发条件：`~/.Trash` 不可写/不存在（其他用户会话、受限环境）。
        #   改法：循环体一律用 `if…fi`（条件为假时 `fi` 返回 0），mv 失败只警告、**保留原文件**。
        printf '%s\n' "$all" | head -n "$del" | while read -r f; do
            if [ -z "$f" ]; then
                continue
            elif [ ! -d "$TRASH" ]; then
                echo "  ⚠️ 废纸篓目录不存在，跳过滚动清理: ${TRASH}（归档未删除，磁盘不会被继续挤占）" >&2
            elif mv "$f" "$TRASH/" 2>/dev/null; then
                echo "  滚动清理: $(basename "$f")"
            else
                echo "  ⚠️ 滚动清理失败（保留原文件）: $(basename "$f")" >&2
            fi
        done
    fi
else
    echo "⚠️ 未找到应用数据目录，跳过数据归档"
fi

# 2) 产物备份滚动兜底（保留 1 份，正常流程不再新增）
rollup() { # $1=前缀 $2=保留份数
  local all total del
  all=$(ls -1d "$BK"/"$1"* 2>/dev/null | sort || true)
  total=$(printf '%s\n' "$all" | grep -c . || true)
  if [ "$total" -gt "$2" ]; then
    del=$((total-$2))
    # 同上：循环体用 if…fi，不用 `&&` 链结尾（`set -e` 会把整脚本带走，见上面的说明）
    printf '%s\n' "$all" | head -n "$del" | while read -r d; do
      if [ -z "$d" ]; then
        continue
      elif [ ! -d "$TRASH" ]; then
        echo "  ⚠️ 废纸篓目录不存在，跳过: $(basename "$d")" >&2
      elif mv "$d" "$TRASH/" 2>/dev/null; then
        echo "  滚动清理: $(basename "$d")"
      else
        echo "  ⚠️ 滚动清理失败（保留原文件）: $(basename "$d")" >&2
      fi
    done
  fi
}
rollup "dist-" 1
rollup "installed-" 1

# 3) 恢复演练
#
# 前面的保护都作用在**产出端**（不产空归档、不重复归档、完整性 + 行数交叉核对），
# 但"归档能不能恢复"从来没验证过 —— 一个截断的 tar.gz 可以安安静静躺在归档目录里
# 5 份，直到你真的需要它的那一天。这里对**最新一份**归档做一次解压 + quick_check +
# 必需表 + 时序核对。
#
# 注意：本脚本现在由 build_app.sh 在 **git 提交之前**调用（数据归档比发布记录更要紧），
# 但恢复演练失败仍不改写归档结论 —— 以非零退出码明确暴露问题，由打包方决定是否继续。
if [ -x "$ROOT/scripts/verify_backup.sh" ]; then
    echo ""
    # ⚠ 必须区分退出码 2（2026-10-16 审查 B1）：verify_backup.sh:17 声明
    #   「2 = 找不到归档，不算失败（可能是首次运行）」，而原先这里写作
    #   `if ! bash verify_backup.sh` —— 把 2 也当失败，于是**新机器首次运行必然红一次**，
    #   还顺带把本脚本带到 exit 1（真实失败与"还没有归档"混成同一条噪声）。
    # ⚠ `|| VERIFY_RC=$?` 而不是裸调用：本脚本 `set -e`，直接写 `bash verify.sh`
    #   再取 `$?` 时，非零返回会**先把脚本带走**，下面的分支永远走不到。
    VERIFY_RC=0
    bash "$ROOT/scripts/verify_backup.sh" || VERIFY_RC=$?
    if [ "$VERIFY_RC" = "2" ]; then
        echo "ℹ️  归档目录还没有归档（首次运行，恢复演练跳过 —— 不算失败）"
    elif [ "$VERIFY_RC" != "0" ]; then
        echo "❌ 恢复演练失败（退出码 ${VERIFY_RC}）—— 现有归档可能无法恢复，请立即人工检查 $BK" >&2
        exit 1
    fi
fi
