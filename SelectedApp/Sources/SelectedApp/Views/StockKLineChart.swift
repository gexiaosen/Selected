import SwiftUI
import SwiftTradingView
import SelectedCore

// MARK: - K 线图表（SwiftTradingView 封装，A股红涨绿跌）

struct StockKLineChart: View {
    let items: [KLineItem]
    let minute: [MinutePoint]
    let period: KLinePeriod
    /// 副图画成交量还是成交额（设置 › 显示 › 图表）。
    @AppStorage(ChartSubPlot.defaultsKey) private var subPlotRaw = ChartSubPlot.volume.rawValue
    /// 标的代码 —— **Y 轴刻度小数位**按它定档（场内基金 3 位，见 `StockFmt.priceDigits`）。
    /// 默认空 = 按股票档出数（只影响行情 Y 轴刻度，K 线本体不受影响）。
    var code: String = ""
    /// 昨收价（分时 Y 轴对称锚点；nil 则退化为数据 min/max）
    var previousClose: Double? = nil
    /// 左侧是否还有更早历史（K 线分页加载）
    var hasMoreEarlier: Bool = false
    /// 拖到最左边缘时回调（App 取更早一页并 prepend）
    var onLoadEarlier: (() -> Void)? = nil

    /// 首屏单根宽度覆盖（pt）；`nil` 时回落到写死的兜底值。
    ///
    /// ⚠ 调用方须先量宽度、用库自己的 `ChartZoomMath.fitCandleWidth` 算出正确初值传进来：
    ///   首帧 `viewportWidth` 是 0，库布局后才把初值钳到 `fitCandleWidth` ⇒
    ///   首帧是错的宽度、随即被改 → 视觉跳（"打开日K先出现一个图再跳成真实的"的成因）。
    ///   分时不走这个参数：它的槽宽由 `chartWidth`（调用方实测的图表宽）现算，
    ///   见 `minuteSlotWidth(chartWidth:)`。
    var initialCandleWidth: CGFloat? = nil

    /// 调用方实测到的**图表区宽度**（pt）。分时用它现算 240 槽的槽宽。
    /// 0 = 还没量到 ⇒ 回落到旧常量那一档（调用方本来就在 `chartWidth == 0` 时走骨架屏）。
    var chartWidth: CGFloat = 0

    init(items: [KLineItem], minute: [MinutePoint], period: KLinePeriod,
         code: String = "",
         previousClose: Double? = nil,
         hasMoreEarlier: Bool = false,
         initialCandleWidth: CGFloat? = nil,
         chartWidth: CGFloat = 0,
         onLoadEarlier: (() -> Void)? = nil) {
        self.items = items
        self.minute = minute
        self.period = period
        self.code = code
        self.previousClose = previousClose
        self.hasMoreEarlier = hasMoreEarlier
        self.initialCandleWidth = initialCandleWidth
        self.chartWidth = chartWidth
        self.onLoadEarlier = onLoadEarlier
    }

    // 时间格式化器统一走 ChinaTime.formatter（时区钉到 Asia/Shanghai、locale 同设）：
    // 裸建 DateFormatter 只设 timeZone 漏 locale，设备非中国时区时 X 轴标签整体偏一天、
    // 非公历日历会整体错年。ChinaTime 是项目"日期唯一出口"。
    private static let dayFmt = ChinaTime.formatter("MM-dd")
    /// 带年份的那一档：只在**跨年**或**本屏第一个**刻度上用（见下面 `labelFormatter` 的注释）
    private static let dayWithYearFmt = ChinaTime.formatter("yyyy-MM-dd")
    private static let monthFmt = ChinaTime.formatter("yy-MM")
    private static let timeFmt = ChinaTime.formatter("HH:mm")
    /// 解析 `yyyy-MM-dd` 走 `ChinaTime.parseDay`（同源，见上）
    private static func parseDay(_ s: String) -> Date? { ChinaTime.parseDay(s) }

