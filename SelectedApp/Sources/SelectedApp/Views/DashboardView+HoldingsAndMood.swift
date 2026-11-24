import SwiftUI
import Charts
import SelectedCore

// MARK: - P1 看板 · 持仓盈亏、昨涨停情绪与领涨板块

extension DashboardView {

    // MARK: 持仓今日（当日浮动盈亏）

    @ViewBuilder
    var holdingsCard: some View {
        if store.viewDate != store.today {
            Card {
                HStack(spacing: 12) {
                    Text("历史日不展示实时持仓盈亏，避免把今天的价格混进历史视图。")
                        .font(.caption)
                        .foregroundStyle(Tok.labelSecondary)
                    Spacer(minLength: 8)
                    Button(store.dashboardDefaultDate == store.today ? "回到当日" : "回到最近交易日") {
                        store.backToDashboardToday()
                    }
                    .btnSecondary()
                    .controlSize(.small)
                }
            }
        } else if let pnl = store.holdingDayPnl {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    if pnl.hasAnyQuote {
                        // 左：市值/盈亏汇总（总市值在第一行） | 中：当日盈亏 | 右：今日贡献。
                        // 左右都吃 maxWidth ⇒ 两翼等宽，当日盈亏真正居中。
                        HStack(alignment: .center, spacing: 12) {
                            holdingsLeftMetrics(pnl)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Divider().frame(height: 54)
                            holdingsDayPnl(pnl)
                            Divider().frame(height: 54)
                            holdingsContributions(pnl)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text("持仓行情获取中… 自选/持仓行情会在后台每 5~60 秒刷新。")
                            .font(.callout)
                            .foregroundStyle(Tok.labelSecondary)
                    }
                    if pnl.missingCount > 0 || pnl.missingPrevCloseCount > 0 {
                        Text(holdingMissingText(pnl))
                            .font(.caption2)
                            .foregroundStyle(Tok.labelSecondary)
                    }
                }
            }
        } else {
            Card {
                HStack(spacing: 12) {
                    Text("暂无持仓 · 在自选页右键「添加持仓」填写成本与数量")
                        .font(.callout)
                        .foregroundStyle(Tok.labelSecondary)
                    Spacer(minLength: 8)
                    Button("去自选") { Page.select(.watch) }
                        .btnSecondary()
                }
            }
        }
    }

    /// 左翼：一行三列（总市值 / 总盈亏 / 盈亏家数），标签与数值居中。
    private func holdingsLeftMetrics(_ pnl: HoldingDayPnl) -> some View {
        HStack(alignment: .top, spacing: 8) {
            holdingMetricColumn("总市值", StockFmt.money(pnl.totalValue), Tok.label)
            holdingMetricColumn("总盈亏", StockFmt.signedMoney(pnl.totalPnl),
                                Sem.pnl(pnl.totalPnl))
            holdingMetricColumn("盈亏家数",
                                "\(pnl.winners) 盈 · \(pnl.losers) 亏",
                                Tok.label)
        }
    }

    private func holdingMetricColumn(_ label: String, _ value: String,
                                     _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Tok.labelSecondary)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// 中翼：当日盈亏。标题、金额、百分比整体居中。
    private func holdingsDayPnl(_ pnl: HoldingDayPnl) -> some View {
        VStack(spacing: 1) {
            Text("当日盈亏")
                .font(.caption2).foregroundStyle(Tok.labelSecondary)
            Text(StockFmt.signedMoney(pnl.dayPnl))
                .font(AppFont.displayNumeric(25, weight: .bold))
                .foregroundStyle(Sem.pnl(pnl.dayPnl))
                .contentTransition(.numericText(value: pnl.dayPnl))
                .motionAware(Mot.value, value: pnl.dayPnl)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(String(format: "%+.2f%%", pnl.dayPnlPct))
                .font(.caption.bold())
                .foregroundStyle(Sem.pnl(pnl.dayPnl))
        }
        .multilineTextAlignment(.center)
        .frame(minWidth: 96)
    }

    /// 右翼：今日贡献（已去掉「查看持仓」按钮）。
    private func holdingsContributions(_ pnl: HoldingDayPnl) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("今日贡献")
                .font(.caption2).foregroundStyle(Tok.labelSecondary)
            if pnl.topMovers.isEmpty {
                Text("昨收缺失，暂无法计算当日盈亏")
                    .font(.caption2).foregroundStyle(Tok.labelSecondary)
            } else {
                ForEach(pnl.topMovers.prefix(3), id: \.code) { line in
                    HStack(spacing: 6) {
                        Text(line.name).font(.caption)
                            .foregroundStyle(Tok.label)
                            .lineLimit(1)
                        Text(line.code)
                            .font(.caption2).foregroundStyle(Tok.labelSecondary)
                        Spacer(minLength: 6)
                        PnlText(value: line.dayPct)
                            .font(.caption2.bold())
                        Text(line.dayPnl.map { StockFmt.signedMoney($0) } ?? "—")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Sem.pnl(line.dayPnl))
                            .frame(width: 62, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                    .stockDetailTap(code: line.code, name: line.name)
                }
            }
        }
    }

    private func holdingMissingText(_ pnl: HoldingDayPnl) -> String {
        var parts: [String] = []
        if pnl.missingCount > 0 { parts.append("行情缺失 \(pnl.missingCount) 只未计") }
        if pnl.missingPrevCloseCount > 0 {
            parts.append("昨收缺失 \(pnl.missingPrevCloseCount) 只不计当日盈亏")
        }
        return parts.joined(separator: "｜")
    }

    // MARK: 昨涨停表现（功能 A · 市场情绪）

    var ztSentimentCard: some View {
        let live = store.ztSentimentLive.flatMap { snap -> ZtSentimentLiveSnapshot? in
            // 跨午夜后旧快照不能冒充今天
            snap.result.date == store.today ? snap : nil
        }
        // 今天已有落库行 = 15:15 收盘任务已定稿 → 优先 DB；否则用盘中快照
        let useLive = store.isDashboardToday && store.ztSentimentToday == nil && live != nil
        let s = useLive ? live?.result : store.ztSentimentToday
        let subtitle: String = {
            if useLive, let live {
                let suffix = store.ztSentimentLiveError == nil ? "" : " · 刷新失败保留上一笔"
                return "昨日涨停股今日 · 盘中 \(Self.clockText(live.updatedAt)) 更新\(suffix)"
            }
            if store.isDashboardToday, let err = store.ztSentimentLiveError, (s?.sample ?? 0) == 0 {
                return "盘中 · \(err)"
            }
            return "昨日涨停股今日 · 收盘定稿"
        }()
        return Card("昨涨停表现", subtitle: subtitle) {
            if let s, s.sample > 0 {
                let trend = ztTrend(useLive: useLive, live: live)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("平均").font(.caption2).foregroundStyle(Tok.labelSecondary)
                            RollingNumber(s.avgPct, format: "%+.2f%%",
                                          font: .title3, color: Sem.pnl(s.avgPct))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("中位").font(.caption2).foregroundStyle(Tok.labelSecondary)
                            RollingNumber(s.medianPct, format: "%+.2f%%",
                                          font: .title3, color: Sem.pnl(s.medianPct))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("晋级").font(.caption2).foregroundStyle(Tok.labelSecondary)
                            Text("\(s.promoted)/\(s.sample)")
                                .font(.title3.monospacedDigit())
                                .foregroundStyle(Tok.label)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("亏损面").font(.caption2).foregroundStyle(Tok.labelSecondary)
                            Text(String(format: "%.0f%%", s.lossRate * 100))
                                .font(.title3.monospacedDigit())
                                .foregroundStyle(s.lossRate > 0.5 ? Sem.down : Tok.labelSecondary)
                        }
                        Spacer(minLength: 0)
                        if useLive {
                            Text("盘中")
                                .font(.caption2.bold())
                                .foregroundStyle(Sem.warn)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Tok.tint(Sem.warn), in: Capsule())
                        }
                    }
                    // 近 N 日平均涨幅迷你趋势（盘中把今天实时点接在末尾）
                    if trend.count >= 2 {
                        Chart(trend, id: \.date) { p in
                            LineMark(x: .value("日期", String(p.date.suffix(5))),
                                      y: .value("均涨", p.avgPct))
                                .interpolationMethod(.monotone)
                            AreaMark(x: .value("日期", String(p.date.suffix(5))),
                                     y: .value("均涨", p.avgPct))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(Tok.tint(Sem.brand, .chip))
                        }
                        .chartYAxis(.hidden).chartXAxis(.hidden)
                        .frame(height: 36)
                    }
                    Text("样本 \(s.sample) 只"
                         + (s.missing > 0 ? "｜停牌/缺价 \(s.missing) 只未计" : "")
                         + (useLive && live?.backfilledPool == true ? "｜已补昨日涨停池" : ""))
                        .font(.caption2).foregroundStyle(Tok.labelSecondary)
                }
            } else {
                Text("开盘后自动生成（需库里有前一交易日的涨停池）；"
                     + "\(ScheduleTimes.shared.clock("limitup")) 收盘定稿")
                    .font(.caption).foregroundStyle(Tok.labelSecondary)
            }
        }
    }

    /// 趋势序列：DB 历史 + 今日盘中实时点（同日只留一份）。
    private func ztTrend(useLive: Bool, live: ZtSentimentLiveSnapshot?) -> [ZtSentimentResult] {
        var trend = store.ztSentimentTrend.filter { $0.sample > 0 }
        if useLive, let r = live?.result,
           !trend.contains(where: { $0.date == r.date }) {
            trend.append(r)
        }
        return trend
    }

    // MARK: 领涨板块 Top5（功能 B）

    var topBoardsCard: some View {
        let liveRows = store.liveTopBoards.filter { $0.date == store.today }
        // 过了全量定稿时刻且库里已有今天 → 用 DB；盘中用 60 秒轻量 TopN。
        // ⚠ 下界取 15:10：用户把调度改到开盘前也不能让"盘中"直接切到空 DB
        let finalMinute = max(ScheduleTimes.shared.time(of: "boardheat")
            .map { $0.hour * 60 + $0.minute } ?? 910, 910)
        let dbToday = store.boardHeatRows.first?.date == store.today
        let afterFinal = ChinaTime.minutesOfDay() >= finalMinute
        let useDb = store.isDashboardToday && dbToday && afterFinal
        let useLive = store.isDashboardToday && !useDb && !liveRows.isEmpty
        let rows = useLive ? liveRows : store.boardHeatRows
        let subtitle: String? = {
            if useLive, let at = store.liveTopBoardsUpdatedAt {
                return "\(store.today) · 盘中 \(Self.clockText(at)) 更新"
            }
            return rows.first?.date
        }()
        return Card("领涨板块", subtitle: subtitle) {
            let top = Array(rows.prefix(5))
            if top.isEmpty {
                Text("盘中每 60 秒抓取当日 Top5；收盘后 \(ScheduleTimes.shared.clock("boardheat")) 全量定稿")
                    .font(.caption).foregroundStyle(Tok.labelSecondary)
            } else {
                VStack(spacing: 5) {
                    ForEach(top) { r in
                        HStack(spacing: 8) {
                            Text(r.boardName).font(.callout)
                                .foregroundStyle(Tok.label)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(StockFmt.signedFlowYi(r.mainNet))
                                .font(.caption.monospacedDigit()).foregroundStyle(Sem.pnl(r.mainNet))
                            Text(String(format: "%+.2f%%", r.changePct))
                                .font(.callout.monospacedDigit()).foregroundStyle(Sem.pnl(r.changePct))
                                .frame(width: 62, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
}
