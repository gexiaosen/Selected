#!/bin/bash
# UI token、排版精度、图表分离、窗口壳与导航绑定静态护栏（由 run_all.sh source）

# 静态护栏：视图里不得就地写死表面色（散写 Color.secondary.opacity 在深色外观下与卡片底
#   几乎无差、层级全糊，代码审查看不出来）。表面色统一走 Tok（row/sunken/chip/…），
#   明暗两档在 Tokens.swift 一处定义、由 theme 自检钉死对比度与层级。
# ⚠ 三个护栏都忽略纯注释行（strip_comments）：注释里为说明历史写法必然出现这些字面量，
#   把注释也算命中就是惩罚写文档。过滤条件：`路径:行号:` 之后以 `//` 开头。
raw_surface=$(grep -rn "Color\.secondary\.opacity" "$SRC_CORE" "$SRC_APP" --include=*.swift \
              | grep -v "Views/Tokens.swift" | strip_comments || true)
if [ -n "$raw_surface" ]; then
    echo "❌ theme_source     视图里又出现写死的表面色（应改用 Tok.* 语义入口）"
    printf '%s\n' "$raw_surface" | head -5 | sed 's/^/     /'
    FAILED+=("theme_source")
else
    echo "✅ theme_source     表面色统一走 Tok（无 Color.secondary.opacity 散写）"
fi

# 静态护栏：字号出口唯一（来源只许两套：AppFont / 系统语义字号；同一字号多种写法 ⇒
#   调一处要全文搜索、新代码没有"该用哪档"的依据）。
# 判据：Tokens.swift（档位定义处）之外不许出现 `.system(size:`（散写）与 `Font.custom`（自造字体）。
# ⚠ 空转检测：enum AppFont 必须还在 Tokens.swift 里，否则"一条都没命中"可能只是档位被搬走。
# ⚠ 判据写 `\.system(size:` 而不是 `\.font(\.system(size:`：后者漏掉裸 `Font.system(size: 11)`（实测假绿）。
font_raw=$(grep -rn '\.system(size:\|Font\.custom\|\.custom("' "$SRC_APP" --include=*.swift \
           | grep -v "Views/Tokens.swift" | strip_comments || true)
if [ ! -f "$SRC_APP/Views/Tokens.swift" ]; then
    echo "❌ font_outlet     找不到档位定义文件（路径漂了 → 护栏会静默失效）"
    FAILED+=("font_outlet")
elif ! grep -qE 'enum AppFont[^A-Za-z0-9_]' "$SRC_APP/Views/Tokens.swift"; then
    echo "❌ font_outlet     Tokens.swift 里已无 enum AppFont（护栏空转：档位被搬走或改名了？）"
    FAILED+=("font_outlet")
elif [ -n "$font_raw" ]; then
    echo "❌ font_outlet     字号散写在 AppFont 之外（应走 AppFont / 系统语义字号）："
    printf '%s\n' "$font_raw" | head -5 | sed 's/^/     /'
    FAILED+=("font_outlet")
else
    echo "✅ font_outlet     字号出口唯一（无散写 .system(size:) / 无 Font.custom）"
fi

# 静态护栏：彩底文字必须走 Tok.onAccent（唯一出口：浅色=白、深色=近黑）。
#   彩底上写死 .white，深色外观下色号提亮、白字发糊（对比度不足）。
raw_white=$(grep -rn "\.white\b" "$SRC_APP" --include=*.swift \
            | grep -v "Views/Tokens.swift" | strip_comments || true)
if [ -n "$raw_white" ]; then
    echo "❌ theme_accent     彩底文字写死了白色（应改用 Tok.onAccent）"
    printf '%s\n' "$raw_white" | head -5 | sed 's/^/     /'
    FAILED+=("theme_accent")
else
    echo "✅ theme_accent     彩底文字统一走 Tok.onAccent（无 .white 散写）"
fi

# 静态护栏：语义色底必须走 `Tok.tint(_:_:)`（三档：.block 0.08 / .chip 0.12 / .strong 0.18）。
# 判据一拦的是模式：括号内任意位置出现 < 0.2 的裸透明度（含三元/变量形态，不只紧邻括号的字面量）。
#   0.2 是自然分界：< 0.2 全部属于语义色底，0.25+ 是另一族（中性提示块底/图表填充/进度条），
#   因此不需要例外白名单，也不会因"加白名单"而失效。
# 判据二：`Sem.*.opacity(` 任意值都禁 —— 语义色不靠透明度表达强弱（明暗两档观感不一致）：
#   底走 Tok.tint、图形色块走 Sem.*Graph/*Series、文字/图标用全色。
#   （变量 laundering 如 `color.opacity(0.85)` 正则追不到，靠审查；判据一只管得到 <0.2 的。）
# ⚠ 扫描范围必须是 $SRC_APP 全量（App 外壳与 Store 与 Views 同层），只扫 Views/ 会漏。
raw_tint=$(grep -rnE "\.opacity\([^)]*0\.[01][0-9]?" "$SRC_APP" --include=*.swift \
           | grep -v "Views/Tokens.swift" | strip_comments || true)
raw_sem_op=$(grep -rnE "Sem\.[A-Za-z]+\.opacity\(" "$SRC_APP" --include=*.swift \
           | grep -v "Views/Tokens.swift" | strip_comments || true)
# ⚠ 防空转：正则或路径漂了 → 一条都不剩 → 看着全绿、其实没查。
#   用"被推荐的出口还在不在"作正控制：Tok.tint 一旦被删/改名，本护栏必须先报出来。
TINT_TOK="$SRC_VIEWS/Tokens.swift"
if [ ! -f "$TINT_TOK" ]; then
    echo "❌ theme_tint       找不到 ${TINT_TOK}（路径漂了 → 护栏会静默失效）"
    FAILED+=("theme_tint")
elif ! grep -q "static func tint(" "$TINT_TOK"; then
    echo "❌ theme_tint       被推荐的出口 `Tok.tint` 已不存在（护栏空转：改法失效了）"
    FAILED+=("theme_tint")
elif [ -n "$raw_tint" ] || [ -n "$raw_sem_op" ]; then
    echo "❌ theme_tint       语义色裸透明度散写（底走 Tok.tint，图形走 *Graph/*Series，文字用全色）"
    printf '%s\n' "$raw_tint" "$raw_sem_op" | head -5 | sed 's/^/     /'
    FAILED+=("theme_tint")
else
    echo "✅ theme_tint       语义色底统一走 Tok.tint（无 <0.2 裸透明度、无 Sem.*.opacity 散写）"
fi

# 静态护栏：按钮样式必须走 Components.swift 的角色出口（btnPrimary / btnSecondary /
#   btnDanger / btnDangerFilled / btnIcon / btn(_:)）。裸写 .buttonStyle(.bordered…) 的
#   唯一允许处是 Views/Components.swift（角色出口的实现处）—— 规则散在每个调用点 = 没有单一出口。
# ⚠ 不拦 .plain（行内命中区，换样式会改命中区与手势优先级）/ .borderless（图标按钮基座）/
#   .link（行内文字链接）—— 豁免是有理由的具名条目，不是"漏掉了"。
# 空转检测（两条）：被扫目录必须存在；func btnPrimary() 必须还在（出口没了，改法就是空话）。
raw_btn=$(grep -rnE "\.buttonStyle\(\.bordered" "$SRC_APP" --include=*.swift \
          | grep -v "Views/Components.swift" | strip_comments || true)
BTN_OUTLET="$SRC_VIEWS/Components.swift"
if [ ! -d "$SRC_APP" ]; then
    echo "❌ button_style    被扫目录不存在：${SRC_APP}（路径漂了 → 护栏会静默失效）"
    FAILED+=("button_style")
elif [ ! -f "$BTN_OUTLET" ] || ! grep -q "func btnPrimary()" "$BTN_OUTLET"; then
    echo "❌ button_style    按钮角色出口不见了（${BTN_OUTLET} 里找不到 func btnPrimary()）→ 护栏空转"
    FAILED+=("button_style")
elif [ -n "$raw_btn" ]; then
    echo "❌ button_style    裸写按钮样式（应改用 btnPrimary/btnSecondary/btnDanger/btnIcon）"
    printf '%s\n' "$raw_btn" | head -5 | sed 's/^/     /'
    FAILED+=("button_style")
else
    echo "✅ button_style     按钮样式统一走角色出口（无裸 .buttonStyle(.bordered…) 散写）"
fi

# 静态护栏：图表库的 YAxis.lineColor 必须真的被消费（最隐蔽的一类：参数声明了、传了，
#   但绘制处写死灰色）。theme 自检只断言 token 值对不对，验不了参数有没有被消费。
TV="$ROOT/SelectedApp/LocalPackages/swift-trading-view/Sources/SwiftTradingView/TradingView.swift"
SKC="$SRC_APP/Views/StockKLineChart.swift"
if [ ! -f "$TV" ]; then
    # ⚠ 必须是 else 报红（2026-10-16 审查 B2 实测）：原先写作 `if [ -f "$TV" ]; then … fi`
    #   **没有 else** —— 于是 vendor 文件改名/移出仓库时本条整段不执行、不打印任何东西，
    #   而全量回归仍以「✅ 全部回归测试通过」收尾。这是 44 条里唯一用肯定式包文件检查的一条，
    #   违反本文件自述的规则（见 :373 一带「路径漂了 → 护栏会静默失效」必须显式报红）。
    echo "❌ chart_param      找不到 ${TV}（vendor 路径漂了 ⇒ 本护栏空转）"
    FAILED+=("chart_param")
elif ! grep -q "yAxis.lineColor" "$TV"; then
    echo "❌ chart_param      水平网格线没有消费 YAxis.lineColor（参数被写死绕过了）"
    FAILED+=("chart_param")