    // MARK: 分时固定时间槽（时间→位置映射，与数据量无关）

    /// 全天固定 240 槽：上午 0~119（9:30-11:30）+ 下午 120~239（13:00-15:00）。
    /// 午休两段**紧邻**（不按真实时间留 90 分钟空白），交界处由图表库画竖虚线。
    private static let minuteSlots = 240

    /// "HH:mm" → 槽位（不在交易时段返回 nil）
    private static func minuteSlot(_ t: String) -> Int? {
        let parts = t.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        let mins = h * 60 + m
        if mins >= 570 && mins <= 690 { return mins - 570 }        // 9:30 ~ 11:30
        // 13:00 ~ 15:00；15:00 收盘归入最后一槽 239（有效槽位 0…239，同 minuteLabels）——
        //   返回 240 会让收盘那根 bar 落到绘图区外
        if mins >= 780 && mins <= 900 { return min(239, 120 + mins - 780) }
        return nil
    }

    /// 槽位时间戳（当日 9:30+i / 13:00+(i-120)，供 X 轴标签用）
    private static func slotTime(_ i: Int, calendar: Calendar, today: DateComponents) -> Double {
        var c = today
        let mins = i < 120 ? 570 + i : 780 + (i - 120)
        c.hour = mins / 60
        c.minute = mins % 60
        return calendar.date(from: c)?.timeIntervalSince1970 ?? 0
    }

    /// 分时图固定时间轴刻度（每半小时；午休交界合并标注）
    private static let minuteLabels: [(index: Int, text: String)] = [
        (0, "09:30"), (30, "10:00"), (60, "10:30"), (90, "11:00"),
        (120, "11:30/13:00"),
        (150, "13:30"), (180, "14:00"), (210, "14:30"), (239, "15:00"),
    ]

    /// 分时槽宽：**按实测绘图区宽度铺满**，不再写死。
    ///
    /// 原值是 `524/240 - 1`，而 524 是"弹窗 640 − ScrollView padding 28 − Card padding 32
    /// − Y 轴列 56"这一套布局下的解析解 —— 它把**窗口宽度当成了常量**。
    /// 详情页图表右侧加了盘口列之后可用宽度只剩 404，按 524 画会把下午那一段
    /// 推到绘图区外（分时又禁缩放，只能平移）⇒ 240 槽不再"严格铺满"。
    /// 现在按同一套几何现算：`viewport` = 调用方实测的图表宽 − Y 轴列，
    /// 与库内 `TradingView` 的视口算法一致（`geometry.size.width - yAxisColumnWidth`）。
    /// 640 宽、无右列时实测 580 ⇒ `(580-56)/240 - 1 = 1.1833`，**与旧常量逐位相同**（不是近似）。
    static func minuteSlotWidth(chartWidth: CGFloat) -> CGFloat {
        guard chartWidth > yAxisColumnWidth + 40 else { return legacyMinuteSlotWidth }
        return ChartZoomMath.fitCandleWidth(count: minuteSlots,
                                            viewportWidth: chartWidth - yAxisColumnWidth,
                                            configuredSpacing: 1, adaptive: false)
    }

    /// 库的 Y 轴列宽（`TradingView` 的 `yAxisColumnWidth` 默认值；本包未覆盖）
    static let yAxisColumnWidth: CGFloat = 56
    /// 没量到宽度时的兜底（= 640 详情窗、无右列那一档）
    private static let legacyMinuteSlotWidth: CGFloat = 524.0 / 240 - 1   // 减 spacing 1

