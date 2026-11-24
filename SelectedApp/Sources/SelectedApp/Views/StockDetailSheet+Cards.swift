import SwiftUI
import SwiftTradingView
import SelectedCore

// MARK: - 详情页卡片（一）：次日区间 → 筹码 → 形态 → 技术指标 → 早盘抢筹 → 涨停 → 回撤风险

extension StockDetailSheet {
    // MARK: 次日高低点区间（统计区间估计，不是预测承诺）

    /// 固定高度容器：加载中 → 骨架，就绪 → 数字，失败 → 说明。
    /// 高度固定是为了**避免数据到达后整页跳动**。
    @ViewBuilder
    var forecastCard: some View {
        Card("次日高低点区间", subtitle: fcSubtitle) {
            Group {
                if fcLoading {
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Tok.skeleton).frame(height: 20)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Tok.skeleton).frame(height: 20)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Tok.skeleton).frame(height: 14)
                    }
                } else if let e = fcError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(Sem.warn)
                        Text(e).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                } else if let r = fc {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 22) {
                            rangeMini("次日高点", central: r.highCentralOrNil,
                                      edge: r.highOptimisticOrNil,
                                      edgeTag: "上限", color: Sem.up)
                            rangeMini("次日低点", central: r.lowCentralOrNil,
                                      edge: r.lowOptimisticOrNil,
                                      edgeTag: "下限", color: Sem.down)
                            Spacer()
                            Button("完整口径") { showForecastSheet = true }
                                .btnSecondary()
                                .help("查看基线分位、近期波动倍数、逐日滚动回测与局限说明")
                                // ⚠ `.popover` 而**不是** `.sheet`：详情页自己就是个 sheet，再开 sheet = sheet-on-sheet →
                                //   焦点套两层，关掉要"退两次"。popover **不是模态**：
                                //   没有焦点陷阱、焦点始终在详情页。
                                //   ⚠ 挂在**这个按钮**上（不是挂在整张 sheet 上）—— 锚点才对。
                                //   ⚠ Esc 的归属：popover **不吃 Esc**，而 **SwiftUI 的 sheet 自己就吃 Esc** →
                                //     一次 Esc 会同时关两层。两件一起才管用：撤掉「关闭」按钮的 Esc 绑定 ＋
                                //     `.interactiveDismissDisabled`（见 `StockDetailSheet`
                                //     的 body 与 `priceHeader`，那里有完整的三条实测）。
                                .popover(isPresented: $showForecastSheet, arrowEdge: .bottom) {
                                    ForecastSheet(presetCode: code)
                                }
                        }
                        Text(fcMetaLine(r)).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .frame(height: 74, alignment: .top)   // 三种状态同高，杜绝跳动
        }
    }

    private var fcSubtitle: String {
        guard let r = fc else { return fcLoading ? "计算中…" : "" }
        let asOf = r.asOfDash
        let base = r.baseCloseOrNil.map { StockFmt.price($0, code: code) } ?? "—"
        return "基准 \(asOf) · 前收 \(base)"
    }

    private func rangeMini(_ title: String, central: Double?, edge: Double?,
                           edgeTag: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(central.map { StockFmt.price($0, code: code) } ?? "—")
                    .font(AppFont.display(20))
                    .monospacedDigit().foregroundStyle(color)
                Text("\(edgeTag) \(edge.map { StockFmt.price($0, code: code) } ?? "—")")
                    .font(.caption).monospacedDigit().foregroundStyle(color)
            }
        }
    }

    private func fcMetaLine(_ r: ForecastResult) -> String {
        var parts: [String] = []
        if let amp = r.expectedRangePctOrNil {
            parts.append(String(format: "预期振幅 %+.2f%%", amp))
        }
        if let k = r.recent?.k {
            parts.append(String(format: "波动倍数 %.2f", k))
        }
        if let bt = r.backtest, bt.n > 0 {
            parts.append(String(format: "回测 n=%d：高≤上限 %.0f%%、低≥下限 %.0f%%",
                                bt.n, bt.highWithinUpper * 100, bt.lowAboveLower * 100))
        }
        parts.append("统计估计，非买卖建议")
        return parts.joined(separator: " ｜ ")
    }

    // MARK: 筹码分布（CYQ，InStock 模块 6）

    /// 筹码分布：**上方套牢盘重不重**。
    ///
    /// ⚠ **只展示、不参与评分**（见 `ChipDistribution` 文件头与
    /// `docs/specs/README.md`）。数据用**打开详情时单独取一份的日K**（500 根，见 `dailyKline`），
    /// 比扫描侧能给的 65 根口径更好，而且对**任何**个股都可用（不限于当轮入选的票）。
    ///
    /// ⚠ **只用日K算**：周K/月K的一根 bar 不是"一个交易日的筹码"，拿它算筹码分布口径就错了。
    ///   所以读的是 `dailyKline`（与图表周期解耦、打开详情时单独取一份），
    ///   而不是图表上的 `kline` —— 图表默认就是分时，`kline` 那时是空的。
    ///
    /// 用**计算属性**而不是 `@State` + 加载钩子：一是省掉"行情还没到时算的是收盘价、
    /// 行情到了却不重算"的同步问题，二是 250 根 × 100 档 ≈ 5 万次浮点运算，
    /// 相对 1s/5s 的行情轮询可以忽略。这也让它**永远与日K同源**。
    private var chipStats: ChipStats? {
        guard !dailyKline.isEmpty else { return nil }
        let price = quote?.currentPrice ?? dailyKline.last?.close ?? 0
        return ChipDistribution.compute(
            dailyKline, currentPrice: price,
            floatShares: ChipDistribution.estimateFloatShares(
                turnoverRate: quote?.turnoverRate,
                volumeInLots: quote?.volume,
                circulationMarketCapYi: quote?.circulationMarketCap,
                price: price))
    }

    private var chipSubtitle: String {
        guard let s = chipStats else { return "" }
        return "近 \(s.window) 个交易日 · " + (s.decayed ? "换手衰减" : "半衰期衰减")
    }

    /// 三态同高（骨架 / 数字 / 说明）：骨架用与数字**逐行等高**的占位块，
    /// 于是不需要写死 `.frame(height:)` 也不会跳动。
    @ViewBuilder
    var chipCard: some View {
        // ⚠ 门控是「有没有日K」而不是「图表是不是日K」—— 图表默认分时，
        //   按周期门控会让这张卡默认整张消失（判据本身与图表周期无关，见 `chipStats`）。
        if dailyKlineLoading || !dailyKline.isEmpty {
            Card("筹码分布", subtitle: chipSubtitle) {
                if let s = chipStats {
                    VStack(alignment: .leading, spacing: 9) {
                        // 获利盘 / 套牢盘：一条比例条 + 两端数字（A股惯例：获利红、套牢绿）
                        HStack(spacing: 8) {
                            Text("获利盘").font(.caption).foregroundStyle(.secondary)
                            Text(String(format: "%.1f%%", s.profitRatio * 100))
                                .font(AppFont.displayNumeric(14)).foregroundStyle(Sem.up)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Tok.tint(Sem.down, .strong))
                                    Capsule().fill(Tok.tint(Sem.up, .strong))
                                        .frame(width: max(0, geo.size.width * s.profitRatio))
                                }
                            }
                            .frame(height: 7)
                            Text(String(format: "%.1f%%", s.aboveMass * 100))
                                .font(AppFont.displayNumeric(14)).foregroundStyle(Sem.down)
                            Text("套牢盘").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 14) {
                            chipCell("平均成本", StockFmt.price(s.avgCost, code: code), nil)
                            chipCell("90% 成本区间",
                                     StockFmt.price(s.cost90Low, code: code) + " ~ " + StockFmt.price(s.cost90High, code: code), nil)
                            chipCell("上方第一道压力",
                                     s.pressurePrice.map { StockFmt.price($0, code: code) } ?? "真空",
                                     s.pressureGapPct)
                        }
                    }
                } else if dailyKlineLoading {
                    VStack(alignment: .leading, spacing: 9) {
                        RoundedRectangle(cornerRadius: 4).fill(Tok.skeleton).frame(height: 17)
                        RoundedRectangle(cornerRadius: 4).fill(Tok.skeleton).frame(height: 30)
                    }
                } else {
                    // ⚠ 补上根数：只说"不足"用户不知道差多少；
                    //   根数取自 Core 常量（不写死），配置改了文案跟着改。
                    Text("日K 不足 \(ChipDistribution.minBars) 根，算不出筹码分布")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// ⚠ 收敛到 `MetricCell`：`gap` 就是它的 `trailing`。
    private func chipCell(_ label: String, _ value: String, _ gap: Double?) -> some View {
        MetricCell(label: label, value: value,
                   trailing: gap.map { String(format: "+%.1f%%", $0) })
    }

    // MARK: K 线形态（InStock 模块 5）

    /// K 线形态：**图上最后一根 K 线是哪种短周期形态**。
    ///
    /// ⚠ **只用图上已加载的日K现算**，不额外发请求（与筹码分布同款）。实测腾讯
    /// `newfqkline` **已经包含当日 bar**（开盘前就带当日日期）→ 不需要拿实时行情合成一根，
    /// 少一处口径不一致的机会。尾部"尚未形成"的占位 bar 由
    /// `KLinePatterns.dropUnformedTail` 剔掉。
    ///
    /// ⚠ **只用日K算**：12 个形态的判据全部按"一根 bar = 一个交易日"定义
    /// （"两日反转""三连阳"），周K/月K 上口径就错了 ⇒ 读 `dailyKline`（与图表周期解耦）。
    ///
    /// 用**计算属性**而不是 `@State` + 加载钩子：让它永远与日K同源
    /// （与 `chipStats` 同一考虑）。只有阈值从参数读，那部分缓存进 `patternCfg`。
    private var patternBars: [KLineItem] {
        KLinePatterns.dropUnformedTail(dailyKline)
    }

    private var patternResult: PatternResult? {
        guard patternBars.count >= KLinePatterns.minBars else { return nil }
        return KLinePatterns.detect(patternBars, config: patternCfg)
    }

    /// 第二组判据：量能 / 连续性。
    ///
    /// ⚠ 与 12 个**形状**刻意分开（见 `KLineSignals` 文件头）：形状是**互斥分类**，
    /// 量能/连续性与它**正交**（一根光头光脚大阳线既可能是天量也可能不是）。
    /// ⚠ 阈值是**本项目的出厂默认值**（清单点名了这几条但没给数），与形态识别阈值同一性质。
    ///
    /// ⚠ 只取末尾 60 根：连续计数与均量都只看尾部，而本页行情每 1~5 秒轮询一次 ——
    /// 每次渲染遍历整段图上的 K 线（可能上千根）是白费。
    private var patternSignals: [KLineSignals.Signal] {
        let tail = Array(patternBars.suffix(60))
        guard tail.count >= KLineSignals.SignalConfig().volAvgDays + 1 else { return [] }
        return KLineSignals.detect(tail)
    }

    /// 形态的两份配置：**一次 `activeParams()`** 读出识别阈值与打分配置。
    ///
    /// ⚠ 缓存进 `@State` 而不是在计算属性里现读 —— `ParamStore.activeParams()` 每次调用
    /// 都会查库 + 解析 JSON，而 `patternResult` 会随行情轮询重算（详情页 1s/5s 一次）。
    /// ⚠ **读取逻辑在 `KLinePatterns.config(from:)` / `PatternScoreConfig.from(_:)` 里，
    /// 引擎侧调的是同一对函数** —— 两处各写一份必然漂移
    /// （"界面显示的形态 ≠ 打分的形态"，且不报错）。
    nonisolated static func loadPatternConfigs() -> (cfg: PatternConfig, scoreCfg: PatternScoreConfig) {
        let params = ParamStore.shared.activeParams()
        return (KLinePatterns.config(from: params), PatternScoreConfig.from(params))
    }

    private var patternSubtitle: String {
        guard let r = patternResult, let day = patternBars.last?.date else { return "" }
        var base = "\(day) · \(r.trend.label)"
        if !r.hits.isEmpty {
            base += " · 命中 \(r.hits.count)/\(KLinePatterns.definitions.count)"
        }
        // 第二组单独报数（与形状不是同一类判据，不能加在一起）
        if !patternSignals.isEmpty { base += " · 量能/连续 \(patternSignals.count) 条" }
        return base
    }

    /// 方向 → 语义色。⚠ A股红涨绿跌：**看多用红（`Sem.up`）、看空用绿（`Sem.down`）**。
    /// 中性用 `Tok.dim`（灰）—— 中性形态（十字星 / 纺锤 / 窄幅整理）本身不是信号，
    /// 涂红涂绿都会让"红=涨"的既有语义串味。
    private func patternColor(_ d: PatternDirection) -> Color {
        switch d {
        case .bullish: return Sem.up
        case .bearish: return Sem.down
        case .neutral: return Tok.dim
        }
    }

    private func patternRow(_ h: PatternHit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(h.name).font(AppFont.bodySmall.weight(.semibold))
                miniBadge(h.direction.label, patternColor(h.direction))
                Text("\(h.bars) 根K线").font(AppFont.detailSmall).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(h.note)
                .font(AppFont.detailSmall).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 第二组的一行（量能 / 连续性）。形状相同，但没有"几根K线"那一栏 ——
    /// 量能是**当日**特征，连续性已经写在 `note` 里。
    private func signalRow(_ s: KLineSignals.Signal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(s.name).font(AppFont.bodySmall.weight(.semibold))
                miniBadge(s.direction.label, patternColor(s.direction))
                Spacer(minLength: 0)
            }
            Text(s.note)
                .font(AppFont.detailSmall).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 口径行。⚠ 卡片上必须写清"形态**当前不参与评分**"及其原因 ——
    /// 否则用户会以为它已经影响选股结果（反过来，等标定通过开启后也必须改这句）。
    private func patternCaliber(_ r: PatternResult) -> String {
        // ⚠ 读**缓存值**，不在渲染路径里现读库：本函数在 `body` 里被调用，
        //   而详情页行情 1s/5s 轮询 → 现读 = 每秒一次读库 + JSON 解析。
        let scoreCfg = patternScoreCfg
        let sigCfg = KLineSignals.SignalConfig()
        let scorePart = scoreCfg.enabled
            ? "形态「参与评分」（看多 +\(scoreCfg.bullishScore) / 看空 \(scoreCfg.bearishScore)"
                + " / 中性 \(scoreCfg.neutralScore)，单只上限 ±\(scoreCfg.cap)）"
            : "⚠ 本卡只展示 —— 形态「当前不参与评分」（出厂默认关闭：方向尚未标定）"
        return "用图上日K现算（不额外发请求），最后一根 = \(patternBars.last?.date ?? "—")"
            + " · 趋势语境按前 \(patternCfg.trendLookback) 根收盘与均线比较"
            + "（决定「锤头 vs 上吊线」这类同形状不同名；走平时不出语境形态）"
            + " · 量能/连续组：均量取前 \(sigCfg.volAvgDays) 日（「不含当日」）、"
            + "天量 ≥ \(fmtMult(sigCfg.heavyVolumeMult))×、连涨放量 ≥ \(fmtMult(sigCfg.surgeUpMult))×、"
            + "下跌无量 ≤ \(fmtMult(sigCfg.quietDeclineMult))×、"
            + "连阳/连阴 ≥ \(sigCfg.consecutiveMin) 根（按「收>开」，与连涨的按涨幅不是一回事）"
            + " —— ⚠ 这几条阈值是「本项目的出厂默认值」（清单点名了判据但没给数），可调"
            + " · " + scorePart
    }

    private func fmtMult(_ v: Double) -> String { String(format: "%.1f", v) }

    @ViewBuilder
    var patternCard: some View {
        // 门控看「有没有日K」而不是图表周期（图表默认分时，见 `chipCard` 同款说明）
        if dailyKlineLoading || !patternBars.isEmpty {
            Card("K 线形态", subtitle: patternSubtitle) {
                if let r = patternResult {
                    VStack(alignment: .leading, spacing: 9) {
                        if r.hits.isEmpty {
                            Text("\(patternBars.last?.date ?? "") 未命中 12 个形态中的任何一个")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(r.hits, id: \.shape) { patternRow($0) }
                        }
                        // 第二组：量能 / 连续性。
                        // ⚠ 与上面的 12 个形状**不是同一类判据**（形状互斥、量能正交），
                        //   所以用小标题分组，而不是混进同一个列表。
                        if !patternSignals.isEmpty {
                            Text("量能 · 连续")
                                .font(AppFont.detailSmall.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                            ForEach(patternSignals, id: \.kind.rawValue) { signalRow($0) }
                        }
                        // ⚠ 口径收进小问号（2026-10-19）：原来是整段常显文字（3~6 行），
                        //   详情页要滚很久才看完一张卡，而它「看一眼就够、偶尔才要细读」。
                        CaliberTip(text: patternCaliber(r), title: "K 线形态口径")
                    }
                } else if dailyKlineLoading {
                    // 骨架用与命中行**逐行等高**的占位，避免加载完成时跳动（与 chipCard 同款）
                    VStack(alignment: .leading, spacing: 9) {
                        RoundedRectangle(cornerRadius: 4).fill(Tok.skeleton).frame(height: 15)
                        RoundedRectangle(cornerRadius: 4).fill(Tok.skeleton).frame(height: 15)
                    }
                } else {
                    Text("日K 不足 \(KLinePatterns.minBars) 根，无法识别形态")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 技术指标四件套

    /// ATR / OBV / MFI / BIAS。**只展示、不进评分**。
    ///
    /// ⚠ 只取末尾 120 根：ATR 的 Wilder 平滑是**递归**的（依赖全序列），但它的记忆衰减很快
    /// —— 120 根（约半年）之后种子早已被冲淡到可忽略。而本页行情每 1~5 秒轮询一次，
    /// 每次渲染都遍历整段图上的 K 线（可能上千根）是白费。
    private var indicators: TechnicalIndicators.Snapshot {
        TechnicalIndicators.snapshot(Array(patternBars.suffix(120)))
    }

    /// 「技术指标」卡至少需要多少根日K —— **判据与文案共用这一个常量**
    ///   （数字若在判据和文案里各写一遍，改一处漏一处就变成错的文案）。
    /// 口径：MFI(14) 需 `14+1 = 15` 根，是这张卡里最长的那个（BIAS(24) 在不足 25 根时会留空）。
    private static let indicatorMinBars = 15

    @ViewBuilder
    var indicatorCard: some View {
        if dailyKlineLoading || !patternBars.isEmpty {
            Card("技术指标", subtitle: indicatorSubtitle) {
                if dailyKlineLoading {
                    // ⚠ 不能走下面那条"不足 N 根"：日K还在路上时说"不足"是**错的结论**
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).fill(Tok.skeleton).frame(height: 15)
                        RoundedRectangle(cornerRadius: 4).fill(Tok.skeleton).frame(height: 15)
                    }
                } else if indicators.barsUsed >= Self.indicatorMinBars {
                    VStack(alignment: .leading, spacing: 8) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)],
                                  spacing: 8) {
                            metricCell("ATR(14)", StockFmt.num(indicators.atr))
                            metricCell("ATR 占价", StockFmt.percent(indicators.atrPercent))
                            metricCell("OBV 20日", obvText)
                            metricCell("MFI(14)", StockFmt.num(indicators.mfi, digits: 1))
                            metricCell("BIAS(6)", biasText(6))
                            metricCell("BIAS(12)", biasText(12))
                            metricCell("BIAS(24)", biasText(24))
                        }
                        CaliberTip(text: indicatorCaliber, title: "技术指标口径")
                    }
                } else {
                    Text("日K 不足 \(Self.indicatorMinBars) 根，算不出这些指标")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var indicatorSubtitle: String {
        guard let day = patternBars.last?.date else { return "" }
        return "\(day) · 只展示，不进评分"
    }

    /// OBV 展示的是 **N 日变化量**（带符号），不是绝对值 —— 绝对值取决于起点，没有意义
    private var obvText: String {
        guard let v = indicators.obvChange else { return "—" }
        return (v >= 0 ? "+" : "−") + StockFmt.volume(abs(v))
    }

    private func biasText(_ period: Int) -> String {
        guard let v = indicators.bias[period] else { return "—" }
        return String(format: "%+.2f%%", v)
    }

    /// 口径行：四个指标各有一个"看起来等价其实不同"的坑，逐个写出来。
    private var indicatorCaliber: String {
        "用图上日K现算（不额外发请求）—— 与 K 线形态卡同一份日K（patternBars，取末 120 根）。"
            + "⚠ ATR 的真实波幅含「跳空」（max(高−低, |高−昨收|, |低−昨收|)），"
            + "与「次日高低点区间」卡用的「振幅」（只看当日区间）「不是同一个数」 —— 跳空日会明显分叉。"
            + "OBV 给的是 「20 日变化量」（绝对值取决于起点，没有意义）。"
            + "BIAS = (收盘−MA_n)/MA_n，与加减分明细里的「偏离均线」"
            + "（|MA5−MA10|/MA10，量的是「均线之间」）「不是同一个量」。"
            + "⚠ MFI 的 80/20 是传统参考线，不是本项目的判据"
            + "（固定阈值买卖信号已被明确否决）。"
            + "四项「均不参与评分」 —— 方向尚未标定。"
    }

    // MARK: 早盘抢筹

    /// 早盘窗口（09:30~10:00）的量能结构 —— **只展示、不进评分**。
    ///
    /// ⚠ 与「尾盘结构」是**同一份 5 分钟线**、但**口径不同**（不是同一张卡的两个数）：
    /// 尾盘卡的基准是"当日已交易平均"，那套口径在早盘**不成立** ——
    /// 10:00 时窗口 == 全天已交易时段，比值**恒等于 1**。
    /// 所以这里用**跨日同窗口对比**：今日早盘量 ÷ 前 N 日**同时段**均量。
    private var morningWindow: IntradayFeaturesCalc.MorningWindow? {
        guard !intradayRawBars.isEmpty, !intradayDay.isEmpty else { return nil }
        return IntradayFeaturesCalc.morningWindow(intradayRawBars, today: intradayDay)
    }

    @ViewBuilder
    var morningCard: some View {
        if let w = morningWindow {
            Card("早盘抢筹", subtitle: morningSubtitle(w)) {
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)],
                              spacing: 8) {
                        metricCell("早盘量比", StockFmt.num(w.volRatioVsPriorDays))
                        metricCell("早盘占当日", w.volShareOfDay.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                        metricCell("早盘涨幅", w.gainPct.map { String(format: "%+.2f%%", $0) } ?? "—")
                        metricCell("早盘新高", w.newHigh ? "是" : "否")
                    }
                    CaliberTip(text: morningCaliber(w), title: "早盘抢筹口径")
                        .font(AppFont.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func morningSubtitle(_ w: IntradayFeaturesCalc.MorningWindow) -> String {
        "\(intradayDay) \(w.from)~\(w.to) · 截止 \(w.lastTime) · \(w.bars) 根 5 分钟线"
    }

    /// 口径行 —— 早盘量比的基准与尾盘卡**不同**，这件事必须写在界面上，
    /// 否则用户会把两张卡的数字当成同一个东西。
    private func morningCaliber(_ w: IntradayFeaturesCalc.MorningWindow) -> String {
        let ratioNote = w.priorDays > 0
            ? "早盘量比 = 今日早盘量 ÷ 前 \(w.priorDays) 个交易日同时段均量"
                + "（跨日同窗口对比，不受日内成交量 U 形分布影响）"
            : "⚠ 数据里只有这一天，「算不出早盘量比」（不拿 1.0 冒充）"
        return "与「尾盘结构」共用同一份 5 分钟线，但「基准不同」 —— "
            + "尾盘那张用「当日已交易平均」，在早盘会「恒等于 1」（10:00 时窗口就是全天）。"
            + ratioNote + "。"
            + "「早盘占当日」的分母是「当日全部」成交（⚠ 盘中看时其实是「至今」）。"
            + "只展示、不进评分。"
    }

    // MARK: 涨停统计

    /// 最近一次涨停的记录 —— **只展示、不进评分**。
    ///
    /// ⚠ 表只覆盖**最近约 10 余个交易日**（东财涨停池的源限制）
    /// → 卡上必须写「库内最近 N 个交易日」，否则"没有记录"会被读成"从来没涨停过"。
    /// ⚠ 库里**一天都没有**（任务还没跑过）→ **整张卡不显示**（`EmptyView`）——
    /// 显示"没有涨停记录"会让人以为"抓过了，确实没涨停"，而真相是"还没抓"。
    @ViewBuilder
    var limitUpCard: some View {
        if limitUpCoveredDays > 0 { limitUpCardBody }
    }

    private var limitUpCardBody: some View {
        Card("涨停统计", subtitle: limitUpSubtitle) {
            VStack(alignment: .leading, spacing: 8) {
                if let r = limitUpRecord {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)],
                              spacing: 8) {
                        metricCell("最近涨停", r.date)
                        metricCell("连板", r.streakText)
                        metricCell("首次封板", r.firstSeal.isEmpty ? "—" : r.firstSeal)
                        metricCell("炸板次数", "\(r.brokenCount) 次")
                        metricCell("封板资金", StockFmt.turnover(r.sealFund / 10000))
                        metricCell("行业", r.industry.isEmpty ? "—" : r.industry)
                    }
                    CaliberTip(text: "数据来自东财涨停池（收盘后抓取）。⚠ 「涨停原因」拿不到"
                               + "（东财无公开报表、同花顺的该字段实测为空），所以这里给的是"
                               + "结构化的「为什么涨」 —— 连板数 / N 天 M 板 / 首末封板时间 / "
                               + "炸板次数 / 行业 / 封板资金。只展示、不进评分。",
                               title: "涨停池口径")
                } else {
                    // ⚠ 不用 `**`：这一句带插值，虽然仍走 LocalizedStringKey，但为免踩
                    //   "拼出来就变 String" 那条坑，统一用「」
                    Text("库内最近 \(limitUpCoveredDays) 个交易日「没有」该股的涨停记录")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var limitUpSubtitle: String {
        let cov = "库内最近 \(limitUpCoveredDays) 个交易日"
        guard let r = limitUpRecord else { return cov }
        return "\(r.date) · \(cov)"
    }

    /// 读库（后台线程、自持只读连接）—— 涨停池由收盘后的调度任务落库，**不需要现取**。
    ///
    /// ⚠ 走 `LimitUpPoolStore` 的自持只读连接（不是 `SQLiteReader.shared`）——
    /// 那个是主线程专用的共享连接，而本 Store 的读要能从任意线程调（调度任务也在用）。
    func loadLimitUp() async {
        let targetCode = code
        let (covered, record) = await Task.detached(priority: .userInitiated) {
            (LimitUpPoolStore.days().count, LimitUpPoolStore.latestRecord(code: targetCode))
        }.value
        guard !Task.isCancelled, targetCode == code else { return }
        limitUpCoveredDays = covered
        limitUpRecord = record
    }

    // MARK: 回撤风险

    /// 近 60 个交易日的回撤结构 —— **只展示、不参与筛选**。
    ///
    /// ⚠ 与「筹码分布」那张卡的「距高点」**不是同一个量**：
    /// 那个量的是**下跌侧**（现价距 60 日最高收盘，防接刀），
    /// 这张量的是**上涨侧**（首收→末收的累计涨幅，防追高）。
    /// 一只"就在最高点"的票在那边看起来毫无风险，在这边可能已经涨了 300%。
    private var drawdown: DeepDrawdown.Stats? {
        DeepDrawdown.stats(patternBars)
    }

    @ViewBuilder
    var drawdownCard: some View {
        if let s = drawdown {
            Card("回撤风险", subtitle: drawdownSubtitle(s)) {
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)],
                              spacing: 8) {
                        metricCell("\(s.days) 日累计涨幅", s.cumGain.map {
                            String(format: "%+.2f%%", $0)
                        } ?? "—")
                        metricCell("最大单日跌幅", maxDropText(s))
                    }
                    HStack(spacing: 4) {
                        Image(systemName: s.clean ? "checkmark.circle.fill"
                                                  : "exclamationmark.triangle.fill")
                            .foregroundStyle(s.clean ? AnyShapeStyle(Sem.down)
                                                     : AnyShapeStyle(Sem.warn))
                        Text(s.clean ? "满足「无大幅回撤」" : "不满足「无大幅回撤」")
                            .font(.callout)
                    }
                    CaliberTip(text: drawdownCaliber(s), title: "回撤风险口径")
                        .font(AppFont.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// ⚠ `maxDrop1d` 是**正值**表示"跌了多少"；展示时取负号变成直觉上的"当日涨跌"
    /// （跌 9.2% 显示 `-9.20%`；最差的一天若仍在涨，显示 `+0.50%`）。
    private func maxDropText(_ s: DeepDrawdown.Stats) -> String {
        guard let d = s.maxDrop1d else { return "—" }
        let txt = String(format: "%+.2f%%", -d)
        return s.maxDropAgoBars > 0 ? "\(txt)（\(s.maxDropAgoBars) 根前）" : txt
    }

    private func drawdownSubtitle(_ s: DeepDrawdown.Stats) -> String {
        let day = patternBars.last?.date ?? "—"
        return "\(day) · 近 \(s.days) 个交易日（\(s.bars) 根日K）· 只展示，不参与筛选"
    }

    private func drawdownCaliber(_ s: DeepDrawdown.Stats) -> String {
        "「无大幅回撤」 = 区间累计涨幅 ≤ "
            + String(format: "%.0f%%", DeepDrawdown.defaultCumGainLimit)
            + " 「且」 无单日跌超 "
            + String(format: "%.0f%%", DeepDrawdown.defaultMaxDropLimit) + "。"
            + "全程「收盘对收盘」（与评分里的「5 日累计涨幅」同口径）。"
            + "⚠ 与「距高点」「不是同一个量」 —— 那个量下跌侧（防接刀），这个量上涨侧（防追高）；"
            + "一只就在最高点的票可能已经涨了 300%。"
            + "⚠ 本卡仅作风险提示展示，不参与筛选；方向尚未标定，仅供参考。"
    }
}
