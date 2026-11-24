#!/bin/bash
# 参数标定与验收（真实库、只读）—— ⚠ **故意不进回归**，已在 run_all.sh 头部登记：
# 非 hermetic（新机器 / CI 上没有那份真实库，也没有那些已评分历史）。
#
# 干什么：把「真实落库特征 → 真引擎重算分数 → 按档位切档 → 双口径统计次日成功率」
# 固化成一条命令，供下一轮参数迭代复现上一轮的结论。
#
# 三个模式：
#   --fidelity  用**产生该轮的那一版参数**重算，逐条比对库里存的 score
#               ⇒ 工具自己的防漂移闸门：改过 `scoreStock` / `DeepInfo` 语义就报红
#   --buckets   双口径（回放收盘 / live 尾盘）分桶命中率
#               ⇒ 标定的证据表；两列方向一致才允许据此改参数
#   --eval      按各版参数切档，输出 入档/日、一档/日、hit@1.5、hit@3.0、收红%、disc 均值
#               ⇒ hit@1.5 = 调优器读的 `stock_outcomes` 政策口径
#               ⇒ hit@3.0 = 界面复盘的每票目标价口径（两者同日可差 10~20pp，都要看）
#
# 跑法：
#   bash SelectedApp/Tools/param_calibrate_test.sh                       # 默认全部对比版本
#   bash SelectedApp/Tools/param_calibrate_test.sh --only-fidelity
#   bash SelectedApp/Tools/param_calibrate_test.sh --db /path/to/selected.sqlite3
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

DB="${SELECTED_CALIBRATE_DB:-$HOME/Library/Application Support/Selected/selected.sqlite3}"
SPLIT="${SELECTED_CALIBRATE_SPLIT:-2026-06-01}"
MODES=(--fidelity --buckets --eval)
[ "${1:-}" = "--only-fidelity" ] && MODES=(--fidelity)

if [ ! -r "$DB" ]; then
    echo "❌ 读不到库：$DB"
    echo "   （本机没有正式运行数据时，用 --db 指到项目 data/selected.sqlite3）"
    exit 2
fi

source "$ROOT/SelectedApp/Tools/core_lib.sh"
TMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/selected_param_calibrate.XXXXXX")"
BIN="$TMP/param_calibrate"

echo "== [1/1] 编译标定驱动并跑 ${MODES[*]} =="
swiftc -O -parse-as-library -I "$CORE_MODULE_DIR" -enable-testing \
    "$ROOT/SelectedApp/Tools/ParamCalibrate.swift" \
    $CORE_OBJS -o "$BIN" || exit 2

VERSIONS=()
for V in backtest-strict 深选v2.0-平衡 深选v2.0-严选; do
    VERSIONS+=(--version "$V")
done

FAILED=0
if ! "$BIN" --db "$DB" --split "$SPLIT" "${MODES[@]}" "${VERSIONS[@]}"; then
    FAILED=1
fi
rm -rf "$TMP"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "✅ 标定驱动通过（fidelity 逐条一致 + 双口径表 + 各版切档对照）"
    exit 0
fi
echo "❌ 标定驱动失败 —— 若为 fidelity 报红：引擎打分口径与历史落库已分叉，本轮参数结论不可信"
exit 1