elif grep -nE "Color\.gray\.opacity" "$TV" | strip_comments | grep -c . >/dev/null; then
    echo "❌ chart_param      水平网格线又出现写死的 Color.gray.opacity"
    FAILED+=("chart_param")
elif [ ! -f "$SKC" ]; then
    echo "❌ chart_param      找不到 ${SKC}（图表调用方路径漂了 ⇒ 下面两条断言空转）"
    FAILED+=("chart_param")
elif ! grep -qE "yAxisColumnWidth: CGFloat = 56" "$TV"; then
    echo "❌ chart_param      库的 Y 轴列宽默认值不再是 56（App 侧的推导常量要跟着改，见下）"
    FAILED+=("chart_param")
elif ! grep -qE "static let yAxisColumnWidth: CGFloat = 56" "$SKC"; then
    echo "❌ chart_param      App 侧 yAxisColumnWidth 与库默认值不再同值 ⇒ 分时的「绘图区宽 = 实测宽 − 轴列」推导会算错，"
    echo "                   后果是 240 槽铺不满或溢出绘图区（右侧留白 / 下午被裁），编译与单测都不报"
    FAILED+=("chart_param")
elif ! grep -q "ChartZoomMath.fitCandleWidth" "$SKC"; then
    echo "❌ chart_param      分时槽宽又回到写死常量（应走 fitCandleWidth 按实测图表宽现算，见 minuteSlotWidth(chartWidth:)）"
    FAILED+=("chart_param")
else
    echo "✅ chart_param      水平网格线消费 YAxis.lineColor（无写死色）+ 分时槽宽按实测视口推导（Y 轴列宽两侧同值）"
fi

# 静态护栏：分时**成交量柱的红绿方向**（`open` 在分时里是"本分钟的涨跌基准"，不是开盘价）
#   库的 `VolumeIndicator` 按 `open > close` 判跌（绿）、否则判涨（红）；最新价胶囊按 `close >= open`。
#   ⇒ 分时的 `open` 若填成现价，`open == close` 恒成立 → **成交量柱永远全红**（2026-10-19 实测），
#     而且编译通过、941 个单测全绿、其余护栏一条都不报 —— 只有源码能钉住。
#   修法：`open` 填"上一分钟价"（首根用昨收）—— 两个消费方都自动拿到正确方向，且不必改库。
# 判据（双向）：正向三条（首根基准 = 昨收 / open 填基准 / 基准逐根推进），
#   反向一条（`open: p.price, close: p.price` 不许再出现 —— 那正是 bug 的原形态）。
CHART_SRC="$SRC_VIEWS/StockKLineChart.swift"
if [ ! -f "$CHART_SRC" ]; then
    echo "❌ minute_volume_open  找不到 ${CHART_SRC}（路径漂了 → 护栏空转）"
    FAILED+=("minute_volume_open")
elif ! grep -q "var refPrice = previousClose" "$CHART_SRC"; then
    echo "❌ minute_volume_open  分时首根的涨跌基准不是昨收（var refPrice = previousClose 不见了）"
    FAILED+=("minute_volume_open")
elif ! grep -qE "open: refPrice" "$CHART_SRC"; then
    echo "❌ minute_volume_open  分时的 open 没填基准价（成交量柱会全红）"
    FAILED+=("minute_volume_open")
elif ! grep -q "refPrice = p.price" "$CHART_SRC"; then
    echo "❌ minute_volume_open  基准价没有逐根推进（每根都和首根比 → 颜色整段一致）"
    FAILED+=("minute_volume_open")
elif grep -nE "open: p\.price, close: p\.price" "$CHART_SRC" | strip_comments | grep -c . >/dev/null; then
    echo "❌ minute_volume_open  分时的 open 又写成现价（open == close ⇒ 成交量柱全红）"
    FAILED+=("minute_volume_open")
else
    echo "✅ minute_volume_open  分时成交量柱按「相对上一分钟/昨收」着色（open 不再写成现价）"
fi

# 静态护栏：涨跌数字**恒带 `+/-`**（设计文档 D2-5，"现状已对，不许回退"那类）。
#   为什么必须有护栏：颜色是这条链路上唯一可以被随手拿掉的通道，而实测
#   **五套配色的涨/跌文字色在二色觉下根本分不开**（deutan ΔE 仅 0.030–0.082，
#   本仓自己的判据是 <0.10 = 不可分；明度差 ΔL 也只有 0.001–0.033 —— text 档刻意齐平，
#   好让数字列不因颜色跳行）。⇒ "红涨绿跌"对一部分用户**不存在**，符号是唯一稳定的方向通道。
#   一旦有人"为了排版好看去掉正号"，界面就退化成"只有色盲看不出方向"——编译不报错、单测全绿。
# 判据：凡 `String(format:` 的入参里出现涨跌字段名，格式串必须含 `%+`。
# ⚠⚠ 同时断言**命中数**（≥ 15）：字段改名 / 路径漂了会让 grep 命中 0 行而"全绿"通过 ——
#   那正是 `sem_contrast` 正则版踩过的坑（护栏空转比没有护栏更糟，见本文件 sem_contrast 段）。
_SC_FIELDS='changePct|changePercent|pnlPct|dayPnlPct|gainPct'
if [ ! -d "$SRC_VIEWS" ]; then
    echo "❌ signed_change     找不到 ${SRC_VIEWS}（路径漂了 → 护栏空转）"
    FAILED+=("signed_change")
else
    _SC_HITS=$(grep -rn 'String(format:' "$SRC_VIEWS" "$SRC_APP" | strip_comments \
               | grep -E "$_SC_FIELDS" || true)
    _SC_N=$(printf '%s' "$_SC_HITS" | grep -c . || true)
    _SC_BAD=$(printf '%s' "$_SC_HITS" | grep -v '%+' || true)
    if [ "${_SC_N:-0}" -lt 15 ]; then
        echo "❌ signed_change     只命中 ${_SC_N} 处涨跌格式化（预期 ≥15）——判据空转，字段名或路径变了"
        FAILED+=("signed_change")
    elif [ -n "$_SC_BAD" ]; then
        echo "❌ signed_change     $(printf '%s' "$_SC_BAD" | grep -c . || true) 处涨跌数字没带 +/-（色觉障碍下读不出方向）"
        printf '%s\n' "$_SC_BAD" | head -5 | sed 's/^/     /'
        FAILED+=("signed_change")
    else
        echo "✅ signed_change     $_SC_N 处涨跌/盈亏格式化全部带符号（颜色之外的方向通道不许拿掉）"
    fi
fi

# 静态护栏：**价格小数位必须按标的定档**（场内基金 3 位，其余 2 位）。
#   2026-10-29 他实测「基金只显示 2 位小数」：净值本来就是 3 位（`159915` 现价 3.406、
#   生产库成本价 `159338 = 1.249`），出口写死 `%.2f` 把 `1.052` 打成 `1.05` ——
#   不是"少一位小数"，是**两个不同净值显示成同一个价**；提醒阈值回显再存回去
#   还会把库里的 1.052 **静默改写成 1.05**。
#   病根不在取数（精度一路保留），只在出口 —— 所以出口收在 `StockFmt.priceDigits/price/signedPrice`。
# 判据三条，每条都能单独变红：
#   ① 出口三个函数必须还在（**正对照**：被改名/搬走时下面的"0 泄漏"可能只是没在查）；
#   ② App 层与 Core 层都不许再出现「`%.2f` 直接吃价格字段」；
#   ③ 出口调用点数量下限（防止大家绕过出口各写各的）。
PP_DEF="$SRC_CORE/StockQuotes.swift"
if [ ! -f "$PP_DEF" ]; then
    echo "❌ price_precision  找不到 ${PP_DEF}（路径漂了 → 护栏会静默失效）"
    FAILED+=("price_precision")
else
    pp_defs=$(grep -cE 'static func (priceDigits|price|signedPrice)\(' "$PP_DEF" || true)
    pp_used=$(grep -rn 'StockFmt\.\(signed\)\?price(' "$SRC_APP" "$SRC_CORE" --include=*.swift \
              | grep -v 'StockQuotes.swift' | strip_comments | wc -l | tr -d ' ')
    pp_leak=$(grep -rnE '%\+?\.2f' "$SRC_APP" "$SRC_CORE" --include=*.swift \
              | grep -E 'currentPrice|previousClose|highPrice|lowPrice|\.change\b|selPrice|targetPrice|stopLossPrice|avgCost|cost90|pressurePrice|\bclose\b' \
              | grep -v 'StockQuotes.swift' | strip_comments || true)
    if [ "${pp_defs:-0}" -lt 3 ]; then
        echo "❌ price_precision  出口只剩 ${pp_defs} 个（应为 3：priceDigits/price/signedPrice ⇒ 被改名或搬走，本护栏空转）"
        FAILED+=("price_precision")
    elif [ -n "$pp_leak" ]; then
        echo "❌ price_precision  价格字段还在被 %.2f 直接格式化（应走 StockFmt.price(_:code:)，基金要 3 位）："
        printf '%s\n' "$pp_leak" | head -5 | sed 's/^/     /'
        FAILED+=("price_precision")
    elif [ "${pp_used:-0}" -lt 25 ]; then
        echo "❌ price_precision  出口调用点只剩 ${pp_used} 处（下限 25 = 2026-10-29 收口时实数，掉了说明有人绕开出口自己写）"
        FAILED+=("price_precision")
    else
        echo "✅ price_precision  价格小数位统一走出口（${pp_used} 处调用，0 处 %.2f 直接吃价格字段）"
    fi
fi

