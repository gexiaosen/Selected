#!/bin/bash
# 文档口径、无障碍边界、日志版本与护栏自检守卫（由 run_all.sh source）

# 静态护栏：README / docs/功能说明.md 不得写死测试条数（会随加测试漂移，写死必过期；
#   允许的写法是「条数以 run_all.sh 输出为准」）。只拦测试/断言条数，不拦护栏条数。
# ⚠ 已知局限（有意接受）：正则只认三种显式形式（N 项用例 / N 项断言 / XCTest N +），
#   文档里的简写「N 项」看不见 —— 放宽会大面积误伤产品参数数。
#   判据：这个数字会不会因为"加测试"而变？会 → 该拦；不会（产品口径）→ 放行。简写靠人读。
# ⚠ 空转检测：两个被扫文件必须存在（路径漂了 → grep 无输出 → 静默通过）。
DOC_RDM="$ROOT/README.md"
DOC_FUN="$ROOT/docs/功能说明.md"
DOC_CI="$ROOT/.github/workflows/regression.yml"
DOC_SPECS="$ROOT/docs/specs/README.md"
if [ ! -f "$DOC_RDM" ] || [ ! -f "$DOC_FUN" ]; then
    echo "❌ docs_no_test_count  被扫文件不存在（路径漂了 → 护栏会静默失效）"
    echo "     README=[${DOC_RDM}] 功能说明=[${DOC_FUN}]"
    FAILED+=("docs_no_test_count")
else
    # ⚠ 扫描面扩到 CI 与 specs（2026-10-16 审查 B7）：原先只看两份主文档，
    #   于是 `.github/workflows/regression.yml` 里那句「39 ✅ / 0 ❌」漂了很久没人管
    #   （实测本仓当前是 59 条 ✅）。判据形态不变，只是把**同样在复写数字的地方**纳进来。
    #   ⚠ 已知局限保留：正则仍只认三种显式形式（放宽会大面积误伤产品参数数）。
    raw_docnum=$(grep -nE '[0-9]+ 项用例|XCTest [0-9]+ \+|[0-9]+ 项断言|[0-9]+ ✅' \
                 "$DOC_RDM" "$DOC_FUN" "$DOC_CI" "$DOC_SPECS" \
                 | strip_comments || true)
    if [ -n "$raw_docnum" ]; then
        echo "❌ docs_no_test_count  文档里又写死了测试条数（会随加测试漂移 → 以 run_all.sh 输出为准）"
        printf '%s\n' "$raw_docnum" | head -5 | sed 's/^/     /'
        FAILED+=("docs_no_test_count")
    else
        echo "✅ docs_no_test_count  文档不写死测试条数（README/功能说明/CI/specs 四处同检）"
    fi

fi

# 静态护栏：Swift 字符串里的 Markdown 粗体 / 反引号记号不得按原样显示给用户。
#   运行时 String → Text(String) 走 verbatim 不解析 → 用户看到字面星号或反引号；
#   Text("字面量") 走 LocalizedStringKey，反引号会渲染成等宽代码样式（中文说明同样禁止）。
# 判据（非注释行含 ** 或 ` 时，满足其一即放行）：
#   ① ** 仅允许：含 Text( 且没有字符串拼接（单字面量 → LocalizedStringKey → 真渲染成粗体）
#   ② ** 仅允许：是归一化器自身（TextMarkup.swift 把该记号当搜索目标 —— 历史落库数据兼容层；
#      新文案一律在源头用「」，不允许新增"引擎文案带 ** + 展示层归一化"的形态，无豁免通道）
#   ③ 反引号 ` 在注释与 SchemaExportData.swift 之外一概禁止（统一用「」或自然中文）
# ⚠ 空转检测（两层，缺一不可）：两个被扫目录必须存在；
#   TextMarkup.swift 必须仍在且仍处理该记号（否则豁免规则形同废纸）。
MD_CORE="$SRC_CORE"
MD_APP="$SRC_APP"
MD_NORM="$SRC_CORE/TextMarkup.swift"
# ⚠ 排除名单：只有 SchemaExportData.swift 一个是数据文件（两个随包 JSON 的 Swift 化形态，
#   里面的 ** 与反引号是 schema 注释/参数说明原文，不是 UI 文案）。
#   下面配了空转检测：文件没了或不再含 ** 就报红（避免这条豁免变成死规则）。
MD_EXCLUDE_RE='Sources/SelectedCore/SchemaExportData.swift'
if [ ! -d "$MD_CORE" ] || [ ! -d "$MD_APP" ]; then
    echo "❌ md_literal       被扫目录不存在（路径漂了 → 护栏会静默失效）"
    echo "     core=[${MD_CORE}] app=[${MD_APP}]"
    FAILED+=("md_literal")
