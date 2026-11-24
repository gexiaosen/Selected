import SwiftUI
import SwiftTA
#if canImport(AppKit)
import AppKit
#endif

/// A customizable view for displaying financial trading data with various indicators.
///
/// `TradingView` is a SwiftUI component that renders a scrollable, zoomable chart
/// for displaying candlestick data along with primary and secondary indicators.
/// It supports custom axes, dynamic legends, and interactive gestures for zooming and scrolling.
///
/// # Layout (2026-09-17 方案 B 重构)
/// ```
/// ┌────────────────────────────────────┬─────────┐
/// │  ScrollView（绘图区，可缩放/平移）      │ Y 轴列   │
/// │  Canvas: 蜡烛/指标/图例/X轴/网格线     │ 刻度+   │
/// │                                    │ 最新价   │
/// └────────────────────────────────────┴─────────┘
/// ```
/// Y 轴为**独立固定列**（通达信/同花顺范式）：刻度永远贴图表区右缘，
/// 不随缩放/平移/数据量变化而移动——修复"缩放后标签往左挪、悬在图表中间"的问题。
///
/// # Example Usage
/// ```swift
/// TradingView(
///     data: data,
///     scrollTrailingInset: 100,
///     primaryContentHeight: 120,
///     primaryContent: [
///         Candles(),
///         MAIndicator(),
///         BBIndicator(),
///     ],
///     secondaryContent: [
///         MACDIndicator()
///     ]
/// )
/// ```
@available(macOS 13.0, iOS 16.0, watchOS 8.0, tvOS 15.0, *)
public struct TradingView: View {
    // MARK: - Properties

    /// The array of candle data to be displayed in the chart.
    public let data: [CandleData]

    /// The y-axis column configuration. If nil, no y-axis column will be drawn.
    /// （方案 B：YAxis 是独立固定列渲染器，不再遵循 Axis 协议）
    public let yAxis: YAxis?

    /// The x-axis configuration for the chart. If nil, no x-axis will be drawn.
    public let xAxis: Axis?

    /// An array of primary content indicators to be displayed in the main chart area.
    public let primaryContent: [any Content]

    /// An array of secondary content indicators to be displayed below the main chart area.
    public let secondaryContent: [any Content]

    /// The range of possible candle widths for zooming.
    public let candleWidthRange: ClosedRange<CGFloat>

    /// The spacing between individual candles.
    public let candleSpacing: CGFloat

    /// 自适应间距（2026-09-18）：开启后缩小时间距按 `min(candleSpacing, 宽度×0.25)` 同步压缩，
    /// 让「缩到最小 = 全部已加载历史正好铺满一屏」在任意根数下都成立 ——
    /// 否则 500 根 × 固定间距 2 光间距就要 1000pt，永远铺不满，缩到头还是半屏空白。
    /// 放大到宽度 ≥ 4×间距 时与配置值完全一致（常规缩放观感不变）。分时图不启用。
    public let adaptiveSpacing: Bool

    /// The inset applied to the trailing edge of the scroll view.
    public let scrollTrailingInset: CGFloat

    /// The height of each secondary content indicator.
    public let secondaryContentHeight: CGFloat

    /// The vertical spacing between secondary content indicators.
    public let secondaryContentSpacing: CGFloat

    /// The horizontal spacing between legend items.
    public let legendSpacingX: CGFloat

    /// The vertical spacing between legend items when wrapped to a new line.
    public let legendSpacingY: CGFloat

    /// The leading padding for the legend items.
    public let legendPaddingLeading: CGFloat

    /// The top padding for the content area.
    public let contentPaddingTop: CGFloat

    /// The bottom padding for the content area.
    public let contentPaddingBottom: CGFloat

    /// The height of the primary content area. If nil, it will be calculated automatically.
    public let primaryContentHeight: CGFloat?

    /// Whether zoom gestures (wheel + pinch) are enabled. Default true.
    ///
    /// 分时图应传 false（2026-09-17 需求）：分时的横向比例由数据量决定（铺满视口），
    /// 允许缩放只会制造"放大后右侧大空白"的困惑；日/周/月 K 保持可缩放。
    public let isZoomable: Bool

    /// 左侧是否还有更早的历史（App 侧分页取数）。false 时不再触发 `onLoadEarlier`。
    public let hasMoreEarlier: Bool

    /// 拖到最左边缘时的回调（2026-09-18 新增）：App 在回调里取更早的一页并 prepend，
    /// 库检测到左侧补入后自动平移滚动偏移，保持可视内容不跳。
    public let onLoadEarlier: (() -> Void)?

    /// Width of the fixed y-axis column on the right. Only used when `yAxis != nil`.
    public let yAxisColumnWidth: CGFloat

    /// 竖分隔线槽位（2026-09-17 分时改造）：在这些数据索引的**左侧**画竖虚线。
    /// 分时图午休交界（上午末格 119 与下午首格 120 之间）传 [120]，示意"此处休市，
    /// 两段时间轴紧邻不按真实时间留空"。
    public let verticalSeparators: [Int]
    /// 竖分隔线（午休交界）的颜色。此前写死 `Color.secondary.opacity(0.5)`，
    /// 深色外观下 `secondary` 本身变浅、再叠 50% 透明度，与卡片底几乎无差 →
    /// 层级丢失。改为可注入（2026-09-20），调用方传主题 token。
    public let verticalSeparatorColor: Color
    /// 图表的无障碍描述（2026-09-20，审计 P2-25）。
    ///
    /// `Canvas` 对 VoiceOver **完全不可见** —— 不传这个参数，屏幕阅读器只会看到一个
    /// 空白区域（图表整体等于不存在）。App 侧应给出摘要，如
    /// "日K线图，共 320 根，最新收盘 12.34"。
    public let chartAccessibilityLabel: String

    /// Y 轴对称锚点（2026-09-17 分时改造）：非 nil 时 Y 轴范围以锚点为中心上下对称
    /// （分时图以昨收价对称，涨跌幅两侧视觉平衡，同花顺/通达信惯例）。K 线传 nil。
    public let yAxisSymmetryAnchor: Double?