ORB_LIB="ThinkingOrbs"
# ② 只允许出现在 Components.swift
#
# ⚠ 护栏自身失效检测：白名单路径漂了 → 静态通过（看着全绿、其实没查）→ 先断言存在；
#   白名单里已无动效引用（特性被回退）→ 空转 → 也报红，提醒把护栏连同 spec 一起下掉。
ORB_ALLOWED=(
    "$SRC_APP/Views/Components.swift"
    "$SRC_APP/Views/Components+PageControls.swift"
    "$SRC_APP/Views/Components+DataDisplay.swift"
)
if ! ls "${ORB_ALLOWED[@]}" >/dev/null 2>&1; then
    echo "❌ orb_whitelist   找不到白名单文件（路径漂了 → 护栏会静默失效）"
    FAILED+=("orb_whitelist")
elif ! grep -q "ThinkingOrb" "${ORB_ALLOWED[@]}"; then
    echo "❌ orb_whitelist   白名单文件里已无动效引用（护栏空转：该连同 spec 一起下掉）"
    FAILED+=("orb_whitelist")
else
    raw_orb=$(grep -rn "ThinkingOrb" "$SRC_APP" --include=*.swift \
              | grep -Ev "Views/Components(\.swift|\+PageControls\.swift|\+DataDisplay\.swift)" | strip_comments || true)
    if [ -n "$raw_orb" ]; then
        echo "❌ orb_whitelist   动效出现在白名单外（应经 Components.swift 的 LoadingView / ThinkingDot）"
        printf '%s\n' "$raw_orb" | head -5 | sed 's/^/     /'
        FAILED+=("orb_whitelist")
    else
        echo "✅ orb_whitelist   动效只在 Components.swift（唯一出口）"
    fi
fi

# 静态护栏：ForEach 的 id 不许绑到整个元素/非标量上（"改回去不会让任何测试变红"）。
#   JSONValue 是所有实体 payload 的底座，id: \.element 会让每次 body 求值把整份 payload
#   拼字符串再哈希（实测 6 MB 结果 → 225ms/次 body），不报错不崩、测试全绿，只是页面卡。
# 判据拦形态：\.element 后面只许跟标量（元组下标 / JSONValue 标量访问器 / 先取子节点再取标量）。
#   豁免清单已清空并删除：CompareView 的 [Int] 轮次改走 SharedDataTable 后不再有裸 `id: \.element`，
#   留着白名单只会让护栏依赖一个随时会漂走的文件路径（2026-10-26 就是它自己报的空转）。
# ⚠ 已知局限：标量访问器清单是手写枚举，JSONValue 新增标量出口会被误报（可见的假红，改清单即可）。
FID_SAFE='id: *\\\.element(\[[^]]*\])?(\.[0-9]+|\.(string|int|double|bool|stringOrDash|intOrZero|doubleOrZero|intOr|doubleOr|boolOr))'
if [ ! -d "$SRC_APP/Views" ]; then
    echo "❌ foreach_id_payload  找不到 ${SRC_APP}/Views（路径漂了 → 护栏会静默失效）"
    FAILED+=("foreach_id_payload")
else
    raw_fid=$(grep -rnE 'id: *\\\.element' "$SRC_APP" --include=*.swift \
              | strip_comments \
              | grep -vE "$FID_SAFE" || true)
    if [ -n "$raw_fid" ]; then
        echo "❌ foreach_id_payload  ForEach 的 id 绑到了非标量上（大 payload 时每次 body 求值都要整份哈希）"
        printf '%s\n' "$raw_fid" | head -5 | sed 's/^/     /'
        echo "     改法：换稳定标量键（下标 / code / 轮次值…）—— 见 docs/specs/README.md"
        FAILED+=("foreach_id_payload")
    else
        echo "✅ foreach_id_payload  ForEach 的 id 只取标量（无豁免，全站通用）"
    fi
fi

# 静态护栏：自选行内小图标按钮的命中区域契约（没有任何测试能验；形状一变就报红 →
#   改的人必须真点一次）。成立靠三件事同时成立：是 Button、.buttonStyle(.plain)、
#   label 自带 .contentShape(Rectangle())（少了可点区缩到字形墨迹，16pt 图标"看着有点不着"）。
#   形状收敛在共用函数 rowIconButton，消费方 alertBell / holdingToggle 必须都走它
#   （只钉共用形状的话，消费方改回 Image + onTapGesture 不会报红）。
# ⚠ 空转检测：rowIconButton 被删/改名 → 抽出为空也必须报红，否则"特性被回退"伪装成"契约完整"。
# ⚠ 抽函数体用花括号配平（"函数头起 N 行"的窗口在函数变短时会串到下一个函数 → 假绿）。
# ⚠ 模式串里的 ( 写成 [(]：awk -v 会对值做转义，\( 被吃成 ( → awk 正则报错（实测踩过）。
# ⚠ 必须有 entered 判据：签名可能跨行，第一行没花括号、depth 还是 0，少了它会抽个空壳。
extract_func() {   # $1 = awk 正则（匹配函数头那一行）
    awk -v pat="$1" '
        !f && $0 ~ pat { f = 1 }
        f {
            probe = $0; opens = gsub(/\{/, "{", probe)
            probe = $0; closes = gsub(/\}/, "}", probe)
            depth += opens - closes
            if (opens > 0) entered = 1
            print
            if (entered && depth <= 0) exit
        }' "$BELL_SRC"
}
BELL_SRC="$SRC_APP/Views/WatchlistView.swift"
if [ ! -f "$BELL_SRC" ]; then
    echo "❌ alert_bell_hit   找不到 ${BELL_SRC}（路径漂了 → 护栏会静默失效）"
    FAILED+=("alert_bell_hit")
else
    hit_body=$(extract_func 'func rowIconButton[(]')
    hit_code=$(printf '%s\n' "$hit_body" | grep -vE '^[[:space:]]*//' || true)
    bell_code=$(extract_func 'func alertBell[(]' | grep -vE '^[[:space:]]*//' || true)
    hold_code=$(extract_func 'func holdingToggle[(]' | grep -vE '^[[:space:]]*//' || true)
    if [ -z "$hit_body" ]; then
        echo "❌ alert_bell_hit   WatchlistView 里已无 rowIconButton（护栏空转：共用形状被删或改名了？）"
        FAILED+=("alert_bell_hit")
    elif ! printf '%s\n' "$hit_code" | grep -c 'buttonStyle(\.plain)' >/dev/null; then
        echo "❌ alert_bell_hit   rowIconButton 丢了 .buttonStyle(.plain)（行级 onTapGesture 会抢走点击）"
        FAILED+=("alert_bell_hit")
    elif ! printf '%s\n' "$hit_code" | grep -c 'contentShape(Rectangle())' >/dev/null; then
        echo "❌ alert_bell_hit   rowIconButton 丢了 label 上的 .contentShape(Rectangle())（可点区缩到字形墨迹 → 点不着）"
        FAILED+=("alert_bell_hit")
    elif ! printf '%s\n' "$bell_code" | grep -c 'rowIconButton(' >/dev/null; then
        echo "❌ alert_bell_hit   alertBell 不再走共用的 rowIconButton（自己搭形状 = 契约失守）"
        FAILED+=("alert_bell_hit")
    elif ! printf '%s\n' "$hold_code" | grep -c 'rowIconButton(' >/dev/null; then
        echo "❌ alert_bell_hit   holdingToggle 不再走共用的 rowIconButton（自己搭形状 = 契约失守）"
        FAILED+=("alert_bell_hit")
    else
        echo "✅ alert_bell_hit   行内小图标按钮契约完整（共用 rowIconButton ＋ 铃铛/持仓标记都走它）"
    fi
fi

# 静态护栏：动效修饰符出口唯一化 —— 带位移/弹性的动效必须走 motionAware /
#   motionAwareTransition（Components.swift，全 App 唯一感知「减弱动态」的出口）。
#   绕开它零代价：裸写照样编译、照样跑，只是辅助功能开关一开就静默失效。
# 机器判不出某条 .animation 驱动的是位移还是不透明度，故钉文件白名单：
#   下列文件全是已评审的纯不透明度/颜色场景；新增裸动效必须先落进来并想清楚为什么不是位移。
# ⚠ 已知局限：本条只保证位置，白名单内新增的位移类动效拦不下来（靠口径注释 + 评审）。
MOTION_ALLOW="SelectedApp.swift|Views/Components.swift|Views/Components\+PageControls.swift|Views/ResultsView.swift|Views/WatchlistView.swift|Views/WatchlistView\+Groups.swift|Views/WatchlistHoldingSection.swift"
motion_raw=$(grep -rnE "withAnimation\(|\.animation\(|\.transition\(" "$SRC_APP" --include=*.swift \
             | grep -v "motionAware" \
             | grep -vE "\.transition\(\.opacity\)" \
             | grep -vE "reduceMotion \?" \
             | strip_comments || true)
motion_fail=""
# 防空转（theme / orb 系列的同一个坑）：排除规则或路径写错 → 一条都不剩 → 看着全绿、其实没查
if [ -z "$motion_raw" ]; then
    motion_fail="排除后一条裸动效都不剩（护栏空转：正则或路径漂了？）"
else
    motion_bad=$(printf '%s\n' "$motion_raw" | grep -Ev "$MOTION_ALLOW" || true)
    if [ -n "$motion_bad" ]; then
        motion_fail="裸动效出现在白名单文件之外（应走 Components.swift 的 motionAware*）"
    fi
fi
# ② 出口实现本身：只钉位置不够 —— 把 reduceMotion ? nil : animation 改回 animation
#    不会让任何测试变红，却让全 App 减弱动态整体失效。钉住这两行的形态：
#    要改写实现就同步改本护栏，别绕过。
motion_impl="$SRC_APP/Views/Components.swift"
if [ -z "$motion_fail" ]; then
    if [ ! -f "$motion_impl" ]; then
        motion_fail="找不到出口实现文件 ${motion_impl}（路径漂了 → 护栏会静默失效）"
    elif ! grep -q 'content\.animation(reduceMotion ? nil : animation, value: value)' "$motion_impl"; then
        motion_fail="motionAware 丢了 reduceMotion 判断（全 App 的减弱动态会静默失效）"
    elif ! grep -q 'content\.transition(reduceMotion ? \.opacity : transition)' "$motion_impl"; then
        motion_fail="motionAwareTransition 丢了 reduceMotion 判断（同上）"
    fi