elif [ ! -f "$MD_NORM" ] || ! grep -q 'range(of: "\*\*")' "$MD_NORM"; then
    echo "❌ md_literal       归一化器缺失或已不再处理该记号：${MD_NORM}"
    echo "     ⇒ 豁免规则 ③ 失去依据（规则还在、对应的实现没了）"
    FAILED+=("md_literal")
elif [ ! -f "$SRC_CORE/SchemaExportData.swift" ] \
     || ! grep -q '\*\*' "$SRC_CORE/SchemaExportData.swift"; then
    echo "❌ md_literal       豁免名单已失效：SchemaExportData.swift 不存在或已不含 '**'"
    echo "     ⇒ 这条豁免没有对象了 —— 请从 MD_EXCLUDE_RE 里删掉它"
    FAILED+=("md_literal")
else
    raw_md=$(grep -rn '\*\*' "$MD_CORE" "$MD_APP" --include=*.swift \
             | grep -v "$MD_EXCLUDE_RE" | strip_comments || true)
    md_bad=""
    while IFS= read -r md_ln; do
        [ -z "$md_ln" ] && continue
        md_body="${md_ln#*:*:}"
        md_code="${md_body%%//*}"          # 记号只在**行尾注释**里 → 不算（本护栏自己的注释就长这样）
        case "$md_code" in *'**'*) ;; *) continue ;; esac
        if printf '%s' "$md_code" | grep -c 'range(of: "\*\*")' >/dev/null; then continue; fi   # ② 归一化器自身
        if [ "${md_code#*Text(}" != "$md_code" ]; then                          # ① 单字面量 Text
            case "$md_code" in *'" +'*|*'+ "'*) ;; *) continue ;; esac
        fi
        md_bad="${md_bad}${md_ln}"$'\n'
    done <<< "$raw_md"
    raw_bt=$(grep -rn '`' "$MD_CORE" "$MD_APP" --include=*.swift \
             | grep -v "$MD_EXCLUDE_RE" | strip_comments || true)
    bt_bad=""
    while IFS= read -r bt_ln; do
        [ -z "$bt_ln" ] && continue
        bt_body="${bt_ln#*:*:}"
        bt_code="${bt_body%%//*}"          # 记号只在行尾注释里 → 不算
        case "$bt_code" in *'`'*) ;; *) continue ;; esac
        bt_bad="${bt_bad}${bt_ln}"$'\n'
    done <<< "$raw_bt"
    if [ -n "$md_bad" ] || [ -n "$bt_bad" ]; then
        if [ -n "$md_bad" ]; then
            echo "❌ md_literal      Swift 字符串里的粗体标记会以**字面星号**显示给用户"
            printf '%s' "$md_bad" | head -8 | sed 's/^/     /'
        fi
        if [ -n "$bt_bad" ]; then
            echo "❌ md_literal      Swift 字符串/代码字面量里不得含裸反引号（界面请改用「」或自然表达）"
            printf '%s' "$bt_bad" | head -8 | sed 's/^/     /'
        fi
        echo "     ⇒ 文案在源头改成「」（2026-10-09 起无 frozen-text 豁免通道）；"
        echo "       展示历史落库旧数据的归一化走 TextMarkup.toCJK（见 SelectedCore/TextMarkup.swift）"
        FAILED+=("md_literal")
    else
        echo "✅ md_literal      Markdown 标记规范（** 仅单字面量/归一化器，无裸反引号）"
    fi
fi