    /// 参考价水平线（2026-09-17 需求：替代原"最新价虚线"）：在主图横贯可视区画一条
    /// 明显的参考虚线（分时传昨收价——用户要求去掉最新价红线、昨收线颜色要显眼）。
    /// 最新价不再画线（Y 轴胶囊已表达，重复画线反而误导）。
    public let referenceLine: (value: Double, color: Color)?

    /// 最新价胶囊的涨跌方向覆盖（2026-10-19 分时成交量红绿修正时加）。
    ///
    /// 默认 nil = 沿用 `close >= open` 判色（K 线：这根蜡烛是阳线还是阴线）。
    /// 分时没有真正的开/收，胶囊该按**相对昨收**判红绿（同花顺/通达信惯例）——
    /// App 侧传入该方向，否则下跌日的胶囊会被判成"阳线红"。
    public let latestPricePositive: Bool?

    // MARK: - Initializer

    /// Initializes a new instance of `TradingView`.
    ///
    /// - Parameters:
    ///   - data: An array of `CandleData` representing the financial data to be displayed.
    ///   - candleWidth: The range of possible candle widths for zooming.
    ///   - initialCandleWidth: The initial candle width. If nil, the midpoint of the range is used.
    ///     Useful when the initial width needs to adapt to the data volume (e.g. intraday charts
    ///     with few bars right after market open should fill the viewport instead of clustering left).
    ///   - isZoomable: Whether wheel/pinch zoom is enabled. Pass `false` for intraday (minute) charts.
    ///   - candleSpacing: The spacing between individual candles.
    ///   - scrollTrailingInset: The inset applied to the trailing edge of the scroll view.
    ///   - primaryContentHeight: The height of the primary content area. If nil, it will be calculated automatically.
    ///   - secondaryContentHeight: The height of each secondary content indicator.
    ///   - secondaryContentSpacing: The vertical spacing between secondary content indicators.
    ///   - legendSpacingX: The horizontal spacing between legend items.
    ///   - legendSpacingY: The vertical spacing between legend items when wrapped to a new line.
    ///   - legendPaddingLeading: The leading padding for the legend items.
    ///   - contentPaddingTop: The top padding for the content area.
    ///   - contentPaddingBottom: The bottom padding for the content area.
    ///   - xAxis: The x-axis configuration. If nil, no x-axis will be drawn.
    ///   - yAxis: The y-axis configuration. If nil, no y-axis column will be drawn.
    ///   - primaryContent: An array of primary content indicators to be displayed in the main chart area.
    ///   - secondaryContent: An array of secondary content indicators to be displayed below the main chart area.
    public init(
        data: [CandleData],
        candleWidth: ClosedRange<CGFloat> = 2...20,
        initialCandleWidth: CGFloat? = nil,
        isZoomable: Bool = true,
        candleSpacing: CGFloat = 2,
        adaptiveSpacing: Bool = false,
        scrollTrailingInset: CGFloat = 0,
        primaryContentHeight: CGFloat? = nil,
        secondaryContentHeight: CGFloat = 100,
        secondaryContentSpacing: CGFloat = 5,
        legendSpacingX: CGFloat = 5,
        legendSpacingY: CGFloat = 2,
        legendPaddingLeading: CGFloat = 10,
        contentPaddingTop: CGFloat = 0,
        contentPaddingBottom: CGFloat = 20,
        xAxis: Axis? = XAxis(),
        yAxis: YAxis? = YAxis(),
        yAxisColumnWidth: CGFloat = 56,
        verticalSeparators: [Int] = [],
        verticalSeparatorColor: Color = Color.secondary.opacity(0.5),
        chartAccessibilityLabel: String = "行情图表",
        yAxisSymmetryAnchor: Double? = nil,
        referenceLine: (value: Double, color: Color)? = nil,
        latestPricePositive: Bool? = nil,
        hasMoreEarlier: Bool = false,
        onLoadEarlier: (() -> Void)? = nil,
        primaryContent: [any Content],
        secondaryContent: [any Content] = []
    ) {
        self.data = data
        self.xAxis = xAxis
        self.yAxis = yAxis
        self.primaryContent = primaryContent
        self.primaryContentHeight = primaryContentHeight
        // 初始宽度可指定（默认取区间中点）。分时图开盘初期数据少时，
        // App 侧会传入“铺满视口”的宽度，避免几十根蜡烛挤在左侧大片空白，看起来像
        // “数据没加载”。（2026-09-17）
        self.candleWidth = initialCandleWidth ?? (candleWidth.lowerBound + candleWidth.upperBound) / 2
        self.candleWidthRange = candleWidth
        self.isZoomable = isZoomable
        self.yAxisColumnWidth = yAxisColumnWidth
        self.verticalSeparators = verticalSeparators
        self.verticalSeparatorColor = verticalSeparatorColor
        self.chartAccessibilityLabel = chartAccessibilityLabel
        self.yAxisSymmetryAnchor = yAxisSymmetryAnchor
        self.referenceLine = referenceLine
        self.latestPricePositive = latestPricePositive
        self.candleSpacing = candleSpacing
        self.adaptiveSpacing = adaptiveSpacing
        self.hasMoreEarlier = hasMoreEarlier
        self.onLoadEarlier = onLoadEarlier
        self.scrollTrailingInset = scrollTrailingInset
        self.secondaryContent = secondaryContent
        self.secondaryContentHeight = secondaryContentHeight
        self.secondaryContentSpacing = secondaryContentSpacing
        self.legendSpacingX = legendSpacingX
        self.legendSpacingY = legendSpacingY
        self.legendPaddingLeading = legendPaddingLeading
        self.contentPaddingTop = contentPaddingTop
        self.contentPaddingBottom = contentPaddingBottom
    }