    /// CandleData 转换：K 线直接映射；分时填入固定 240 槽（空槽占位，折线自动跳过）
    ///
    /// ⚠⚠ 分时的 `open` **不是开盘价**，而是"**本分钟的涨跌基准**"（上一分钟价；首根用昨收）：
    ///   库的成交量柱按 `open > close` 判跌（绿）、否则判涨（红），最新价胶囊按 `close >= open` 判色。
    ///   若把 `open` 也写成现价（原先如此），`open == close` 恒成立 ⇒ **成交量柱永远全红**、
    ///   下跌日的现价胶囊也是红的（与"红涨绿跌"直接冲突）。用基准价填 `open` 后，
    ///   两个消费方都自动得到正确方向，且**不必改库**。
    ///   ⚠ 折线读的是 `close`、Y 轴区间读 `high/low`，都不受影响（见 `MinuteLines`）。
    private var candles: [CandleData] {
        if period == .minute {
            let cal = ChinaTime.calendar
            let comps = cal.dateComponents([.year, .month, .day], from: Date())
            var slots = [CandleData?](repeating: nil, count: Self.minuteSlots)
            var cumAmount = 0.0, cumVol = 0.0, prevCum = 0.0
            /// 累计成交额（元）的上一分钟值 —— 与 volume 一样取差分
            var prevCumAmount = 0.0
            /// 上一分钟价（首根为昨收）—— 成交量的红绿基准
            var refPrice = previousClose
            for p in minute {
                guard let idx = Self.minuteSlot(p.time) else { continue }
                let vol = max(p.volume - prevCum, 0)   // 腾讯分时给的是累计量
                prevCum = p.volume
                let amt = max(p.amount - prevCumAmount, 0)
                prevCumAmount = p.amount
                cumVol += vol
                cumAmount += p.price * vol
                let avg = cumVol > 0 ? cumAmount / cumVol : nil   // VWAP 均价（黄线）
                slots[idx] = CandleData(
                    time: Self.slotTime(idx, calendar: cal, today: comps),
                    open: refPrice ?? p.price, close: p.price,
                    high: p.price, low: p.price,
                    volume: vol, amount: amt, avgPrice: avg
                )
                refPrice = p.price
            }
            return (0..<Self.minuteSlots).map { i in
                slots[i] ?? CandleData(
                    time: Self.slotTime(i, calendar: cal, today: comps),
                    open: 0, close: 0, high: 0, low: 0, volume: 0
                )
            }
        }
        return items.map {
            CandleData(
                time: Self.parseDay($0.date)?.timeIntervalSince1970 ?? 0,
                open: $0.open, close: $0.close, high: $0.high, low: $0.low,
                volume: $0.volume, amount: $0.amount
            )
        }
    }

    /// 分时最新有效价（末槽为 0 时回退最后一个非零点，与价格线着色的判据严格统一）
    private var latestMinutePrice: Double? {
        minute.last(where: { $0.price > 0 })?.price
    }

    /// 分时最新价相对**昨收**的涨跌（`nil` = 昨收未知 → 退回库默认判色）。
    ///
    /// ⚠ 不能靠 `close >= open`：分时的 `open` 是"上一分钟价"（见 `candles`），
    ///   那样胶囊会随最后一笔的涨跌变色，而 A 股惯例是按**当日涨跌**（相对昨收）着色。
    private var minuteLastPricePositive: Bool? {
        guard let pc = previousClose, pc > 0, let last = latestMinutePrice else { return nil }
        return last >= pc
    }

    /// 传给图表库的**允许缩放范围**（不是"当前宽度"）。库的语义：区间 = 缩放钳位边界，中点 = 初始宽度。
    /// K 线下限写 0.1（与 `ChartZoomMath` 最小宽度一致），库内部会与「铺满视口所需宽度」取大（`zoomLowerBound`），
    /// 即便加载 1500+ 根历史也能缩到恰好铺满视口，同时不会出现"内容比视口窄、右边半屏空白"。
    /// 分时禁缩放（isZoomable=false），range 仅作形式参数，实际宽度由 `minuteSlotWidth` 决定。
    private var candleWidthRange: ClosedRange<CGFloat> {
        period == .minute ? 0.3...2.7 : 0.1...20
    }