fi
# ③ 时长口径：曲线 + duration 的字面量只许出现在 Components.swift 的 `Mot` 定义里
#    （2026-10-28 收口：此前 20 个调用点各写各的，6 个互不相干的值散在 7 个文件，
#    "整体利落一点"要逐处找、新增动效没人知道该填几秒 —— 和表格列宽三套算法同病）。
#    绕开 Mot 零编译代价，所以只能机器拦。
# ⚠ 正对照：定义文件里必须真扫到 ≥8 条曲线。正则漂了会一条都不剩 ⇒ 看着全绿、其实没查。
MOTION_LIT='(^|[^[:alnum:]_])duration:|\.(easeIn|easeOut|easeInOut|linear|spring|bouncy|smooth|timingCurve)\('
motion_lit_bad=$(grep -rnE "$MOTION_LIT" "$SRC_APP" --include=*.swift \
                 | grep -v 'Views/Components.swift' | strip_comments || true)
motion_lit_defs=$(grep -cE 'static let [a-zA-Z]+: Animation = \.' "$SRC_APP/Views/Components.swift" || true)
if [ -z "$motion_fail" ]; then
    if [ -n "$motion_lit_bad" ]; then
        motion_fail="Mot 之外出现字面量曲线/duration（应收进 Components.swift 的 Mot）"
        motion_bad="$motion_lit_bad"
    elif [ "${motion_lit_defs:-0}" -lt 8 ]; then
        motion_fail="Mot 里只扫到 ${motion_lit_defs} 条曲线定义（<8 ⇒ 被删了或正则漂了，护栏空转）"
    fi
fi
if [ -n "$motion_fail" ]; then
    echo "❌ motion_whitelist  ${motion_fail}"
    printf '%s\n' "${motion_bad:-}" | head -5 | sed 's/^/     /'
    FAILED+=("motion_whitelist")
else
    echo "✅ motion_whitelist  出口唯一 + 减弱动态真响应 + 曲线/时长只许在 Mot（当前 ${motion_lit_defs} 档）"
fi

# 静态护栏：持仓金额精度 —— 成本价可以是 3 位小数（券商摊薄成本 / ETF 净值），
#   编辑弹窗若用 %.2f 预填，点一下保存就把库里成本价静默改坏（此后市值/盈亏全错、无提示）。
#   "视图里到底调没调格式化纯函数"没有任何自动化能验，只能靠静态断言。
# 判据（三条正向断言，缺一即红）：
#   ① WatchlistHoldingSection 的预填走 StockFmt.exact(item.costPrice)
#   ② WatchColumns 的成本价列走 StockFmt.costPrice(cost)
#   ③ Core 里 costPrice / money / exact 三个入口都还在
# ⚠ 断言完整调用形状（含实参）—— 只按名字查会被自己的注释喂饱。
# ⚠ 空转检测：三个被扫文件必须存在（路径漂了 → grep 无输出 → 静默通过）。
HP_HOLD="$SRC_VIEWS/WatchlistHoldingSection.swift"
HP_COLS="$SRC_VIEWS/WatchColumns.swift"
HP_FMT="$SRC_CORE/StockQuotes.swift"
if [ ! -f "$HP_HOLD" ] || [ ! -f "$HP_COLS" ] || [ ! -f "$HP_FMT" ]; then
    echo "❌ holding_precision  被扫文件不存在（路径漂了 → 护栏会静默失效）"
    echo "     ${HP_HOLD} / ${HP_COLS} / ${HP_FMT}"
    FAILED+=("holding_precision")
elif ! grep -q 'StockFmt\.exact(item\.costPrice)' "$HP_HOLD"; then
    echo "❌ holding_precision  编辑弹窗预填没走 StockFmt.exact(item.costPrice)（%.2f 预填 → 保存即静默改坏成本价）"
    FAILED+=("holding_precision")
elif ! grep -q 'StockFmt\.costPrice(cost)' "$HP_COLS"; then
    echo "❌ holding_precision  成本价列没走 StockFmt.costPrice(cost)（3 位小数会被压成 2 位）"
    FAILED+=("holding_precision")
elif ! grep -q 'func costPrice(' "$HP_FMT" || ! grep -q 'func money(' "$HP_FMT" \
     || ! grep -q 'func exact(' "$HP_FMT"; then
    echo "❌ holding_precision  StockFmt 少了 costPrice / money / exact 里的某一个（格式化唯一来源被拆了？）"
    FAILED+=("holding_precision")
else
    echo "✅ holding_precision  预填保真 ＋ 成本价 3 位（StockFmt 三个入口都在）"
fi

# 静态护栏：Toast 必须按档位上色，且四档都要真的用上。
#   底色/描边不带语义色 ⇒ 成功/失败/警告/信息一眼分不出；调用点全用 .info ⇒
#   定义了没人用 = 死档位。ToastBanner 在 App 层，swift test 覆盖不到视图，
#   "用了哪一档"更是没有任何自动化能验。
# 判据：① ToastBanner 体内必须出现 Tok.tint(color（底/边带语义色，只染图标不算）；
#   ② .error 与 .warning 在调用点各至少 5 / 3 处（防四档重新退化成两档）。
# ⚠ 空转检测：enum Style 的五档声明必须还在（第 5 档 loading：长任务占位，由同一 key 的
#   完成条原位替换，是唯一不按 2.0/3.5s 收尾的档）。
TS_SRC="$SRC_APP/Views/Components+Overlays.swift"
if [ ! -f "$TS_SRC" ]; then
    echo "❌ toast_styled  找不到 ${TS_SRC}（路径漂了 → 护栏会静默失效）"
    FAILED+=("toast_styled")
elif ! grep -q 'enum Style { case success, info, warning, error, loading }' "$TS_SRC"; then
    echo "❌ toast_styled  ToastCenter.Style 的五档声明不见了（护栏空转）"
    FAILED+=("toast_styled")