    /// 用于 `.onChange(of:)` 感知「根数变化 或 同长度下首尾时间戳变化（换周期/换股）」
    private struct DataSignature: Equatable {
        let count: Int
        let first: Double?
        let last: Double?
    }

    @State private var candleWidth: CGFloat
    @State private var lastScaleValue: CGFloat = 1.0

    // 滚轮缩放（2026-09-16 新增，见 installWheelZoom）
    @State private var wheelHover = WheelHoverFlag()
    @State private var wheelZoomMonitor: Any?
    @State private var scrollOffset: CGFloat = 0
    @State private var isScrollAtEnd = true
    /// 绘图区（ScrollView）宽度：滚轮锚定与可视区计算用。
    /// 注意是**绘图区**宽而非组件全宽（全宽含右侧 Y 轴列）。
    @State private var viewportWidth: CGFloat = 0
    @State private var scrollViewProxy: ScrollViewProxy? {
        didSet {
            scrollViewProxy?.scrollTo("chartEnd", anchor: .trailing)
        }
    }
    @State private var scrollDisabled = false
    /// 上一次数据的起始时间戳：用于识别「App 在左侧补入更早历史（prepend）」并保持可视内容不跳
    @State private var lastFirstTime: Double?
    /// 上一次数据的**末尾**时间戳：与 `lastFirstTime` 一起区分
    /// 「左侧补入」（末尾不变 → 需平移偏移）与「整段换数据」（如切换周期 → 不能当作补入，
    /// 否则会把画面锚到历史中段，而不是最新一段）
    @State private var lastLastTime: Double?
    /// 更早历史是否正在加载（防止拖到边缘时反复触发回调）
    @State private var loadingEarlier = false
    /// 鼠标拖拽平移的起始偏移（拖拽期间不读异步回传的 scrollOffset，避免漂移）
    @State private var dragStartOffset: CGFloat?

    // MARK: - 布局常量

    /// 主图图例区固定高度（两行小字）。原实现动态测量图例行数会让图表可视区起点
    /// 随图例长度跳动，且主画布与 Y 轴列无法对齐——固定化后两边严格一致（方案 B）。
    private let primaryLegendAreaHeight: CGFloat = 26
    /// 副图图例区固定高度（一行小字）
    private let secondaryLegendAreaHeight: CGFloat = 14

    private var contentWidth: CGFloat {
        contentWidth(for: candleWidth)
    }

    // MARK: - 缩放边界与步进（数学在 ChartZoomMath：单一实现 + 离线自检）

    /// 指定宽度下的蜡烛间距：自适应模式下随宽度线性压缩（下限 0.15pt）
    private func spacing(for width: CGFloat) -> CGFloat {
        ChartZoomMath.spacing(for: width, configured: candleSpacing, adaptive: adaptiveSpacing)
    }

    private var effectiveSpacing: CGFloat { spacing(for: candleWidth) }

    /// 单根步进（蜡烛宽 + 间距）—— 本视图所有横向位置计算的唯一基准
    private var step: CGFloat { candleWidth + effectiveSpacing }

    private func contentWidth(for width: CGFloat) -> CGFloat {
        ChartZoomMath.contentWidth(
            count: data.count, width: width,
            configuredSpacing: candleSpacing, adaptive: adaptiveSpacing,
            viewportWidth: viewportWidth, configuredInset: scrollTrailingInset)
    }

    /// 「恰好铺满绘图区」对应的蜡烛宽（解析解）。
    /// 注意**不含尾部留白**：铺满时留白自动归零 → 缩到最小最后一根贴右缘、右侧无空白
    /// （2026-09-20 修：原实现把 50pt 留白算进铺满宽度，缩到头右侧仍有一条空隙）。
    private var fitCandleWidth: CGFloat {
        ChartZoomMath.fitCandleWidth(
            count: data.count, viewportWidth: viewportWidth,
            configuredSpacing: candleSpacing, adaptive: adaptiveSpacing)
    }

    /// 缩放下限：配置下限与「铺满宽度」取大 → 缩到最小正好铺满，内容永不比视口窄
    /// （这正是「缩小到一定程度右侧出现半屏空白」的根治：原实现下限写死 1pt，
    ///  120 根月K 只有 ~410pt 宽，贴左显示、右半屏空白，且 scrollTo 贴右对齐在
    ///  内容窄于视口时根本无法产生位移，纯属无效补丁）。
    private var zoomLowerBound: CGFloat {
        max(candleWidthRange.lowerBound, fitCandleWidth)
    }

    /// 缩放上限：配置上限与「铺满宽度」取大 → 极少根数（如次新股 12 根月K）也能铺满
    private var zoomUpperBound: CGFloat {
        max(candleWidthRange.upperBound, fitCandleWidth)
    }

    /// 把当前宽度钳进当前生效范围（视口/根数变化后调用）
    private func clampCandleWidthIfNeeded() {
        guard viewportWidth > 0, !data.isEmpty else { return }
        let lo = zoomLowerBound, hi = zoomUpperBound
        guard lo <= hi else { return }
        if candleWidth < lo { candleWidth = lo } else if candleWidth > hi { candleWidth = hi }
    }

    /// 缩放锚点（绘图区局部 x）：**指针位置**优先；没有 hover 事件时回退"视口中心"
    private var zoomAnchorX: CGFloat {
        guard let x = wheelHover.x, viewportWidth > 0 else { return viewportWidth / 2 }
        return max(0, min(x, viewportWidth))
    }

