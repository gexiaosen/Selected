import SwiftUI
import Charts
import SelectedCore

// MARK: - 复盘验证（Swift Charts 原生图表）

struct WinrateRow: Identifiable {
    let id: String
    let name: String
    let winrate: Double
    let detail: String
    let isCore: Bool
}

struct ReviewView: View {
    private let store = Store.shared

    /// 复盘页"平均准确度"仪表的取色：门槛**读生效参数**（`store.tier1Min/tier2Min`），
    /// 读不到 → 中性灰**不表态** —— 与 `ScoreBadge` 的 nil 口径一致（不拿写死的数冒充门槛）。
    /// ⚠ `Int(avgScore)` 截断而非四舍五入：非负分数下 `x >= n ⟺ floor(x) >= n`（整数门槛 n），
    ///   与 Double 比较逐点等价，不引入边界漂移。
    private func accuracyGaugeTint(avgScore: Double, tier1: Int?, tier2: Int?) -> Color {
        guard let t1 = tier1, let t2 = tier2 else { return .secondary }
        return Sem.scoreColor(Int(avgScore), tier1: t1, tier2: t2)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageActionBar {
                DateChip()
                ActionBarButton(title: "复盘", isBusy: store.busy.contains("review"),
                                isDisabled: !(store.viewDate == store.today || store.viewDate == store.engineTargetSelDate),
                                helpText: (store.viewDate == store.today || store.viewDate == store.engineTargetSelDate)
                                    ? "重算引擎目标选股日（\(store.engineTargetSelDate ?? store.today)）的复盘；T+1 \(ScheduleTimes.shared.clock("review")) 自动执行，提前触发会产生非协议时点数据"
                                    : "该日非引擎复盘目标（目标为 \(store.engineTargetSelDate ?? "--")），不可重算") {
                    store.recomputeReview()
                }
            }
            FitScrollView {
                VStack(spacing: 14) {
                    // 重跑失败时旧复盘仍在屏上（`staleWhileBusy`），toast 走后就没人知道
                    //   这是旧数 —— 就近给口径说明 + 重试（见 `RunFailureBanner`）
                    if store.reviewReport?.isOK == true {
                        RunFailureBanner(key: "review",
                                         staleNote: "屏上仍是上一次成功的复盘，本次未更新",
                                         retryTitle: "重试复盘") {
                            store.recomputeReview()
                        }
                    }

                    // 判据是"有没有报告"而不是"在不在跑"：重跑期间旧复盘留在原位
                    //   （`staleWhileBusy`），进度由操作栏那颗「复盘」按钮的转圈承担。
                    if let rv = store.reviewReport, rv.isOK {
                        content(rv)
                            .staleWhileBusy(store.busy.contains("review"))
                    } else if store.busy.contains("review") {
                        LoadingView(text: "拉取5分钟K线计算四层胜率…", design: .composing)
                    } else if store.isPicklessSelDay {
                        // 空仓日：三轮均无入档信号，复盘/验证均无标的可算——页面级统一说明（验证区不再重复渲染）
                        VStack(spacing: 12) {
                            Card("空仓日", subtitle: "选股日 \(store.viewDate)") {
                                EmptyDayCard(
                                    detail: "该日三轮均无入档信号（一/二档为 0），复盘与盘中验证均无标的",
                                    footer: "空仓是有效的风控信号：未选出达标标的，本日不进场。空仓日复盘仍会在 T+1 \(ScheduleTimes.shared.clock("review")) 自动生成（记录近 N 日空仓占比统计）。")
                            }
                            RecentRecordHint(lead: "空仓日无复盘/验证明细，最近有入档信号的选股日") { d in
                                store.jump(toDate: d)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    } else {
                        VStack(spacing: 12) {
                            // 空态：预计生成时间 + 最近可查看跳转，两层即止
                            // （“请勿提前手动触发”已并入右上角按钮 tooltip，不在空态重复第三层描述）
                            PendingStageView(stageName: "复盘", eta: "T+1 \(ScheduleTimes.shared.clock("review"))")
                            RecentRecordHint(lead: "复盘在选股次一交易日 \(ScheduleTimes.shared.clock("review")) 生成") { d in
                                store.jump(toDate: d)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }

                    // 复盘未生成时验证必然也没有：两段"未生成"空态上下叠会让页面像坏了，
                    // 只在复盘报告就绪后渲染验证区（空仓日上方卡已说明，不重复）。
                    if store.reviewReport?.isOK == true, !store.isPicklessSelDay {
                        verifySection
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private func content(_ rv: ReviewResult) -> some View {
        // 空仓日：无入档标的，四层胜率/预判准确度无样本可算——直接说明空仓，不画全 0 空图
        if rv.isEmptyDay || rv.stocks.isEmpty {
            Card("复盘 · 空仓日", subtitle: "选股日 \(rv.selDateDash) · T+1 \(rv.reviewTimeDash) 复盘") {
                EmptyDayCard(
                    detail: "该选股日无入档标的（三轮均未选出达标股票），四层胜率与准确度无样本",
                    footer: "空仓是有效的风控信号：未选出达标标的，本日不进场。复盘记录保留大盘方向验证，空仓占比统计见历史迭代页。")
            }
            // 空仓复盘仍保留大盘方向验证（预判准确度里唯一有意义的项）
            let acc = rv.accuracy
            Card("预判准确度") {
                KVRow(key: "大盘方向", value: acc.marketHit ? "命中 ✓" : "未命中 ✗",
                      valueColor: acc.marketHit ? Sem.down : Sem.warn,
                      maxWidth: 700)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            if !rv.insights.isEmpty {
                Card("复盘洞察") {
                    ForEach(rv.insights, id: \.self) { t in
                        Label(t, systemImage: "lightbulb").font(.callout)
                    }
                }
            }
        } else {
        let fl = rv.fourLayerWinrate
        let acc = rv.accuracy
        let rows: [WinrateRow] = [
            .init(id: "snapshot", name: "快照 10:00", winrate: fl.snapshot.winrate,
                  detail: "\(fl.snapshot.wins)/\(fl.snapshot.total)", isCore: false),
            .init(id: "close", name: "收盘持有", winrate: fl.close.winrate,
                  detail: "\(fl.close.wins)/\(fl.close.total)", isCore: false),
            .init(id: "window", name: "窗口可用", winrate: fl.window.winrate,
                  detail: "\(fl.window.wins)/\(fl.window.total)", isCore: true),
            .init(id: "ceiling", name: "策略上限", winrate: fl.ceiling.winrate,
                  detail: "\(fl.ceiling.wins)/\(fl.ceiling.total)", isCore: false),
        ]

        Card("四层胜率", subtitle: "选股日 \(rv.selDateDash) · T+1 \(rv.reviewTimeDash) 复盘") {
            Chart(rows) { r in
                BarMark(
                    x: .value("胜率", r.winrate),
                    y: .value("层级", r.name)
                )
                .foregroundStyle(r.isCore ? AnyShapeStyle(Sem.accent.gradient) : AnyShapeStyle(Sem.info.gradient))
                .annotation(position: .trailing, alignment: .leading) {
                    Text("\(String(format: "%.1f", r.winrate))% (\(r.detail))")
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                .cornerRadius(4)
            }
            // ⚠ domain 到 112 而不是 100：100% 的柱会顶到绘图区右缘，
            //   `.trailing` 注解被视图边界裁掉（实测 “100.0%” 只剩 “100.0”）。
            //   留 12% 尾量给注解；刻度仍只画 0…100。
            .chartXScale(domain: 0...112)
            .chartXAxis {
                AxisMarks(values: [0, 25, 50, 75, 100])
            }
            .frame(height: 170)
        }

        Card("预判准确度") {
            HStack(spacing: 28) {
                // 准确度 gauge：0-100 环形进度（一眼读出水平）
                VStack(spacing: 4) {
                    Gauge(value: acc.avgScore, in: 0...100) {
                        Label("平均准确度", systemImage: "target")
                    } currentValueLabel: {
                        RollingNumber(acc.avgScore, format: "%.0f",
                                      font: .system(.title3, design: .rounded).bold())
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(accuracyGaugeTint(avgScore: acc.avgScore, tier1: store.tier1Min, tier2: store.tier2Min))
                    .frame(width: 84, height: 84)
                    Text("平均准确度 /100").font(.caption2).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    KVRow(key: "大盘方向", value: acc.marketHit ? "命中 ✓" : "未命中 ✗",
                          valueColor: acc.marketHit ? Sem.down : Sem.warn)
                    // 窗口命中率进度条（0-100 横条，颜色按 50% 分界）
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("窗口命中率").foregroundStyle(.secondary)
                            Spacer()
                            RollingNumber(acc.windowHitRate, format: "%.1f%%")
                        }
                        .font(.callout)
                        ProgressView(value: min(max(acc.windowHitRate, 0), 100), total: 100)
                            .progressViewStyle(.linear)
                            .tint(Sem.change(acc.windowHitRate >= 50 ? "good" : "bad"))
                    }
                    KVRow(key: "目标价偏差", value: "\(String(format: "%.2f", acc.avgTargetDiff))%")
                }
                .frame(maxWidth: 720, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
        // 尾部卡片「拉伸吞留白」：未消费的高度吸进卡片，页面底部不露白
        .frame(maxHeight: .infinity, alignment: .top)

        if let ref = rv.reference, !ref.isEmptyObject, let cw = ref.closeWinrateOrNil {
            Card("暴跌日参考数据") {
                KVRow(key: "假设持有到收盘胜率", value: "\(String(format: "%.1f", cw))%",
                      maxWidth: 720)
                KVRow(key: "策略上限胜率",
                      value: "\(String(format: "%.1f", ref.ceilingWinrate))%",
                      maxWidth: 720)
                Text("所有标的均不参与胜率统计——空仓观望是风控策略的正确执行")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        let stocks = rv.stocks
        if !stocks.isEmpty {
            Card("预测 vs 实际", subtitle: "\(stocks.count)只") {
                // ⚠ 单元格点击（stockDetailTap）须在 Table 内仍弹详情
                let cols = [
                    DataTableColumn("name", "标的"),
                    DataTableColumn("signal", "信号", width: 72),
                    DataTableColumn("window", "窗口盈亏", width: 88, alignment: .trailing, isNumeric: true),
                    DataTableColumn("close", "收盘盈亏", width: 88, alignment: .trailing, isNumeric: true),
                    DataTableColumn("high", "高点时间", width: 84, alignment: .trailing, isNumeric: true),
                    DataTableColumn("acc", "准确度", width: 64, alignment: .trailing, isNumeric: true),
                ]
                SharedDataTable(columns: cols, rows: stocks) { s, c in
                    switch c.id {
                    case "name":
                        Text(s.nameDash)
                            .lineLimit(1)
                            .stockDetailTap(code: s.code, name: s.nameDash)
                    case "signal":
                        Text(s.skipped ? "跳过" : SignalTag.label(for: SignalType(rawValue: s.signalType)))
                            .foregroundStyle(s.skipped ? Color.secondary : Color.primary)
                    case "window":
                        if s.skipped {
                            Text("不参与").foregroundStyle(.secondary)
                        } else {
                            PnlText(value: s.windowProfitOrNil)
                        }
                    case "close":
                        PnlText(value: s.closeProfitOrNil)
                    case "high":
                        Text(s.highTimeDash).monospacedDigit()
                    default:
                        Text("\(s.accuracyScore)").monospacedDigit()
                    }
                }
            }
        }

        if !rv.insights.isEmpty {
            Card("交叉分析洞察") {
                ForEach(rv.insights, id: \.self) { t in
                    Label(t, systemImage: "lightbulb").font(.callout)
                }
            }
        }
        }
    }

    // MARK: 盘中验证

    @ViewBuilder
    private var verifySection: some View {
        // 判据同复盘：有报告就让它留在原位（重跑期间 `staleWhileBusy` 淡化 + 禁交互），
        //   只有确实还没有报告时才占位。
        if let vf = store.verifyReport, vf.isOK {
            Group {
                if vf.isEmptyDay {
                    // 空仓日：无入档信号即无标的可验证，展示说明而非全 0 空卡
                    Card("盘中验证（T+1 10:00 快照）", subtitle: "选股日 \(vf.selDateDash) · 空仓日") {
                        EmptyDayCard(
                            detail: "该选股日无入档信号（全部标的未达入档线），无标的可验证",
                            footer: "空仓是有效的风控信号：三轮未选出达标标的，本日不进场。")
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    let stats = vf.stats
                    Card("盘中验证（T+1 10:00 快照）", subtitle: "选股日 \(vf.selDateDash) · T+1 \(vf.verifyTimeDash) 执行") {
                        HStack(spacing: 32) {
                            KVRow(key: "总体胜率",
                                  value: "\(String(format: "%.1f", stats.total.winrate))%")
                            KVRow(key: "持续信号",
                                  value: "\(String(format: "%.1f", stats.consensus.winrate))%")
                            KVRow(key: "脉冲信号",
                                  value: "\(String(format: "%.1f", stats.pulse.winrate))%")
                        }
                        ForEach(vf.warnings, id: \.self) { t in
                            ErrorView(message: t)
                        }
                        if !vf.deviations.isEmpty {
                            Text("预判偏离 \(vf.deviations.count) 只，详见引擎日志")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .staleWhileBusy(store.busy.contains("verify"))
        } else if store.busy.contains("verify") {
            LoadingView(text: "盘中验证…", design: .searching)
        } else {
            // 空态透明化：验证是 T+1 协议快照，仅自动触发（手动提前验证会产生非协议时点数据）
            PendingStageView(stageName: "验证", eta: "T+1 \(ScheduleTimes.shared.clock("verify"))")
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

// MARK: - 历史迭代（日期由全局 DateChip 控制，与其他页面联动）

struct HistoryView: View {
    private let store = Store.shared

    /// 四层胜率明细表是否展开（默认只显示最近 20 行 —— 范围开到"全部"时表格会很长）
    @State private var trendTableExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            PageActionBar {
                DateChip()
                ActionBarButton(title: "迭代", isBusy: store.busy.contains("iterate"),
                                isDisabled: store.isHistorical,
                                helpText: store.isHistorical ? "历史模式下不可重跑，请先回到最新交易日" : "三天迭代报告") {
                    store.recomputeIterate()
                }
            }

            FitScrollView {
                VStack(spacing: 14) {
                    // 四层胜率跨日走势（与复盘页同口径同四层）——先看趋势，再跳明细
                    winrateTrendCard
                    // 多观察窗（次日午前 vs 拿三天）——直接回答"哪个口径更对"
                    multiWindowCard
                    if let h = store.historyRecord {
                        // ⚠ 不在这里拉伸：历史卡不是尾卡，拉伸会把后面的迭代报告推到页面底部
                        //   （截图里表现为中间一整屏空白）。让内容自然排列，空白留在页尾。
                        historyCard(h)
                    } else {
                        VStack(spacing: 12) {
                            EmptyStateView(icon: "calendar.badge.exclamationmark",
                                           // ⚠ "未生成"（还没积累过任何数据）与"无记录"（那天跑过，只是没选股）
                                           //   两态各自说清，写成同一句话用户会查错方向
                                           title: store.dayMeta.isEmpty ? "尚未积累历史数据" : "该日无复盘记录",
                                           hint: store.dayMeta.isEmpty ? "跑完第一个交易日并复盘后，这里会出现历史记录"
                                                                       : "可切换日期查看其他交易日（日列表仅显示有数据的日期）")
                            RecentRecordHint(lead: "该日无选股记录") { d in
                                store.jump(toDate: d)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    if let it = store.iterateReport {
                        iterateCard(it)
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: 多观察窗

    /// 一行 = 一个口径
    private struct WindowRow: Identifiable {
        let id: String
        let name: String
        let hint: String
        let stats: WindowStats?
        /// 可执行主口径（次日午前）—— 单独高亮
        let isCore: Bool
    }

    /// 「次日午前卖，还是拿三天更对」—— 四个口径并列。
    ///
    /// ⚠⚠ **样本数必须一起显示**：`disc_profit` 在 T+1 就有值、`t5_close_pct` 要等 5 个交易日
    /// → 长窗样本天然比短窗少。只显示胜率的话，"T+5 胜率低"会被读成"拿五天更差"，
    /// 而真实原因可能只是**还没到期**（那是两个完全相反的策略结论）。
    @ViewBuilder
    private var multiWindowCard: some View {
        if let m = store.multiWindow, !m.isEmpty {
            let rows: [WindowRow] = [
                WindowRow(id: "l3", name: "次日午前", hint: "纪律口径：窗口内首次触及目标价即卖出",
                          stats: m.l3, isCore: true),
                WindowRow(id: "t1", name: "次日收盘", hint: "T+1 收盘涨跌（既有的 close_profit）",
                          stats: m.t1, isCore: false),
                WindowRow(id: "t3", name: OutcomeWindow.t3.label, hint: "T+3 收盘涨跌",
                          stats: m.t3, isCore: false),
                WindowRow(id: "t5", name: OutcomeWindow.t5.label, hint: "T+5 收盘涨跌",
                          stats: m.t5, isCore: false),
            ]
            Card("多观察窗", subtitle: "近 \(m.days) 个选股日 · 回答「次日午前卖，还是拿三天更对」") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows) { r in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(r.name)
                                    .font(.callout)
                                    .fontWeight(r.isCore ? .semibold : .regular)
                                if r.isCore {
                                    Text("主口径")
                                        .font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Tok.tint(Sem.up, .chip),
                                                    in: Capsule())
                                }
                                Spacer(minLength: 8)
                                if let s = r.stats {
                                    Text("\(String(format: "%.1f", s.winrate))%")
                                        .font(.callout).monospacedDigit()
                                        .fontWeight(r.isCore ? .semibold : .regular)
                                    Text(signedPct(s.avgProfit))
                                        .font(.caption).monospacedDigit()
                                        .foregroundStyle(s.avgProfit >= 0 ? Sem.up : Sem.down)
                                    // ⚠ 样本数不能省：长窗样本天然少（还没到期）
                                    Text("\(s.wins)/\(s.total)")
                                        .font(.caption2).monospacedDigit()
                                        .foregroundStyle(Tok.dim)
                                } else {
                                    Text("—").font(.callout).foregroundStyle(Tok.dim)
                                    Text("无样本").font(.caption2).foregroundStyle(Tok.dim)
                                }
                            }
                            if let s = r.stats {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Tok.stroke)
                                        Capsule()
                                            .fill(Sem.change(s.winrate >= 50 ? "good" : "bad"))
                                            .frame(width: geo.size.width
                                                   * CGFloat(min(max(s.winrate, 0), 100)) / 100)
                                    }
                                }
                                .frame(height: 5)
                            }
                            Text(r.hint).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Divider().opacity(0.4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("⚠ 四个口径的样本数不同是正常的：T+3/T+5 要等交易日走完才补得上"
                             + "（补数由每次复盘自动完成）。先看样本数再看胜率 ——"
                             + "否则会把「还没到期」读成「拿得更差」。")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text("T+3/T+5 是观察口径，不参与调优标签（LABEL_METRICS 仍是 5 个）；"
                             + "样本集合与上方「四层胜率走势」不同，两组数字不该互相印证。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// 带符号百分数（`+1.42%` / `-0.40%`）
    private func signedPct(_ v: Double) -> String {
        String(format: "%@%.2f%%", v >= 0 ? "+" : "", v)
    }

    // MARK: 四层胜率跨日走势（与复盘页四层胜率同口径，形成"趋势 → 跳明细"闭环）

    /// 走势数据点：层级名与复盘页 BarChart 一致（快照/收盘持有/窗口可用/策略上限）
    private struct WinratePoint: Identifiable {
        let date: String
        let layer: String
        let winrate: Double
        var id: String { "\(date)-\(layer)" }
    }

    /// 四层线尾**标签**配色（text 档：窗口=红·核心，收盘=绿，快照=橙，上限=紫）。
    /// ⚠ 标签是文字要 4.5:1；折线本身走下面的 `*Series` 图形档（明度阶梯），两者同色相不同明度。
    private static let trendLayers: [(key: String, name: String, color: Color)] = [
        ("window", "窗口可用", Sem.up),
        ("close", "收盘持有", Sem.down),
        ("snapshot", "快照 10:00", Sem.warn),
        ("ceiling", "策略上限", Sem.accent),
    ]

    /// 线尾：某层**最后一个有样本的选股日**的胜率 —— 层名直接标在这里
    private struct TrendTerminal {
        let key: String
        let name: String
        let color: Color
        let value: Double
    }

    // MARK: 线尾标注的几何档位
    //
    // 「会不会叠字、能漂多远」的判据在 `TrendLabelLayout`（Core，`TrendLabelLayoutTests`
    // 用手算整数钉死）；这里只留"槽子留多宽"和传给它的三个阈值。
    // ⚠ `labelMinGap` 是**像素**，对应 `AppFont.detailSmall`（10pt）的一行高 —— 换字号要同步换它。

    /// 绘图区右缘到标签文字的间距
    private static let labelSlotX: CGFloat = 6
    /// 最窄标签槽（层名都很短时也不至于挤到线上）
    private static let labelGutterMin: CGFloat = 44
    /// 实测宽度之外左右各留的呼吸
    private static let labelGutterPad: CGFloat = 12
    /// 回落那行比线尾标签多一个圆点 + 间距，槽宽必须一起量进去
    /// （离屏渲染实测：不补这 10pt，"快照 10:00" 会在槽里折成两行）
    private static let labelDotAllowance: CGFloat = 10
    private static let labelMinGap: Double = 13
    private static let labelMaxDrift: Double = 20
    private static let labelInset: Double = 8

    @ViewBuilder
    private var winrateTrendCard: some View {
        // 少于 2 个样本画不出走势：不显示整卡（新库不出现空图，与项目空态约定一致）
        if store.winrateTrend.count >= 2 {
            // 范围可切（近 20 / 60 / 120 / 全部）；超过 `WinrateTrend.weeklyThreshold`（120）
            // 自动按自然周聚合 —— 逐日折线在几百个点上会糊成一条带。
            // ⚠ 聚合口径必须写在副标题里（周均值是"简单平均"：库里只存胜率、不存样本数
            //   ⇒ 加权拿不到权重），否则周线会被读成日线。
            let raw = store.winrateTrend
            let isWeekly = raw.count > WinrateTrend.weeklyThreshold
            let rows = isWeekly ? WinrateTrend.weekly(raw) : raw
            let shownRows = trendTableExpanded ? rows : Array(rows.suffix(20))
            Card("四层胜率走势",
                 subtitle: trendSubtitle(rawCount: raw.count, shown: rows.count, isWeekly: isWeekly)) {
                VStack(alignment: .leading, spacing: 8) {
                // 改范围后重拉（数据在库里，很便宜）
                HStack {
                    Picker("", selection: Binding(
                        get: { store.winrateTrendRange },
                        set: { store.winrateTrendRange = $0; store.reloadWinrateTrend() })) {
                        Text("近 20").tag(20)
                        Text("近 60").tag(60)
                        Text("近 120").tag(120)
                        Text("全部").tag(0)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 300)
                    Spacer()
                }
                .padding(.bottom, 2)
                let points: [WinratePoint] = rows.flatMap { d in
                    Self.trendLayers.compactMap { layer in
                        guard let wr = d.winrate(for: layer.key) else { return nil }
                        return WinratePoint(date: d.date, layer: layer.name, winrate: wr)
                    }
                }
                // 层名直接标在线尾，不再要底部那条图例带：读图时视线不必在"图 ↔ 图例"之间往返。
                let terminals: [TrendTerminal] = Self.trendLayers.compactMap { layer in
                    guard let v = rows.lazy.compactMap({ $0.winrate(for: layer.key) }).last else { return nil }
                    return TrendTerminal(key: layer.key, name: layer.name, color: layer.color, value: v)
                }
                // 槽宽按**内容实测**（和表格列宽同一套量字口径，见 `ColumnLayout`）：
                // 拍固定宽度必然要么截字、要么留一条白边。
                let labelW = terminals.map { ColumnLayout.measure($0.name, ColumnLayout.microNS) }.max() ?? 0
                let gutter = max(Self.labelGutterMin,
                                 labelW + Self.labelGutterPad + Self.labelDotAllowance)
                let slotW = max(20, gutter - Self.labelSlotX * 2)
                Chart(points) { p in
                    LineMark(
                        x: .value("选股日", String(p.date.dropFirst(5))),   // MM-dd，省宽度
                        y: .value("胜率", p.winrate)
                    )
                    .foregroundStyle(by: .value("层级", p.layer))
                    .lineStyle(StrokeStyle(lineWidth: p.layer == "窗口可用" ? 2.5 : 1.5))
                    .interpolationMethod(.monotone)
                    if p.layer == "窗口可用" {
                        PointMark(
                            x: .value("选股日", String(p.date.dropFirst(5))),
                            y: .value("胜率", p.winrate)
                        )
                        .foregroundStyle(by: .value("层级", p.layer))
                        .symbolSize(30)
                    }
                }
                .chartYScale(domain: 0...100)
                // ⚠ `position: .leading` 不是风格选择：macOS 26 的 y 轴数值默认画在**右缘**，
                //   正好压在下面那条标签槽上（离屏渲染实测：层名"策略上限"与刻度"75"叠字）。
                //   右缘整条要让给线尾标注，刻度必须挪去左边。
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 25, 50, 75, 100])
                }
                // KeyValuePairs 字面量（Charts 的 scale API 不收 Dictionary）
                // 系列档：text 档四支明度齐平，deutan 下红↔橙/红↔绿不可分（ΔE 0.02–0.08）
                .chartForegroundStyleScale([
                    "窗口可用": Sem.upSeries,
                    "收盘持有": Sem.downSeries,
                    "快照 10:00": Sem.warnSeries,
                    "策略上限": Sem.accentSeries,
                ])
                .chartLegend(.hidden)
                // 绘图区右缘腾出标签槽：标签画在槽里，不参与折线的坐标映射
                .chartPlotStyle { $0.padding(.trailing, gutter) }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        let plot = geo[proxy.plotAreaFrame]
                        let placed = TrendLabelLayout.place(
                            anchors: terminals.map { TrendLabelLayout.Anchor(id: $0.key, value: $0.value) },
                            domain: 0...100,
                            plotHeight: Double(plot.height),
                            minGap: Self.labelMinGap,
                            maxDrift: Self.labelMaxDrift,
                            inset: Self.labelInset)
                        ZStack(alignment: .topLeading) {
                            switch placed {
                            case .labels(let got):
                                ForEach(got, id: \.id) { one in
                                    if let t = terminals.first(where: { $0.key == one.id }) {
                                        Text(t.name)
                                            .font(AppFont.detailSmall)
                                            .foregroundStyle(t.color)
                                            .lineLimit(1)
                                            .frame(width: slotW, alignment: .leading)
                                            .position(x: plot.maxX + Self.labelSlotX + slotW / 2,
                                                      y: plot.minY + one.y)
                                    }
                                }
                            case .crowded:
                                // 终点挤成一团：硬标要么叠字、要么漂得认不出本尊 ⇒ 层名集中在槽顶，
                                // 圆点/字号与线尾同一套，读者照样靠颜色对上（判据见 TrendLabelLayout）。
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(terminals, id: \.key) { t in
                                        HStack(spacing: 4) {
                                            Circle().fill(t.color)
                                                .frame(width: t.key == "window" ? 8 : 6,
                                                       height: t.key == "window" ? 8 : 6)
                                            Text(t.name)
                                                .font(AppFont.detailSmall)
                                                .foregroundStyle(t.key == "window" ? Color.primary : Color.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(width: slotW, height: plot.height, alignment: .topLeading)
                                .position(x: plot.maxX + Self.labelSlotX + slotW / 2,
                                          y: plot.minY + plot.height / 2)
                            }
                        }
                    }
                }
                .frame(height: 200)
                Divider()
                // 明细表：最近在上，行点击跳转该选股日看完整复盘
                // ⚠ 行数跟着范围走（全部/120 天会很长）⇒ 默认只显示最近 20 行 + 展开
                let tableRows = Array(shownRows.reversed())
                let cols = [
                    DataTableColumn("date", isWeekly ? "周起始" : "选股日", width: 104),
                    DataTableColumn("window", "窗口可用", width: 84, alignment: .trailing, isNumeric: true),
                    DataTableColumn("close", "收盘持有", width: 84, alignment: .trailing, isNumeric: true),
                    DataTableColumn("snapshot", "快照 10:00", width: 90, alignment: .trailing, isNumeric: true),
                    DataTableColumn("ceiling", "策略上限", width: 84, alignment: .trailing, isNumeric: true),
                ]
                SharedDataTable(columns: cols, rows: tableRows) { d, c in
                    switch c.id {
                    case "date":
                        Button {
                            if !d.date.isEmpty { store.jump(toDate: d.date) }
                        } label: {
                            Text(d.dateDash)
                                .monospacedDigit()
                                .foregroundStyle(Sem.brand)
                        }
                        .buttonStyle(.plain)
                        .help("查看 \(d.dateDash) 的完整复盘")
                    case "window":
                        let w = d.winrate(for: "window") ?? 0
                        Text(String(format: "%.1f%%", w))
                            .font(TableMetrics.rowNumericFont.weight(.bold))
                            .foregroundStyle(w >= 50 ? Sem.down : Sem.warn)
                    case "close":
                        Text(String(format: "%.1f%%", d.winrate(for: "close") ?? 0))
                    case "snapshot":
                        Text(String(format: "%.1f%%", d.winrate(for: "snapshot") ?? 0))
                    default:
                        Text(String(format: "%.1f%%", d.winrate(for: "ceiling") ?? 0))
                    }
                }
                if rows.count > 20 {
                    Button(trendTableExpanded ? "收起（只显示最近 20 行）" : "展开全部（\(rows.count) 行）") {
                        trendTableExpanded.toggle()
                    }
                    .btnSecondary()
                }
                }
            }
        }
    }

    /// 四层胜率卡的副标题：**范围 / 聚合方式 / 总点数**都要写出来（口径写在界面上）
    private func trendSubtitle(rawCount: Int, shown: Int, isWeekly: Bool) -> String {
        let scope = store.winrateTrendRange > 0 ? "近 \(rawCount) 个有样本选股日"
                                               : "全部 \(rawCount) 个有样本选股日"
        // ⚠ 这里不能写 `**`：`Card` 的 subtitle 是 `Text(String)`（verbatim，不解析 Markdown）
        //   ⇒ 星号会原样显示给用户（护栏 `md_literal`）
        let agg = isWeekly ? " · 按自然周聚合（\(shown) 个点，周均值是各日简单平均）" : ""
        return scope + agg + " · 与复盘页四层胜率同口径（点击日期查看该日完整复盘）"
    }

    /// 字段非 NSNull 且非空 → 环节存在
    @ViewBuilder
    private func historyCard(_ h: HistoryRecord) -> some View {
        Card("\(h.dateDash) 全链路", subtitle: "以选股日为准：预判/验证/复盘均为选股日的次日动作（如 9/11 选股 → 9/12 早盘预判、9/12 收盘复盘）") {
            VStack(alignment: .leading, spacing: 8) {
            if h.rounds.isEmpty {
                Text("当日无选股记录（空仓日或未运行）")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(h.rounds, id: \.slot) { r in
                    // ⚠ 不用 `slot_label`：它恒等于默认表，会与实际执行时刻（`run_time`）打架；
                    //   只留轮次号 + 实际时刻
                    KVRow(key: "第\(r.slot)轮 · \(r.runTimeClock)",
                          value: "一档 \(r.tier1Count) / 二档 \(r.tier2Count)",
                          maxWidth: 560)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                statusRow("三轮对比", date: h.dateDash, present: h.exists("compare"))
                // 预判时刻取 `predict_time`（`predict_date` 是纯日期、无时刻）；
                // 与相邻两行口径一致：盘中验证写 "T+1 10:00 …"、收盘复盘写 "T+1 \(reviewTime) …"。
                statusRow("早盘预判", date: h.predict.map { "T+1 \($0.predictTime) 早盘预判本日标的" } ?? "T+1 早盘 \(ScheduleTimes.shared.clock("predict")) 待执行",
                          present: h.exists("predict"))
                statusRow("盘中验证", date: h.verify?.hasVerifyTimeKey == true
                          ? "T+1 \(ScheduleTimes.shared.clock("verify")) 已验证本日标的"
                          : "T+1 早盘 \(ScheduleTimes.shared.clock("verify")) 待执行",
                          present: h.exists("verify"))
                statusRow("收盘复盘", date: h.review.map { "T+1 \($0.reviewTime) 复盘本日标的" } ?? "T+1 收盘后待执行",
                          present: h.exists("review"))
                statusRow("三天迭代", date: h.iterate.map(\.triggerDate) ?? "计数未满 3 有效日",
                          present: h.exists("iterate"))
            }
            // 复盘核心胜率速览
            let wr = h.review?.fourLayer.window.winrate
            if let wr {
                KVRow(key: "窗口可用胜率（核心）", value: "\(String(format: "%.1f", wr))%",
                      valueColor: wr >= 50 ? Sem.down : Sem.warn,
                      maxWidth: 560)
            }
            }
        }
    }

    private func statusRow(_ label: String, date: String, present: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: present ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(present ? AnyShapeStyle(Sem.down) : AnyShapeStyle(Tok.dim))
            Text(label).font(.callout)
            Text(date)
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    @ViewBuilder
    private func iterateCard(_ it: IterateResult) -> some View {
        let et = it.emptyTrend
        Card("迭代报告", subtitle: it.triggerDateDash) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 28) {
                    KVRow(key: "计数器", value: "\(it.counter)/3")
                    KVRow(key: "近\(et.totalDays)日空仓占比",
                          value: "\(String(format: "%.1f", et.emptyRatio))%")
                }
                .frame(maxWidth: 560, alignment: .leading)
                let avg = it.fourLayerAvg
                if !avg.json.dict.isEmpty {
                    // 四层胜率 mini BarChart：与复盘页四层胜率同构图，形成呼应
                    let avgRows: [WinrateRow] = [
                        .init(id: "snapshot", name: "快照", winrate: avg.snapshot,
                              detail: "", isCore: false),
                        .init(id: "close", name: "收盘", winrate: avg.close,
                              detail: "", isCore: false),
                        .init(id: "window", name: "窗口", winrate: avg.window,
                              detail: "", isCore: true),
                        .init(id: "ceiling", name: "上限", winrate: avg.ceiling,
                              detail: "", isCore: false),
                    ]
                    Chart(avgRows) { r in
                        BarMark(
                            x: .value("胜率", r.winrate),
                            y: .value("层级", r.name)
                        )
                        .foregroundStyle(r.isCore ? AnyShapeStyle(Sem.accent.gradient) : AnyShapeStyle(Sem.info.gradient))
                        .annotation(position: .trailing, alignment: .leading) {
                            RollingNumber(r.winrate, format: "%.0f%%",
                                          font: .caption2, color: .secondary)
                        }
                        .cornerRadius(3)
                    }
                    // 与上方四层胜率图同口径：留 12% 尾量，防 100% 注解被裁
                    .chartXScale(domain: 0...112)
                    .chartXAxis {
                        AxisMarks(values: [0, 50, 100])
                    }
                    .frame(height: 110)
                }
                ForEach(it.insights, id: \.self) { t in
                    Label(t, systemImage: "sparkles").font(.callout)
                }
            }
        }
    }
}

// 原生 Table 需要行 Identifiable；ReviewStock 是 JSONEntity 包装，以 code 作 id —— 仅本文件使用。
extension ReviewStock: Identifiable {
    public var id: String { code }
}

// 同上：日期行以 date 作 id
extension WinrateTrendRow: Identifiable {
    public var id: String { date }
}
