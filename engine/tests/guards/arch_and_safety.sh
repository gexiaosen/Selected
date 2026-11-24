#!/bin/bash
# 架构、数据连接、调度安全、网络完整与打包合规静态护栏（由 run_all.sh source）

# 脚本语法体检：SelectedApp/*.sh（含 build_app.sh，打包+签名+安装最要紧的脚本）、
#   SelectedApp/Tools/*.sh、scripts/*.sh、engine/tests/*.sh —— 这些都不在别的检查覆盖里，
#   坏了不会有任何东西变红，只能靠这一步发现（代价约 1 秒）。
# ⚠ 用 `find … | while read` 而不是 `ls glob`：`set -euo pipefail` 下 `ls` 无匹配返回非零，
#   会让整条管道失败并静默中止脚本。
# ⚠ SelectedApp 只加 -maxdepth 1：Tools/ 已在上面扫过，不重复（也不扫 .build/dist）。
SYNTAX_FAIL=0
while read -r s; do
    [ -n "$s" ] || continue
    if ! bash -n "$s" 2>/dev/null; then
        echo "   ❌ bash -n 失败：$s"; SYNTAX_FAIL=1
    fi
done < <({ find "$ROOT/SelectedApp" -maxdepth 1 -name '*.sh' -type f 2>/dev/null
           find "$ROOT/scripts" "$ROOT/SelectedApp/Tools" "$ROOT/engine/tests" -name '*.sh' -type f 2>/dev/null
         } | sort -u)
if [ "$SYNTAX_FAIL" -eq 0 ]; then
    echo "✅ syntax_check    SelectedApp/{,Tools/}*.sh + scripts/ + engine/tests/ 语法体检通过"
else
    echo "❌ syntax_check    有脚本语法不过（它们不在别的检查覆盖里 → 只能靠这一步发现）"
    FAILED+=("syntax_check")
fi

for d in "$SRC_CORE" "$SRC_APP" "$SRC_VIEWS"; do
    if [ ! -d "$d" ]; then
        echo "❌ guard_paths     源码目录不存在：${d}（拆分后路径已变 → 护栏会静默失效）"
        FAILED+=("guard_paths")
    fi
done

# 静态护栏：参数版本列表只能有一份实现（SQLiteReader 不得再出现 paramVersions 只读副本，
#   界面只走 ParamStore.listVersions —— 规则写两份只改一份必然打架，且不会让任何测试变红）。
# ⚠ 护栏自身也会失效：路径漂了 → [ -f ] 为假、grep 无输出 → 静默通过（看着全绿、其实没查）。
#   所以下面每条护栏都先断言"被扫的路径存在"，路径漂了就报红。
READER="$SRC_CORE/SQLiteReader.swift"
PSTORE="$SRC_CORE/ParamStore.swift"
if [ ! -f "$READER" ] || [ ! -f "$PSTORE" ]; then
    echo "❌ param_source     找不到 ${READER} / ${PSTORE}（拆分后路径已变 → 护栏会静默失效）"
    FAILED+=("param_source")
elif ! grep -qE "func +listVersions" "$PSTORE"; then
    # ⚠ 阳性对照（2026-10-16 审查 B2）：本护栏是**禁止式**判据（Reader 里不许有 paramVersions）。
    #   如果只查"禁止的东西不存在"，那么把 `ParamStore.listVersions` 改名/删掉后
    #   禁止式必然通过 —— 于是"单一实现"其实已经消失，护栏却报 ✅（空转）。
    echo "❌ param_source      ParamStore 里找不到 listVersions（单一实现已漂走 ⇒ 禁止式判据空转）"
    FAILED+=("param_source")
elif grep -qE "func +paramVersions" "$READER"; then
    echo "❌ param_source      SQLiteReader 又出现了参数版本列表的重复实现（应只用 ParamStore.listVersions）"
    FAILED+=("param_source")
else
    echo "✅ param_source     参数版本列表单一实现（ParamStore.listVersions）"
fi