    /// 以锚点为中心缩放（滚轮与捏合共用同一实现）：锚点所指的那段行情在屏幕上保持不动。
    ///
    /// 2026-09-20 改：原实现锚定"可视区**中心**"（用户体感像"以最新一条为基点"，因为
    /// 缩放后画面常被贴右对齐）。锚点换算按内容宽度等比映射 —— 内容宽与单根步进同比，
    /// 故等价于"指针下的那根不动"，同时天然避免旧偏移越界（缩到铺满时 span→0 单独处理）。
    @MainActor
    private func zoom(to next: CGFloat, anchorX: CGFloat) {
        guard viewportWidth > 0, !data.isEmpty else { return }
        let oldContentWidth = contentWidth
        guard oldContentWidth > 0 else { return }
        let anchor = max(0, min(anchorX, viewportWidth))
        let newContentWidth = contentWidth(for: next)
        candleWidth = next
        let span = newContentWidth - viewportWidth
        guard span > 1 else {
            // 内容已不比视口宽（铺满）：只能整体展示，贴右对齐
            scrollViewProxy?.scrollTo("chartEnd", anchor: .trailing)
            return
        }
        let anchorContentX = min(max(scrollOffset + anchor, 0), oldContentWidth)
        let proportion = anchorContentX / oldContentWidth
        let newOffset = min(max(newContentWidth * proportion - anchor, 0), span)
        scrollViewProxy?.scrollTo("chartEnd", anchor: UnitPoint(x: newOffset / span, y: 0))
    }

    /// 主图底部预留（副图总高 + 底 padding）
    private var primaryBottomOffset: CGFloat {
        (secondaryContentHeight + secondaryContentSpacing)
            * CGFloat(secondaryContent.count) + contentPaddingBottom
    }

    /// Y 轴范围对称化（锚点为中心上下对称，分时图以昨收价为锚）。
    /// 主画布与 Y 轴列共用，保证两处范围严格一致。
    private func symmetrized(_ bounds: (min: Double, max: Double)) -> (min: Double, max: Double) {
        guard let anchor = yAxisSymmetryAnchor else { return bounds }
        let half = max(abs(bounds.max - anchor), abs(anchor - bounds.min))
        guard half > 0 else { return bounds }
        return (anchor - half, anchor + half)
    }

    /// 组件总高（primaryContentHeight 指定时）
    private var totalHeight: CGFloat? {
        primaryContentHeight != nil
            ? primaryContentHeight! + contentPaddingTop + contentPaddingBottom
                + (secondaryContentHeight + secondaryContentSpacing)
                * CGFloat(secondaryContent.count)
            : nil
    }

    /// 每次 body 求值把最新几何与状态快照同步到引用类型 `wheelHover`，
    /// 保证 `.onAppear` 注册的 `NSEvent` 滚轮闭包始终读取当前数据和边界（不会读 `.onAppear` 时的旧副本）。
    private func syncWheelBridge(viewportWidth currentViewportWidth: CGFloat) {
        let vw = viewportWidth > 0 ? viewportWidth : currentViewportWidth
        let fit = vw > 0 && !data.isEmpty
            ? ChartZoomMath.fitCandleWidth(count: data.count, viewportWidth: vw,
                                           configuredSpacing: candleSpacing, adaptive: adaptiveSpacing)
            : 0
        wheelHover.isZoomable = isZoomable
        wheelHover.scrollDisabled = scrollDisabled
        wheelHover.candleWidth = candleWidth
        wheelHover.viewportWidth = vw
        wheelHover.zoomLowerBound = max(candleWidthRange.lowerBound, fit)
        wheelHover.zoomUpperBound = max(candleWidthRange.upperBound, fit)
        let currentView = self
        wheelHover.zoomHandler = { next, anchor in
            currentView.zoom(to: next, anchorX: anchor)
        }
    }

