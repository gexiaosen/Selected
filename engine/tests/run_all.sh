#!/bin/bash
# Selected 引擎 — 全量回归测试入口
#
# 用法：
#   engine/tests/run_all.sh          # 无需任何外部依赖（纯 Swift 工具链）
#
# 覆盖（**只剩这三类**）：
#   core_unit        SelectedCore 与 SelectedApp 单元测试（`swift test`：数值口径 / 取值语义 / 参数契约 / UI 状态 / 分层）
#                    —— 唯一还覆盖"引擎计算"的自动化
#   自检类           sqlite_writer / history_replay / classify / limit_up_pool / alert /
#                    pool_list / market_tag / chart_zoom / theme / audit_fixes / watch_group /
#                    migration / diag_check / symbol_names
#                    （验 Swift 侧行为契约，不比对任何历史期望值）
#   静态护栏         guard_paths / param_source / theme_source / font_outlet /
#                    theme_accent / theme_tint / button_style / sh_var_brace / chart_param / sched_timer /
#                    tune_timesafe / orb_layering / orb_whitelist /
#                    foreach_id_payload / alert_owner / alert_session /
#                    alert_bell_hit / motion_whitelist / sched_no_text_state /
#                    docs_no_test_count / syntax_check /
#                    md_literal / fetch_completeness / docs_paths / a11y_absent /
#                    install_signed / holding_precision / push2_throttled / toast_styled /
#                    winrate_trend / holding_wording / log_level_prefix / version_sync / guard_count_sync /
#                    suite_ran / readconn_close_cover / guard_doc_coverage / term_consistency /
#                    sem_contrast / doc_baseline_numbers / host_fallback / plist_keys /
#                    sidebar_notoggle / close_minimize / minute_volume_open / window_chrome /
#                    signed_change / price_precision / bar_separation / no_zebra / table_geometry / row_cursor /
#                    page_merge
#                    （共 **53** 条，与 README / docs/功能说明.md 里写的数字一致；
#                      guard_paths 是"护栏自身的护栏"—— 它只在失败时出声、没有 ✅ 行，
#                      但同样独立产出 ❌，所以计入总数。改这条注释时**必须同步改那两份文档**。）
#
# ⚠ **按需审计驱动 —— 故意不进回归，在此登记**：
#   `SelectedApp/Tools/compare_live_check.sh`  真实库 + 联网对比真实行情
#   `SelectedApp/Tools/alert_realdb_check.sh`  需用户本机真实库
#   `SelectedApp/Tools/param_calibrate_test.sh` 参数标定/验收，需真实库里的已评分历史
#   —— 以上三者都**非 hermetic**（新机器 / CI 上没有那个库）→ 不能进回归，但必须在此登记。
#      ⚠ 判据不是"有没有 ✅ 行"，而是**这个文件存不存在于本清单里**。跑法见各自脚本头部。
#
# 条数由 `guard_count_sync` 强制三处一致，并校验"三处数字 == `GUARD_NAMES` 的长度"。
#   ⇒ **新增护栏要改两处**：往 `GUARD_NAMES` 加名字 + 三处数字 +1。漏任一处都会报红。
#
# 全部离线、不触碰生产库（自检类走隔离的 SELECTED_DATA_DIR；无网络访问）。
#
# 编译方式：`SelectedApp/Tools/core_lib.sh` 先 `swift build` 出 `SelectedCore.o`，
#   各脚本只编译自己那一个驱动文件并链接该 `.o` —— 新增 Core 文件不需要改任何脚本。
#   分层约束由 `Tests/SelectedCoreTests/CoreLayeringTests.swift` 钉死（Core 不得 import UI 框架）。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# ⚠⚠ 工具链前置断言：新机器 / CI 上缺 swift/swiftc/xcrun 时，各套件的 command -v 守卫会
#   全部静默跳过、零输出，脚本照样走到末尾打印「✅ 全部回归测试通过」并 exit 0。
#   ⇒ 工具链缺失立刻 exit 2 —— 2 =「没跑成」（1 =「跑了但失败」，CI 里可区分）。
#   ⚠ 守卫处数别写死：实际由末尾 `suite_ran` 动态校验（数守卫数，不数注释）。
for _tool in swift swiftc xcrun; do
    if ! command -v "$_tool" >/dev/null 2>&1; then
        echo "❌ 缺工具链：$_tool —— 回归**未执行**（不是通过）" >&2
        echo "   本仓需要 Xcode 工具链（swift / swiftc / xcrun）。" >&2
        echo "   若已装 Xcode 但仍报缺，检查 DEVELOPER_DIR：" >&2
        echo "     export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer" >&2
        exit 2
    fi
