import SwiftUI
import SelectedCore

// MARK: - 三轮对比（选股结果页**时间线的第四格**，不是独立页面）
//
// 2026-10-29 老板两步拍板：M1「拆开没必要」⇒ 并入选股结果页；M2「三轮入口调整到这，
// 不要平铺在最下面 —— 他们正好是一个时间线：第一轮、第二轮、第三轮、三轮对比」
// ⇒ 于是它从页尾那段变成段选器的第四格：**切到这一格 = 整页换成对比内容**。
// 顶栏（日期 + 「生成对比」）与滚动容器都由 `ResultsView` 提供，本视图只负责这一格。
// 深链（通知「三轮对比已生成」）也落到结果页，由 `Store.compareLegRequested` 把时间线切过来。

struct CompareSection: View {
    private let store = Store.shared

    var body: some View {
        VStack(spacing: 14) {
            // 段标题**不写**：这一格的入口就是段选器上那枚「三轮对比」，内容区再来一遍
            // 是同一件事说两遍（M1 时它是页尾一段才需要分界标题，M2 变成一格之后不需要）。

            // 重跑失败时旧报告仍在屏上（`staleWhileBusy`），toast 走后就没人知道
            //   这是旧数 —— 就近给出口径说明 + 重试（见 `RunFailureBanner`）
            if store.compareReport != nil {
                RunFailureBanner(key: "compare",
                                 staleNote: "屏上仍是上一次成功的对比报告，本次未更新",
                                 retryTitle: "重试生成") {
                    store.generateCompare()
                }
            }

            // 判据是"有没有报告"而不是"在不在跑"：重跑期间旧报告留在原位
            //   （`staleWhileBusy` 淡化 + 禁交互），进度由操作栏那颗「生成对比」按钮的转圈承担
            //   —— 整块换成 LoadingView 会连带丢掉滚动位置。
            if let cmp = store.compareReport {
                Group {
                    // ⚠ 报告存在但 `status != ok`（如 `no_data`）须单独呈现：
                    //   若落进下面的空态分支，会把「数据不足/失败」读成「还没到点」，用户不会去排查。
                    // ⚠ hint 用 `cmp.statusLabel`（映射收在 CompareEntities），
                    //   不暴露引擎原始 `status` 字段（开发者词汇）。
                    if cmp.isOK {
                        content(cmp)
                    } else {
                        EmptyStateView(
                            icon: "exclamationmark.triangle",
                            title: "对比未生成（数据不足）",
                            hint: "当日轮次不足以做交并集分析（原因：\(cmp.statusLabel)）"
                                  + " —— 三轮选股至少要有两轮出票。")
                    }
                }
                .staleWhileBusy(store.busy.contains("compare"))
            } else if store.busy.contains("compare") {
                LoadingView(text: "汇总三轮对比…", design: .connecting)
            } else {
                VStack(spacing: 12) {
                    // 空态透明化：显示预计生成时间而非空白（⚠ 时刻读 `ScheduleTimes`，写死会在用户改调度后失真）
                    PendingStageView(stageName: "对比", eta: "选股日 \(ScheduleTimes.shared.clock("compare"))")
                    RecentRecordHint(lead: "当日三轮扫描与对比在 \(ScheduleTimes.shared.clock("compare")) 生成") { d in
                        store.jump(toDate: d)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    @ViewBuilder
    private func content(_ cmp: CompareReport) -> some View {
        let slots = cmp.availableSlots
        let stab = cmp.stability

        Card("大盘环境变化") {
            VStack(alignment: .leading, spacing: 12) {
                let envTable = cmp.marketEnvTable
                // 三轮卡片式呈现：柱状图只画涨跌幅（负值向下），轮次信息以列形式排布
                if envTable.count > 1 {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(envTable, id: \.slot) { m in
                            envRoundCard(m)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                // 单轮时无对比意义，退化为原文本行
                if envTable.count == 1, let m = envTable.first {
                    HStack {
                        Text("第\(m.slot)轮 \(m.labelDash)")
                            .frame(width: 110, alignment: .leading)
                        PnlText(value: m.shChangePctOrNil)
                        Text("涨平跌 \(m.upCount):\(m.flatCount):\(m.downCount)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(m.shOK ? "正常" : "偏弱")
                            .font(.caption.bold())
                            .foregroundStyle(m.shOK ? Sem.down : Sem.warn)
                    }
                    .font(.callout)
                }
            }
        }

        Card("信号稳定性") {
            VStack(alignment: .leading, spacing: 6) {
                let groups = stabilityGroups(stab)
                let maxCount = groups.map { $0.1.count }.max() ?? 0
                ForEach(Array(groups.enumerated()), id: \.element.0) { _, g in
                    stabilityRow(g.0, codes: g.1, color: g.2, maxCount: maxCount)
                }
            }
        }
        // 尾部卡片「拉伸吞留白」：未消费的高度吸进卡片，页面底部不露白
        .frame(maxHeight: .infinity, alignment: .top)

        let signals = cmp.signals
        if !signals.isEmpty {
            Card("逐标的轨迹") {
                // 静态表统一走 SharedDataTable（列定义/排序在 helper 里，ViewBuilder 内不放语句）
                SharedDataTable(columns: compareColumns(slots),
                                rows: compareOrderedCodes(signals)) { code, c in
                    compareCell(code: code, column: c, signals: signals)
                }
            }
        }

        // ⚠ `TextMarkup.toCJK`：源头文案已是「」；保留归一化是为历史落库数据兼容 ——
        //   `compare_reports` 里旧轮次的 JSON 仍是 `**` 形态，`Text(String)` 走 verbatim 会把星号原样显示。
        ForEach(cmp.warnings, id: \.self) { text in
            ErrorView(message: TextMarkup.toCJK(text))
        }

        let suggestions = cmp.suggestions
        if !suggestions.isEmpty {
            Card("操作建议") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(suggestions, id: \.text) { s in
                        Label {
                            Text(TextMarkup.toCJK(s.text))
                        } icon: {
                            Image(systemName: SuggestionStyle.icon(s.type))
                                .foregroundStyle(SuggestionStyle.color(s.type))
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    /// 单轮大盘环境卡片：涨跌幅迷你条（0 轴居中、红涨绿跌）+ 涨跌比 + 环境状态，一列一轮信息聚合
    private func envRoundCard(_ m: CompareMarketEnvRow) -> some View {
        let pct = m.shChangePct
        let up = m.upCount
        let down = m.downCount
        let flat = m.flatCount
        let ok = m.shOK
        return VStack(alignment: .leading, spacing: 6) {
            Text("第\(m.slot)轮 · \(m.labelDash)")
                .font(.caption.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            PnlText(value: pct)
                .font(.callout.bold())
            // 0 轴居中的迷你涨跌条：共用组件（审查 #16），量程 ±1.5%、红涨绿跌
            ZeroAxisDeltaBar(value: pct, fullScale: 1.5,
                             positiveColor: Sem.upGraph, negativeColor: Sem.downGraph,
                             baselineColor: Tok.skeleton)
                .frame(height: 12)
            HStack(spacing: 6) {
                Text("涨平跌 \(up):\(flat):\(down)")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 0)
                Text(ok ? "正常" : "偏弱")
                    .font(.caption2.bold())
                    .foregroundStyle(ok ? Sem.down : Sem.warn)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.sunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 稳定性分组（标签, 代码列表, 颜色）：轮次不足时只显示未验证组，
    /// 不展示"三轮均一档"这类结论（缺失轮次会伪造出一致性）
    ///
    /// ⚠ 判据用 `isExplicitlyUnverified`（显式 `false` 才算未验证）——
    ///   用 `!persistenceVerified` 会把"键缺失"也算成未验证（`no_data` 变体就是空 stability）。
    private func stabilityGroups(_ stab: CompareStability) -> [(String, [String], Color)] {
        if stab.isExplicitlyUnverified {
            return [
                ("未验证（按脉冲对待）", stab.unverified, .secondary),
                ("末轮新增（尾盘强化）", stab.finalNew, Sem.tailEnhance),
                ("评分递减（信号减弱）", stab.declining, .secondary),
            ]
        }
        return [
            ("三轮均一档（最强）", stab.alwaysTier1, Sem.signal(.strongest)),
            ("三轮均入档（持续）", stab.consensus, Sem.signal(.consensus)),
            ("非全轮入选（脉冲）", stab.pulseOnly, Sem.signal(.pulse)),
            ("末轮新增（尾盘强化）", stab.finalNew, Sem.tailEnhance),
            ("评分递减（信号减弱）", stab.declining, .secondary),
        ]
    }

    private func stabilityRow(_ label: String, codes: [String], color: Color, maxCount: Int) -> some View {
        let list = codes
        // 条宽按组内最大计数归一化（maxCount=0 或无数据不画条）
        let ratio = maxCount > 0 ? Double(list.count) / Double(maxCount) : 0
        return HStack(alignment: .center, spacing: 10) {
            Text(label).font(.callout).foregroundStyle(color)
                .frame(width: 150, alignment: .leading)
            ProgressView(value: ratio)
                .progressViewStyle(.linear)
                .tint(color)
                .frame(width: 60)
            Text(list.isEmpty ? "无" : list.joined(separator: "、"))
                .font(.callout)
            Spacer()
        }
        .help("\(label)：\(list.count) 只")
    }

    private func compareColumns(_ slots: [Int]) -> [DataTableColumn] {
        var cols = [DataTableColumn("name", "标的")]
        for slot in slots {
            cols.append(DataTableColumn("round\(slot)", "第\(slot)轮", width: 88,
                                        alignment: .trailing, isNumeric: true))
        }
        cols.append(DataTableColumn("signal", "信号", width: 88))
        cols.append(DataTableColumn("trend", "趋势", width: 110))
        return cols
    }

    /// ⚠ `signals` 是动态键（键=证券代码）→ 行 id 用 code；按信号强度排序，同档按代码稳定。
    private func compareOrderedCodes(_ signals: [String: CompareSignal]) -> [String] {
        signals.keys.sorted { a, b in
            let ra = SignalType(rawValue: signals[a]?.signalType ?? "")?.rank ?? 9
            let rb = SignalType(rawValue: signals[b]?.signalType ?? "")?.rank ?? 9
            return ra == rb ? a < b : ra < rb
        }
    }

    @ViewBuilder
    private func compareCell(code: String, column c: DataTableColumn,
                             signals: [String: CompareSignal]) -> some View {
        let m = signals[code] ?? CompareSignal(JSONValue([:]))
        switch c.id {
        case "name":
            Text(m.nameDash)
                .lineLimit(1)
                .stockDetailTap(code: code, name: m.nameDash)
        case "signal":
            SignalTag(type: SignalType(rawValue: m.signalType))
        case "trend":
            Text(m.trendDash).foregroundStyle(.secondary)
        default:
            let slot = Int(c.id.dropFirst(5)) ?? 0
            compareScoreCell(m.scores[slot])
        }
    }

    /// 逐标的轨迹里的单轮分数：入档才给淡色胶囊（红=入档），缺失轮显示 `·`。
    @ViewBuilder
    private func compareScoreCell(_ v: Double?) -> some View {
        if let sv = v {
            let qualified = store.tier1Min.map { sv >= Double($0) } ?? false
            let observed = store.tier2Min.map { sv >= Double($0) } ?? false
            if qualified {
                Text("\(Int(sv))")
                    .font(TableMetrics.rowNumericFont.weight(.bold))
                    .foregroundStyle(Sem.up)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Tok.tint(Sem.up)))
            } else {
                Text("\(Int(sv))")
                    .foregroundStyle(observed ? Sem.warn : Color.secondary)
            }
        } else {
            Text("·").foregroundStyle(Tok.dim)
        }
    }

}
// MARK: - 早盘预判

struct PredictView: View {
    private let store = Store.shared

    var body: some View {
        VStack(spacing: 0) {
            PageActionBar {
                DateChip()
                ActionBarButton(title: "重算", isBusy: store.busy.contains("predict"),
                                isDisabled: !(store.viewDate == store.today || store.viewDate == store.engineTargetSelDate),
                                helpText: (store.viewDate == store.today || store.viewDate == store.engineTargetSelDate)
                                    ? "按最新行情重算引擎目标选股日（\(store.engineTargetSelDate ?? store.today)）的预判"
                                    : "该日非引擎预判目标（目标为 \(store.engineTargetSelDate ?? "--")），不可重算") {
                    store.recomputePredict()
                }
            }
            FitScrollView {
                VStack(spacing: 14) {
                    if store.busy.contains("predict") {
                        LoadingView(text: "按最新行情重新预判…", design: .solving)
                    } else if let pred = store.predictReport {
                        if pred.stocks.isEmpty && pred.isEmptyDay {
                            EmptyStateView(icon: "tray", title: "空仓日（前日选股为 0 只）",
                                           hint: "空仓是有效的风控信号；本日不生成预判，不消耗迭代计数器")
                        } else {
                            content(pred)
                        }
                    } else {
                        VStack(spacing: 12) {
                            // 空态透明化：显示预计生成时间而非空白（针对本选股日的次日开盘；时刻读 `ScheduleTimes`）
                            PendingStageView(stageName: "预判", eta: "T+1 \(ScheduleTimes.shared.clock("predict"))")
                            RecentRecordHint(lead: "预判在选股次一交易日 \(ScheduleTimes.shared.clock("predict")) 生成") { d in
                                store.jump(toDate: d)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private func content(_ pred: PredictResult) -> some View {
        let mc = pred.marketEnv
        // 灯级解析一次，徽章与红灯分支共用（`nil` = 缺失/未识别 → 非红灯）
        let light = MarketLightLevel(rawValue: mc.light)

        Card("大盘预判", subtitle: "选股日 \(pred.selDateDash) · T+1 \(pred.predictTimeDash) 生成",
             prominence: .hero) {
            VStack(spacing: 10) {
                HStack {
                    LightBadge(level: light)
                    Spacer()
                    Text("开盘：\(mc.openStatusDash) \(String(format: "%+.2f", mc.shOpenPct))%")
                    Text("外盘：\(mc.usMarketDash)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Text("3日趋势").foregroundStyle(.secondary)
                    Text(mc.sh3dTrendDash)
                    Spacer(minLength: 0)
                }
                .font(.callout)
                if light == .red {
                    // 三价合一的成因在此说明：crash 分支不操作，目标/止损无意义（非数据异常）
                    ErrorView(message: "红灯预警：大盘连跌≥2日，建议空仓观望，不操作。下列个股不给出目标价/止损价（无操作即无止盈止损），属策略预期。")
                }
            }
        }
        // ⚠ 拉伸只能挂**最后一张卡**。原实现挂在“大盘预判”上，把首页摘要卡拉成
        //   一大片空白、真正需要铺满的个股列表反而留在中间（截图见 2026-10-20 审查）。
        let stocks = pred.stocks
        let hasOverall = !pred.overall.isEmpty
        if !stocks.isEmpty {
            if hasOverall {
                stocksCard(stocks)
            } else {
                // 没有总体策略时，个股列表就是尾卡：吃掉剩余高度
                stocksCard(stocks)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }

        if hasOverall {
            Card("总体策略") {
                ForEach(pred.overall, id: \.self) { t in
                    Label(t, systemImage: "checkmark.seal").font(.callout)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func stocksCard(_ stocks: [PredictStock]) -> some View {
        Card("个股操作建议", subtitle: "\(stocks.count)只 · 持续信号优先") {
            VStack(spacing: 0) {
                ForEach(stocks, id: \.code) { s in
                    predictRow(s)
                        .padding(.vertical, 8)
                    if s.code != stocks.last?.code {
                        TableRule()
                    }
                }
            }
        }
    }

    private func predictRow(_ s: PredictStock) -> some View {
        // crash 分支：红灯日不操作，目标/止损无意义 → 显示"—"而非与选股价相同的数字
        let isCrash = s.strategyKey == "crash"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text("\(s.code) \(s.nameDash)").bold()
                    .lineLimit(1)
                    .stockDetailTap(code: s.code, name: s.nameDash)
                SignalTag(type: SignalType(rawValue: s.signalType))
                if isCrash {
                    Label("红灯 · 空仓观望", systemImage: "exclamationmark.octagon")
                        .font(.caption.bold())
                        .foregroundStyle(Sem.up)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Tok.tint(Sem.up), in: Capsule())
                        .help("大盘连跌≥2日触发红灯：策略不操作，无止盈止损价（非数据异常）")
                }
                Spacer(minLength: 8)
                // 风险与建议收成一个右上角小组：不再各自飘在行尾、与下一行的“预判”错位。
                // crash 行左侧已有红灯胶囊，右侧不再重复一次“空仓观望”。
                if !isCrash {
                    HStack(spacing: 6) {
                        Text(s.riskLevelDash)
                            .font(AppFont.detail.weight(.semibold))
                            .foregroundStyle(riskColor(s.riskLevel))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Tok.tint(riskColor(s.riskLevel)), in: Capsule())
                        Text(s.positionAdviceDash)
                            .font(AppFont.detail)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                statCellText("选股价", StockFmt.price(s.selPrice, code: s.code))
                    .frame(maxWidth: .infinity, alignment: .leading)
                statCellPnl("开盘", s.openPctOrNil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                statCellText("卖出窗口",
                             isCrash ? "不参与" : "\(s.sellWindowStartDash)~\(s.sellWindowEndDash)",
                             bold: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // 着色口径与个股详情页统一（走 `Sem.targetPrice` / `Sem.stopLossPrice` 语义色，勿两页写反）
                statCellText("目标价", isCrash ? "—" : StockFmt.price(s.targetPrice, code: s.code),
                             color: isCrash ? .secondary : Sem.targetPrice)
                    .frame(maxWidth: .infinity, alignment: .leading)
                statCellText("止损价", isCrash ? "—" : StockFmt.price(s.stopLossPrice, code: s.code),
                             color: isCrash ? .secondary : Sem.stopLossPrice)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // “预判”也是同一排统计格：标签/数值与左边五格同基线，
                // 不再用 Spacer 推到最右、悬在统计行外面。
                VStack(alignment: .leading, spacing: 2) {
                    Text("预判").font(AppFont.detail).foregroundStyle(.secondary)
                    Text(s.predictDirectionDash).font(.callout).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !isCrash {
                priceRangeBar(s)
            }
        }
    }

    /// 价格区间条（dumbbell 简化版）：选股价 → 目标价 盈利区间（红），
    /// 选股价 → 止损价 风险区间（绿）。
    ///
    /// ⚠ 不读生产者不产出的键（如 `open_price`：`PhasePredict` 与冻结的 Python 参考实现都没有它，
    ///   读出来恒为 `nil`——不报错、只是永远空）。需要开盘游标应改读 `open_pct` 换算。
    /// ⚠ 数据守卫用 `@ViewBuilder` + `if`，不用 `AnyView(EmptyView())`——
    ///   `AnyView` 破坏结构身份（任何状态变化整条重建）。
    @ViewBuilder
    private func priceRangeBar(_ s: PredictStock) -> some View {
        let sel = s.selPrice
        let target = s.targetPrice
        let stop = s.stopLossPrice
        let lo = min(sel, stop)
        let hi = max(sel, target)
        if sel > 0, target > 0, stop > 0, hi > lo {
            priceRangeBarShape(lo: lo, hi: hi, sel: sel, target: target, stop: stop, code: s.code)
        }
    }

    /// 区间条本体（守卫之外的部分；单独立函数是因为视图构建器里**不能声明局部函数** `pos`）
    private func priceRangeBarShape(
        lo: Double, hi: Double, sel: Double, target: Double, stop: Double, code: String
    ) -> some View {
        let span = hi - lo
        func pos(_ v: Double) -> CGFloat { CGFloat((v - lo) / span) }
        return GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                // 轨道
                Capsule().fill(Tok.stroke).frame(height: 4)
                // 止损区间（选股价→止损价）：A股绿=下跌风险
                Capsule()
                    .fill(Sem.downGraph)
                    .frame(width: max(abs(pos(stop) - pos(sel)) * w, 3), height: 4)
                    .offset(x: min(pos(stop), pos(sel)) * w)
                // 目标区间（选股价→目标价）：红=上涨收益
                Capsule()
                    .fill(Sem.upGraph)
                    .frame(width: max(abs(pos(target) - pos(sel)) * w, 3), height: 4)
                    .offset(x: min(pos(target), pos(sel)) * w)
                // 选股价锚点（白芯圆点）
                Circle().fill(Color.primary).frame(width: 6, height: 6)
                    .offset(x: pos(sel) * w - 3)
            }
            .frame(height: 12)
        }
        .frame(height: 12)
        .help("绿=止损区间 \(StockFmt.price(stop, code: code))，红=目标区间 \(StockFmt.price(target, code: code))，锚点=选股价 \(StockFmt.price(sel, code: code))")
    }

    private func statCellText(_ label: String, _ value: String, bold: Bool = false, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(AppFont.detail).foregroundStyle(.secondary)
            Text(value).font(bold ? .callout.bold().monospacedDigit() : .callout.monospacedDigit())
                .foregroundStyle(color)
        }
    }

    private func statCellPnl(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(AppFont.detail).foregroundStyle(.secondary)
            PnlText(value: value).font(.callout)
        }
    }

    /// 风险配色：未识别 / 空串 → nil → 次级色（`Sem.risk` 的唯一入口）
    private func riskColor(_ raw: String) -> Color {
        Sem.risk(RiskLevel(rawValue: raw))
    }
}
