#!/bin/bash
# 生成随包资源 `THIRD_PARTY_NOTICES.txt`（第三方许可声明）
#
# 为什么需要它：
#   BSD-3-Clause 要求「**再分发二进制时必须以文档形式附上版权声明与许可全文**」，
#   MIT 同样要求「随软件附上许可文本」。本项目把两个 vendor 包编译进了 `.app`，
#   所以包内必须有一份合并声明。
#
# **为什么用脚本生成而不是手写一个文件**
#   三份声明分散在三个地方（两个包的 LICENSE + ta-lib 的 THIRD-PARTY-NOTICE.md），
#   手抄进 bundle 意味着「上游升级后忘了同步」。
#   ⇒ 构建时现合并，且**缺任何一份就 exit 1**（宁可打包失败，也不要打出一个
#   声明不全的包）。
#
# 用法：SelectedApp/Tools/gen_third_party_notices.sh <输出路径>
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:?用法：gen_third_party_notices.sh <输出路径>}"

SWIFT_TV="$ROOT/SelectedApp/LocalPackages/swift-trading-view"
ORBS="$ROOT/SelectedApp/LocalPackages/ThinkingOrbs"
TA_LIB="$SWIFT_TV/Sources/ta-lib/THIRD-PARTY-NOTICE.md"

# 缺任何一份都**直接失败**（见文件头说明）
MISSING=""
for f in "$SWIFT_TV/LICENSE" "$ORBS/LICENSE" "$TA_LIB"; do
    [ -f "$f" ] || MISSING="${MISSING}
  · ${f#$ROOT/}"
done
if [ -n "$MISSING" ]; then
    echo "❌ 第三方许可文件缺失，打包中止：$MISSING" >&2
    echo "   ⇒ 宁可打包失败，也不要打出声明不全的 .app（BSD-3 / MIT 都要求随包附许可全文）。" >&2
    exit 1
fi

{
    echo "Third-Party Notices — Selected"
    echo "==============================="
    echo
    echo "本文件由 SelectedApp/Tools/gen_third_party_notices.sh 在构建时自动生成，"
    echo "内容来自三个来源文件，请勿手工编辑。"
    echo
    echo "本程序自身采用 GNU General Public License v3.0（见仓库根 LICENSE；GPL-3.0 全文随包在 Resources/LICENSE.txt）。"
    echo "下列第三方组件被编译进本应用的二进制中，其许可条款同样适用。"
    echo
    echo
    echo "────────────────────────────────────────────────────────────────────────"
    echo "1. Swift Trading View（K线 / 分时图表）"
    echo "────────────────────────────────────────────────────────────────────────"
    echo "上游：https://github.com/sergiikhliustin/swift-trading-view"
    echo "许可：BSD 3-Clause"
    echo
    cat "$SWIFT_TV/LICENSE"
    echo
    echo
    echo "────────────────────────────────────────────────────────────────────────"
    echo "2. ThinkingOrbs（点阵动效）"
    echo "────────────────────────────────────────────────────────────────────────"
    echo "上游：https://github.com/haplollc/ThinkingOrbs"
    echo "许可：MIT（原作者 Jakub Antalik / Haplo LLC 双版权声明）"
    echo
    cat "$ORBS/LICENSE"
    echo
    echo
    echo "────────────────────────────────────────────────────────────────────────"
    echo "3. TA-Lib 相关说明"
    echo "────────────────────────────────────────────────────────────────────────"
    echo "上游：https://www.ta-lib.org/ （BSD License）"
    echo
    echo "注意：本项目并未复制 TA-Lib 上游源码，只参照了其 API 命名与错误码取值。"
    echo "以下为详细界定（哪些参照了、哪些是自己实现的）："
    echo
    cat "$TA_LIB"
} > "$OUT"

echo "  第三方声明: $(basename "$OUT")（$(wc -l < "$OUT" | tr -d ' ') 行，3 份许可）"