# 静态护栏：`$VAR` 紧跟非 ASCII 字符必须写成 `${VAR}`。
#   bash 会把全角括号的首字节并进变量名 → 引用不存在的变量（明明已赋值，是名字解析错了）；
#   叠加 set -u ⇒ 脚本当场退出。bash -n 抓不到（语法合法），只能靠这条静态判据。
#   实测崩过 build_app.sh 的打 tag 一步，也崩过本脚本护栏错误分支里的引用（比报错更糟：静默）。
# ⚠ 判据用 C locale 的字节类 `[^ -~]`（BSD grep 不支持 -P）；
# ⚠ 排除单引号内片段：单引号里 $ 不展开、不是雷，盲改 ${VAR} 会把字面量改坏（必须排除）。
sh_var_hits=""
for _f in $(grep -rl --include='*.sh' . "$ROOT/SelectedApp" "$ROOT/engine" "$ROOT/scripts" 2>/dev/null | sort -u); do
    [ -f "$_f" ] || continue
    case "$_f" in */.build/*|./.build/*) continue ;; esac
    _hit=$(LC_ALL=C sed "s/'[^']*'//g" "$_f" \
           | grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' 2>/dev/null | grep -v ':[[:space:]]*#' || true)
    [ -n "$_hit" ] && sh_var_hits="${sh_var_hits}${_f}:${_hit}
"
done
if [ -n "$sh_var_hits" ]; then
    echo "❌ sh_var_brace    \$VAR 紧跟全角字符（bash 会把它并进变量名，set -u 下直接退出）："
    printf '%s' "$sh_var_hits" | head -5 | sed 's/^/     /'
    echo "     ⇒ 改法：写成 \${VAR}（单引号内不受影响，本判据已排除）"
    FAILED+=("sh_var_brace")
else
    echo "✅ sh_var_brace    无 \$VAR 紧跟全角字符（该写 \${VAR} 的地方都写了）"
fi

# 静态护栏：调度器三条契约（都"删掉不会报错"，没有测试能验，只能靠源码钉死）：
#   ① 定时器必须加到 .common 模式（scheduledTimer 注册在 default 模式，滚动/拖拽/菜单跟踪
#      期间不触发）；② 必须有 didWakeNotification 唤醒补偿（否则合盖过夜错过的任务没人重评估）；
#   ③ 必须保留间隔下限 max(0.05, delay)。
SCHED="$SRC_APP/Scheduler.swift"
if [ ! -f "$SCHED" ]; then
    echo "❌ sched_timer     找不到 ${SCHED}（路径漂了 → 护栏会静默失效）"
    FAILED+=("sched_timer")
elif grep -nE "Timer\.scheduledTimer" "$SCHED" | strip_comments | grep -c . >/dev/null; then
    echo "❌ sched_timer      又用了 Timer.scheduledTimer（注册在 default 模式，拖拽/菜单期间不触发）"
    FAILED+=("sched_timer")
elif ! grep -q "RunLoop.main.add" "$SCHED"; then
    echo "❌ sched_timer      定时器没有显式加到 .common 模式"
    FAILED+=("sched_timer")
elif ! grep -q "didWakeNotification" "$SCHED"; then
    echo "❌ sched_timer      缺少系统唤醒补偿（didWakeNotification）"
    FAILED+=("sched_timer")
elif ! grep -qE 'max\(0\.0?5,' "$SCHED"; then
    # ⚠ 间隔下限也是契约：sleepSeconds 在"已该醒"时返回 0.05，armTimer 再 max(0.05, delay)
    #   兜一层；去掉下限 → Timer 间隔为 0 → 主线程忙转卡死。上限由 ScheduleEngine 单测锁定。
    echo "❌ sched_timer      定时器缺少间隔下限（max(0.05, delay)）—— 间隔为 0 会让主线程忙转卡死"
    FAILED+=("sched_timer")
else
    echo "✅ sched_timer     定时器走 .common 模式 + 有间隔下限 + 已装系统唤醒补偿"
fi

# 静态护栏：调优路径不得读取实时数据源（调优是历史快照反事实重放；引入 DataSources. 会被
#   "今天的行情"污染、产生未来函数，表现只是"分数变了"，没有任何测试能发现）。
# ⚠ 只扫 PhaseTune.swift：PhaseIterate 的 DataSources.runDate() 是纯本地日期，属正常用途。
# ⚠ 必须走 strip_comments：PhaseTune 注释里提到 DataSources.swift，否则会惩罚写文档。
TUNE="$SRC_CORE/PhaseTune.swift"
if [ ! -f "$TUNE" ]; then
    echo "❌ tune_timesafe  找不到 ${TUNE}（路径漂了 → 护栏会静默失效）"
    FAILED+=("tune_timesafe")
elif grep -n "DataSources\." "$TUNE" | strip_comments | grep -c . >/dev/null; then
    echo "❌ tune_timesafe  调优路径引入了实时数据源（历史快照会被今天行情污染 → 未来函数）"
    grep -n "DataSources\." "$TUNE" | strip_comments | head -5 | sed 's/^/     /'
    FAILED+=("tune_timesafe")
else
    echo "✅ tune_timesafe  调优路径只读历史快照（无 DataSources 调用）"
fi

# 静态护栏：点阵动效（ThinkingOrbs）的两条边界（都"删掉不会报错"）：
#   ① 分层：SelectedCore 不得 import 这个 UI 动效库（CoreLayeringTests 只拦框架名，
#      拦不住"Core 反向依赖 UI 库"）。
#   ② 白名单：动效只允许出现在 Components* 的 LoadingView / ThinkingDot（唯一出口）；
#      新增使用点必须先加进白名单并同步 spec —— 散写正是白名单失控的形态。
# 决策与清单：docs/specs/README.md
ORB_LIB="ThinkingOrbs"

# ① Core 不许 import 它
if grep -rn "import $ORB_LIB" "$SRC_CORE" --include=*.swift | strip_comments | grep -c . >/dev/null; then
    echo "❌ orb_layering   SelectedCore 依赖了 UI 动效库（Core 必须保持无 UI 依赖）"
    grep -rn "import $ORB_LIB" "$SRC_CORE" --include=*.swift | strip_comments | head -5 | sed 's/^/     /'
    FAILED+=("orb_layering")
else
    echo "✅ orb_layering   Core 不依赖 ThinkingOrbs（UI 库只给 App 层）"
fi


# 静态护栏：告警的判据与写库不许回到视图层。
#   判据在 SelectedCore.AlertEval、评估与投递在 AlertMonitor（常驻，与当前页面无关）——
#   写回视图靠 .task 驱动的话"切页即静默失效"，不会让任何测试变红，只能靠护栏钉。
# ⚠ 护栏自身失效检测：被扫路径必须存在 + AlertMonitor 里 AlertEval.evaluate 还在（防空转）。
ALERT_MONITOR="$SRC_APP/AlertMonitor.swift"
if [ ! -d "$SRC_APP/Views" ]; then
    echo "❌ alert_owner      找不到 ${SRC_APP}/Views（路径漂了 → 护栏会静默失效）"
    FAILED+=("alert_owner")
elif [ ! -f "$ALERT_MONITOR" ]; then
    echo "❌ alert_owner      找不到 ${ALERT_MONITOR}（路径漂了 → 护栏会静默失效）"
    FAILED+=("alert_owner")
elif ! grep -q "AlertEval\.evaluate" "$ALERT_MONITOR"; then
    echo "❌ alert_owner      AlertMonitor 里已无 AlertEval.evaluate（护栏空转：该特性被回退了？）"
    FAILED+=("alert_owner")
else
    # 只扫 `Views/`：`StoreWatch.swift` 的 `AlertStore.save` 是**用户点确认**时的写
    # （合法入口），`AlertMonitor.swift` 的 `markFired` 是**触发时**的写。
    raw_alert=$(grep -rnE 'AlertEval\.|AlertStore\.(save|markFired|removeAll)' \
                "$SRC_APP/Views" --include=*.swift | strip_comments || true)
    if [ -n "$raw_alert" ]; then
        echo "❌ alert_owner      告警判据/写库出现在视图层（切页即静默失效 → 必须走 AlertMonitor）"
        printf '%s\n' "$raw_alert" | head -5 | sed 's/^/     /'
        echo "     改法：判据放 SelectedCore/AlertEval，评估与投递放 SelectedApp/AlertMonitor"
        FAILED+=("alert_owner")
    else
        echo "✅ alert_owner      告警判据与写库只在 AlertMonitor / StoreWatch（视图层无命中）"
    fi
fi

# 静态护栏：交易时段口径只能有一份 —— AlertWindow.sessionRanges（SelectedCore/AlertRules.swift），
#   视图侧与轮询节奏都走它；各写一份一旦漂移 = 提醒时响时不响，两处单独看都对。
# ⚠ 两个方向都查：旧函数名 inChinaTradingSession 不得复活；AlertMonitor 必须真的引用
#   AlertWindow.inSession（否则它自己又写了一份，前一条依然为真 → 空转）。
if [ ! -f "$ALERT_MONITOR" ]; then
    echo "❌ alert_session    找不到 ${ALERT_MONITOR}（路径漂了 → 护栏会静默失效）"
    FAILED+=("alert_session")
elif ! grep -q "AlertWindow\.inSession" "$ALERT_MONITOR"; then
    echo "❌ alert_session    AlertMonitor 未引用 AlertWindow.inSession（轮询节奏又自写了一份口径？）"
    FAILED+=("alert_session")
else
    raw_session=$(grep -rn "inChinaTradingSession" "$SRC_CORE" "$SRC_APP" --include=*.swift \
                  | strip_comments || true)
    if [ -n "$raw_session" ]; then
        echo "❌ alert_session    交易时段口径出现了第二份（旧 WatchlistView.inChinaTradingSession）"
        printf '%s\n' "$raw_session" | head -5 | sed 's/^/     /'
        echo "     唯一一份在 SelectedCore/AlertRules.swift 的 AlertWindow.sessionRanges"
        FAILED+=("alert_session")
    else
        echo "✅ alert_session    交易时段口径唯一（AlertWindow.sessionRanges）"
    fi
fi

# 静态护栏：调度器不得用文案子串判状态 —— 失败文案只要含「非交易日」任务就被判完成
#   （不重试、不通知，静默丢任务）；靠注释维持的约束迟早会破，删掉这条分支不会让测试变红。
# 正路是结构化判据：Job 返回 ["status": "not_trading_day"]（不抛错），只认 status。
# 判据：.contains("（对字符串字面量调 contains）；不会误伤 Set 的 contains（没有引号）。
SCHED_SRC="$SRC_APP/Scheduler.swift"
if [ ! -f "$SCHED_SRC" ]; then
    echo "❌ sched_no_text_state  找不到 ${SCHED_SRC}（路径漂了 → 护栏会静默失效）"
    FAILED+=("sched_no_text_state")
else
    raw_txtstate=$(grep -hnE '\.contains\("' "$SRC_APP"/Scheduler*.swift | strip_comments || true)
    if [ -n "$raw_txtstate" ]; then
        echo "❌ sched_no_text_state  Scheduler 又出现了「用文案子串判状态」（失败文案会被当成状态 → 静默丢任务）"
        printf '%s\n' "$raw_txtstate" | head -5 | sed 's/^/     /'
        echo "     正路：只认结构化 status（见 finish 里 r?.status == \"not_trading_day\"）"
        FAILED+=("sched_no_text_state")
    else
        echo "✅ sched_no_text_state  调度器不用文案判状态（只认结构化 status）"
    fi
fi

# 静态护栏：抓取"不完整"必须整轮作废，不许静默用半截。
#   两个同源病：分页把"解析失败"与"已到末页"都写成裸 break → 半截列表被当完整写缓存
#   （候选池静默缩小，表现只是"今天选出的票变少"）；龙虎榜固定第 1 页 → 超上限被静默截断。
#   两条的 HTTP 路径都不在回归里，改回旧写法不会有任何测试变红。
# 判据：
#   ① DataSourcesLists 不许出现「把异常当末页」的签名；分页解析必须走 decodeListPage，
#      它把两者在类型上分开（nil = 异常 → 整轮作废；[] = 末页 → 正常收尾）。
#   ② LhbSource 必须含完整性闸门（dataTotal( + "day_incomplete"）。
# ⚠ 空转检测：两个被扫文件必须存在；decodeListPage 调用点 ≥3（A股/基金/港股三个入口）。
FC_LISTS="$SRC_CORE/DataSourcesLists.swift"
FC_LHB="$SRC_CORE/LhbSource.swift"
if [ ! -f "$FC_LISTS" ] || [ ! -f "$FC_LHB" ]; then
    echo "❌ fetch_completeness  被扫文件不存在（路径漂了 → 护栏会静默失效）"
    echo "     lists=[${FC_LISTS}] lhb=[${FC_LHB}]"
    FAILED+=("fetch_completeness")
else
    fc_bad=""
    if grep -qF 'if text == nil || !stripped.hasPrefix("[")' "$FC_LISTS"; then
        fc_bad="分页里又出现「把异常当末页」的旧写法（必须走 decodeListPage）"
    fi
    # ⚠ 数**调用点**（总数 − 定义），**不绑局部变量名**：第一版写成 `decodeListPage(text)`，
    #   于是把参数改个名（`decodeListPage(body)`）就会被误判成"0 处"→ 假红。
    n_dlp=$(( $(grep -c 'decodeListPage(' "$FC_LISTS" || true) - $(grep -c 'func decodeListPage(' "$FC_LISTS" || true) ))
    if [ "${n_dlp:-0}" -lt 3 ]; then
        fc_bad="${fc_bad} decodeListPage 调用只有 ${n_dlp:-0} 处（应 ≥3：A股/基金/港股三个分页入口）"
    fi
    if ! grep -q 'dataTotal(' "$FC_LHB" || ! grep -q '"day_incomplete"' "$FC_LHB"; then
        fc_bad="${fc_bad} 龙虎榜缺少完整性闸门（dataTotal / day_incomplete）"
    fi
    # ③ 状态码：`let (data, _) = try await URLSession.shared.data(for:)` 把 URLResponse 丢掉
    #    → 403/500 的 HTML 错误页会被当数据解析（表现是"这只票没数据"，不是报错）。
    #    唯一出口是 HTTPFetch.get（SelectedCore/HTTPFetch.swift）。
    n_badhttp=$(grep -rn 'let (data, _) = try await URLSession.shared.data(for:' \
                --include=*.swift "$SRC_CORE" "$SRC_APP" | strip_comments | wc -l | tr -d ' ')
    if [ "${n_badhttp:-0}" -gt 0 ]; then
        fc_bad="${fc_bad} 有 ${n_badhttp} 处直连 URLSession 丢掉了 response（状态码没校验 → 应走 HTTPFetch.get）"
    fi
    n_hf=$(grep -rn 'HTTPFetch.get(' --include=*.swift "$SRC_CORE" "$SRC_APP" | wc -l | tr -d ' ')
    if [ "${n_hf:-0}" -lt 8 ]; then
        fc_bad="${fc_bad} HTTPFetch.get 只出现 ${n_hf:-0} 次（应 ≥8：8 处异步取数全走它）"
    fi
    # ④ 读库：while sqlite3_step(...) == SQLITE_ROW 把"step 出错"与"没有更多行"混成同一个退出
    #    → 返回半截行且无任何报错。正解 = 判返回码：DONE 才是正常结束，其余丢弃已取的行。
    #    ⚠ 改回去不会有任何测试变红（撞锁/列缺失在正常环境下复现不了）。
    n_step=$(grep -rn 'while sqlite3_step(' --include=*.swift "$SRC_CORE" "$SRC_APP" \
             | strip_comments | wc -l | tr -d ' ')
    if [ "${n_step:-0}" -gt 0 ]; then
        fc_bad="${fc_bad} 有 ${n_step} 处 while sqlite3_step(...)==SQLITE_ROW（把出错当结尾 → 会返回半截行）"
    fi
    n_rc=$(grep -rn 'if rc == SQLITE_DONE { break }' --include=*.swift "$SRC_CORE" "$SRC_APP" \
           | wc -l | tr -d ' ')
    # ⚠ 这个下限会随 ReadOnlyConnection 迁移而下降（Store 行循环搬进共享实现后就不再有自己的
    #   rc 判断）—— 那是对的，不是回归。迁移 Store 时同步下调这个下限，并在本注释记一行。
    #   当前 6 = 16 − 11（已迁 11 个 Store）＋ 1（ReadOnlyConnection 自己那条）。
    if [ "${n_rc:-0}" -lt 6 ]; then
        fc_bad="${fc_bad} 只有 ${n_rc:-0} 处判了 SQLITE_DONE（应 ≥6：各 Store 的行循环 + ReadOnlyConnection）"
    fi
    # ⚠ 正面检查：**共享实现自己必须判** —— 它一旦退化，所有已迁的 Store **一起**退化
    #   （而单看各处计数看不出来）。这条是本组里唯一"越迁越重要"的检查。
    if ! grep -q 'if rc == SQLITE_DONE { break }' "$SRC_CORE/ReadOnlyConnection.swift"; then
        fc_bad="${fc_bad} ReadOnlyConnection.query 缺 rc 判断（共享实现退化 → 已迁 Store 一起退化）"
    fi
    if [ -n "$fc_bad" ]; then
        echo "❌ fetch_completeness  取数失败会被静默吞掉（半截列表写缓存 / 少票 / 把错误页当数据）"
        echo "     ${fc_bad}"
        FAILED+=("fetch_completeness")
    else
        echo "✅ fetch_completeness  分页异常整轮作废（${n_dlp} 个入口）+ 龙虎榜校验源报总数 + 8 处取数校验状态码 + ${n_rc} 处行循环判 DONE"
    fi
fi

# 静态护栏：装到 /Applications 之后必须清 xattr + 落盘后再验一次签名。
#   cp -R 会把源 bundle 的 xattr 带进去，codesign --strict 判为 detritus ⇒ 落盘那份签名失效；
#   症状离病根极远（实测：通知中心图标变占位方块，而图标文件本身正常）。
#   只在 /tmp 组装后验一次 = 静默失效（那时是全新文件、必然通过）。
# 判据（只看安装段，即 free_path "$DEST" 之后）：① 有 xattr -cr "$DEST"；
#   ② 有落盘后的 codesign --verify（失败要退出非零）。
# ⚠ 必须 grep -v 掉注释行：上面说明里原样出现了那两个字符串，不过滤会被自己的注释喂饱。
# ⚠ 空转检测：build_app.sh 必须存在（路径漂了 → 静默通过）。
INSTALL_SRC="$ROOT/SelectedApp/build_app.sh"
if [ ! -f "$INSTALL_SRC" ]; then
    echo "❌ install_signed  找不到 ${INSTALL_SRC}（路径漂了 → 护栏会静默失效）"
    FAILED+=("install_signed")
else
    inst_seg=$(awk '/free_path "\$DEST"/{f=1} f{print}' "$INSTALL_SRC" | grep -vE '^[[:space:]]*#')
    if ! printf '%s\n' "$inst_seg" | grep -c 'xattr -cr "\$DEST"' >/dev/null; then
        echo "❌ install_signed  安装段缺 xattr -cr \"\$DEST\"（落盘后签名会因 xattr 失效 → 系统服务不认 bundle）"
        FAILED+=("install_signed")
    elif ! printf '%s\n' "$inst_seg" | grep -c 'codesign --verify' >/dev/null; then
        echo "❌ install_signed  安装段缺**落盘后**的 codesign --verify（只在 /tmp 验过 = 静默失效）"
        FAILED+=("install_signed")
    else
        echo "✅ install_signed  安装段清 xattr ＋ 落盘后验签都在"
    fi
fi

# 静态护栏：东财 push2 家族的外部抓取必须走全局限速器。
#   东财对 push2* 批量端点按出口 IP 限流，连发会被封（实测被封后同族行业/基本面刷新
#   几乎 100% 被拒，界面只写"源无响应或返回不完整"）。
#   "叶子函数到底调没调限速器"没有自动化能验 —— 删掉 throttleAfterNetwork() 全量回归不会红。
# 判据：两处批量抓取都要调 DataSources.throttleAfterNetwork()（次数下界，允许更多）。
# ⚠ 断言调用形状（含括号），避免被注释里提到的函数名喂饱。
# ⚠ 空转检测：DataSources.swift 里 throttleAfterNetwork 的定义必须还在。
# ⚠ 2026-10-28 少了一处：`IndustrySource`（所属行业）整条下线，见 docs/功能说明.md。
PT_KLINE="$SRC_CORE/HistoryBarsSource.swift"
PT_FUN="$SRC_CORE/FundamentalSource.swift"
PT_DS="$SRC_CORE/DataSources.swift"
if [ ! -f "$PT_KLINE" ] || [ ! -f "$PT_FUN" ] || [ ! -f "$PT_DS" ]; then
    echo "❌ push2_throttled  被扫文件不存在（路径漂了 → 护栏会静默失效）"
    FAILED+=("push2_throttled")
elif ! grep -q 'func throttleAfterNetwork' "$PT_DS"; then
    echo "❌ push2_throttled  DataSources 里没有 throttleAfterNetwork（限速器被删了？护栏空转）"
    FAILED+=("push2_throttled")
else
    pt_bad=""
    # ⚠ 必须**剔掉注释行**再数：上面这些文件的文档注释里**原样写着** `throttleAfterNetwork()`，
    #   不剔就会被自己的注释喂饱（"注释污染"假绿）。
    pt_n() { grep -n 'throttleAfterNetwork()' "$1" 2>/dev/null \
             | grep -vcE '^[0-9]+:[[:space:]]*//' || true; }
    [ "$(pt_n "$PT_KLINE")" -ge 2 ] || pt_bad="${pt_bad} HistoryBarsSource(需≥2 实得$(pt_n "$PT_KLINE"))"
    [ "$(pt_n "$PT_FUN")"   -ge 1 ] || pt_bad="${pt_bad} FundamentalSource(需≥1 实得$(pt_n "$PT_FUN"))"
    if [ -n "$pt_bad" ]; then
        echo "❌ push2_throttled  批量抓取漏了全局限速（东财按出口 IP 限流，连发会被封）：${pt_bad}"
        FAILED+=("push2_throttled")
    else
        echo "✅ push2_throttled  东财 push2 家族的两处批量抓取都走全局限速器"
    fi