# 静态护栏：文档里点名的仓内路径必须真的存在。
# 判据：README.md / docs/功能说明.md / docs/specs/*.md 里反引号中的仓内路径
#   （docs/ engine/ SelectedApp/ scripts/ .github/ 开头 + 已知扩展名）必须 [ -e ] 为真。
#   读者按路径找不到文件，而文档看起来一切正常。
# ⚠ 已删除路径白名单：文档里"当时存在、现已删除"的路径在此显式登记（历史 spec 按当时状态
#   写的引用不该改写），并配空转检测：登记项若又存在了 → 报红（白名单过期）。
DOCP_DELETED_PREFIXES=(
    "engine/selected_engine/"     # 2026-09-24 删除 Python 参考实现（用户要求，见 docs/specs/README.md「删除参考实现」）
    "engine/tests/freeze_reference.py"
    "engine/tests/frozen_reference.json"
    "engine/analysis/"
    "scripts/build_python_runtime.sh"   # 同上：内嵌解释器已不再需要
    # ⚠ 对账驱动与夹具整体删除后，下面这些是历史 spec 按当时状态写下的路径 ——
    #   它们是决策当时的真实依据，不该改写。
    "scripts/capture_reconcile_fixtures.sh"
    "SelectedApp/Tools/ParamSchemaTest.swift"
    "SelectedApp/Tools/ParamStoreTest.swift"
    "SelectedApp/Tools/ScreenerReconcile.swift"
    "SelectedApp/Tools/watch_store_test.sh"
    # ⚠ 27 MB 行情快照已无人读（挪走后回归仍全绿）；这一条是历史 spec 按当时状态点名过的路径。
    "engine/tests/fixtures/2026-09-14/index_daily_kline.json"
    # ⚠ 旧 CI 配置留档已删除（内容被 .github/workflows/regression.yml 完全取代）；
    #   历史 spec 按当时状态点名的引用登记在这。原文：git log --all -- docs/ci-regression.yml
    "docs/ci-regression.yml"
)
docp_is_deleted() {
    local p="$1" pre
    for pre in "${DOCP_DELETED_PREFIXES[@]}"; do
        case "$p" in "$pre"*) return 0 ;; esac
    done
    return 1
}
# 逐个 `engine/tests/*.py`（对账脚本）也算已删除路径 —— 但它们**不是**前缀，
# 用一条单独规则：`engine/tests/` 下的 `.py`（该目录现在只剩 run_all.sh 与 fixtures/）。
docp_is_deleted_py() { case "$1" in engine/tests/*.py) return 0 ;; *) return 1 ;; esac; }

# ⚠ 空转检测：三个被扫目标必须存在（路径漂了 → `grep` 无输出 → 会静默通过）。
DOCP_RDM="$ROOT/README.md"
DOCP_FUN="$ROOT/docs/功能说明.md"
DOCP_SPECS="$ROOT/docs/specs"
if [ ! -f "$DOCP_RDM" ] || [ ! -f "$DOCP_FUN" ] || [ ! -d "$DOCP_SPECS" ]; then
    echo "❌ docs_paths      被扫目标不存在（路径漂了 → 护栏会静默失效）"
    echo "     README=[${DOCP_RDM}] 功能说明=[${DOCP_FUN}] specs=[${DOCP_SPECS}]"
    FAILED+=("docs_paths")
else
    # 空转检测：白名单里每一项都必须**真的不存在** —— 否则说明被删的东西回来了，白名单已过期
    docp_stale=""
    for pre in "${DOCP_DELETED_PREFIXES[@]}"; do
        [ -e "$ROOT/$pre" ] && docp_stale="${docp_stale} ${pre}"
    done
    if [ -n "$docp_stale" ]; then
        echo "❌ docs_paths      已删除路径白名单过期 —— 这些路径又存在了：${docp_stale}"
        echo "     ⇒ 说明被删的东西回来了（Python 参考实现？对账驱动？）—— 请复核白名单与 2026-09-24 的决策"
        FAILED+=("docs_paths")
    else
    docp_bad=""
    docp_n=0
    while IFS= read -r docp_p; do
        [ -z "$docp_p" ] && continue
        docp_n=$((docp_n + 1))
        if docp_is_deleted "$docp_p" || docp_is_deleted_py "$docp_p"; then
            continue        # 历史 spec 里的"当时存在、现已删除"的路径（见上方白名单）
        fi
        [ -e "$ROOT/$docp_p" ] || docp_bad="${docp_bad} ${docp_p}"
    done < <(grep -rhoE '`(docs|engine|SelectedApp|scripts|\.github)/[A-Za-z0-9_./+-]+\.(swift|py|sh|json|md|plist|yml)`' \
             "$DOCP_RDM" "$DOCP_FUN" "$DOCP_SPECS" 2>/dev/null | tr -d '`' | sort -u)
    if [ -n "$docp_bad" ]; then
        echo "❌ docs_paths      文档点名了**不存在**的仓内路径（读者按它去找会找不到）"
        for docp_p in $docp_bad; do echo "     ✗ ${docp_p}"; done | head -8
        echo "     ⇒ 若是「计划过但没建」的文件，请写明（如：计划里写 X，实际落在 Y）"
        echo "     ⇒ 若确实**已删除**（历史 spec 里按当时状态写的），加进 DOCP_DELETED_PREFIXES"
        FAILED+=("docs_paths")
    else
        echo "✅ docs_paths      docs/ 与 README 点名的仓内路径全部存在（检查 ${docp_n} 条）"
    fi
    fi
fi

# 静态护栏：本项目不做读屏无障碍（用户决定）—— Sources/SelectedApp 里不得再出现
#   读屏专用修饰符。这类修饰符没有任何自动化能验，只会挂在人工清单里付维护成本。
# ⚠ 只拦读屏那几个：accessibilityReduceMotion 必须留着（"减弱动态"偏好，驱动 motionAware，
#   与读屏是两件事）。图表库（vendored swift-trading-view）自带的 accessibility* 不在扫描范围。
# 空转检测：被扫目录存在；accessibilityReduceMotion 必须还在
#   （否则说明有人把 accessibility* 整族删了，会连减弱动态一起删掉）。
A11Y_SRC="$SRC_APP"
if [ ! -d "$A11Y_SRC" ]; then
    echo "❌ a11y_absent     被扫目录不存在：${A11Y_SRC}（路径漂了 → 护栏会静默失效）"
    FAILED+=("a11y_absent")
else
    a11y_hits=$(grep -rnE '\.accessibility(Label|Element|Hidden|Value|Hint|AddTraits|SortPriority|Identifier)\(' \
                "$A11Y_SRC" --include='*.swift' | strip_comments || true)
    a11y_rm=$(grep -rlE 'accessibilityReduceMotion' "$A11Y_SRC" --include='*.swift' | wc -l | tr -d ' ')
    if [ "$a11y_rm" = "0" ]; then
        echo "❌ a11y_absent     找不到 accessibilityReduceMotion（减弱动态被一起删了？护栏空转）"
        FAILED+=("a11y_absent")
    elif [ -n "$a11y_hits" ]; then
        echo "❌ a11y_absent     又出现了读屏专用修饰符（2026-09-23 用户决定：本项目不做读屏无障碍）"
        printf '%s\n' "$a11y_hits" | head -5 | sed 's/^/     /'
        FAILED+=("a11y_absent")
    else
        echo "✅ a11y_absent     无读屏专用修饰符（减弱动态 ${a11y_rm} 个文件仍在）"
    fi
fi

# 静态护栏：日志必须带级别前缀 —— 所有 NSLog( 的第一个参数以 [ERROR] / [NOTICE] / [DEBUG] 开头
#   （排障时 log show 可按级别筛；模块前缀不表达严重程度）。
# ⚠ 为什么不用 os.Logger（两条硬约束）：① SelectedCore 只许 import Foundation/SQLite3
#   （CoreLayeringTests 钉死），os 不在白名单；② os.Logger 的 info/debug 默认不写进统一日志
#   ⇒ 直接替换会让一批日志静默消失。NSLog 总能看见 + 前缀可过滤。
# ⚠ 已知不足（有意接受）：没有按级别开关与字段级脱敏；当前日志只打错误描述与表名，不含凭据。
# ⚠ 空转检测：被扫目录必须存在（路径漂了 → grep 无输出 → 静默通过）。
if [ ! -d "$SRC_CORE" ] || [ ! -d "$SRC_APP" ]; then
    echo "❌ log_level_prefix  源码目录不存在（路径漂了 → 护栏会静默失效）"
    FAILED+=("log_level_prefix")
else
    LOG_PREFIX_BAD=$(grep -rn 'NSLog("' "$SRC_CORE" "$SRC_APP" 2>/dev/null \
        | grep -vE 'NSLog\("\[(ERROR|NOTICE|DEBUG)\]' || true)
    if [ -n "$LOG_PREFIX_BAD" ]; then
        echo "❌ log_level_prefix  有 NSLog 没带级别前缀（排障时无法按级别筛）："
        printf '%s\n' "$LOG_PREFIX_BAD" | head -5 | sed 's/^/     /'
        echo "     ⇒ 写成 NSLog(\"[ERROR] …\") / NSLog(\"[NOTICE] …\") / NSLog(\"[DEBUG] …\")"
        FAILED+=("log_level_prefix")
    else
        echo "✅ log_level_prefix  所有 NSLog 都带级别前缀（[ERROR] / [NOTICE] / [DEBUG]）"
    fi
fi

# 静态护栏：版本号双键 + 语义化格式（唯一源头是 Info.plist 的 CFBundleShortVersionString，
#   两键漂移会错位系统按版本判更新/缓存，而界面与文档全看不出来）。
# 判据：① Short 符合语义化 x.y.z；② Build 为纯数字（惯例 yyyyMMdd，同日第二次 yyyyMMdd.N）；
#   ③ 两键不得同值 —— Apple TN2420：组合唯一即可，且 macOS build 号必须跨版本单调递增，
#   「两键同值」把两个语义不同的 key 混成一个、同一版本重打时无法区分。
# ⚠ 空转检测：被扫文件必须存在（路径漂了 → PlistBuddy 输出空 → 静默通过）。
PLIST="$ROOT/SelectedApp/Resources/Info.plist"
if [ ! -f "$PLIST" ]; then
    echo "❌ version_sync   找不到 ${PLIST}（路径漂了 → 护栏会静默失效）"
    FAILED+=("version_sync")
else
    v_short=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)
    v_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || true)
    if [ -z "$v_short" ] || [ -z "$v_build" ]; then
        echo "❌ version_sync   版本键缺失：ShortVersion=[${v_short:-空}]  Version=[${v_build:-空}]"
        FAILED+=("version_sync")
    elif ! echo "$v_short" | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+$' >/dev/null; then
        echo "❌ version_sync   CFBundleShortVersionString（${v_short}）不符合语义化格式 x.y.z"
        FAILED+=("version_sync")
    elif ! echo "$v_build" | grep -cE '^[0-9]{4,}$|^[0-9]+(\.[0-9]+)*$' >/dev/null; then
        # ⚠ 这里判 Build 的格式（判据与理由见本节头部：两键不得同值，build 独立递增）。
        echo "❌ version_sync   CFBundleVersion（${v_build}）格式不对（应为纯数字：yyyyMMdd，或同日 yyyyMMdd.N）"
        FAILED+=("version_sync")
    elif [ "$v_short" = "$v_build" ]; then
        echo "❌ version_sync   两键同值（${v_short}）—— build 号必须**独立**于版本号（Apple TN2420 要求 macOS 跨版本单调递增）"
        FAILED+=("version_sync")
    else
        # ⚠ 追加判据（2026-10-19）：**未交付版本号的复用判定必须在位**。
        #   自增发生在构建之前（版本要写进包内 plist），所以一旦某次 release 中途死掉，
        #   那一格号就白吃了：实测一次会话中断攒出 14 格空号 + 9 份没人用的 dSYM，
        #   而 /Applications 里还是旧包 ⇒ 对着旧界面反馈"改了没生效"。
        #   删掉这段不会让任何测试变红，只会让下一次中断重新通胀 ⇒ 按本项目纪律钉成断言。
        #   判据用变量名 `ver_unspent`（比 grep 中文注释稳，改措辞不会误报）。
        if ! grep -q 'ver_unspent=1' "$ROOT/SelectedApp/build_app.sh"; then
            echo "❌ version_sync   build_app.sh 里找不到「未交付版本号复用」判定（ver_unspent）"
            echo "   ⇒ 被中断的 release 会白吃版本号与 dSYM；修法见该脚本 HEAD_PLIST 那一段。"
            FAILED+=("version_sync")
        else
            echo "✅ version_sync   版本 ${v_short}（build ${v_build}）：语义化 + build 独立递增 + 未交付格可复用"
        fi
    fi
fi

# 静态护栏：三处「静态护栏条数」必须一致且等于 GUARD_NAMES 长度。
#   加护栏的人只改自己眼前那一处就会漂移（三处单独看都"像是对的"），这类漂移不会让测试变红。
#   权威条数 = GUARD_NAMES 数组长度（唯一来源）；README / 功能说明 / 本文件头部必须等于它。
# ➕ 反向检查：数组里每个名字必须在脚本中真的有对应 ❌ 输出（防"护栏删了名字还留着"）。
# ⚠ 人工核对实际条数：跑一次数输出（grep '^✅ '），别静态数源码标签 —— 变量插值的 ✅ 行
#   抽不到会少算；guard_paths 没有 ✅ 行，人工数要 +1。
# ⚠ 空转检测（两层，缺一不可）：被扫的三个文件必须存在；三个正则任一抽不出数字必须报红，
#   而不是"两边都抽到空、空 == 空"地通过。
GCS_HDR="$ROOT/engine/tests/run_all.sh"
GCS_RDM="$ROOT/README.md"
GCS_FUN="$ROOT/docs/功能说明.md"
if [ ! -f "$GCS_HDR" ] || [ ! -f "$GCS_RDM" ] || [ ! -f "$GCS_FUN" ]; then
    echo "❌ guard_count_sync  被扫文件不存在（路径漂了 → 护栏会静默失效）"
    echo "     run_all.sh=[${GCS_HDR}] README=[${GCS_RDM}] 功能说明=[${GCS_FUN}]"
    FAILED+=("guard_count_sync")
else
    n_hdr=$(grep -oE '共 \*\*[0-9]+\*\* 条' "$GCS_HDR" | grep -oE '[0-9]+' | head -1)
    n_rdm=$(grep -oE '\*\*[0-9]+ 条静态护栏' "$GCS_RDM" | grep -oE '[0-9]+' | head -1)
    n_fun=$(grep -oE '\*\*[0-9]+ 条静态护栏' "$GCS_FUN" | grep -oE '[0-9]+' | head -1)
    if [ -z "$n_hdr" ] || [ -z "$n_rdm" ] || [ -z "$n_fun" ]; then
        echo "❌ guard_count_sync  抽不到条数（正则/措辞漂了 → 护栏会静默失效）"
        echo "     run_all.sh 头部=[${n_hdr:-空}]  README=[${n_rdm:-空}]  功能说明=[${n_fun:-空}]"
        FAILED+=("guard_count_sync")
    elif [ "$n_hdr" != "$n_rdm" ] || [ "$n_hdr" != "$n_fun" ]; then
        echo "❌ guard_count_sync  三处护栏条数不一致：run_all.sh=${n_hdr} README=${n_rdm} 功能说明=${n_fun}"
        FAILED+=("guard_count_sync")
    elif [ "$n_hdr" != "${#GUARD_NAMES[@]}" ]; then
        echo "❌ guard_count_sync  三处数字（${n_hdr}）≠ GUARD_NAMES 的长度（${#GUARD_NAMES[@]}）"
        echo "     ⇒ 要么改了数字没改数组，要么加了护栏没改数字"
        echo "     数组内容：${GUARD_NAMES[*]}"
        FAILED+=("guard_count_sync")
    else
        # 反向：数组里每个名字都必须真的有一条 ❌ 输出（防"护栏被删、名字还留在数组里"）
        gcs_missing=""
        for g in "${GUARD_NAMES[@]}"; do
            grep -q "❌ $g" "$GCS_HDR" "$HERE/guards/"*.sh || gcs_missing="${gcs_missing} ${g}"
        done
        if [ -n "$gcs_missing" ]; then
            echo "❌ guard_count_sync  GUARD_NAMES 里这些名字在脚本中**没有对应的 ❌ 输出**：${gcs_missing}"
            echo "     ⇒ 护栏可能被删了而名字还留着（长度不变 → 一致性检查看不出来）"
            FAILED+=("guard_count_sync")
        else
            # ⚠ 扩扫第 4、5 处（2026-10-16 审查 B7）：本护栏原先**只看这三处**，
            #   而 `.github/workflows/regression.yml` 与 `docs/specs/README.md` 同样在
            #   复写护栏条数 —— 实测两处都停在「42 条」很久，全仓五处数字三个值，
            #   而回归一直全绿。教训：**"手工同步 N 处 + 只校验 N 处"的护栏，
            #   失效点就在第 N+1 处**。现在凡是写「N 条(静态)护栏」的文件都在扫描范围内。
            gcs_extra_bad=""
            for xf in "$ROOT/.github/workflows/regression.yml" "$ROOT/docs/specs/README.md"; do
                [ -f "$xf" ] || continue
                for x in $(grep -oE '[0-9]+ ?条(静态)?护栏|护栏（[0-9]+ ?条|护栏\([0-9]+ ?条' "$xf" | grep -oE '[0-9]+'); do
                    [ "$x" = "${#GUARD_NAMES[@]}" ] || gcs_extra_bad="${gcs_extra_bad} $(basename "$xf")=${x}"
                done
            done
            if [ -n "$gcs_extra_bad" ]; then
                echo "❌ guard_count_sync  扩扫文件里写死的护栏条数与实际不符：${gcs_extra_bad}"
                echo "     ⇒ 修法：把这些处的数字改成实际条数，或改写为「以 run_all.sh 输出为准」。"

                FAILED+=("guard_count_sync")
            else
                echo "✅ guard_count_sync  三处一致且等于实际条数（${n_hdr} 条），扩扫 CI 与 specs 亦无漂移"
            fi
        fi

    fi
fi

# ⚠⚠ 实际执行套件数校验（suite_ran）：工具链前置断言之外的第二道防线 ——
#   前置断言挡「一个都没跑」，本条挡「跑了一部分」（守卫条件写错、套件被误注释）。
#   ⚠ 判据必须独立于登记处本身：这里数的是守卫行数，不是 RAN+= 登记行数 ——
#   数登记行的话，删一处登记期望值同步降低 ⇒ 自洽通过、防线形同不存在
#   （判据和被测对象来自同一处 ⇒ 一起漂）。守卫数与登记数是两个独立事实。
EXPECTED_SUITES=$(grep -cE 'if command -v swiftc? >/dev/null 2>&1 && \[[^]]+\]; then$' "$HERE/lib/suites.sh")
actual_suites=${#RAN[@]}
if [ "$actual_suites" -ne "$EXPECTED_SUITES" ]; then
    echo "❌ suite_ran       实际执行 ${actual_suites} 个套件，应为 ${EXPECTED_SUITES} 个 —— 有套件被静默跳过"
    echo "     ⇒ 很可能某个 \`command -v swift\` 守卫的条件没满足（工具链 / 脚本文件缺失）。"
    echo "     ⇒ **这不是「通过」，是「没跑」** —— 查上面哪个套件连 ✅ 行都没有。"
    FAILED+=("suite_ran")
else
    echo "✅ suite_ran       实际执行 ${actual_suites}/${EXPECTED_SUITES} 个套件（无静默跳过）"
fi

# 静态护栏：文档里写死的「当前基线」数字必须与实测一致。
#   这类数字的问题不是"今天对不对"，而是明天必然错（加 spec / 改代码就没人更新）。
# 判据：README 目录树里「docs/specs —— N 份」必须等于实测份数（每次新增 spec 就会漂）。
#   「静态护栏 —— N 条」由 guard_count_sync 间接管。
# ⚠ 不锁「12 条口径漂移」「K 线 12 个形状」这类设计事实 —— 不随代码增长而变，锁了是负担。
_DB_BAD=""
_db_specs=$(ls "$ROOT/docs/specs"/*.md 2>/dev/null | wc -l | tr -d ' ')
_db_doc_specs=$(grep -oE 'specs/ *#[^#]*—— [0-9]+ 份' "$ROOT/README.md" | grep -oE '[0-9]+' | head -1)
if [ -z "$_db_doc_specs" ]; then
    echo "❌ doc_baseline_numbers  README 目录树里找不到「docs/specs —— N 份」这一行（格式变了 → 护栏空转）"
    FAILED+=("doc_baseline_numbers")
elif [ "$_db_specs" != "$_db_doc_specs" ]; then
    echo "❌ doc_baseline_numbers  README 写 specs ${_db_doc_specs} 份，实际 ${_db_specs} 份"
    echo "     ⇒ 要么补一份 spec（好事），要么把 README 的数字改对。"
    echo "     ⇒ 这类数字只要漂了就没人数得清，所以钉住它。"
    FAILED+=("doc_baseline_numbers")
else
    echo "✅ doc_baseline_numbers  README 的基线数字与实测一致（specs ${_db_specs} 份）"
fi

# 静态护栏：GUARD_NAMES 里每一条都必须在功能说明 §十二 里被点名。
#   guard_count_sync 只管数字不管名单 —— 「数组新增了、文档名单忘了」会全绿通过
#   （数字与长度都对得上，只有名单内容对不上，而它不看内容）。
# 判据（双向）：① 数组里每个名字都能在功能说明里找到（`名字` 形式）；
#   ② 功能说明里提到的护栏名都要在数组里（防文档写了实现已删的护栏 —— 比①更隐蔽）。
_GD_BAD=""
_GD_DOC="$ROOT/docs/功能说明.md"
if [ ! -f "$_GD_DOC" ]; then
    echo "❌ guard_doc_coverage  功能说明不存在：${_GD_DOC}（路径变了 → 护栏空转）"
    FAILED+=("guard_doc_coverage")
else
    # 取 §十二 那一段（从「N 条静态护栏」到下一个 `---`）
    _GD_SEG=$(awk '/条静态护栏/,/^---$/' "$_GD_DOC")
    for _g in $GUARD_NAMES_LIST; do
        printf '%s' "$_GD_SEG" | grep -c "\`$_g\`" >/dev/null || _GD_BAD="$_GD_BAD $_g(文档未提)"
    done
    # 反向：文档里提到的形如 xxx_yyy 的反引号标识符必须在数组里。
    # ⚠ 用 case 而不是 printf | grep -q：后者把整个数组当一个模式，永远不匹配（实测假红）。
    # ⚠⚠ 必须用 "${GUARD_NAMES[@]}"（带下标展开）而不是 $GUARD_NAMES —— 后者只取第 0 个元素，
    #   所有匹配必然失败、整条护栏恒报「数组里没有」。
    #   （for _g in $GUARD_NAMES_LIST 能工作是因为 LIST 是含全部名字的字符串。）
    _GD_NAMES_FLAT=" $(printf '%s ' "${GUARD_NAMES[@]}") "
    # ⚠⚠ 反向判据必须排除普通单词（animation / block / break / error 是正文里的普通词）：
    #   只认「含下划线且以已知护栏前缀开头」的标识符（前缀取自现有护栏名首段）。
    #   这样"文档写了实现已删的护栏"仍能抓到，而普通词不会被误报。
    for _m in $(printf '%s' "$_GD_SEG" | grep -oE '\`[a-z][a-z0-9]*_[a-z0-9_]+\`' | tr -d '\`' | sort -u); do
        # ⚠ 白名单：文档也会点名别的东西（自检套件名、表名如 data_source_logs、日志 event 值
        #   如 host_degraded、已下线别名 p0_guard），它们不是护栏，不挡会报「数组里没有」（假红）。
        case " audit_fixes classify sqlite_writer history_replay chart_zoom
               market_tag pool_list alert limit_up_pool watch_group theme
               migration p0_guard host_degraded data_source_logs " in
            *" $_m "*) continue ;;
        esac
        case "$_GD_NAMES_FLAT" in
            *" $_m "*) : ;;                       # 在数组里 ✓
            *) _GD_BAD="$_GD_BAD $_m(数组里没有)" ;;
        esac
    done
    if [ -n "$_GD_BAD" ]; then
        echo "❌ guard_doc_coverage  护栏名单与功能说明 §十二 不一致："
        echo "$_GD_BAD" | tr ' ' '\n' | grep . | sed 's/^/     · /'
        echo "     ⇒ 数组里有而文档没写 = 用户以为有这道防线，实际看文档找不到；"
        echo "       文档写了而数组里没有 = 用户以为有，实际代码里已删。"
        echo "     ⇒ 两边都要改：加/删数组项 + 同步功能说明 §十二 的名单与 README.md:92 的数字。"
        FAILED+=("guard_doc_coverage")
    else
        echo "✅ guard_doc_coverage  $(printf '%s\n' $GUARD_NAMES_LIST | wc -l | tr -d ' ') 条护栏在功能说明里都有点名（双向一致）"
    fi
fi