    public var body: some View {
        GeometryReader { geometry in
            // 绘图区宽 = 组件宽 - Y 轴列宽（无 Y 轴时不扣）
            let viewport = CGSize(
                width: max(0, geometry.size.width - (yAxis != nil ? yAxisColumnWidth : 0)),
                height: geometry.size.height
            )
            let _ = syncWheelBridge(viewportWidth: viewport.width)
            HStack(spacing: 0) {
                // MARK: 绘图区（可滚动）
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        ZStack(alignment: .topLeading) {
                            Canvas(rendersAsynchronously: false) { context, size in
                                renderChart(context: context, contentSize: size, viewport: viewport)
                            }
                            .frame(width: contentWidth, height: totalHeight)
                            // Canvas 对 VoiceOver 不可见（2026-09-20，审计 P2-25）：
                            // 合并为单个可访问元素并给出调用方提供的摘要
                            .accessibilityElement()
                            .accessibilityLabel(chartAccessibilityLabel)

                            GeometryReader { p in
                                Color.clear.preference(
                                    key: ScrollOffsetPreferenceKey.self,
                                    value: p.frame(in: .named("scroll")).minX
                                )
                            }
                            // 绘图区宽度同步（滚轮锚定/可视区计算需要）
                            Color.clear
                                .frame(width: 0, height: 0)
                                .onAppear {
                                    viewportWidth = viewport.width
                                    // 首帧就要钳位（2026-09-18）：初始宽度可能低于"铺满"所需
                                    // （如次新股的月K 只有十几根），不钳会留下右侧大片空白 ——
                                    // onChange 只在**变化**时触发，首次布局不会走那里
                                    clampCandleWidthIfNeeded()
                                }
                                .onChange(of: viewport) { newValue in
                                    viewportWidth = newValue.width
                                    // 宽度变化会改变"铺满宽度" → 重新钳位，避免窗口缩放后出现空白
                                    clampCandleWidthIfNeeded()
                                }
                        }
                        .id("chartEnd")
                    }
                    .coordinateSpace(name: "scroll")
                    .scrollDisabled(scrollDisabled)
                    // ⚠ 横向滚动条必须**真的**藏掉（2026-10-29）：`showsIndicators: false`
                    //   在「系统设置 → 显示 → 显示滚动条：始终」下并不生效，遗留式滚动条
                    //   会常驻 ScrollView 底缘 —— 而日期就画在画布底部那条
                    //   `contentPaddingBottom` 带里，于是滑块整条压在日期上。
                    //   SDK 探针实测：`scrollIndicators(_:axes:)` 是 **macOS 13.0+**（本包底档即 13，
                    //   不需要条件分支），只针对横向轴关掉，纵向不受影响。
                    .scrollIndicators(.hidden, axes: .horizontal)
                    .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                        scrollOffset = -value

                        // Calculate if we're at the end
                        let cw = contentWidth
                        isScrollAtEnd = abs(value) >= cw - viewport.width - 1  // 1 point tolerance

                        // 拖到最左边缘 → 请求更早历史（2026-09-18）。
                        // 阈值取 3 根步进：到边缘前就开始预取，手感上"拖到头数据已在"。
                        // 离开边缘 12 根后重新武装，保证可以一段一段往回翻。
                        if hasMoreEarlier, let loadEarlier = onLoadEarlier {
                            if scrollOffset <= step * 3 {
                                if !loadingEarlier {
                                    loadingEarlier = true
                                    loadEarlier()
                                }
                            } else if scrollOffset > step * 12 {
                                loadingEarlier = false
                            }
                        }
                    }
                    .onAppear {
                        scrollViewProxy = proxy
                        lastFirstTime = data.first?.time
                        lastLastTime = data.last?.time
                    }
                    #if !os(watchOS) && !os(tvOS)
                    .gesture(
                        isZoomable
                        ? MagnificationGesture()
                            .onChanged { val in
                                self.scrollDisabled = true
                                let delta = val / self.lastScaleValue
                                self.lastScaleValue = val
                                let next = self.candleWidth * delta
                                // 与滚轮共用同一套生效边界（下限=铺满宽度）与**同一锚点**
                                // （指针位置）：捏合也以指针所指的行情为中心缩放
                                guard next >= zoomLowerBound, next <= zoomUpperBound else { return }
                                zoom(to: next, anchorX: zoomAnchorX)
                            }
                            .onEnded { _ in
                                // without this the next gesture will be broken
                                self.lastScaleValue = 1.0
                                // 立即解除滚动/滚轮冻结（2026-09-22 改）。
                                // 原写法是 `withAnimation(.default.delay(0.5)) { scrollDisabled = false }`，
                                // 而 `scrollDisabled` 同时挡着 ScrollView 滚动（`.scrollDisabled(scrollDisabled)`）
                                // 与滚轮缩放（wheelZoomMonitor 里的 `guard !scrollDisabled`）——
                                // 于是一次捏合结束后，**整整 0.5 秒内滚动和滚轮缩放都是死的**，
                                // 手感是"松手后卡一下"。上面那行 `lastScaleValue` 复位才是
                                // "without this the next gesture will be broken" 指的东西。
                                // 若"下一次手势失效"真的复现，正确做法是把这两行的生效点挪到
                                // 下一帧（`DispatchQueue.main.async`），而不是退回延迟半秒。
                                self.scrollDisabled = false
                            }
                        : nil
                    )
                    // 指针位置（缩放锚点）+ 悬停标记：连续 hover 拿绘图区局部坐标
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            wheelHover.value = true
                            wheelHover.x = point.x
                        case .ended:
                            wheelHover.value = false
                        }
                    }
                    #if os(macOS)
                    // 鼠标左键拖拽平移（2026-09-20 新增）：macOS 的 ScrollView **不支持**
                    // 拖拽滚动 —— 提示文字写的「拖动平移」在鼠标上从来没生效过。
                    // 触控板双指水平滑动走系统路径（见滚轮监视器的水平分量放行），这里补鼠标这一路。
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                let span = contentWidth - viewportWidth
                                guard span > 1 else { return }   // 缩到最小：内容正好铺满，无可平移
                                if dragStartOffset == nil { dragStartOffset = scrollOffset }
                                let base = dragStartOffset ?? scrollOffset
                                let target = min(max(base - value.translation.width, 0), span)
                                scrollViewProxy?.scrollTo(
                                    "chartEnd",
                                    anchor: UnitPoint(x: target / span, y: 0))
                            }
                            .onEnded { _ in dragStartOffset = nil }
                    )
                    #endif
                    .onAppear { if isZoomable { installWheelZoom() } }
                    .onChange(of: isZoomable) { zoomable in
                        if zoomable { installWheelZoom() } else { removeWheelZoom() }
                    }
                    .onDisappear { removeWheelZoom() }
                    #elseif os(watchOS)
                    .focusable()
                    .digitalCrownRotation(
                        $candleWidth,
                        from: candleWidthRange.lowerBound,
                        through: candleWidthRange.upperBound,
                        by: (candleWidthRange.upperBound - candleWidthRange.lowerBound) / 20,
                        sensitivity: .low
                    )
                    #endif
                    .onChange(of: DataSignature(count: data.count, first: data.first?.time, last: data.last?.time)) { _ in
                        // 左侧补入更早历史（prepend）：内容整体右移 idx*step，
                        // 把滚动偏移同步右移同样距离 → 可视内容原地不动（不跳）。
                        // 追加（左侧未变）时维持原有"贴右跟随最新"行为。
                        let newFirst = data.first?.time
                        let newLast = data.last?.time
                        // 判据必须同时满足「头更早了」+「尾没变」：只看头会把"切换周期整段换数据"
                        // 误判成左侧补入，画面会被锚到历史中段而不是最新一段。
                        let isPrepend = (newLast != nil && newLast == lastLastTime)
                        if isPrepend, let oldFirst = lastFirstTime, let nf = newFirst, nf < oldFirst,
                           let idx = data.firstIndex(where: { $0.time >= oldFirst }), idx > 0 {
                            let cw = contentWidth
                            if cw > viewport.width {
                                let target = min(max(scrollOffset + CGFloat(idx) * step, 0),
                                                 cw - viewport.width)
                                scrollViewProxy?.scrollTo(
                                    "chartEnd",
                                    anchor: UnitPoint(x: target / (cw - viewport.width), y: 0))
                            }
                        } else if !isPrepend {
                            scrollViewProxy?.scrollTo("chartEnd", anchor: .trailing)
                        }
                        lastFirstTime = newFirst
                        lastLastTime = newLast
                        loadingEarlier = false
                        clampCandleWidthIfNeeded()
                    }
                }

                // MARK: 独立 Y 轴列（固定，不随滚动/缩放移动）
                if yAxis != nil {
                    Canvas(rendersAsynchronously: false) { context, size in
                        renderYAxisColumn(context: context, columnSize: size, viewport: viewport)
                    }
                    .frame(width: yAxisColumnWidth)
                    // 纯装饰（刻度数字已由主图的无障碍摘要覆盖）→ 对 VoiceOver 隐藏，
                    // 否则会在图表之后多出一个"空白"元素
                    .accessibilityHidden(true)
                }
            }
        }
        .frame(height: totalHeight)
    }

    // MARK: - 可视区计算

    private func candlesInfo(for viewport: CGSize) -> CandlesInfo? {
        // ⚠ 必须用**实际步进**（含自适应压缩后的间距）。2026-09-18 修：
        // 原实现写死 `candleWidth + candleSpacing`（配置间距），而绘制侧用的是压缩后的
        // effectiveSpacing。两者在"缩小到一定程度"（宽度 < 4×间距）后不再相等 →
        // 可视窗口被算短、右端数据根本不画，表现为"缩小后缺数据、没日期"。
        let step = self.step
        // 钳制偏移（2026-09-17 修）：缩放后内容变窄，偏移回传存在异步窗口期，
        // 旧 scrollOffset 可能使 startIndex 超过数据总量（如 480 > 120 根），
        // range 反转 → Canvas 全部指标返回空 → 图表空白，看起来像“K线没加载出来”。
        // 按当前内容宽度钳制后，每一帧的可视区计算都在界内。
        let cw = contentWidth
        let safeOffset = min(scrollOffset, max(0, cw - viewport.width))
        let visibleItemCount = Int(viewport.width / step) + 1
        let startIndex = max(0, min(Int(safeOffset / step), max(0, data.count - 1)))
        let endIndex = min(data.count, startIndex + visibleItemCount)
        return CandlesInfo(
            data: data,
            startIndex: startIndex,
            endIndex: endIndex
        )
    }

    // MARK: - 主画布渲染（蜡烛/指标/图例/X轴/网格线/最新价虚线）

    private func renderChart(context: GraphicsContext, contentSize: CGSize, viewport: CGSize) {
        guard let candlesInfo = candlesInfo(for: viewport) else { return }
        // 安全偏移（2026-09-17 修）：滚轮/捏合改 candleWidth 后，ScrollView 的
        // 偏移回传是异步的——过渡帧里 scrollOffset 可能已超出新的内容宽度，
        // 直接用会算出负宽度图例 / 超界 startIndex，表现为缩放后图表空白。
        // 此处按当前内容宽度钳制，保证每一帧坐标都在界内。
        let safeOffset = min(scrollOffset, max(0, contentSize.width - viewport.width))
        let width = max(0, min(contentSize.width - safeOffset, viewport.width))

        let calculatedData = primaryContent.map { $0.calculate(candlesInfo: candlesInfo) }
        let yBounds = symmetrized(calculatedData.reduce(
            (Double.greatestFiniteMagnitude, Double.zero)
        ) { result, item in
            (min(result.0, item.min), max(result.1, item.max))
        })
        // 空数据保护：reduce 初值会留下 (max, 0)，画出来是错的
        guard yBounds.0 <= yBounds.1, data.count > 0 else { return }

        // 主图可视区（图例区固定高度，Y 轴列用同一套数值保证对齐；极窄/极矮下 clamp 避免负高度或除零）
        let primaryRect = CGRect(
            x: safeOffset,
            y: contentPaddingTop + primaryLegendAreaHeight,
            width: width,
            height: max(1, contentSize.height - primaryBottomOffset
                - contentPaddingTop - primaryLegendAreaHeight)
        )

        // 水平网格线（与 Y 轴列刻度共用 labelValues，线与数字永远对齐）
        // 颜色取自 `yAxis.lineColor`（2026-09-20 修复）：此前这里写死
        // `Color.gray.opacity(0.18)`，而 `YAxis.lineColor` 声明了却从不被消费 ——
        // 调用方（App 的 Tok.hairline）传了也没用，深色外观下网格线几乎不可见。
        if let yAxis {
            for value in yAxis.labelValues(for: yBounds) {
                let scale = primaryRect.height / CGFloat(max(yBounds.1 - yBounds.0, .ulpOfOne))
                let y = CGFloat(yBounds.1 - value) * scale + primaryRect.minY
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: contentSize.width, y: y))
                context.stroke(line, with: .color(yAxis.lineColor), lineWidth: 1)
            }
        }

        // 竖分隔线（午休交界等）：在指定槽位左侧画竖虚线，横跨主图可视区
        for sepIndex in verticalSeparators {
            let x = CGFloat(sepIndex) * step    // 同 candlesInfo：必须用实际步进
            guard x >= safeOffset, x <= safeOffset + width else { continue }
            var line = Path()
            line.move(to: CGPoint(x: x, y: primaryRect.minY))
            line.addLine(to: CGPoint(x: x, y: primaryRect.maxY))
            context.stroke(line, with: .color(verticalSeparatorColor),
                           style: .init(lineWidth: 1, dash: [3, 3]))
        }

        // 参考价水平虚线（昨收价等）：横贯主图，颜色明显区别于网格线；
        // 原为"最新价虚线"已按需求移除（最新价由 Y 轴胶囊表达，画线重复且误导）（2026-09-17）
        if let ref = referenceLine {
            let scale = primaryRect.height / CGFloat(max(yBounds.1 - yBounds.0, .ulpOfOne))
            let y = CGFloat(yBounds.1 - ref.value) * scale + primaryRect.minY
            if primaryRect.minY...primaryRect.maxY ~= y {
                var line = Path()
                line.move(to: CGPoint(x: safeOffset, y: y))
                line.addLine(to: CGPoint(x: safeOffset + width, y: y))
                context.stroke(line, with: .color(ref.color),
                               style: .init(lineWidth: 1.2, dash: [5, 3]))
            }
        }

        // 主图指标
        let zipped = zip(primaryContent, calculatedData)
        for (content, calc) in zipped {
            let contextInfo = ContextInfo(
                context: context,
                contextSize: contentSize,
                visibleBounds: primaryRect,
                candleWidth: candleWidth,
                candleSpacing: effectiveSpacing,
                yBounds: yBounds
            )
            content.draw(contextInfo: contextInfo, candlesInfo: candlesInfo, calculatedData: calc)
        }

        // X 轴（主画布底部）
        if let xAxis {
            let contextInfo = ContextInfo(
                context: context,
                contextSize: contentSize,
                visibleBounds: primaryRect,
                candleWidth: candleWidth,
                candleSpacing: effectiveSpacing,
                yBounds: yBounds
            )
            xAxis.draw(contextInfo: contextInfo, candlesInfo: candlesInfo)
        }

        // 主图图例
        let legend = zipped.flatMap {
            $0.0.legend(candlesInfo: candlesInfo, calculatedData: $0.1)
        }
        drawLegend(
            context: context,
            bounds: CGRect(
                origin: CGPoint(x: safeOffset + legendPaddingLeading, y: contentPaddingTop),
                size: CGSize(width: width, height: primaryLegendAreaHeight)
            ),
            text: legend,
            spacingX: legendSpacingX,
            spacingY: legendSpacingY
        )

        // 副图（从底往上叠）
        for (index, content) in secondaryContent.reversed().enumerated() {
            let calc = content.calculate(candlesInfo: candlesInfo)
            let top = contentSize.height - secondaryContentHeight
                * CGFloat(index + 1) - secondaryContentSpacing * CGFloat(index)
                - contentPaddingBottom
            let rect = CGRect(
                x: safeOffset,
                y: top + secondaryLegendAreaHeight,
                width: width,
                height: secondaryContentHeight - secondaryLegendAreaHeight
            )
            let contextInfo = ContextInfo(
                context: context,
                contextSize: contentSize,
                visibleBounds: rect,
                candleWidth: candleWidth,
                candleSpacing: effectiveSpacing,
                yBounds: (min: calc.min, max: calc.max)
            )
            content.draw(contextInfo: contextInfo, candlesInfo: candlesInfo, calculatedData: calc)

            let secLegend = content.legend(candlesInfo: candlesInfo, calculatedData: calc)
            drawLegend(
                context: context,
                bounds: CGRect(
                    origin: CGPoint(x: safeOffset + legendPaddingLeading, y: top),
                    size: CGSize(width: width, height: secondaryLegendAreaHeight)
                ),
                text: secLegend,
                spacingX: legendSpacingX,
                spacingY: legendSpacingY
            )
        }
    }

    // MARK: - Y 轴列渲染（固定列：主图刻度/副图刻度/最新价胶囊）

    private func renderYAxisColumn(context: GraphicsContext, columnSize: CGSize, viewport: CGSize) {
        guard let yAxis, columnSize.width > 0 else { return }
        guard let candlesInfo = candlesInfo(for: viewport), data.count > 0 else { return }

        let columnHeight = totalHeight ?? columnSize.height

        let calculatedData = primaryContent.map { $0.calculate(candlesInfo: candlesInfo) }
        let yBounds = symmetrized(calculatedData.reduce(
            (Double.greatestFiniteMagnitude, Double.zero)
        ) { result, item in
            (min(result.0, item.min), max(result.1, item.max))
        })
        guard yBounds.0 <= yBounds.1 else { return }

        // 主图段（与 renderChart 同一套布局公式，高度下限与主图保持一致）
        let primarySegment = YAxis.Segment(
            rect: CGRect(
                x: 0,
                y: contentPaddingTop + primaryLegendAreaHeight,
                width: columnSize.width,
                height: max(1, columnHeight - primaryBottomOffset
                    - contentPaddingTop - primaryLegendAreaHeight)
            ),
            yBounds: yBounds
        )

        // 副图段（含指标自提供的刻度文本）
        var secondarySegments: [YAxis.Segment] = []
        for (index, content) in secondaryContent.reversed().enumerated() {
            let calc = content.calculate(candlesInfo: candlesInfo)
            let top = columnHeight - secondaryContentHeight
                * CGFloat(index + 1) - secondaryContentSpacing * CGFloat(index)
                - contentPaddingBottom
            secondarySegments.append(YAxis.Segment(
                rect: CGRect(
                    x: 0,
                    y: top + secondaryLegendAreaHeight,
                    width: columnSize.width,
                    height: secondaryContentHeight - secondaryLegendAreaHeight
                ),
                yBounds: (min: calc.min, max: calc.max),
                secondaryLabels: content.yAxisLabels(candlesInfo: candlesInfo, calculatedData: calc)
            ))
        }

        // 最新价胶囊：取最后一个**有效**数据点（分时固定槽数组尾部可能是空槽，
        // close=0 会画出 0.00 错位胶囊）（2026-09-17 修）
        let last = data.last { $0.close > 0 }
        yAxis.drawColumn(
            context: context,
            size: columnSize,
            primary: primarySegment,
            secondarySegments: secondarySegments,
            lastPrice: last.map {
                (value: $0.close, isPositive: latestPricePositive ?? ($0.close >= $0.open))
            }
        )
    }

    // MARK: - 图例绘制

    private func legendSize(
        for text: [Text],
        context: GraphicsContext,
        bounds: CGRect,
        spacingX: CGFloat,
        spacingY: CGFloat
    ) -> CGSize {
        guard bounds.width > 0 else { return .zero }
        let textSizes = text.map { context.resolve($0) }.map { $0.measure(in: bounds.size) }
        let width = textSizes.reduce(0) { $0 + $1.width + spacingX }
        let height = textSizes.reduce(0) { max($0, $1.height) } * ceil(width / bounds.width)
        return CGSize(width: min(width, bounds.width), height: height)
    }

    private func drawLegend(
        context: GraphicsContext,
        bounds: CGRect,
        text: [Text],
        spacingX: CGFloat,
        spacingY: CGFloat
    ) {
        guard bounds.width > 0 else { return }
        let resolvedTexts = text.map { context.resolve($0) }
        var x: CGFloat = max(bounds.minX, 0)
        var y: CGFloat = bounds.minY
        for (_, resolvedText) in resolvedTexts.enumerated() {
            let textSize = resolvedText.measure(in: bounds.size)
            if x + textSize.width > bounds.maxX {
                x = bounds.minX
                y += textSize.height + spacingY
            }
            context.draw(
                resolvedText,
                at: CGPoint(x: x, y: y),
                anchor: .topLeading
            )
            x += textSize.width + spacingX
        }
    }
}