fi

# 静态护栏：Info.plist 的提审必需键必须齐全且合法。
# 判据：① plutil -lint 语法合法（改它时手滑很容易破结构）；② 提审/上架必需键齐全（清单见下）；
#   ③ NSHumanReadableCopyright 与仓库根 LICENSE 对得上（GNU GPL v3.0）——
#      写 public domain / Unlicense 会与 LICENSE 矛盾，第三方组件版权在 THIRD_PARTY_NOTICES.txt；
#   ④ 本地化声明必须是中文：从未声明本地化的 App，AppKit 标准菜单与系统面板全按英文渲染，
#      与"中文为唯一界面语言"直接矛盾。判据要查值（键在、值是 en 或空数组 = 没声明）。
_PK_BAD=""
_PLIST="$ROOT/SelectedApp/Resources/Info.plist"
if [ ! -f "$_PLIST" ]; then
    echo "❌ plist_keys      找不到 ${_PLIST}（路径漂了 → 护栏会静默失效）"
    FAILED+=("plist_keys")
elif ! plutil -lint "$_PLIST" >/dev/null 2>&1; then
    echo "❌ plist_keys      Info.plist 语法不合法（plutil -lint 失败）—— 改它时可能破坏了结构"
    FAILED+=("plist_keys")
else
    # ① 必需键（含义见本节注释；末两个见 ②）
    for _k in CFBundleDisplayName CFBundleExecutable CFBundleIdentifier CFBundleName \
              CFBundlePackageType CFBundleShortVersionString CFBundleVersion \
              LSMinimumSystemVersion NSUserNotificationsUsageDescription \
              LSApplicationCategoryType NSHumanReadableCopyright \
              CFBundleDevelopmentRegion CFBundleLocalizations; do
        /usr/libexec/PlistBuddy -c "Print :$_k" "$_PLIST" >/dev/null 2>&1 || _PK_BAD="$_PK_BAD 缺${_k}"
    done
    # ② 光有键不够，值要是中文：空数组 / 写成 en 都等于没声明，
    #   症状只在菜单栏可见（语法合法、测试全绿）。
    _PK_LANG=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleLocalizations' "$_PLIST" 2>/dev/null || echo "")
    case "$_PK_LANG" in
        *zh-Hans*|*zh_CN*) : ;;   # 声明了简中 ✓
        *) _PK_BAD="$_PK_BAD 本地化未声明简中(${_PK_LANG:-空})" ;;
    esac
    _PK_REGION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDevelopmentRegion' "$_PLIST" 2>/dev/null || echo "")
    case "$_PK_REGION" in
        zh_CN|zh-Hans|zh-Hans-CN) : ;;
        *) _PK_BAD="$_PK_BAD 开发区域非中文(${_PK_REGION:-空})" ;;
    esac
    # ③ 版权声明必须与仓库根 LICENSE 对得上（GNU GPL v3.0）
    _PK_CR=$(/usr/libexec/PlistBuddy -c 'Print :NSHumanReadableCopyright' "$_PLIST" 2>/dev/null || echo "")
    case "$_PK_CR" in
        *"GNU General Public License"*|*"GPL-3.0"*|*"GPLv3"*) : ;;   # 与 LICENSE 一致 ✓
        *) _PK_BAD="$_PK_BAD 版权声明与LICENSE不一致" ;;
    esac
    if [ -n "$_PK_BAD" ]; then
        echo "❌ plist_keys      Info.plist 有问题：${_PK_BAD}"
        echo "     · 缺键：LSApplicationCategoryType / NSHumanReadableCopyright 是 2026-10-07 补的"
        echo "       （提审 / App Store Connect 需要）；CFBundleDevelopmentRegion /"
        echo "       CFBundleLocalizations 是 2026-10-08 补的（系统菜单中文化的唯一依据）。"
        echo "     · 值不对：本地化只认 zh-Hans / zh_CN；版权必须写 GNU General Public License（LICENSE 是 GPL-3.0），"
        echo "       第三方组件的版权在 Contents/Resources/THIRD_PARTY_NOTICES.txt。"
        FAILED+=("plist_keys")
    else
        echo "✅ plist_keys      13 个必需键齐全 + 声明中文 + 语法合法 + 版权声明与 LICENSE 一致"
    fi