done

# ⚠ 架构前置断言：本项目仅支持 arm64。在 x86_64 / Rosetta 下跑回归会「全绿」，
#   但测的不是 arm64 产物（看着验证过，其实验证的不是那个东西）。exit 2 与工具链断言一致。
#   分工：build_app.sh 拦产出（不许打出 x86_64 的包），这里拦验证。
if [ "$(uname -m)" != "arm64" ]; then
    echo "❌ 架构不符：当前 $(uname -m)，本项目仅支持 arm64 —— 回归**未执行**" >&2
    echo "   在 x86_64 / Rosetta 下跑回归会「全绿」，但测的不是 arm64 产物。" >&2
    echo "   （打包侧已有同样断言：build_app.sh:56-58）" >&2
    exit 2
fi


FAILED=()
# 实际执行了的套件计数：守卫在缺工具链/缺脚本时会静默跳过 ⇒ 末尾用它交叉校验
#   「本轮真的跑了 N 个套件」，少跑不放过（`suite_ran` 护栏）。
RAN=()


SRC_CORE="$ROOT/SelectedApp/Sources/SelectedCore"
SRC_APP="$ROOT/SelectedApp/Sources/SelectedApp"
SRC_VIEWS="$SRC_APP/Views"

strip_comments() { grep -vE '(^|:)[0-9]+:[[:space:]]*//'; }

# ⚠⚠ 静态护栏的名单唯一来源：本数组的长度就是权威条数，
#   三处文档数字（README / 功能说明 / 本文件头部）必须等于它（`guard_count_sync` 校验）。
# ⇒ 新增一条护栏要改两处：① 往数组加名字；② 三处数字 +1。
#   漏 ① → 本断言报红；漏 ② → 一致性断言报红。
#   ⚠ 已知局限：加了护栏却不往数组里加 → 长度不变、断言仍通过，只能靠评审兜底。
GUARD_NAMES=(
    guard_paths param_source theme_source theme_accent theme_tint font_outlet sh_var_brace button_style
    chart_param sched_timer tune_timesafe orb_layering orb_whitelist
    foreach_id_payload alert_owner alert_session alert_bell_hit motion_whitelist
    sched_no_text_state docs_no_test_count syntax_check
    md_literal fetch_completeness docs_paths a11y_absent install_signed holding_precision
    push2_throttled toast_styled winrate_trend holding_wording log_level_prefix version_sync guard_count_sync
    suite_ran
    readconn_close_cover
    guard_doc_coverage
    term_consistency
    sem_contrast
    doc_baseline_numbers
    host_fallback
    plist_keys
    sidebar_notoggle
    close_minimize
    minute_volume_open
    window_chrome
    signed_change price_precision
    bar_separation no_zebra table_geometry row_cursor
    page_merge
)

# 供 `guard_doc_coverage` 用（纯展开成一行，便于 `for` 遍历）
GUARD_NAMES_LIST="$(printf '%s ' "${GUARD_NAMES[@]}")"


# 1. 执行测试套件（Core / App 单测 + Swift 自检驱动）
source "$HERE/lib/suites.sh"

# 2. 执行静态护栏分组（架构与安全 / UI 与排版 / 文档与元校验）
source "$HERE/guards/arch_and_safety.sh"
source "$HERE/guards/ui_tokens_and_layout.sh"
source "$HERE/guards/docs_and_meta.sh"

echo ""
if [ "${#FAILED[@]}" -eq 0 ]; then
    echo "✅ 全部回归测试通过（${actual_suites} 个套件）"
    exit 0
fi
echo "❌ 失败用例：${FAILED[*]}"
exit 1
