import SwiftUI
import SwiftTradingView
import SelectedCore

// MARK: - 详情页卡片（二）：策略命中 → 超买超卖 → 基本面 → 资金流向 → 龙虎榜 → 尾盘结构

extension StockDetailSheet {
    // MARK: 超买超卖

    /// 六条**固定阈值**超买超卖信号（KDJ / RSI / CCI / CR / WR / VR）。
    ///
    /// ⚠ **只展示 —— 不进评分、不进筛选**，两条**独立**的理由：
    /// 1. **清单自己写明**：这类固定阈值信号与 Selected 的评分体系是**两套哲学**
    ///    （Selected 的档位门槛可调且带锁档，比固定阈值更精细），「不建议引入」，
    ///    只可作为"个股详情页的参考指标"展示。
    /// 2. ⚠ 本项目自己的证据更硬：KD / RSI / MACD 都源自同一条价格序列、**高度相关**，
    ///    把几个相关读数当几个**独立**证据去加总会**高估可信度**（判据见 `CorrelationDiagnostic` 文件头）。
    ///    这六条**互相之间**也高度同源 → 做成六个加分项正是那个错误。
    ///
    /// ⚠⚠ **"未评估"与"中性"必须分开显示**：日K不足 / `MD==0`（无波动）/ 分母为 0 时，
    /// 那条判据**根本没跑**。混进"中性"会让界面显示"这只票不超买不超卖"，
    /// 而真相是"**我们没能力判断**"。
    ///
    /// ⚠ 用图上日K现算（**零新数据源、零额外请求**），与形态卡/策略卡同一份 bar 集。
    @ViewBuilder
    var oscillatorCard: some View {
        if dailyKlineLoading || !dailyBars.isEmpty {
            Card("超买超卖", subtitle: oscillatorSubtitle) {
                if let o = oscillatorOutcome, !o.readings.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)],
                                  spacing: 8) {
                            ForEach(o.readings, id: \.kind.rawValue) { oscillatorCell($0) }
                        }
                        // ⚠ 算不出的**单独一组**（"没能力判断" ≠ "中性"）
                        if !oscillatorSkippedKinds.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("未评估（算不出 —— 不等于中性）")
                                    .font(AppFont.detailSmall.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(oscillatorSkippedKinds, id: \.rawValue) { k in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text(k.title)
                                            .font(.caption2).foregroundStyle(.secondary)
                                            .frame(width: 42, alignment: .leading)
                                        Text(o.skipped[k] ?? "")
                                            .font(.caption2).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                        CaliberTip(text: oscillatorCaliber, title: "振荡指标口径")
                    }
                } else if dailyKlineLoading {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)],
                              spacing: 8) {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 4).fill(Tok.skeleton)
                                .frame(height: 30)
                        }
                    }
                } else {
                    // ⚠ 两种原因分开说：走到 else 是「一根日K都没有」或
                    //   「有日K但六条全算不出」（后者含"区间无波动"，与"日K不足是**不同的原因**）。
                    Text(dailyBars.isEmpty ? "没有日K数据，算不出这些指标"
                                           : "日K 不足或区间无波动，这 6 条都算不出")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func oscillatorCell(_ r: Oscillators.Reading) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(r.kind.title).font(AppFont.detailSmall).foregroundStyle(.secondary)
                Text(r.zone.title)
                    .font(AppFont.detailSmall.weight(.semibold))
                    .foregroundStyle(oscillatorZoneColor(r.zone))
            }
            Text(r.values.map { "\($0.name) \(StockFmt.num($0.value, digits: 2))" }
                    .joined(separator: " "))
                .font(AppFont.detail).monospacedDigit()
                .foregroundStyle(r.zone == .neutral ? Color.secondary : Color.primary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 超买 → 红（与"A股涨"同色系）、超卖 → 绿（与"跌"同色系）、中性 → 次级色。
    ///
    /// ⚠ **严重档不改色** —— 严重程度写在文字里（"严重超买"）。
    /// 不额外发明一套配色（`Sem` 里已有的语义色够用，且用户对红涨绿跌已有直觉）。
    private func oscillatorZoneColor(_ z: Oscillators.Zone) -> Color {
        switch z {
        case .overbought, .severeOverbought: return Sem.up
        case .oversold, .severeOversold: return Sem.down
        case .neutral: return .secondary
        }
    }

    private var oscillatorOutcome: Oscillators.Outcome? {
        guard !dailyBars.isEmpty else { return nil }
        return Oscillators.evaluate(dailyBars, config: oscConfig)
    }

    /// 没算出的那几条，按 `allCases` 顺序（`ForEach` 的 id 才稳定）
    private var oscillatorSkippedKinds: [Oscillators.Kind] {
        guard let o = oscillatorOutcome else { return [] }
        return Oscillators.Kind.allCases.filter { o.skipped[$0] != nil }
    }

    private var oscillatorSubtitle: String {
        guard let o = oscillatorOutcome else { return "" }
        let nonNeutral = o.readings.filter { $0.zone != .neutral }
        var s = nonNeutral.isEmpty ? "六条均中性" : "\(nonNeutral.count) 条非中性"
        if !o.skipped.isEmpty { s += " · \(o.skipped.count) 条未评估" }
        return s
    }

    private var oscillatorCaliber: String {
        let c = oscConfig
        func n0(_ v: Double) -> String { String(format: "%.0f", v) }
        return "图上日K现算（不额外发请求），最后一根 = \(dailyBars.last?.date ?? "—")"
            + " · 阈值来自指标筛选设置（KDJ \(n0(c.kdjObK))/\(n0(c.kdjObD))/\(n0(c.kdjObJ))，"
            + "RSI \(c.rsiPeriod) 日，CCI \(c.cciPeriod) 日，CR \(c.crPeriod) 日，"
            + "WR \(c.wrPeriod) 日，VR \(c.vrPeriod) 日）"
            + " · ⚠ 「公式清单没给」，用的是本项目的读法：KDJ 初值 K=D=\(n0(c.kdjInit))、"
            + "一字板 RSV 取 50；RSI 用「简单平均」（不是 Wilder 平滑）；"
            + "CR 的中价取 (H+L)/2；VR 的平盘 = 「收==昨收」。改这些等于改口径。"
            + " · ⚠⚠ 这六条不是六份独立证据 —— KDJ / WR / CR 都基于"
            + "「价在 N 日高低之间的位置」，CCI 用的是均值偏离，只有 VR 用量能；"
            + "而 MFI（已有）与 RSI 同族。把它们当独立证据加总会「高估可信度」"
            + "（可在调优报告的相关性诊断中查看同族指标重叠度）。"
            + " · ⚠ 本卡只展示 —— 不进评分、不进筛选：固定阈值与「评分 + 档位」是两套哲学，仅供参考。"
    }

    // MARK: 基本面

    /// 五组基本面（清单模块 1.2 的六组里**可校验的五组**）。
    ///
    /// ⚠ **只展示 —— 不进评分、不进筛选**。清单自己把它定性成
    /// 「**慢变量**，与"次日午前"的时间尺度不匹配」，而本项目取向也是"选股不掺基本面"
    /// （InStock 策略 11 的 "PE 0~20 + PB≤10 + ROE≥15" 是**另一套哲学**）。
    ///
    /// ⚠ 第六组「股本股东」**不做**：它要的总股本 / 流通股本 / 股东人数所在的字段
    /// 实测**算术上校验不过**（含义不明）→ 宁缺勿错。见 `FundamentalSource` 的校验表。
    ///
    /// ⚠⚠ **`nil` 显示成「—」，不是 0** —— 源用 `-` 表示"没有"，
    /// 而"资产负债率 0%"是"无负债"，与"没数据"**完全不同的结论**。
    /// （这一层由 `StockFmt.num/percent/marketCap` 统一兜住：它们对 `nil` 都返回「—」。）
    @ViewBuilder
    var fundamentalCard: some View {
        if let f = stockFundamentals {
            Card("基本面", subtitle: fundamentalSubtitle(f)) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(f.groups) { g in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(g.title)
                                .font(AppFont.detailSmall.weight(.semibold))
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)],
                                      spacing: 6) {
                                ForEach(g.metrics, id: \.label) { m in
                                    metricCell(m.label, fundamentalText(m))
                                }
                            }
                        }
                    }
                    CaliberTip(text: fundamentalCaliber, title: "基本面口径")
                        .font(AppFont.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if Store.shared.fundamentalStockCount == 0 {
            // ⚠ 整表为空时给一张说明卡（含刷新入口指引）—— 否则整卡消失看起来像
            //   "这一块不存在"，而不是"数据没抓"。
            Card("基本面", subtitle: "未抓取") {
                Text("基本面数据尚未抓取 —— 设置页「个股档案」可刷新")
                    .font(AppFont.detail).foregroundStyle(.secondary)
            }
        }
    }

    /// ⚠ `nil` 一律走 `StockFmt`（它对 `nil` 返回「—」）—— **不要**在这里写 `?? 0`。
    private func fundamentalText(_ m: Fundamental.Metric) -> String {
        switch m.unit {
        case .multiple, .perShare:
            return StockFmt.num(m.value, digits: 2)
        case .percent:
            return StockFmt.percent(m.value)
        case .money:
            // 源是**元**；界面统一按**亿元**读（与市值同一个量级直觉）
            return StockFmt.marketCap(m.value.map { $0 / 1e8 })
        }
    }

    private func fundamentalSubtitle(_ f: Fundamental.Item) -> String {
        let empty = f.groups.flatMap(\.metrics).filter { $0.value == nil }.count
        let total = f.groups.flatMap(\.metrics).count
        return empty == 0 ? "\(total) 项" : "\(total) 项 · \(empty) 项无数据"
    }

    private var fundamentalCaliber: String {
        "数据来自东方财富财务接口（季度级慢变量），"
            + "在设置页「个股档案」里手动刷新。⚠ 本卡只展示 —— 不进评分、不进筛选"
            + "（与「次日午前」的时间尺度不匹配）。"
            + "⚠ 仅展示可校验的五组指标：第六组「股本股东」的源字段校验不稳定，暂未纳入。"
            + "⚠ 「—」= 「无数据」（不是 0）：「资产负债率 0%」是「无负债」，"
            + "与「没数据」完全不同的结论。"
    }

}