@available(macOS 13.0, iOS 16.0, watchOS 8.0, tvOS 15.0, *)
struct TradingView_Preview: PreviewProvider {
    @ViewBuilder
    static var previews: some View {
        let data = CandleData.generateSampleData(count: 1000)
        TradingView(
            data: data,
            scrollTrailingInset: 100,
            primaryContentHeight: 120,
            primaryContent: [
                Candles(),
                MAIndicator(),
                BBIndicator(),
            ],
            secondaryContent: [
                MACDIndicator(),
                VolumeIndicator()
            ]
        )
    }
}


// MARK: - 滚轮缩放（2026-09-16 新增，macOS）

/// 悬停与滚轮缩放状态桥：必须用**引用类型**承载。
/// `@State` 布尔值与 View struct 的 `let data` 被 `NSEvent` 闭包捕获后都会停在创建时刻，
/// 每次视图刷新时由 `syncWheelBridge` 写入最新值，令滚轮监视器始终使用最新数据与缩放边界。
final class WheelHoverFlag: @unchecked Sendable {
    var value = false
    /// 指针在绘图区内的 x（缩放锚点：以鼠标位置为中心缩放）。
    /// nil = 尚未收到 hover 事件（回退到"视口中心"）。
    var x: CGFloat?
    var isZoomable = true
    var scrollDisabled = false
    var candleWidth: CGFloat = 0
    var viewportWidth: CGFloat = 0
    var zoomLowerBound: CGFloat = 0
    var zoomUpperBound: CGFloat = 0
    var zoomHandler: (@MainActor (CGFloat, CGFloat) -> Void)?

