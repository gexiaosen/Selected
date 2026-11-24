import SwiftUI
import SelectedCore

// MARK: - P1 看板 · 大盘 Hero

extension DashboardView {

    var marketHero: some View {
        // 三种来源（扫描结果 / 库行 / 预判）共用 `SelectedCore.MarketEnv` 一个类型 ——
        // 不"谁非空用谁"地把两种键集混起来。
        // 回退链本身保留（**产品行为**：尾盘扫描优先，无轮次时回退早盘预判），
        // 但"这个来源有没有这个字段"改成按字段问（`OrNil` 变体），
        // 而不是"整个对象非空就用它" —— 预判来源没有 `up_count` / `sh_price`，
        // 旧写法会静默读成 0。
        let latestEnv = store.roundSummaries.last?.marketEnv
        let predEnv = store.predictReport?.marketEnv
        let hasLatest = !(latestEnv?.isEmpty ?? true)
        let hasPred = !(predEnv?.isEmpty ?? true)
        let env: MarketEnv? = hasLatest ? latestEnv : (hasPred ? predEnv : nil)
        let envSource = hasLatest ? "尾盘扫描" : (hasPred ? "早盘预判" : "")
        // 只认"今天拉到的"实时指数：跨午夜后旧值不能冒充今天
        let liveFetchedToday = store.liveIndexFetchedAt.map {
            ChinaTime.day($0) == store.today
        } ?? false
        let live = (store.isDashboardToday && liveFetchedToday) ? store.liveIndex : nil
        let scannedToday = store.dayMeta[store.today] != nil
        let liveMode = store.isDashboardToday && !scannedToday && live != nil
        // 环境口径（扫描/预判）：无数据时 envLight 会对空对象误报黄灯，需短路
        let hasEnv = !(env?.isEmpty ?? true)
        let (lightText, lightColor): (String, Color)
        if liveMode, let lv = store.realtimeLightLevel {
            lightText = realtimeLightText(lv)
            lightColor = Sem.light(lv)
        } else if hasEnv {
            (lightText, lightColor) = envLight(env)
        } else {
            (lightText, lightColor) = ("", .clear)
        }
        let livePct = live?["change_pct"].double
        let liveTrend: (String, Color)? = livePct.flatMap { p in
            if p > 0 { return ("实时上涨", Sem.up) }
            if p < 0 { return ("实时下跌", Sem.down) }
            return ("平盘", .secondary)
        }
        // 涨跌比无实时涨跌家数源：实时模式下如实标注"待今日扫描"，不展示昨日快照
        // ⚠ 用 `OrNil` 变体：预判来源**没有** up/down/flat_count，
        // 用 `upCount`（缺省 0）会让"待尾盘"分支被误判成"涨跌家数都是 0"
        let up = liveMode ? nil : env?.upCountOrNil
        let down = liveMode ? nil : env?.downCountOrNil
        let flat = liveMode ? nil : env?.flatCountOrNil
        let ratioText: String
        if liveMode {
            ratioText = "待今日扫描"
        } else if let u = up, let d = down, (u > 0 || d > 0) {
            let f = flat ?? 0
            ratioText = "\(u):\(f):\(d)"
        } else if envSource == "早盘预判" {
            ratioText = "待尾盘"
        } else {
            ratioText = "待首轮扫描"
        }
        let envTrend = env?.sh3dTrend ?? ""
        let trendDisplay: String
        if liveMode {
            trendDisplay = store.live3dTrend ?? "实时获取中…"
        } else {
            trendDisplay = (!envTrend.isEmpty && envTrend != "-" && envTrend != "—")
                ? envTrend : (store.live3dTrend ?? "—")
        }

        // 市场状态（P2 · B1+B2）：环境里的 `regime` 五态。
        // `UNKNOWN`（历史不足，或 P2 之前落的库行）与键缺失**都不显示** —— 不猜。
        let regime: (String, Color)? = {
            guard !liveMode, let raw = env?.regime, !raw.isEmpty, raw != "UNKNOWN"
            else { return nil }
            let label = Self.regimeLabel(raw)
            let text = env?.maPeriodUsedOrNil.map { "\(label)（MA\($0)）" } ?? label
            return (text, Self.regimeColor(raw))
        }()

        let statusDetail: String
        if !store.isDashboardToday {
            if store.historicalIndexQuotesFetching {
                statusDetail = "历史日 · 四指数获取中…"
            } else if let asOf = store.historicalIndexQuotesAsOf {
                statusDetail = asOf == store.viewDate
                    ? "历史日 · 指数为该日收盘"
                    : "历史日 · 指数为 \(asOf) 收盘"
            } else {
                statusDetail = "历史日 · 指数快照缺失"
            }
        } else if liveMode {
            statusDetail = "今日尚未扫描 · 正式信号以尾盘扫描为准"
        } else if store.isDashboardToday && store.liveIndexFetching {
            statusDetail = "实时行情获取中…"
        } else {
            statusDetail = store.roundSummaries.isEmpty
                ? (envSource == "早盘预判" ? "今日未扫描 · 环境来自早盘预判" : "今日尚未扫描")
                : "已扫描 \(store.roundSummaries.count)/3 轮"
        }

        return Card(prominence: .hero) {
            VStack(alignment: .leading, spacing: 14) {
                // 四指数等宽横排。数字位数变化只影响本格，不推动相邻格。
                HStack(alignment: .top, spacing: 0) {
                    let indices = DashboardPrefs.shared.displayed
                    ForEach(indices, id: \.symbol) { item in
                        indexTile(item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if item.symbol != indices.last?.symbol {
                            Divider()
                                .frame(height: 82)
                                .padding(.horizontal, 12)
                        }
                    }
                }
                Divider()
                heroEnvStrip(lightText: lightText, lightColor: lightColor, liveTrend: liveTrend,
                             ratioText: ratioText, up: up, down: down, flat: flat,
                             trendDisplay: trendDisplay, regime: regime,
                             statusDetail: statusDetail, showLive: live != nil)
            }
            .environment(\.colorScheme, colorScheme)
        }
    }

    /// 单格指数。今天用实时批量行情；历史日不拿实时价冒充历史。
    private func indexTile(_ item: MarketIndex) -> some View {
        let q = indexQuote(item.symbol)
        let isHistorical = !store.isDashboardToday
        return VStack(alignment: .leading, spacing: 3) {
            Text(item.name)
                .font(.caption)
                .foregroundStyle(Tok.labelSecondary)
                .lineLimit(1)
            if let q {
                Text(StockFmt.price(q.currentPrice, code: q.code))
                    .font(AppFont.displayNumeric(30, weight: .bold))
                    .foregroundStyle(Tok.label)
                    .contentTransition(.numericText(value: q.currentPrice))
                    .motionAware(Mot.value, value: q.currentPrice)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    PnlText(value: q.changePercent)
                        .font(.callout.bold())
                    Text(StockFmt.signedPrice(q.change, code: q.code))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Sem.pnl(q.change))
                }
                let high = q.highPrice > 0 ? StockFmt.price(q.highPrice, code: q.code) : "—"
                Text(isHistorical
                     ? "收盘 \(store.historicalIndexQuotesAsOf ?? store.viewDate) · 高 \(high)"
                     : "成交 \(StockFmt.turnover(q.turnover)) · 高 \(high)")
                    .font(.caption2)
                    .foregroundStyle(Tok.labelSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else if (store.isDashboardToday && store.liveIndexFetching)
                        || (isHistorical && store.historicalIndexQuotesFetching) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Tok.skeleton)
                    .frame(width: 112, height: 30)
                Text(isHistorical ? "历史指数获取中…" : "实时获取中…")
                    .font(.caption2)
                    .foregroundStyle(Tok.labelSecondary)
            } else {
                Text("—")
                    .font(AppFont.display(26, weight: .bold))
                    .foregroundStyle(Tok.labelSecondary)
                Text(isHistorical ? "该日无指数快照" : "暂无实时指数")
                    .font(.caption2)
                    .foregroundStyle(Tok.labelSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 当前格子的指数：今天用实时（行情时间戳必须是今天），历史日用该日收盘回填。
    private func indexQuote(_ symbol: String) -> StockQuote? {
        if store.isDashboardToday {
            guard let at = store.liveIndexFetchedAt,
                  ChinaTime.day(at) == store.today else { return nil }
            return store.liveIndexQuotes[symbol]
        }
        guard store.historicalIndexQuotesDate == store.viewDate else { return nil }
        return store.historicalIndexQuotes[symbol]
    }

    /// Hero 底部环境条：灯级 + 涨跌比 + 3日趋势 + 状态。
    ///
    /// ⚠ 三段各自必须 `.fixedSize(horizontal: true, vertical: false)` —— 外层用
    ///   `ViewThatFits(in:.horizontal)` 在"单行"与"两行"之间二选一，而**能折行的视图
    ///   永远算"放得下"**：CJK 可以在「3日趋势」和「（上证）」之间断行，于是窄窗口下
    ///   单行版胜出、标签自己折成两行，把「（上证）」孤零零甩到第二行（2026-10-28 老板实拍）。
    ///   钉成原子段之后，放不下才轮到下面的两行兜底版。
    private func heroEnvStrip(lightText: String, lightColor: Color, liveTrend: (String, Color)?,
                              ratioText: String, up: Int?, down: Int?, flat: Int?,
                              trendDisplay: String, regime: (String, Color)?,
                              statusDetail: String, showLive: Bool) -> some View {
        let lead = HStack(spacing: 7) {
            if !lightText.isEmpty {
                Circle().fill(lightColor).frame(width: 8, height: 8)
                Text(lightText).font(.callout.bold()).foregroundStyle(lightColor)
            } else if let (t, c) = liveTrend {
                Circle().fill(c).frame(width: 8, height: 8)
                Text(t).font(.callout.bold()).foregroundStyle(c)
            } else {
                Text("暂无环境数据").font(.callout.bold()).foregroundStyle(Tok.labelSecondary)
            }
            if let (t, c) = regime {
                Text(t).font(.caption.bold()).foregroundStyle(c)
            }
            if showLive {
                Text("实时")
                    .font(.caption2.bold())
                    .foregroundStyle(Sem.down)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Tok.tint(Sem.down), in: Capsule())
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        let ratio = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("涨跌比").foregroundStyle(Tok.labelSecondary)
            Text(ratioText)
                .monospacedDigit()
                .foregroundStyle(ratioText.hasPrefix("待") ? Tok.labelSecondary : Tok.label)
            if let u = up, let d = down, u + d > 0 {
                BreadthBar(up: u, flat: flat ?? 0, down: d)
                    .frame(width: 84)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: true, vertical: false)
        let trend = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("3日趋势（上证）").foregroundStyle(Tok.labelSecondary)
            if trendDisplay == "—" {
                Text("—").foregroundStyle(Tok.labelSecondary)
            } else {
                Text(trendDisplay)
                    .foregroundStyle(Tok.label)
                    .lineLimit(1)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: true, vertical: false)
        let status = VStack(alignment: .trailing, spacing: 3) {
            Text(store.isDashboardToday
                 ? Self.beijingTodayLabel(Date())
                 : "查看日 \(store.viewDate)")
                .font(.caption).foregroundStyle(Tok.labelSecondary)
            Text(statusDetail)
                .font(.caption2).foregroundStyle(Tok.labelSecondary)
                .multilineTextAlignment(.trailing)
        }
        .fixedSize()

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                lead
                ratio
                trend
                Spacer(minLength: 12)
                status
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 18) {
                    lead
                    ratio
                    Spacer(minLength: 0)
                }
                HStack(spacing: 18) {
                    trend
                    Spacer(minLength: 0)
                    status
                }
            }
        }
        .environment(\.colorScheme, colorScheme)
    }

    /// 市场状态五态 → 中文文案（P2）。未知取值原样返回，不猜。
    private static func regimeLabel(_ raw: String) -> String {
        switch raw {
        case "BULL_TREND":      return "多头趋势"
        case "BULL_CORRECTION": return "多头回调"
        case "BEAR_TREND":      return "空头趋势"
        case "PANIC":           return "恐慌"
        case "RECOVERY":        return "修复反弹"
        default:                return raw
        }
    }

    /// 市场状态五态 → 语义色（A股口径：红涨绿跌；回调/修复用次级色，不冒充方向）
    private static func regimeColor(_ raw: String) -> Color {
        switch raw {
        case "BULL_TREND":  return Sem.up
        case "BEAR_TREND", "PANIC": return Sem.down
        case "BULL_CORRECTION", "RECOVERY": return .secondary
        default:            return .secondary
        }
    }

    /// 盘中实时灯的展示文案（与引擎正式灯区分，明确标注"实时"）
    private func realtimeLightText(_ level: MarketLightLevel) -> String {
        switch level {
        case .red: return "红灯 · 盘中连跌≥2日"
        case .yellow: return "黄灯 · 盘中偏弱或平盘"
        case .green: return "绿灯 · 盘中上涨"
        }
    }
}