else
    # ⚠ 必须**剔掉注释行**：上面几段说明里就写着 `Tok.tint`，不剔会被自己的注释喂饱
    #   （"注释污染"假绿）。
    ts_body=$(awk '/^struct ToastBanner/{f=1} f&&/^\/\/ MARK:/{exit} f{print}' "$TS_SRC" \
              | grep -vE '^[[:space:]]*//')
    ts_err=$(grep -rc 'style: \.error' "$SRC_APP" --include=*.swift 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')
    ts_warn=$(grep -rc 'style: \.warning' "$SRC_APP" --include=*.swift 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')
    if ! printf '%s\n' "$ts_body" | grep -c 'Tok\.tint(color' >/dev/null; then
        echo "❌ toast_styled  ToastBanner 的底/边没带语义色（只有图标带色 ⇒ 四档一眼分不出）"
        FAILED+=("toast_styled")
    elif [ "$ts_err" -lt 5 ] || [ "$ts_warn" -lt 3 ]; then
        echo "❌ toast_styled  .error=${ts_err} 处 / .warning=${ts_warn} 处 —— 四档又退化成两档了"
        echo "     （失败类调用点必须显式标 .error / .warning，别再用 .info 兜）"
        FAILED+=("toast_styled")
    else
        echo "✅ toast_styled  Toast 底/边带语义色（.error ${ts_err} 处 / .warning ${ts_warn} 处）"
    fi
fi

# 静态护栏：四层胜率走势的范围与聚合口径必须写在界面上（三条纯展示口径，改掉不会让测试变红）：
#   ① 默认范围 20 —— 改默认值 = 静默换掉所有人看到的东西（加功能不该有这个副作用）；
#   ② 聚合阈值 120 —— 与 WinrateTrend.weeklyThreshold 脱节时，图上按周而副标题不说 ⇒ 周线被读成日线；
#   ③ 副标题必须写明「按自然周聚合」—— 库里只存胜率不存样本数，周均值只能是简单平均
#      （某天 3 只票与 300 只票权重相同）；这是唯一可得的口径，但必须让用户知道。
# 判据：① 空转检测 WinrateTrend.layerKeys 四层键还在；② Store 默认 == 20、阈值 == 120；
#   ③ ReviewView 真的消费 weeklyThreshold（而不是又写死一个数）；④ 副标题出现「按自然周聚合」。
# ⚠ ③④ 必须剔掉注释行再 grep（说明注释里就写着这些词，会被自己的注释喂饱）。
WT_CORE="$SRC_CORE/WinrateTrend.swift"
WT_STORE="$SRC_APP/Store.swift"
WT_VIEW="$SRC_VIEWS/ReviewView.swift"
if [ ! -f "$WT_CORE" ] || [ ! -f "$WT_STORE" ] || [ ! -f "$WT_VIEW" ]; then
    echo "❌ winrate_trend  被扫文件不存在（路径漂了 → 护栏会静默失效）"
    FAILED+=("winrate_trend")
elif ! grep -q 'public static let layerKeys = \["window", "close", "snapshot", "ceiling"\]' "$WT_CORE"; then
    echo "❌ winrate_trend  WinrateTrend.layerKeys 的四层键声明不见了（护栏空转）"
    FAILED+=("winrate_trend")
elif ! grep -qE 'var winrateTrendRange: Int = 20' "$WT_STORE"; then
    echo "❌ winrate_trend  Store.winrateTrendRange 的默认值不是 20"
    echo "     （加「范围切换」不该顺带换掉默认看到的东西；改默认值 = 静默换掉所有人的视图）"
    FAILED+=("winrate_trend")
elif ! grep -qE 'public static let weeklyThreshold = 120' "$WT_CORE"; then
    echo "❌ winrate_trend  WinrateTrend.weeklyThreshold 不是 120（与界面上的聚合说明脱节）"
    FAILED+=("winrate_trend")
else
    wt_code=$(grep -vE '^[[:space:]]*//' "$WT_VIEW")
    if ! printf '%s\n' "$wt_code" | grep -c 'WinrateTrend\.weeklyThreshold' >/dev/null; then
        echo "❌ winrate_trend  ReviewView 没消费 WinrateTrend.weeklyThreshold（又写死了一个阈值？）"
        FAILED+=("winrate_trend")
    elif ! printf '%s\n' "$wt_code" | grep -c '按自然周聚合' >/dev/null; then
        echo "❌ winrate_trend  ReviewView 副标题没写明「按自然周聚合」（周线会被读成日线）"
        FAILED+=("winrate_trend")
    else
        echo "✅ winrate_trend  默认 20 / 阈值 120 / 副标题写明按周聚合（口径写在界面上）"
    fi
fi

# 静态护栏：自选行「添加持仓」文案三处必须一致（行右键菜单项 / 行内按钮悬浮提示 / 持仓区空态提示）。
#   改一处忘改另一处 ⇒ 提示里点名的菜单项在菜单里不存在，用户按提示去找找不到。
#   纯文案、没有任何自动化能验（要看真实菜单），只能靠护栏。
# 判据：① 空转检测被扫文件存在；② 三处各自的具体形状都含「添加持仓」；
#   ③ 反向：全仓不许再出现旧词「标记持仓」（防"改了一半"）。
HW_VIEW="$SRC_VIEWS/WatchlistView.swift"
HW_GROUPS="$SRC_VIEWS/WatchlistView+Groups.swift"
HW_HOLD="$SRC_VIEWS/WatchlistHoldingSection.swift"
if [ ! -f "$HW_VIEW" ] || [ ! -f "$HW_GROUPS" ] || [ ! -f "$HW_HOLD" ]; then
    echo "❌ holding_wording  被扫文件不存在（路径漂了 → 护栏会静默失效）"
    FAILED+=("holding_wording")
elif ! grep -q 'Button("添加持仓' "$HW_GROUPS"; then
    echo "❌ holding_wording  行右键菜单项不是「添加持仓…」（改名漏了这一处？）"
    FAILED+=("holding_wording")
elif ! grep -q '点击添加持仓' "$HW_VIEW"; then
    echo "❌ holding_wording  行内持仓按钮的悬浮提示没跟着改成「添加持仓」"
    FAILED+=("holding_wording")
elif ! grep -q '右键「添加持仓」' "$HW_HOLD"; then
    echo "❌ holding_wording  持仓区空态提示没跟着改（用户按它去找菜单项会找不到）"
    FAILED+=("holding_wording")
elif grep -rq '标记持仓' "$SRC_APP"; then
    echo "❌ holding_wording  还残留旧词「标记持仓」（改了一半）："
    grep -rn '标记持仓' "$SRC_APP" | head -3
    FAILED+=("holding_wording")
else
    echo "✅ holding_wording  「添加持仓」三处一致（菜单项 / 悬浮提示 / 空态提示），无旧词残留"
fi

# 静态护栏：表格**不许回潮斑马纹**（老板 2026-10-23 看完判「很丑」，方案表里选了"只删交替纹"）。
#   行的分界只由 `TableRule` 那条 1px hairline 给；`SharedDataTable` 连 zebra 开关都拆了 ——
#   留着开关 = 下一个人顺手就打开。判据扫的是**实现**，注释里讨论斑马纹不算。
if [ ! -d "$SRC_VIEWS" ]; then
    echo "❌ no_zebra 找不到 ${SRC_VIEWS}（路径漂了 → 护栏会静默失效）"
    FAILED+=("no_zebra")
elif grep -rqE 'isMultiple\(of: 2\)|var zebra|zebra: Bool|\.zebra\b' "$SRC_VIEWS"; then
    echo "❌ no_zebra 斑马纹回潮（隔行上色或 zebra 开关又出现了）："
    grep -rnE 'isMultiple\(of: 2\)|var zebra|zebra: Bool|\.zebra\b' "$SRC_VIEWS" | head -5 | sed 's/^/     /'
    FAILED+=("no_zebra")
else
    echo "✅ no_zebra        视图层没有隔行底色也没有 zebra 开关（行分隔只有 hairline）"
fi

# 静态护栏：表格几何只能有**一份定义**（2026-10-26 老板报"行高不对、还是没统一"，
#   根因就是各页各写一份：板块矩阵自己 `rowHeight = 24`、指标筛选自己 `height: 24` + `Divider().opacity(0.35)`，
#   同一个 App 里三种行高两种分隔线 —— 注释里写"请用同一套"没有任何约束力）。
#   表头 28/11pt、行 30/12pt、1px hairline 唯一活在 `Views/Components+DataTable.swift`；
#   别的文件不许再定义同名几何常量，也不许把原生 `Table` + `.tableStyle`/`alternatesRowBackgrounds`
#   换回来（那两个自带斑马纹与列竖线，`no_zebra` 的 zebra 关键字抓不到它）。
# ⚠ 正向断言：在册的表格页必须**真的引用** `TableMetrics` / `SharedDataTable` ——
#   只有定义、没人引用 = 这套 token 已经名存实亡，护栏自己也空转。加表格页就往外加名字（只准变长）。
_DT="$SRC_VIEWS/Components+DataTable.swift"
_TABLE_PAGES="ResultsView ReviewView TunePanelView CompareView BoardView IndicatorScreenerView"
if [ ! -f "$_DT" ]; then
    echo "❌ table_geometry  找不到 ${_DT}（路径漂了 → 护栏会静默失效）"
    FAILED+=("table_geometry")
else
    _TG_DUP=$(grep -rnE 'static (let|var) (rowHeight|headerHeight|headerFont|rowFont|rowNumericFont)\b' \
              "$SRC_VIEWS" | grep -v 'Components+DataTable\.swift' | strip_comments || true)
    _TG_NATIVE=$(grep -rnE '\.tableStyle\(|alternatesRowBackgrounds' "$SRC_VIEWS" | strip_comments || true)
    # 列宽**分配算法**也只能有一份（2026-10-27 B1）：原先选股结果按内容实测、
    #   SharedDataTable 按弹性列拿 2 倍权重、指标筛选"名称拿 62% + 各带上限"，
    #   同一个 App 里三种列宽行为。唯一实现 = `ColumnLayout`（本文件），
    #   判据：系数 1.35 与 `func distribute(`/`func baseWidth(` 只许出现在定义处。
    _TG_ALGO=$(grep -rnE '1\.35|func (distribute|baseWidth)\(' "$SRC_VIEWS" \
               | grep -vE 'Components\+DataTable\.swift' | strip_comments || true)
    _TG_ORPHAN=""
    for _pg in $_TABLE_PAGES; do
        _pf="$SRC_VIEWS/${_pg}.swift"
        if [ ! -f "$_pf" ]; then
            _TG_ORPHAN="${_TG_ORPHAN}${_pg}.swift 文件不存在（改名要同步登记）"$'\n'
        elif ! grep -qE 'TableMetrics\.|SharedDataTable' "$_pf"; then
            _TG_ORPHAN="${_TG_ORPHAN}${_pg}.swift 不再引用 TableMetrics / SharedDataTable"$'\n'
        fi
    done
    # 正向断言：三处消费方必须真的走 ColumnLayout（只留定义没人调 = 收口又散回去）
    for _cl in "ResultsView" "IndicatorScreenerView"; do
        grep -q 'ColumnLayout\.' "$SRC_VIEWS/${_cl}.swift" \
            || _TG_ORPHAN="${_TG_ORPHAN}${_cl}.swift 不再引用 ColumnLayout（列宽算法又自己写了一份？）"$'\n'
    done
    if [ -n "$_TG_DUP" ]; then
        echo "❌ table_geometry  表格几何被抄了第二份（各页各写行高 → 永远统一不了）："
        printf '%s\n' "$_TG_DUP" | head -5 | sed 's/^/     /'
        FAILED+=("table_geometry")
    elif [ -n "$_TG_NATIVE" ]; then
        echo "❌ table_geometry  原生 Table 的样式回来了（自带斑马纹与列竖线，静态表一律走 SharedDataTable）："
        printf '%s\n' "$_TG_NATIVE" | head -5 | sed 's/^/     /'
        FAILED+=("table_geometry")
    elif [ -n "$_TG_ALGO" ]; then
        echo "❌ table_geometry  列宽分配算法又抄了一份（唯一实现是 Components+DataTable.swift 的 ColumnLayout）："
        printf '%s\n' "$_TG_ALGO" | head -5 | sed 's/^/     /'
        FAILED+=("table_geometry")
    elif [ -n "$_TG_ORPHAN" ]; then
        echo "❌ table_geometry  有表格页脱离了共享几何（定义了没人用 = 这套 token 名存实亡）："
        printf '%s' "$_TG_ORPHAN" | sed 's/^/     /'
        FAILED+=("table_geometry")
    else
        echo "✅ table_geometry  表头 28 / 行 30 / hairline 只有一份定义，且在册表格页都在消费"
    fi
fi

# 静态护栏：可点击行必须有**指针反馈**（2026-10-27 UI/UX 审查 A3）。
#   淡底只回答"鼠标在哪"，手型光标才回答"这一行能不能点"；改造前全仓 `pointerStyle` /
#   `NSCursor` **0 处命中** —— 自绘行（`contentShape` + `onTapGesture`）拿不到按钮那层
#   系统光标语义，用户只能靠"试"。
#   出口唯一：`Views/Components.swift` 的 `clickableRow()`（内部走 macOS 26
#   `.pointerStyle(.link)`；**不许**换成 `NSCursor.pointingHand.push()/pop()` —— 本 App 的
#   行会在悬停中被销毁（列表刷新 / 切页），pop 不掉 ⇒ 光标长时间卡在手型）。
#   判据：挂了 `onTapGesture` 的视图文件必须同时挂 `.clickableRow()`
#   （模式**不带前导点** —— `FocusDismiss.swift` 是 `onTapGesture {` 的无点写法，
#    带点就扫不到，那条豁免会变成空转的死条目）。
#   ⚠ 豁免清单只准变短：`FocusDismiss.swift` 的 tap 是"点空白处撤焦点"，不是可点行。
#   2026-10-28 追加两格（吸收 bencho.dev 的 Press 类微交互）：按下态必须由
#   `clickableRow()` 里的 `RowPressFeedback` + `MousePressCenter`（本地事件监视器，只观察不吞事件）提供，
#   且**不许**用 `onLongPressGesture(minimumDuration: 0)` / `DragGesture(minimumDistance: 0)`
#   去取按下态 —— 那是往行的 `onTapGesture` 旁边再塞一个识别器抢同一次点击，只能真机验。
RC_DEF="$SRC_VIEWS/Components.swift"
RC_EXEMPT="FocusDismiss.swift"
if [ ! -f "$RC_DEF" ]; then
    echo "❌ row_cursor      找不到 ${RC_DEF}（路径漂了 → 护栏会静默失效）"
    FAILED+=("row_cursor")
elif ! grep -q "func clickableRow(" "$RC_DEF"; then
    echo "❌ row_cursor      clickableRow() 出口不在了（改法已失效，护栏空转）"
    FAILED+=("row_cursor")
else
    rc_tap_files=$(grep -rnE "[^a-zA-Z]onTapGesture" "$SRC_VIEWS" --include=*.swift \
                   | strip_comments | cut -d: -f1 | sort -u)
    rc_bad=""
    rc_scanned=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$(basename "$f")" in
            $RC_EXEMPT) continue ;;
        esac
        rc_scanned=$((rc_scanned + 1))
        grep -q "\.clickableRow()" "$f" || rc_bad="${rc_bad}$(basename "$f")"$'\n'
    done <<< "$rc_tap_files"
    rc_used=$(grep -rn "\.clickableRow()" "$SRC_VIEWS" --include=*.swift \
              | grep -v "Views/Components\.swift" | strip_comments | wc -l | tr -d ' ')
    # ② 按下态出口必须真的挂在 clickableRow() 里（删掉不会让任何测试变红，只是全 App
    #    静默失去"我点到了"的反馈）；监视器必须把事件原样返回 —— 返回 nil = 把左键吃掉
    #    = 全站点不动，而那行代码看着人畜无害。
    rc_press=""
    grep -q 'modifier(RowPressFeedback())' "$RC_DEF" || rc_press="clickableRow() 不再挂 RowPressFeedback"
    grep -q 'final class MousePressCenter' "$RC_DEF" || rc_press="${rc_press:+$rc_press / }MousePressCenter 不在了"
    grep -q 'return event' "$RC_DEF" || rc_press="${rc_press:+$rc_press / }监视器丢了 return event"
    # ③ 取按下态**不许**改用会抢点击的识别器：往行的 onTapGesture 旁边再塞一个识别器，
    #    抢不抢得赢只能真机点才知道（离屏 NSHostingView 连"什么都不加"的正对照都 0 次触发，
    #    见 Components.swift 的 MousePressCenter 注释）。这条拦的是"想当然的改法"。
    rc_steal=$(grep -rnE 'onLongPressGesture\(minimumDuration:[[:space:]]*0|DragGesture\(minimumDistance:[[:space:]]*0' \
               "$SRC_VIEWS" --include=*.swift | strip_comments || true)
    if [ -n "$rc_bad" ]; then
        echo "❌ row_cursor      有可点击行没挂指针反馈（应加 .clickableRow()）："
        printf '%s' "$rc_bad" | sed 's/^/     /'
        FAILED+=("row_cursor")
    elif [ -n "$rc_steal" ]; then
        echo "❌ row_cursor      用识别器取按下态 = 往行的 onTapGesture 旁边再塞一个识别器抢同一次点击"
        printf '%s\n' "$rc_steal" | grep -v '^$' | head -3 | sed 's/^/     /'
        FAILED+=("row_cursor")
    elif [ -n "$rc_press" ]; then
        echo "❌ row_cursor      ${rc_press}"
        printf '%s' "$rc_bad" | sed 's/^/     /'
        FAILED+=("row_cursor")
    elif [ "$rc_scanned" = "0" ]; then
        echo "❌ row_cursor      一条 onTapGesture 都没扫到（路径或正则漂了 → 护栏空转）"
        FAILED+=("row_cursor")
    elif [ "$rc_used" -lt 6 ]; then
        echo "❌ row_cursor      clickableRow() 调用点只剩 ${rc_used} 处（下限 6 = 改造时实挂数，掉了说明被绕开）"
        FAILED+=("row_cursor")
    else
        echo "✅ row_cursor      可点击行统一挂 clickableRow()（扫过 ${rc_scanned} 个文件，调用点 ${rc_used} 处）+ 按下态出口在位且不吞事件"
    fi
fi

# 静态护栏：主窗口/设置窗口的分栏壳必须是**固定两列骨架**（2026-10-15 老板拍板重构，钉住骨架态）。
#   原生 NavigationSplitView 的分隔条光标/拖拽/收起整族问题三轮 AppKit 补丁全失败
#   （removeTrackingArea no-op / 换 delegate 卡死主线程 / 塞挡板子视图打乱分栏管理→侧栏被收起），
#   ⇒ 结构性拆除：`FixedTwoColumnShell`（HStack + NSVisualEffectView 材质），NSSplitView 不存在，
#   分隔条/光标/拖拽/收起路径一起消失。宽度锁/可见性绑定/硬切三件套、光标探针死代码不得回潮。
#   详见 docs/specs/README.md「主窗口侧栏开关删除」。
_SB_APP="$SRC_APP/SelectedApp.swift"
_SB_SET="$SRC_APP/Views/SettingsView.swift"
_SB_COMP="$SRC_APP/Views/Components.swift"
_SB_PAGE="$SRC_APP/Views/Components+PageControls.swift"
if [ ! -f "$_SB_APP" ]; then
    echo "❌ sidebar_notoggle 找不到 ${_SB_APP}（路径漂了 → 护栏会静默失效）"
    FAILED+=("sidebar_notoggle")
elif grep -q 'NavigationSplitView {' "$_SB_APP" || grep -q 'NavigationSplitView {' "$_SB_SET"; then
    echo "❌ sidebar_notoggle NavigationSplitView 被换回来了 —— 分隔条光标/拖拽/收起整族问题会一起回来（三轮补丁全失败才重构的）"
    FAILED+=("sidebar_notoggle")
elif ! grep -q 'FixedTwoColumnShell(sidebarWidth: 144)' "$_SB_APP"; then
    echo "❌ sidebar_notoggle 主窗口没挂固定两列骨架（或侧栏宽度漂了 144）"
    FAILED+=("sidebar_notoggle")
elif ! grep -q 'FixedTwoColumnShell(sidebarWidth: 144)' "$_SB_SET"; then
    echo "❌ sidebar_notoggle 设置窗口没挂固定两列骨架（或侧栏宽度漂了 144）"
    FAILED+=("sidebar_notoggle")
elif ! grep -q '\.background(WindowGlass' "$_SB_COMP"; then
    echo "❌ sidebar_notoggle 整窗玻璃被摘或改成与两列平级的兄弟层 —— 兄弟层那版实测把系统选中胶囊画成纯黑块"
    FAILED+=("sidebar_notoggle")
elif grep -qE 'Tok\.windowBase|PanelMetrics' "$_SB_PAGE"; then
    echo "❌ sidebar_notoggle 内容层的面板底回潮（windowBase 实底/描边/阴影/内缩）—— 老板实机否掉：内容直接坐在玻璃上"
    FAILED+=("sidebar_notoggle")
elif grep -q 'SidebarDividerCursorKiller\|DividerCursorBlocker\|sidebarDividerCursorFix' "$_SB_APP" "$_SB_SET"; then
    echo "❌ sidebar_notoggle 光标探针死代码回潮（骨架下没有 NSSplitView，探针无处可施且挡板会打乱分栏）"
    FAILED+=("sidebar_notoggle")
elif ! grep -q 'CommandGroup(replacing: \.sidebar)' "$_SB_APP"; then
    echo "❌ sidebar_notoggle 「显示/隐藏侧边栏」菜单命令保险被摘（系统若再注入就是收起路径）"
    FAILED+=("sidebar_notoggle")
elif grep -qE 'final class SidebarWidthLock|columnVisibility|navigationSplitViewColumnWidth|^[[:space:]]*\.transaction \{ \$0\.animation = nil \}' "$_SB_APP"; then
    echo "❌ sidebar_notoggle 宽度锁/可见性绑定/列宽钉/硬切有回潮（骨架下这些全是死器官）"
    FAILED+=("sidebar_notoggle")
else
    echo "✅ sidebar_notoggle  两扇窗口都是固定两列骨架（玻璃单层且只当背景 · 内容层无面板底 · 探针死代码/三件套无回潮）"
fi

# 静态护栏：「三轮对比」变成结果页时间线第四格的接线（2026-10-29 老板两步拍板）。
#   M1「拆开没必要」⇒ 并入选股结果页；M2「三轮入口调整到这，不要平铺在最下面 ——
#   他们正好是一个时间线：第一轮、第二轮、第三轮、三轮对比」⇒ 它是段选器的**第四格**，
#   切到那一格 = 整页换成对比内容。同一批还把页内那条「链路状态条」整行下掉（三处调用）。
#   拆回去不会让任何测试变红，而四种失效都长得像正常：
#   ① 侧栏悄悄多回一行（十页）；② 对比成了没人渲染的孤儿（界面上整个功能消失、不报错）；
#   ③ 点通知只把 App 带到前台、停在某一轮那格（正文说的是对比结论）；
#   ④ 链路状态条回潮 —— 老板 2026-10-29 明确判"这一行去掉"，页内进度另有出口（按钮转圈 +
#      LoadingView），全局状态在侧栏底部圆点条，这一行是第三份重复。
#   另外「声明顺序 = 侧栏顺序 = ⌘1…⌘9」这条纪律原先只有注释在维持（`SelectedApp.swift` 自己写的），
#   加页/删页漏一处就是某页键盘进不去、或分派落不到视图 —— 这里把三处计数钉成必须相等。
_PM_APP="$SRC_APP/SelectedApp.swift"
_PM_RV="$SRC_VIEWS/ResultsView.swift"
_PM_CS="$SRC_VIEWS/CompareView.swift"
_PM_NT="$SRC_APP/Notifier.swift"
_PM_SC="$SRC_APP/Scheduler+Finish.swift"
_PM_ST="$SRC_APP/Store.swift"
_pm_missing=""
for _f in "$_PM_APP" "$_PM_RV" "$_PM_CS" "$_PM_NT" "$_PM_SC" "$_PM_ST"; do
    [ -f "$_f" ] || _pm_missing="${_pm_missing}${_f}"$'\n'
done
# 三个计数：枚举 case 数 / ⌘ 菜单按钮数 / 详情分派 case 数
_pm_cases=$(sed -n '/^enum Page: /,/^    var id: String/p' "$_PM_APP" \
            | grep -E '^    case ' | sed 's/^    case //' | tr ',' '\n' \
            | sed 's/^ *//;s/ *$//' | grep -c .)
_pm_short=$(grep -cE 'Button\(Page\.[a-z]+\.title\) \{ Page\.select' "$_PM_APP")
_pm_disp=$(grep -cE '^[[:space:]]*case \.[a-z]+: [A-Z][A-Za-z]*View\(\)$' "$_PM_APP")
_pm_case_list=$(sed -n '/^enum Page: /,/^    var id: String/p' "$_PM_APP" \
                | grep -E '^    case ' | sed 's/^    case //' | tr ',' '\n' | sed 's/^ *//;s/ *$//')
_pm_orphan=""
grep -qE 'struct CompareSection: View' "$_PM_CS" \
    || _pm_orphan="${_pm_orphan}CompareView.swift 里已经没有 struct CompareSection（那一格的本体改名/搬走，登记要跟上）"$'\n'
# 第四格必须在段选器上真的存在（只写 enum case 而没进 Picker = 时间线少一格）
grep -qE 'tag\(Leg\.compare\)' "$_PM_RV" \
    || _pm_orphan="${_pm_orphan}段选器里没有「三轮对比」那一格（tag(Leg.compare) 不见了）"$'\n'
if [ -n "$_pm_missing" ]; then
    echo "❌ page_merge      找不到这些文件（路径漂了 → 本护栏会静默失效）："
    printf '%s\n' "${_pm_missing%$'\n'}" | sed 's/^/     /'
    FAILED+=("page_merge")
elif [ "$_pm_cases" -eq 0 ]; then
    echo "❌ page_merge      取不到 Page 枚举的 case 清单（声明写法变了 → 计数断言全是空转）"
    FAILED+=("page_merge")
elif printf '%s\n' $_pm_case_list | grep -qx compare; then
    echo "❌ page_merge      Page 枚举里又出现 compare —— 侧栏回到十页，M1 的合并被推翻（要改就连带删掉深链那一整条链）"
    FAILED+=("page_merge")
elif [ "$_pm_short" -ne "$_pm_cases" ] || [ "$_pm_disp" -ne "$_pm_cases" ]; then
    echo "❌ page_merge      三处页面清单数不齐：枚举 ${_pm_cases} / ⌘ 菜单 ${_pm_short} / 详情分派 ${_pm_disp}"
    echo "     ⇒ 少一个 ⌘ 那条页键盘进不去；少一个分派 case 那页是空白。改页要三处一起数。"
    FAILED+=("page_merge")
elif ! grep -qE 'CompareSection\(\)' "$_PM_RV"; then
    echo "❌ page_merge      结果页不再渲染 CompareSection —— 对比成了孤儿（侧栏已无该页，等于整个功能从界面上消失且无报错）"
    FAILED+=("page_merge")
elif grep -rn 'PipelineStatusBar' "$SRC_APP" "$SRC_CORE" | strip_comments | grep -q .; then
    echo "❌ page_merge      链路状态条回潮（老板 2026-10-29 判「这一行去掉」；页内进度看按钮转圈，全局看侧栏圆点条）："
    grep -rn 'PipelineStatusBar' "$SRC_APP" "$SRC_CORE" | strip_comments | head -3 | sed 's/^/     /'
    FAILED+=("page_merge")
elif ! grep -qE 'return \(\.results, \.compare[,)]' "$_PM_SC"; then
    echo "❌ page_merge      Scheduler 的 compare 落点不再是（结果页 + 第四格）—— 点通知会停在某一轮那格或错页"
    FAILED+=("page_merge")
elif ! grep -qE '\["section"\] *= *section' "$_PM_NT" || ! grep -qE 'userInfo\["section"\]' "$_PM_NT"; then
    echo "❌ page_merge      通知不再携带 / 读取 section —— 那一格的标记在 userInfo 边界上断了"
    FAILED+=("page_merge")
elif ! grep -qE 'requestCompareLeg\(\)' "$_PM_NT" || ! grep -qE 'func requestCompareLeg' "$_PM_ST"; then
    echo "❌ page_merge      didReceive → Store 的切格请求这一环断了（点通知只剩「把 App 叫到前台」）"
    FAILED+=("page_merge")
elif ! grep -qE 'leg = \.compare' "$_PM_RV" || ! grep -qE 'consumeCompareLeg\(\)' "$_PM_RV"; then
    echo "❌ page_merge      结果页没把请求兑现成切格（或不作废）—— 深链到不了第四格，或下次进页又自己跳过去"
    FAILED+=("page_merge")
elif [ -n "$_pm_orphan" ]; then
    echo "❌ page_merge      那一格的本体 / 入口不在位："
    printf '%s\n' "${_pm_orphan%$'\n'}" | sed 's/^/     /'
    FAILED+=("page_merge")
else
    echo "✅ page_merge      ${_pm_cases} 页三处数齐 · 对比在时间线第四格且深链可切 · 链路状态条已下线"
fi

# 静态护栏：窗口 chrome 的两条**非显然**约束（删掉不会让任何测试变红，2026-10-19 老板两连问逼出来的）。
#   ① 红绿灯 (18,18)：空工具栏带**只能**把按钮摆到 左 12 / 上 13.5（截图像素实测），
#      18 是 `pinTrafficLights` 手摆 `standardWindowButton` frame 摆出来的；而 AppKit 的
#      `NSTitlebarView.layout()` 每次重排都会把按钮摆回 12/13.5 ⇒ 必须挂
#      `didUpdate`/`didResize` 自愈观察器。删任一处 → 红绿灯静默回到 12/13.5
#      （老板原话：「你确认上、左是 18pt 的距离吗，我观感上并不是」）。
#   ② 内容栏上边可拖窗口：靠 `PageActionBar` 背景里的 `WindowDragStrip`。它是**手写**
#      mouseDown/mouseDragged 的 NSView —— `mouseDownCanMoveWindow = true`、
#      `NSVisualEffectView`、`window.performDrag(with:)` 三条路在 `NSHostingView` 里**都不生效**
#      （命中链探针实测：mouseDown 被调用、属性为 true，窗口就是不动）。删掉 = 带区右半边变死区。
#   ⚠ 两条反向断言：拖动区**不许**改挂 `.overlay`（会吃掉页栏按钮的点击）；
#     `mouseDownCanMoveWindow` **不许**改回 `true`（那条 AppKit 路径在这里不生效）。
#   ⚠ 空转检测：三个被扫文件必须存在（路径漂了 → grep 无输出 → 静默通过）。
_WC_APP="$SRC_APP/MainWindowChrome.swift"
_WC_COMP="$SRC_APP/Views/Components.swift"
_WC_PAGE="$SRC_VIEWS/Components+PageControls.swift"
if [ ! -f "$_WC_APP" ] || [ ! -f "$_WC_COMP" ] || [ ! -f "$_WC_PAGE" ]; then
    echo "❌ window_chrome  被扫文件不存在（${_WC_APP} / ${_WC_COMP} / ${_WC_PAGE}）→ 护栏会静默失效"
    FAILED+=("window_chrome")
elif ! grep -q 'trafficLightInset: CGFloat = 18' "$_WC_APP"; then
    echo "❌ window_chrome 红绿灯目标边距被改（或改名）—— 应恒为 18，与侧栏/页栏 18pt 同一套"
    FAILED+=("window_chrome")
elif ! grep -q 'pinTrafficLights(window)' "$_WC_APP"; then
    echo "❌ window_chrome 装完工具栏带没调 pinTrafficLights —— 空带只能到 12/13.5，18 摆不出来"
    FAILED+=("window_chrome")
elif ! grep -q 'installTrafficLightPinning(window)' "$_WC_APP"; then
    echo "❌ window_chrome 红绿灯自愈观察器没挂 —— AppKit 每次标题栏重排都会把按钮摆回 12/13.5"
    FAILED+=("window_chrome")
elif ! grep -q 'background(WindowDragStrip())' "$_WC_PAGE"; then
    echo "❌ window_chrome 页栏没挂拖动区 —— 内容栏上边会重新变成拖不动窗口的死区"
    FAILED+=("window_chrome")
elif grep -qE 'overlay\([^)]*WindowDragStrip' "$_WC_PAGE"; then
    echo "❌ window_chrome 拖动区改挂到 .overlay 了 —— 它会盖住按钮，页栏整排点击失灵"
    FAILED+=("window_chrome")
elif ! grep -q 'mouseDownCanMoveWindow: Bool { false }' "$_WC_COMP"; then
    echo "❌ window_chrome 拖动区的 mouseDownCanMoveWindow 被改回 true —— 那条 AppKit 路径在 NSHostingView 里不生效（试过，窗口不动）"
    FAILED+=("window_chrome")
elif ! grep -q 'func mouseDragged' "$_WC_COMP"; then
    echo "❌ window_chrome 拖动区的手写 mouseDragged 被删 —— 窗口拖动只剩没人接管的空壳"
    FAILED+=("window_chrome")
else
    echo "✅ window_chrome   红绿灯 18/18（手摆 + 自愈）与内容栏顶部拖动区都在位（含两条反向断言）"
fi

# 静态护栏：主窗口「关闭 = 最小化」必须真的接线（老板拍板；删掉不会让任何测试变红）。
#   行为只由一段非显然机制兑现：包一层主窗口 delegate（红叉与 Cmd+W 只有 windowShouldClose
#   一个共同入口）+ 守卫挂到主窗口 + Dock 重开路径 deminiaturize；任何一步被"顺手简化"都静默失效。
# 判据（三条，缺一不可；①②必须取函数体再匹配）：
#   ① windowShouldClose 里要 miniaturize 且 return false（红叉 + Cmd+W 都拦下）；
#   ② revealWindow 里要 deminiaturize（最小化窗口 makeKeyAndOrderFront 放不出来）；
#   ③ AppShellView 必须真的挂 .mainWindowCloseGuard()（写了守卫不挂 = 没有）。
# ⚠ ①② 不能全文 grep：注释里也写着这些词，全文匹配会让"删掉真实现"照样判绿。
_CW_APP="$SRC_APP/SelectedApp.swift"
_CW_CHROME="$SRC_APP/MainWindowChrome.swift"
if [ ! -f "$_CW_APP" ] || [ ! -f "$_CW_CHROME" ]; then
    echo "❌ close_minimize  找不到 ${_CW_APP} / ${_CW_CHROME}（路径漂了 → 护栏会静默失效）"
    FAILED+=("close_minimize")
else
    _CW_BAD=""
    _CW_SHOULD=$(awk '/func windowShouldClose\(_ sender: NSWindow\) -> Bool \{/,/^    \}/' "$_CW_CHROME")
    printf '%s' "$_CW_SHOULD" | grep -cE '\bminiaturize\(' >/dev/null || _CW_BAD="$_CW_BAD windowShouldClose没接miniaturize"
    printf '%s' "$_CW_SHOULD" | grep -cE 'return false' >/dev/null      || _CW_BAD="$_CW_BAD windowShouldClose没拒绝关闭"
    _CW_REVEAL=$(awk '/^private func revealWindow\(_ window: NSWindow\) \{/,/^\}/' "$_CW_CHROME")
    printf '%s' "$_CW_REVEAL" | grep -cE '\bdeminiaturize\(' >/dev/null || _CW_BAD="$_CW_BAD revealWindow没deminiaturize"
    # 空转检测：挂载点必须是一条真代码行（`strip_comments` 会把注释行滤掉）
    grep -nE '^[[:space:]]*\.mainWindowCloseGuard\(\)' "$_CW_APP" | strip_comments | grep -c . >/dev/null \
        || _CW_BAD="$_CW_BAD AppShellView没挂.mainWindowCloseGuard()"
    if [ -n "$_CW_BAD" ]; then
        echo "❌ close_minimize  主窗口「关闭=最小化」接线被拆了：${_CW_BAD}"
        echo "     ⇒ 现象：红叉/Cmd+W 又变成真关窗口（或点 Dock 图标没反应）。"
        echo "     ⇒ 见 MainWindowChrome.swift 的 MainWindowCloseGuard 注释（三条机制缺一不可）。"
        FAILED+=("close_minimize")
    else
        echo "✅ close_minimize  主窗口关闭=最小化接线完整（红叉+Cmd+W 拦下 · Dock 重开会 deminiaturize）"
    fi
fi

# 静态护栏：语义色的 WCAG 对比度达标。
#   红绿是本 app 唯一的信息通道（色弱用户靠它区分涨跌），「提高对比度」开启时
#   涨跌/警示/信号全都不增强 = 最需要时失效；HC 变体自己不达标就是"加了等于没加"。
# 判据：用 WCAG 相对亮度公式实算，目标 4.5:1（这些色显示文字，不能用 3.0 大字档）；
#   背景基准 Tok.row（实读 Tokens.swift 的四个 α 再合成），四档（浅/深 × 基础/HC）全部 ≥ 4.5。
# ⚠ 实现在 Tools/sem_contrast_check.sh。这里故意不套 command -v swiftc 守卫（否则守卫行数
#   +1，suite_ran 期望值要跟着改）：缺工具链时由 .sh 自己 exit 2 报红 ——
#   "缺依赖"永远不会变成静默跳过。
_SC_SEM=$(bash "$ROOT/SelectedApp/Tools/sem_contrast_check.sh" 2>&1)
_SC_RC=$?
if [ $_SC_RC -eq 0 ]; then
    echo "✅ sem_contrast     $_SC_SEM"
elif [ $_SC_RC -eq 2 ]; then
    # 2 = 抽取失败 / 缺工具链 ⇒ 护栏空转，必须报红（不是"通过"，是"没跑"）
    echo "❌ sem_contrast     $_SC_SEM"
    FAILED+=("sem_contrast")
else
    echo "❌ sem_contrast     语义色对比度不达标（目标 4.5:1，四档全要过）："
    printf '%s\n' "$_SC_SEM" | sed 's/^/     · /'
    echo "     ⇒ 背景基准：Tok.row —— **实读 Tokens.swift 的四个 α 再合成**（不再写死常量）。"
    echo "     ⇒ 改法：保持**色相**不变、再拉开一档明度（浅更深、深更亮）"
    echo "       —— 改色相会把一种语义变成另一种（例如警示橙偏红就成了「危险」）。"
    FAILED+=("sem_contrast")
fi

# 静态护栏：**图形档**（比例条 + 图表系列）的分离度（实现在 Tools/bar_separation_check.sh，读真类型实算）。
# 防的是"顺手把色值统一回去"：涨/跌的 text 档明度**刻意齐平**（数字列不因颜色跳行），
# 而图形档是在同色相同彩度下把明度拉开一档，让二色觉下仍分得开（deutan ΔE ≥0.115）。
# 这种"看起来更整齐"的改动不会让任何其它测试变红 —— 对比度更高、主题自检更过、像素基线照抄。
_SC_BAR=$(bash "$ROOT/SelectedApp/Tools/bar_separation_check.sh" 2>&1)
_SC_BAR_RC=$?
if [ $_SC_BAR_RC -eq 0 ]; then
    echo "✅ bar_separation   $_SC_BAR"
elif [ $_SC_BAR_RC -eq 2 ]; then
    echo "❌ bar_separation   $_SC_BAR"
    FAILED+=("bar_separation")
else
    echo "❌ bar_separation   图形档（比例条/图表系列）分离度不达标："
    printf '%s\n' "$_SC_BAR" | sed 's/^/     · /'
    echo "     ⇒ 改法：保持**色相与彩度**不变、只挪 OKLab L（涨压暗/跌提亮，深档反向）。"
    echo "       真解不出来（出色域）就登记进 BarSeparationCheck.swift 的 gamutExempt 并写清原因 ——"
    echo "       那张表是棘轮，只准变短。"
    FAILED+=("bar_separation")
fi

# 静态护栏：术语一致性 —— 同一概念不许两种中文叫法（术语唯一来源是 Views/Terms.swift，
#   与"颜色收进 Tok"是同一个病：散写必然漂移）。
# 判据：列出的禁用变体在 App 层里必须为 0。
# ⚠ 只列确定同义异名的；「胜率 vs 命中率」语义不同刻意不列 —— 强行统一会把两个指标混成一个。
_TC_BAD=""
# 「回最新」（缺"到"）：规范写法是 `Terms.backToLatest` = 「回到最新」
_tc_hits=$(grep -rn '回最新' "$SRC_APP" --include='*.swift' | strip_comments || true)
[ -n "$_tc_hits" ] && _TC_BAD="$_TC_BAD 回最新(应为「回到最新」)"
# 「上证」单独出现（规范是 `Terms.shangHaiIndex` = 「上证指数」）
# ⚠ 必须排除注释里的话（如 `DashboardView:49` 的「拉最新上证指数」）与
#   另一个指数名「上证50」—— 后者是**指数名**不是简称。
_tc_hits=$(grep -rnE '"上证"|「上证」' "$SRC_APP" --include='*.swift' | strip_comments || true)
[ -n "$_tc_hits" ] && _TC_BAD="$_TC_BAD 上证(应为「上证指数」)"
if [ -n "$_TC_BAD" ]; then
    echo "❌ term_consistency  术语不一致（同一概念两种叫法）："
    printf '%s\n' "$_TC_BAD" | sed 's/^/     · /'
    echo "     ⇒ 改走 Views/Terms.swift（术语唯一来源），别在 View 里直接写字面量。"
    FAILED+=("term_consistency")
else
    echo "✅ term_consistency  指数名与按钮文案的写法唯一（禁用变体 0 处）"
fi