    /// 从最新实时状态算下一步宽度（供滚轮监视器与离线测试共用，保证同帧连滚不丢失步长）
    func stepZoomWidth(factor: CGFloat) -> CGFloat? {
        guard isZoomable, !scrollDisabled, factor != 1, zoomLowerBound <= zoomUpperBound else { return nil }
        let next = min(max(candleWidth * factor, zoomLowerBound), zoomUpperBound)
        guard next != candleWidth else { return nil }
        return next
    }

    func resolvedAnchorX() -> CGFloat {
        guard let x, viewportWidth > 0 else { return viewportWidth / 2 }
        return max(0, min(x, viewportWidth))
    }
}

#if !os(watchOS) && !os(tvOS)
@available(macOS 13.0, iOS 16.0, watchOS 8.0, tvOS 15.0, *)
extension TradingView {
    /// 安装滚轮缩放。
    ///
    /// 为什么需要：本视图原先只有捏合手势，**滚轮无人处理** → 事件冒泡到外层 ScrollView，
    /// 把整个页面滚走 —— 使用者看到的正是"滚轮/触控板一动，UI 就乱"。
    /// 这里在鼠标悬停于图表时**吞掉一切滚轮事件**（含已到缩放上下限、捏合进行中），
    /// 只把有效的那部分转成缩放，与捏合共用同一套**生效边界**
    /// （`zoomLowerBound`/`zoomUpperBound`，下限即"铺满视口"宽度），保持单一缩放状态源。
    func installWheelZoom() {
        guard wheelZoomMonitor == nil else { return }
        let bridge = wheelHover
        wheelZoomMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            var consumed = false
            MainActor.assumeIsolated {
                guard bridge.value, bridge.isZoomable else { return }
                // 触控板双指**水平**滑动 = 平移：放行给系统（由本视图自己的横向 ScrollView
                // 处理）。原实现把水平分量也一并吞掉 —— 等于把触控板的左右滑也禁了，
                // 表现为"不能左右拖动"（2026-09-20 修）
                if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) { return }
                // 2026-09-18：**指针在图表上就吞掉滚轮**，不再"只有真的改变了宽度才吞"。
                // 原实现到缩放上下限后 `next == old` 直接放行 → 事件冒泡给外层页面滚动视图，
                // 表现为"缩到头再滚，页面就滑走"（这正是用户报的"缩放时页面容易滑动"）。
                consumed = true
                // 捏合进行中：偏移被冻结，滚轮不参与缩放，但同样要吞掉（否则页面照样滑）
                guard !bridge.scrollDisabled else { return }
                // 触控板(delta 精细)与鼠标滚轮(刻度大)增益不同，分开处理
                let raw = event.hasPreciseScrollingDeltas
                    ? event.scrollingDeltaY / 60
                    : event.scrollingDeltaY / 8
                let factor = 1 + max(-0.25, min(0.25, raw))
                guard let next = bridge.stepZoomWidth(factor: factor) else { return }
                // 同帧连发多次滚轮事件时先推进桥上的 candleWidth，避免读回旧值
                bridge.candleWidth = next
                // 锚点 = 指针位置（2026-09-20）：鼠标在哪，就以哪为中心放大/缩小
                bridge.zoomHandler?(next, bridge.resolvedAnchorX())
            }
            return consumed ? nil : event
        }
    }

    func removeWheelZoom() {
        if let monitor = wheelZoomMonitor {
            NSEvent.removeMonitor(monitor)
            wheelZoomMonitor = nil
        }
    }
}
#endif