fi

# 静态护栏：数据源必须有同族 host 降级链，且降级不能静默失效。
#   实测 push2 clist 连接失败 ×3，基本面/板块热度没有兜底就静默返回空。
#   与 push2_throttled 不同：那条管"别被限流"，这条管"源挂了怎么办"。
# 判据：① DataSources.hostFallbacks 至少覆盖 1 个 host（空表 = 降级形同虚设）；
#   ② 候选出现不带 https:// 前缀的项时 rewritingHost 必须能处理 —— 把完整 URL 传进
#      comps.host 会拼出 `https://https//…` ⇒ 函数返回 nil、降级静默失效且不报错。
_HF_BAD=""
# ⚠ 计数用 awk 而不是 grep -E：表项是多行数组字面量，单行正则匹配不到 ⇒ 恒为 0（假绿）。
_HF_COUNT=$(awk '/static let hostFallbacks/,/^    \]/' "$SRC_CORE/DataSources.swift" | grep -c 'DataSourceEndpoints\.')
if [ "$_HF_COUNT" = "0" ]; then
    echo "❌ host_fallback    降级表是空的 / 找不到 hostFallbacks —— 数据源挂了没有任何兜底"
    FAILED+=("host_fallback")
elif ! grep -q 'https://' <(grep -A 3 'static func rewritingHost' "$SRC_CORE/DataSources.swift" | head -6); then
    # ⚠ rewritingHost 入口必须能剥 https:// 前缀（否则传完整 URL 静默失效）
    echo "❌ host_fallback    rewritingHost 没处理「带 https:// 前缀的目标」—— 传常量进来会静默失效"
    FAILED+=("host_fallback")