    /// K 线首屏单根宽度（pt）：与既有观感一致（约 50 根一屏），
    /// 不取区间中点是因为加载 500 根后中点会偏大、一屏根数变少。
    private static let kLineInitialCandleWidth: CGFloat = 8

    var body: some View {
        let data = candles
        // 数据源没有成交额（新浪兜底 / 部分市场）时不画空副图：回落到成交量，
        // 图例会显示「Vol:」而不是「额:」，含义仍然可辨。
        let useAmount = ChartSubPlot(rawValue: subPlotRaw) == .amount
            && data.contains { $0.amount > 0 }
        if data.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis.ascending")
                    .font(AppFont.glyph(28)).foregroundStyle(Tok.dim)
                Text("暂无数据").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                TradingView(
                    data: data,
                    candleWidth: candleWidthRange,
                    // ⚠ 分时：宽度由 240 个固定槽决定，但**槽宽按调用方实测的图表宽现算**
                    //   （详情窗加了盘口右列后可用宽度会变，写死会把下午裁出绘图区）；
                    //   非分时：用调用方按**实测宽度**算好的值，`nil` 才回落到写死的兜底
                    //   —— 见 `initialCandleWidth` 属性的说明（这是"打开时不跳"的关键）
                    initialCandleWidth: period == .minute
                        ? Self.minuteSlotWidth(chartWidth: chartWidth)
                        : (initialCandleWidth ?? Self.kLineInitialCandleWidth),
                    isZoomable: period != .minute,   // 分时禁缩放
                    candleSpacing: period == .minute ? 1 : 2,
                    // K 线启用自适应间距：缩小时间距同步压缩，「缩到最小 = 全部已加载历史正好铺满一屏」才能成立；
                    // 分时禁用（240 槽须严格铺满）。
                    adaptiveSpacing: period != .minute,
                    // 尾部留白 = 0：留"呼吸位"会在最新一根与 Y 轴列之间留出一条永远存在的空白。
                    // 不留白 = 最新一根贴右缘，任何缩放级别下内容都铺满绘图区。
                    scrollTrailingInset: 0,
                    // 底部留白 36：容纳 X 轴日期行，且与卡片下缘留出呼吸（留小了日期看起来像被压住）
                    contentPaddingBottom: 36,
                    xAxis: xAxis,
                    // 独立 Y 轴列（方案 B）：刻度贴图表右缘固定，不随缩放平移。
                    // 涨跌胶囊遵循 A股红涨绿跌：positive(涨)=红、negative(跌)=绿
                    yAxis: YAxis(
                        negativeCandleColor: Sem.down,
                        positiveCandleColor: Sem.up,
                        lineColor: Tok.hairline,
                        labelFont: AppFont.micro,
                        labelColor: .secondary,
                        labelsCount: 5,
                        labelFormatter: { StockFmt.price($0, code: code) },
                        // 深色下涨跌色更亮，胶囊白字对比不足 → 配深字（Sem 侧统一给色）
                        latestLabelColor: Tok.onAccent
                    ),
                    // 午休交界（上午末槽 119 与下午首槽 120 之间）竖虚线
                    // 颜色走 Tok.stroke：写死灰色在深色外观下与卡片底几乎无差 → 分隔线消失
                    verticalSeparators: period == .minute ? [120] : [],
                      verticalSeparatorColor: Tok.stroke,
                      // ⚠ 本项目不做读屏无障碍：这里不传 `chartAccessibilityLabel`。
                      //   图表库自带默认标签（「行情图表」）—— 那是 vendored 包的行为，要一并去掉得改包源码。
                      // 分时 Y 轴以昨收价对称（涨跌两侧视觉平衡，同花顺惯例）
                    yAxisSymmetryAnchor: period == .minute ? previousClose : nil,
                    // 昨收参考线（分时）：明显区别于网格线的中性色虚线（不画最新价线，胶囊保留）
                    referenceLine: period == .minute && previousClose != nil
                        ? (value: previousClose!, color: Tok.stroke)
                        : nil,
                    // 最新价胶囊的红绿：分时按**相对昨收**判（A 股惯例），K 线沿用 `close >= open`
                    latestPricePositive: period == .minute ? minuteLastPricePositive : nil,
                    // 拖到最左边缘自动补齐更早历史；分时不需要（当日全天已在槽位里）
                    hasMoreEarlier: period != .minute && hasMoreEarlier,
                    onLoadEarlier: onLoadEarlier,
                    primaryContent: primaryContent,
                    secondaryContent: [
                        // 刻度/图例用紧凑格式（X万 / X亿）—— 原样输出 21619.00 又长又难读
                        VolumeIndicator(positiveCandleColor: Sem.up, negativeCandleColor: Sem.down,
                                        valueFormatter: { StockFmt.volumeCompact($0) },
                                        // 副图刻度默认 .black，深色下会看不见
                                        yAxisLabelColor: .secondary,
                                        usesAmount: useAmount)
                    ]
                )
            }
        }
    }

    private var primaryContent: [any Content] {
        // 分时：价格折线 + 均价线（VWAP 黄线）；K 线：蜡烛 + MA
        if period == .minute {
            return [MinuteLines(priceColor: minutePriceColor, avgColor: Tok.minuteAvg)]
        }
        let c = Candles(negativeCandleColor: Sem.down, positiveCandleColor: Sem.up)
        // 均线显式给色（不再吃库默认 .yellow/.brown/.purple：白底看不清 / 深底看不见）
        return [c, MAIndicator(periods: [
            .init(value: 7, color: Tok.maShort),
            .init(value: 25, color: Tok.maMid),
            .init(value: 99, color: Tok.maLong),
        ])]
    }

    /// 分时价格线颜色：与最新价胶囊同一口径（相对昨收，红涨绿跌）。
    /// 原先固定 `Sem.brand` 蓝线，和全应用的涨跌语义脱节；数据不足时回落到品牌色。
    private var minutePriceColor: Color {
        guard let prev = previousClose, prev > 0, let last = latestMinutePrice else {
            return Sem.brand
        }
        return last >= prev ? Sem.up : Sem.down
    }

    /// 图表底部图例。分时：固定时间轴刻度（半小时一档 + 午休合并标注），不随数据量自适应——
    /// 位置本身由固定槽位决定。
    private var xAxis: XAxis {
        if period == .minute {
            return XAxis(
                lineColor: Tok.hairline,
                labelFont: AppFont.micro,
                labelColor: .secondary,
                fixedLabels: Self.minuteLabels
            )
        }
        return XAxis(
            lineColor: Tok.hairline,
            labelFont: AppFont.micro,
            labelColor: .secondary,
            // 自适应间隔（0 = 按可视根数取 1/6）：按总根数取间隔，加载大量根数后间隔过大、一屏看不到一个日期。
            labelInterval: 0,
            // ⚠ 缩到跨几年时，只写「07-05」根本分不出是哪一年（2026-10-29 他实测反馈）。
            //   规则：**跨年处**与**本屏第一个**刻度带完整年份，其余仍是 `MM-dd`
            //   （每个刻度都加 5 个字符会把一屏挤满，而年份只需要在换年时锚一次）。
            labelFormatter: { ts, prev in
                let date = Date(timeIntervalSince1970: ts)
                switch period {
                case .daily, .weekly:
                    let full = Self.dayWithYearFmt.string(from: date)
                    guard let prev, Self.dayWithYearFmt.string(
                        from: Date(timeIntervalSince1970: prev)).hasPrefix(full.prefix(4))
                    else { return full }        // 本屏第一个刻度，或已与上一个刻度跨年
                    return Self.dayFmt.string(from: date)
                case .monthly: return Self.monthFmt.string(from: date)
                case .minute: return Self.timeFmt.string(from: date)
                }
            }
        )
    }
}
