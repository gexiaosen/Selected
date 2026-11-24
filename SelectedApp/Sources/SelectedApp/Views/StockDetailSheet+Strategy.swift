import SwiftUI
import SwiftTradingView
import SelectedCore

// MARK: - 详情页卡片（二）：策略命中 → 超买超卖 → 基本面 → 资金流向 → 龙虎榜 → 尾盘结构

extension StockDetailSheet {
    // MARK: 策略命中

    /// 六条**独立选股策略**的命中情况（InStock 模块 7）。
    ///
    /// ⚠ **只展示 —— 不参与评分、不参与筛选**，两条理由都很硬：
    /// 1. **清单自己警告过**：「每一条都是独立策略，需逐个回测验证，**不能直接信 README**」，
    ///    而这里实现的六条条件**正是从那份 README 抄的**（清单没有 InStock 的源码）
    ///    → 零标定下让它们影响选股 = **凭直觉给分**。
    /// 2. 落成排除/加分项只能"新参数 + 默认关"，而"默认关的旋钮"是本项目反复踩的坑。
    ///
    /// ⚠ **"未评估"与"未命中"必须分开显示**：日K不够 / 上市不满时该条判据**根本没跑**，
    /// 混进"未命中"会让界面显示"这只票不符合海龟法则"，而真相是"**我们没能力判断**"。
    ///
    /// ⚠ 用图上日K现算（不额外发请求），与形态卡同一份 bar 集
    /// （都过一遍 `dropUnformedTail` —— 开盘前腾讯会给一根 high/low 全 0 的"当日占位 bar"）。
    ///
    /// ⚠ 两条策略（回踩年线要 MA250、低 ATR 要 250 根）**引擎侧算不出来**
    /// （`datalen` 只有 65）→ 这也是本卡只能落在详情页的原因之一。
    @ViewBuilder
    var strategyCard: some View {
        if dailyKlineLoading || !dailyBars.isEmpty {
            Card("策略命中", subtitle: strategySubtitle) {
                if let r = strategyOutcome {
                    VStack(alignment: .leading, spacing: 9) {
                        // ⚠⚠ 2026-11-19（老板要求）：**6 条全列 + 逐条标状态**。
                        //   原实现只在"有命中"时列命中行，全未命中时只给一句
                        //   「未命中这 6 条策略中的任何一条」—— 用户看不到
                        //   **是哪 6 条**、也看不到**每条各自什么状态**，
                        //   只能去翻口径猜判据是什么。
                        //   ⇒ 现在无论命中与否，6 条一律列出来，每条前面放状态徽章。
                        //
                        // ⚠ **状态是三态，不是两态**（`Outcome` 的设计就这样）：
                        //   · 命中 —— `r.hits` 里有它（带依据 note）
                        //   · 未命中 —— 评估过但不符合
                        //   · 未评估 —— 数据不够，**判据根本没跑**（`r.skipped`）
                        //   把「未评估」混进「未命中」会让界面显示成"这只票不符合海龟法则"，
                        //   而真相是"我们没能力判断" —— 这正是 `Outcome` 注释警告的事。
                        //   ⇒ 三态各自有独立徽章，颜色也不同（命中用 `Sem.up`、
                        //     未命中用 `Tok.dim`、未评估用 `Sem.warn`）。
                        ForEach(StrategySignals.Kind.allCases, id: \.rawValue) { kind in
                            strategyKindRow(kind, outcome: r)
                        }
                        // 汇总行：只在「一条都没命中」时给，说清今天的结论。
                        // ⚠ 放在列表**之后**：先看到每条的状态，再看结论，顺序才对。
                        if r.hits.isEmpty {
                            Text(hitSummaryText(r))
                                .font(AppFont.detailSmall)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                        }
                        CaliberTip(text: strategyCaliber, title: "策略口径")
                            .font(AppFont.detail).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if dailyKlineLoading {
                    // 骨架与命中行等高，避免加载完成时跳动（与形态卡同款）
                    VStack(alignment: .leading, spacing: 9) {
                        RoundedRectangle(cornerRadius: 4).fill(Tok.skeleton).frame(height: 15)
                        RoundedRectangle(cornerRadius: 4).fill(Tok.skeleton).frame(height: 15)
                    }
                } else {
                    // ⚠ 说清"为什么"：走到 else 只有一种可能 —— **一根日K都没有**
                    //   （`strategyOutcome` 在 `dailyBars.isEmpty` 时返回 nil）。
                    //   "有日K但不够"不走这里：那时 6 条策略各自把
                    //   「日K不足（有 N 根，需要 M 根）」写进 `skipped`，在下方"未评估"组逐条显示。
                    Text("没有日K数据，无法评估这 6 条策略")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// **两组日K判据共用**的 bar 集（形态 / 策略 / 超买超卖同一份）：
    /// 只剔"全零占位 bar"，**不剔盘中那根未完成的**
    /// （判的是"此刻是什么状态"，用最新价当收盘是合理口径；口径写在卡片上）
    ///
    /// ⚠ 读 `dailyKline`（**与图表周期解耦**）而不是图表上的 `kline`：
    ///   图表默认是分时，`kline` 那时为空 —— 按 `period == .daily` 门控会让这些卡默认整批消失。
    var dailyBars: [KLineItem] {
        KLinePatterns.dropUnformedTail(dailyKline)
    }

    private var strategyOutcome: StrategySignals.Outcome? {
        guard !dailyBars.isEmpty else { return nil }
        // ⚠ **不传 `listedDays`** → 用**交易日数**（= 日K根数）判"上市 ≥N 日"。
        //   口径说明见 `StrategySignals.evaluate` 的参数注释（有意不用自然日，
        //   否则同一个 250 会在两条数据路径上差出 4 个月）。
        return StrategySignals.evaluate(dailyBars)
    }

    /// 没评估的那几条，按 `allCases` 顺序（`ForEach` 的 id 才稳定）
    private var strategySkippedKinds: [StrategySignals.Kind] {
        guard let r = strategyOutcome else { return [] }
        return StrategySignals.Kind.allCases.filter { r.skipped[$0] != nil }
    }

    private var strategySubtitle: String {
        guard let r = strategyOutcome else { return "" }
        if r.hits.isEmpty {
            return r.skipped.count == StrategySignals.Kind.allCases.count ? "无法评估" : "未命中"
        }
        return "命中 \(r.hits.count)/\(StrategySignals.Kind.allCases.count)"
    }

    /// **单条策略的行**（2026-11-19 新增，替代原 `strategyRow`）。
    ///
    /// 三态各自的样子：
    /// · **命中** —— 红点 + 「命中」徽章（`Sem.up`，A股语义=涨）+ 依据正文（`Hit.note`）
    /// · **未命中** —— 空心灰点 + 灰字，无第二行（不需要解释"为什么不符合"，
    ///   每条判据都有 4~6 个条件，逐条解释会把这张卡撑成一页）
    /// · **未评估** —— 橙点 + 「未评估」徽章（`Sem.warn`）+ 原因（`skipped` 的文案，
    ///   如「日K不足（有 30 根，需要 250 根）」）
    ///
    /// ⚠ **未命中行不置灰到看不见**：用 `Tok.dim` 而不是 `opacity(0.5)` ——
    ///   前者是主题定义的"附属信息"色，后者在深色主题下会糊成一片。
    /// ⚠ 状态点用 `Circle` 而不是 SF Symbol：三种状态只需区分"实心/空心/颜色"，
    ///   用图标反而要记三个图标的形状含义。
    @ViewBuilder
    private func strategyKindRow(_ kind: StrategySignals.Kind,
                                 outcome: StrategySignals.Outcome) -> some View {
        let hit = outcome.hits.first { $0.kind == kind }
        let skipReason = outcome.skipped[kind]
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // 状态点：命中=实心红、未命中=空心灰、未评估=实心橙
                if hit != nil {
                    Circle().fill(Sem.up).frame(width: 5, height: 5)
                } else if skipReason != nil {
                    Circle().fill(Sem.warn).frame(width: 5, height: 5)
                } else {
                    Circle().strokeBorder(Tok.dim, lineWidth: 1).frame(width: 5, height: 5)
                }
                Text(kind.title)
                    .font(.caption)
                    .fontWeight(hit != nil ? .medium : .regular)
                    .foregroundStyle(hit != nil ? AnyShapeStyle(.primary) : AnyShapeStyle(Tok.dim))
                Spacer(minLength: 0)
                // 状态徽章（未命中不挂徽章 —— 「没有标记」本身就是最轻的标记）
                if hit != nil {
                    statePill("命中", color: Sem.up)
                } else if skipReason != nil {
                    statePill("未评估", color: Sem.warn)
                }
            }
            // 第二行：命中的依据 / 未评估的原因。未命中不需要。
            if let hit {
                Text(hit.note)
                    .font(AppFont.detailSmall).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let skipReason {
                Text(skipReason)
                    .font(AppFont.detailSmall).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 极小的状态徽章（这张卡内部专用 —— 全 App 的徽章各有语义，不要再往外抽）。
    private func statePill(_ text: String, color: Color) -> some View {
        Text(text)
            // ⚠ 字号/底色都走项目出口（护栏 `font_outlet` / `theme_tint` 盯着）：
            //   · 字号 → `AppFont.micro`（= 9pt，就是 .system(size: 9) 的唯一出口）
            //   · 语义色底 → `Tok.tint(...)`（它额外处理「提高对比度」档位，
            //     直接写 `color.opacity(0.12)` 在 HC 模式下会不够显眼）
            .font(AppFont.micro.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Tok.tint(color), in: Capsule())
    }

    /// 「一条都没命中」时的结论句。
    /// ⚠ **必须区分"全都未评估"** —— 那说明是数据不够，不是这只票不符合 6 条策略。
    private func hitSummaryText(_ r: StrategySignals.Outcome) -> String {
        let day = dailyBars.last?.date ?? ""
        let total = StrategySignals.Kind.allCases.count
        if r.skipped.count == total {
            return "\(day) 这 \(total) 条策略全部未评估（日K 不够）—— 不是不符合，是判断不了"
        }
        if r.skipped.isEmpty {
            return "\(day) 未命中这 \(total) 条策略中的任何一条"
        }
        return "\(day) 未命中 \(total - r.skipped.count) 条已评估的策略；"
            + "另有 \(r.skipped.count) 条因数据不够未评估"
    }

    private var strategyCaliber: String {
        let c = StrategySignals.Config()
        return "图上日K现算（不额外发请求），最后一根 = \(dailyBars.last?.date ?? "—")"
            + " · 「上市 ≥\(c.flagMinListedDays) / \(c.lowAtrMinListedDays) 日」按「交易日数」"
            + "（= 日K根数）算，不是自然日"
            + " · 本卡只展示 —— 这 6 条策略条件采用默认阈值、尚未经过历史标定，"
            + "不参与评分、不参与筛选"
            + " · 六条「互不排斥」（可同时命中，与 12 个形态的互斥设计相反）；"
            + "放量倍数与小涨上限采用默认设置，仅供参考。"
    }

    // MARK: 尾盘结构

    /// 尾盘结构：**尾盘（默认最后 30 分钟）是在放量抢筹还是在缩量**。
    ///
    /// ⚠ 与前三张卡（筹码 / 资金流 / 龙虎榜）**性质不同**：那三张是"只展示、不参与评分"，
    /// 而尾盘结构**本身就是引擎打分的输入**（`Screener.swift`：尾盘量比 ≥1.5 → +12 分、
    /// 收盘位置 ≥0.9 → +8 分、尾盘创新高 → +10 分）。所以口径行**不能**写"不参与评分" —— 那是假话。
    ///
    /// ## 口径（必须写在界面上）
    ///
    /// · **尾盘窗口 = "已交易时段的最后 N 分钟"**，不是固定的 14:30–15:00 ——
    ///   否则 14:00 那轮窗口为空、14:50 那轮只走 2/3，三轮不可比（引擎的设计，本卡沿用）
    /// · `尾盘量能` 是**相对全日强度的倍数**：1.00x = 与全日平均一致，越大越放量
    /// · `收盘位置` = (价 − 当日最低) ÷ (当日最高 − 当日最低)，1.00 = 收在当日最高
    ///
    /// ## 数据从哪来
    ///
    /// 按需取一次 5 分钟线（新浪 `datalen=240` ≈ **最近 5 个交易日**，单只 1 个请求，60s TTL 缓存）。
    /// **不复用扫描当时算好的值**（那个在 `deep_info.intraday` 里）：扫描在 14:00/14:30/14:50 跑，
    /// 尾盘窗口当时**还没走完**；而详情页多在盘后打开，拿到的是**完整**的尾盘窗口。
    /// 两者口径相同、**时点不同** → 卡片按需重算，并在口径里写明时点。
    @ViewBuilder
    var intradayCard: some View {
        // 非 `securities` 成员（ETF / 指数）不显示：引擎的尾盘结构只对 A 股个股算（与扫描池同集合）。
        // 用 `EmptyView` 而不是"显示一张空卡"—— 后者会让人以为"这只票没有分时数据"。
        if !intradayUnsupported { intradayCardBody }
    }

    private var intradayCardBody: some View {
        Card("尾盘结构", subtitle: intradaySubtitle) {
            if let f = intraday {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 14) {
                        plainCell("尾盘量能", ratioText(f.tailVolRatio))
                        flowCell("尾盘涨幅", signedPct(f.tailGainPct), (f.tailGainPct ?? 0) >= 0)
                        plainCell("收盘位置", posText(f.closePosition))
                        plainCell("尾盘量占比", shareText(f.tailVolShare))
                    }
                    HStack(spacing: 8) {
                        if f.tailNewHigh { miniBadge("尾盘创新高", Sem.up) }
                        Text("日内高点 \(f.dayHighTime.isEmpty ? "—" : f.dayHighTime)"
                             + "（\(bucketText(f.highBucket))）")
                            .font(AppFont.detail).foregroundStyle(.secondary)
                        if let a = f.highAgeRatio {
                            Text("· 高点距今 \(Int((a * 100).rounded()))% 交易时长")
                                .font(AppFont.detail).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    CaliberTip(text: intradayCaliber(f), title: "尾盘结构口径")
                        .font(AppFont.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if intradayLoading {
                // 骨架用与数字块**逐行等高**的占位，避免加载完成时跳动（与 chipCard / 资金流同款）
                VStack(alignment: .leading, spacing: 9) {
                    RoundedRectangle(cornerRadius: 4).fill(Tok.skeleton).frame(height: 30)
                    RoundedRectangle(cornerRadius: 4).fill(Tok.skeleton).frame(height: 16)
                }
            } else {
                // ⚠ 走到这里说明**窗口内没有任何一天**够 `minBars`（`pickLatest` 已经优先挑过
                //   够算的那天了），所以要按"近几个交易日都不足"来说，而不是"今天没有数据"
                Text("暂无分时数据 · 近几个交易日的 5 分钟线均不足 \(intradayMinBars) 根")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var intradaySubtitle: String {
        guard let f = intraday else { return "" }
        return "\(intradayDay) · 尾盘 \(f.tailStart)–\(f.lastBarTime)"
            + (intradayLive ? "" : " · 非实时")
    }

    /// 口径行。⚠ 尾盘结构**参与打分**（不像筹码 / 资金流 / 龙虎榜），所以这里不能说"只展示"。
    private func intradayCaliber(_ f: IntradayFeatures) -> String {
        let src = intradayLive ? "行情用实时值" : "行情由 \(intradayDay) 当日 5 分钟线重建"
        return "尾盘 = 已交易时段的最后 \(f.tailWindowMin) 分钟"
            + "（\(f.tailStart)–\(f.lastBarTime)，当日共 \(f.barsToday) 根）"
            + " · 尾盘量能 = 尾盘成交强度 ÷ 全日平均强度（1.00x = 与全日持平）"
            + " · \(src)。⚠ 尾盘结构「是引擎打分的输入」，本卡与打分同口径，"
            + "但为「按需重算」 —— 扫描在 \(ScheduleTimes.shared.roundClocks.joined(separator: "/")) 跑，那时尾盘窗口尚未走完，值可能不同。"
    }

    /// 倍数（尾盘量能）：基值 1.00 是"与全日平均一致"，所以必须带 `x`，不能只给数字
    private func ratioText(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.2fx", v)
    }

    /// 带正负号的百分比（尾盘涨幅的方向不能省）
    private func signedPct(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%+.2f%%", v)
    }

    /// 0–1 分位，保留 2 位（1.00 = 收在当日最高）
    private func posText(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.2f", v)
    }

    /// 占比 0–1 → 百分数。⚠ 这个字段是**小数**（`tail_vol_share`），
    /// 与东财龙虎榜的 `*_RATIO`（已是百分数）**相反** —— 两处别串了。
    private func shareText(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f%%", v * 100)
    }

    /// 日内最高价出现的时段（引擎给的是 morning / midday / tail）
    private func bucketText(_ b: String) -> String {
        switch b {
        case "morning": return "早盘"
        case "midday": return "盘中"
        case "tail": return "尾盘"
        default: return "—"
        }
    }

    /// 读尾盘结构：**按需取一次 5 分钟线**（不落库 —— 5 分钟线本身可随时重取）。
    ///
    /// ⚠ 窗口与门槛取**激活参数**（与引擎打分同源），读不到才回落引擎默认值 30 / 20；
    /// 参数改了本卡跟着变，所以口径行把**实际用的窗口**写出来。
    func loadIntraday() async {
        intradayLoading = true
        // 口径闸门：引擎的尾盘结构只对 `securities` 里的 A 股个股算（与扫描池同集合）
        guard FundFlowStore.isKnownStock(code) else {
            intradayUnsupported = true
            intraday = nil
            intradayLoading = false
            return
        }
        intradayUnsupported = false

        let cfg = (ParamStore.shared.activeParams()?["scoring"] as? [String: Any])?["intraday"]
            as? [String: Any] ?? [:]
        let windowMin = (cfg["tail_window_min"] as? Int) ?? 30
        let minBars = (cfg["min_bars"] as? Int) ?? 20
        intradayWindowMin = windowMin
        intradayMinBars = minBars

        // 取数放后台：单只 1 个请求；缓存与限速都已在 `fetch5minBars` 内部处理
        let bars = await Task.detached(priority: .utility) {
            DataSources.fetch5minBars(code)
        }.value
        guard !Task.isCancelled else { return }

        // 取数返回后再读最新 quote：首帧并发的 QuoteAPI.single 可能已在途中到达
        var live: EngineQuote?
        if let q = quote {
            var eq = EngineQuote()
            eq.code = code
            eq.price = q.currentPrice
            eq.volume = q.volume          // 手
            live = eq
        }

        guard let picked = IntradayDigest.pickLatest(bars, today: ChinaTime.day(),
                                                     liveQuote: live, minBars: minBars) else {
            intraday = nil
            intradayDay = ""
            intradayLive = false
            intradayRawBars = []
            intradayLoading = false
            return
        }
        // ⚠ 原始 bars 在**任何早退之前**存下来（早盘窗口要用前几天的 bar）
        intradayRawBars = bars
        intradayDay = picked.day
        intradayLive = picked.usedLiveQuote
        intraday = IntradayFeaturesCalc.compute(picked.bars, today: picked.day,
                                                quote: picked.quote,
                                                minBars: minBars, tailWindowMin: windowMin)
        intradayLoading = false
    }

    /// 行情晚于 `loadIntraday` 到达且此前是降级重建时，直接拿缓存的 5 分钟线重算，不再重拉网络。
    func refreshIntradayWithQuoteIfNeeded() {
        guard !intradayLive,
              !intradayRawBars.isEmpty,
              let q = quote,
              q.currentPrice != 0 || q.volume != 0 else { return }
        let today = ChinaTime.day()
        guard intradayDay == today else { return }
        var eq = EngineQuote()
        eq.code = code
        eq.price = q.currentPrice
        eq.volume = q.volume
        guard let picked = IntradayDigest.pickLatest(intradayRawBars, today: today,
                                                     liveQuote: eq, minBars: intradayMinBars),
              picked.usedLiveQuote else { return }
        intradayDay = picked.day
        intradayLive = picked.usedLiveQuote
        intraday = IntradayFeaturesCalc.compute(picked.bars, today: picked.day,
                                                quote: picked.quote,
                                                minBars: intradayMinBars,
                                                tailWindowMin: intradayWindowMin)
    }

    /// 只读查询：原生取数 + 计算（与「次日区间」弹窗共用同一入口）。
    ///
    /// ⚠ 必须保持 `async` 并由 `.task(id: code)` 直接 await：若内部裸起 `Task {}`，
    /// `.task(id:)` 在同步函数返回后**立刻**结束并取消自己的任务 —— 那个内层 Task 不继承取消，
    /// 弹窗关掉后仍会写已消失视图的 `@State`。
    func loadForecast() async {
        fcLoading = true
        fcError = nil
        fc = nil
        let out = await ForecastEngine.fetchAndForecast(code: code, name: stockName)
        guard !Task.isCancelled else { return }        // 弹窗已关：不再写状态
        guard let out else {
            fcLoading = false
            fcError = "\(code) 的日K线取数失败（数据源异常或代码无效）"
            return
        }
        fcLoading = false
        if out.status == "insufficient_data" {
            fcError = out.dataError.isEmpty ? "-" : out.dataError
            return
        }
        fc = out
    }

    // MARK: - 图表首帧遮罩（防「打开/切周期时画面整段跳」）

/// 图表**首帧遮住**：库的 `scrollViewProxy.didSet` 会 `scrollTo("chartEnd", anchor: .trailing)`，
/// 而那是**首帧之后**才生效的滚动 —— 若那一帧可见，画面会从"最早一根"整段跳到最新一根。
///
/// ## ⚠ 遮罩状态必须放在**这个子视图**里
///
/// 若状态挂在页面（`StockDetailSheet`）的 `@State` 上，会**跨图表重建存活**：
/// 切周期时 `.id(period)` 造出**新图表**，而旧状态仍是上一张图的 `true`
/// ⇒ 新图**第一帧就是可见的**（且此时库还没滚到最右）⇒ 用户看到跳动。
/// ⇒ 把状态搬进子视图、`.id(period)` 放在**它外面** ⇒ 每次重建自动从"隐藏"起步。
///
/// ⚠ 与"数据变化"无关：prepend 更早历史（`kline` 变长）**不会**重建本视图 ⇒ 不会重新遮罩
///   （若把 `id` 挂到 `kline.count` 上，加载更早历史时图表会闪一下 —— 那正是别这么写的原因）。
/// ⚠ 这是**遮盖**不是根治（根治要改 vendored 库，仓库明确不 fork 它）—— 用户可见效果等价。
private struct ChartFirstFrameMask<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var painted = false

    var body: some View {
        content
            .opacity(painted ? 1 : 0)
            .task {
                painted = false
                // 让出一帧：等 ScrollView 完成首次布局、库的 onAppear 把 scrollTo 跑完。
                // 120ms ≈ 3~4 帧（实测库的滚动在图表出现后 ~30ms 落地），留够余量更稳。
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                painted = true
            }
    }
}

    // ⚠ 初蜡烛宽度**写死 8**（`kLineInitialCandleWidth`），**别改成"正好铺满视口"** ——
    //   铺满 ⇒ 内容没有滚动空间 ⇒ ScrollView 的 `scrollOffset` 初始就是 0（最左）
    //   ⇒ 触发库里「拖到最左自动加载更早历史」（`scrollOffset <= step * 3`）⇒ 不断追加根数、
    //   蜡烛宽度被越压越小 ⇒ 画面明显跳。写死 8 让内容远宽于视口 ⇒ 有滚动空间 ⇒
    //   库的 `scrollTo("chartEnd")` 把偏移贴到最右（≠ 0），不会误触发；
    //   首帧那一下滚动位移由 `ChartFirstFrameMask` 的 opacity 遮罩处理。
    //   ⚠ 判据：**"让内容正好铺满"这类尺寸优化，会改变"有没有滚动空间"这个隐含前提** ——
    //     而依赖"滚动位置"的逻辑会因此被误触发。改任何"初始尺寸"之前，先问：有谁在读滚动偏移？

    /// 图表右上角的降级标注（数据源/口径差异必须让人看得见）
    private var chartSourceNote: String {
        if period == .minute {
            return chartMinuteFallback ? "东财分时兜底" : ""
        }
        // 文案跟着**实际走的那条链路**：同花顺是前复权（只是根数少）、新浪是不复权（有除权跳空），
        // 两条共用一句"不复权"会把前者说错。
        switch chartKLineSource {
        case .ths: return "同花顺兜底·前复权"
        case .sina: return chartKLineAdjusted ? "" : "新浪兜底·不复权"
        case .tencent, nil: return ""
        }
    }

    var chartCard: some View {
        // 用主页面同款 Card 承载（tab 承担标题职责，故不再重复标题）
        Card {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(KLinePeriod.allCases, id: \.self) { p in
                    Button {
                        period = p
                        // ⚠ 切周期会重建图表（`.id(period)`），库随即在首帧报一次「偏移≈0」
                        //   → 必须**同步上锁**（`rearmLoadEarlier` 把 `allowLoadEarlier` 置 false）。
                        //   ⚠ 别只靠 `.onChange(of: period)`：那个 handler 在重建那一帧之后才跑，
                        //     库的回调可能抢在前面 ⇒ 白拉一页。
                        rearmLoadEarlier()
                    } label: {
                        // ⚠ padding / background 必须挂在 **label 里面**：挂到 Button 外面时
                        //   胶囊的色块只是"画在按钮外面"，命中区仍只有文字 ⇒ 要点正中才生效
                        //   （2026-11-02 他实测反馈"可点击范围只有文字"）。
                        //   收口写法与 `ParamsCenterView` 的域导航一致：内容 → padding → 底色 → contentShape。
                        Text(p.displayName)
                            .font(AppFont.detail.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(
                                period == p ? AnyShapeStyle(Sem.brand) : AnyShapeStyle(Tok.chip),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .foregroundStyle(period == p ? Tok.onAccent : .secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                // 数据源降级如实标注（口径差异必须让人看得见）：
                // · 分时 → 东财兜底；· K 线 → 新浪不复权兜底
                Text(chartLoading ? "加载中…" : chartSourceNote)
                    .font(.caption2).foregroundStyle(.secondary)
            }

            // 图表 + 右侧盘口列。⚠ `chartWidth` 量的是**图表那一侧**：
            //   加了 168pt 的右列之后，整行宽度与图表可视宽度不再相等，
            //   所以测量点必须留在 `chartBody` 上（移到外层会让首帧按错的宽度画一版）。
            HStack(alignment: .top, spacing: 12) {
                chartBody
                    .frame(maxWidth: .infinity)
                    // ⚠ 测量点跟着图表那一侧走：`chartWidth == 0` 前不渲染图表（见 `chartBody`），
                    //   挂到整行会让"右列宽度"混进图表宽度里。
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chartWidth = $0 }
                if bookColumnVisible { orderBookColumn }
            }
        }
        }
    }

    /// 图表本体（骨架 / 错误 / 图表三态，高度一律 340，互切不位移）
    @ViewBuilder
    private var chartBody: some View {
        // ⚠ `chartWidth == 0` 也走骨架屏：宽度还没量到就渲染图表，库会先按错的宽度画一版、
        //   布局完成后才被修正 → 视觉跳一下。多等一帧换"一次画对、不跳"。
        if chartLoading || chartWidth == 0 {
            // 骨架屏占位（项目约定不用全屏 spinner：它会让整块区域"消失"而不是"即将出现"）
            // ⚠ 高度必须与下方图表的 `.frame(height: 340)` **一致** ——
            //   不一致时切到图表整块内容会位移，看起来也是"跳一下"
            RoundedRectangle(cornerRadius: 8)
                .fill(Tok.skeleton)
                .frame(maxWidth: .infinity, minHeight: 340)
                .overlay(ProgressView().controlSize(.small))
        } else if let msg = chartError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2).foregroundStyle(Sem.warn)
                Text(msg).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("重试") { reloadToken += 1 }
                    .btnSecondary()
            }
            // ⚠ 高度与骨架屏 / 图表保持一致（340），避免三种状态互切时内容位移
            .frame(maxWidth: .infinity, minHeight: 340)
        } else {
            ChartFirstFrameMask {
                StockKLineChart(items: kline, minute: minute, period: period, code: code,
                            previousClose: quote?.previousClose,
                            hasMoreEarlier: hasMoreHistory,
                            // 分时的 240 槽要按实测图表宽铺满（右侧盘口列会把它挤窄）
                            chartWidth: chartWidth,
                            // ⚠ 必须挡住首帧的误触发（首帧 `scrollOffset` 必然是 0，
                            //   完整原因见 `allowLoadEarlier` 的注释）
                            onLoadEarlier: {
                                guard allowLoadEarlier else { return }
                                // ⚠ 句柄收口，详情页消失时取消（onDisappear 里 cancel；`loadEarlierHistory` 内也有取消检查）
                                loadEarlierTask = Task { await loadEarlierHistory() }
                            })
                    .frame(height: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            // 切换周期时重建图表：缩放级别回到首屏口径、画面停在最新一段
            // （否则库内滚动偏移会沿用上一周期的位置，可能出现"停在历史中段"）
            // ⚠ `.id(period)` 必须放在 `ChartFirstFrameMask` **外面** ——
            //   遮罩状态在子视图里，靠这次重建归位（见该类型注释）。
            .id(period)
        }
    }
}