else
    # ⚠ 空转检测：建了入口却没人用 ⇒ 降级完全不存在（比没有更糟：看起来存在）。
    #   用 `grep -rl … | grep -v … | wc -l`，不是 `grep -rq … | grep -qv …`（后者永远不成立）。
    _HF_USERS=$(grep -rl 'httpGetWithHostFallback' "$SRC_CORE" --include='*.swift' 2>/dev/null \
                | grep -v 'DataSources.swift' | wc -l | tr -d ' ')
    if [ "$_HF_USERS" -lt 1 ]; then
        echo "❌ host_fallback    建了降级入口但没有任何 Source 在用（空转）"
        FAILED+=("host_fallback")
    else
        # ⚠ 阈值是 <1（至少一个 Source 在用）而不是 =2：部分降级仍有价值，不该报红。
        #   但数字必须显示 —— "从 2 退到 1"这种变化在日志里看得见。
        echo "✅ host_fallback    降级表 ${_HF_COUNT} 项引用，${_HF_USERS} 个 Source 在用；换 host 不静默失效"
    fi
fi

# 静态护栏：每条连接必须在**自己的 init 里**登记进 `DataConnections`，
#            且换库入口 `Store.invalidateAllDataConnections()` 只走注册表。
#
# ⚠ 这条护栏被**重写**过一次（2026-10-16 审查 B8 · 连接注册表）。上一版做的是：
#   扫「哪些文件声明了 ReadOnlyConnection」→ 再去函数体里找对应的 `XxxStore.close()`。
#   那本质上是把"两处靠人同步的列表"做成机械版 —— 声明一换写法（改属性名、换持有形式）
#   它就静默空转，所以它自己还得挂着"持有形态①②"的正则和阳性对照来防自己。
#   现在登记动作写进 init ⇒ 可检查的东西变成三个与代码长相无关的稳定形状。
#
# 判据（三条，缺一判红）：
#   ① 四类持有者各自 `DataConnections.register(self)`
#      —— 少一个的后果是该类新连接静默不进清单（换库后继续读旧 inode）。
#   ② `invalidateAllDataConnections()` 函数体里有 `DataConnections.closeAll()`。
#   ③ 那个函数体里**不许**再出现逐个点名的 `.close()` / `.invalidate()` 行 ——
#      手写点名清单一旦长回来，就退回"新增 Store 得记得加一行"的老问题
#      （那个老问题实测漏过 4 个：提醒规则 / 资金流 / 涨停池 / 龙虎榜）。
# ⚠ 三条都配阳性对照：文件找不到、函数体抽为空 ⇒ 判红，不判"没什么要查的"。
RC_FILE="$SRC_APP/StoreRounds.swift"
RC_BAD=""
RC_REG_N=0
for rf in "$SRC_CORE/ReadOnlyConnection.swift" "$SRC_CORE/SQLiteReader.swift" \
          "$SRC_CORE/SQLiteWriter.swift" "$SRC_CORE/HistoryBarStore.swift"; do
    if [ ! -f "$rf" ]; then
        RC_BAD="$RC_BAD $(basename "$rf" .swift)(文件不存在)"
        continue
    fi
    RC_REG_N=$((RC_REG_N + 1))
    grep -q 'DataConnections\.register(self)' "$rf" || RC_BAD="$RC_BAD $(basename "$rf" .swift)"
done
RC_BODY=""
if [ -f "$RC_FILE" ]; then
    RC_BODY=$(awk '/static func invalidateAllDataConnections\(\)/,/^    \}/' "$RC_FILE")
fi
# ⚠ 这里**不能用 strip_comments**：那个 helper 的过滤条件是 `路径:行号:` 之后以 `//` 开头，
#   只适配 `grep -rn` 的输出；RC_BODY 是 awk 抽出来的**裸函数体**（没有前缀），
#   交给它的注释行一条都滤不掉 ⇒ 函数体里那句解释历史的注释会被当成"手写清单又长回来了"。
RC_HAND=$(printf '%s\n' "$RC_BODY" | grep -vE '^[[:space:]]*//' \
          | grep -E '\.(close|invalidate|invalidateConnection)\(\)' || true)
if [ ! -f "$RC_FILE" ]; then
    echo "❌ readconn_close_cover  路径不存在：${RC_FILE}（拆分后路径变了 → 护栏空转）"
    FAILED+=("readconn_close_cover")
elif [ -z "$RC_BODY" ]; then
    echo "❌ readconn_close_cover  抽不到 invalidateAllDataConnections 的函数体（签名漂了 → 护栏空转）"
    echo "     ⇒ 修法：把本节的 awk 起始模式补全，不能默认'没查到就算过'。"
    FAILED+=("readconn_close_cover")
elif [ "$RC_REG_N" -lt 4 ]; then
    echo "❌ readconn_close_cover  只扫到 ${RC_REG_N}/4 类连接持有者文件（路径漂了 → 本条只剩一半效力）"
    FAILED+=("readconn_close_cover")
elif [ -n "$RC_BAD" ]; then
    echo "❌ readconn_close_cover  这些持有者没有自我登记进 DataConnections：$RC_BAD"
    echo "     ⇒ 该类的新连接不进换库清单 ⇒ 导入/换库后继续读旧 inode，而界面上没有任何异常。"
    echo "     ⇒ 修法：在该类型的 init 里加 \`DataConnections.register(self)\`。"
    FAILED+=("readconn_close_cover")
elif ! printf '%s\n' "$RC_BODY" | grep -q 'DataConnections\.closeAll()'; then
    echo "❌ readconn_close_cover  invalidateAllDataConnections() 不再走 DataConnections.closeAll()"
    echo "     ⇒ 换库清单回到手写点名制（历史上漏过 4 个 Store 就是这个形状造成的）。"
    FAILED+=("readconn_close_cover")
elif [ -n "$RC_HAND" ]; then
    echo "❌ readconn_close_cover  函数体里又出现逐个点名的关闭调用："
    printf '%s\n' "$RC_HAND" | sed 's/^/     · /'
    echo "     ⇒ 清单已由注册表覆盖，手写行不会让覆盖面变大，只会让"新增 Store 要不要加一行"重新变成人的问题。"
    FAILED+=("readconn_close_cover")
else
    echo "✅ readconn_close_cover  ${RC_REG_N} 类持有者自我登记 + 换库入口只走注册表（无手写点名清单）"
fi

