import SwiftUI
import SelectedCore

// MARK: - P1 看板 · 信号分类与今日结论

extension DashboardView {

    /// 信号类型聚合切片：（类型, 数量），按 最强→持续→脉冲 排序，未识别归"other"
    ///
    /// 入参用 `SignalType?`：`nil` 即"其他"（未验证 / 空串 / 未识别统一归此）。图表取值键另经 `chartKey` 落回字符串
    /// —— Swift Charts 的 `foregroundStyle(by:)` 只接受 Plottable，但这层转换收在一处。
    private var signalSlices: [(SignalType?, Int)] {
        let grouped = Dictionary(grouping: store.todaySignals) { Self.sliceKind($0.signalType) }
        let counts = grouped.mapValues { $0.count }
        let ordered: [SignalType] = [.strongest, .consensus, .pulse]
        var slices: [(SignalType?, Int)] = ordered.compactMap { t -> (SignalType?, Int)? in
            guard let n = counts[t], n > 0 else { return nil }
            return (t, n)
        }
        if let others = counts[nil], others > 0 { slices.append((nil, others)) }
        return slices
    }

    /// 独立成块的三种信号；`unverified` 与空串/未识别一并返回 nil（归"其他"）
    private static func sliceKind(_ raw: String) -> SignalType? {
        guard let t = SignalType(rawValue: raw) else { return nil }
        switch t {
        case .strongest, .consensus, .pulse: return t
        case .unverified: return nil
        }
    }

    /// 档位取值键：`nil`（其他）→ "other"；堆叠条的每段与筛选状态都用这个键
    private static func chartKey(_ t: SignalType?) -> String { t?.rawValue ?? "other" }

    // MARK: 信号分类 · 堆叠条
    //
    // ⚠ 别再换回环形图：扇形角度比不出大小，12 只里 8 只脉冲 = 图上一个大棕块，
    //   除了图例已经写着的数字，那张图不提供任何额外信息。堆叠条一次补齐三条通道：
    //   ① **数字落在自己那一段的正上方** —— 数字行与胶囊行共用同一个宽度函数，天然对齐，不必回头查图例；
    //   ② **段序 = 强度序**（最强→持续→脉冲→其他），与右侧清单的排序同向 ⇒ 位置成了真通道；
    //   ③ **段间 2pt 缝** —— 与 `BreadthBar` 同一条 P5 结论：色觉障碍下缝/位置/宽度比颜色可靠。
    // 交互语义原样搬过来（悬停提示、点击筛选、再点当前档复位）；环形图的"点中心孔复位"没有对应物，
    //   由"再点一次"独立承担。命中区 = 数字 + 胶囊整列，比扇区好点。

    /// 段间缝宽：与 `BreadthBar` 同口径
    private static let mixGap: CGFloat = 2
    /// 胶囊段高：本页主视觉，比 `BreadthBar` 的 8pt 抬到 10pt
    private static let mixBarHeight: CGFloat = 10
    /// 数字行高：`.caption` 实测 10pt，固定住免得切换档名时整块跳高
    private static let mixLabelHeight: CGFloat = 13
    private static let mixLabelSpacing: CGFloat = 3
    /// 段宽低于此值只标数字、不标档名（「最强 12」实测 ≈34pt，留余量）
    private static let mixNameMinWidth: CGFloat = 40
    /// 保底段宽：一只也要点得着。代价是总宽可能小幅溢出 —— 最多 4 段 ×8pt，卡片窄不到 50pt
    private static let mixMinSegment: CGFloat = 8

    /// 每段宽度（数字行与胶囊行共用）：占比 × 可用宽，再抬到保底宽
    private func signalMixWidths(_ slices: [(SignalType?, Int)], total: CGFloat) -> [CGFloat] {
        let sum = max(slices.reduce(0) { $0 + $1.1 }, 1)
        let usable = max(total - Self.mixGap * CGFloat(max(slices.count - 1, 0)), 1)
        return slices.map { max(usable * CGFloat($0.1) / CGFloat(sum), Self.mixMinSegment) }
    }

    @ViewBuilder var signalsCard: some View {
        if !store.todaySignals.isEmpty {
            Card("信号分类", subtitle: "\(store.todaySignals.count)只") {
                let allSlices = signalSlices
                // 原来这里是 `ViewThatFits`（宽屏 donut+图例横排 / 窄屏只剩图例）：
                // 堆叠条横向自适应，窄窗口自动退化成"只标数字的短条"，不再需要第二套画法。
                VStack(alignment: .leading, spacing: 8) {
                    signalMixBar(allSlices)
                    Divider()
                    signalListBlock
                }
                .environment(\.colorScheme, colorScheme)
            }
        } else if let pred = store.dashboardPredictFallback {
            // 开盘回退（审查 #1）：当日信号未产出时给今早的预判摘要，而不是一整天占位文案。
            Card("今日预判", subtitle: "选股日 \(pred.selDateDash)") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        LightBadge(level: MarketLightLevel(rawValue: pred.marketEnv.light))
                        Spacer()
                        Text("标的 \(pred.stocks.count) 只").font(.callout)
                    }
                    if pred.stocks.isEmpty && pred.isEmptyDay {
                        Text("空仓日（前日选股为 0 只）")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(pred.overall.prefix(2), id: \.self) { t in
                            Label {
                                Text(t).lineLimit(2)
                            } icon: {
                                Image(systemName: "checkmark.seal")
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        } else {
            Card("信号分类", subtitle: "三轮完成后生成") {
                Text("三轮对比后自动分类为：最强 / 持续 / 脉冲")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func signalMixBar(_ allSlices: [(SignalType?, Int)]) -> some View {
        GeometryReader { geo in
            let widths = signalMixWidths(allSlices, total: geo.size.width)
            HStack(alignment: .top, spacing: Self.mixGap) {
                ForEach(Array(allSlices.enumerated()), id: \.element.0) { idx, item in
                    signalMixColumn(item, width: idx < widths.count ? widths[idx] : Self.mixMinSegment)
                }
            }
        }
        .frame(height: Self.mixLabelHeight + Self.mixLabelSpacing + Self.mixBarHeight)
    }

    /// 一列 = 数字（够宽才带档名）在上 + 胶囊段在下；整列是命中区
    private func signalMixColumn(_ item: (SignalType?, Int), width: CGFloat) -> some View {
        let key = Self.chartKey(item.0)
        let isOn = signalFilter == key
        let dimmed = signalFilter != nil && !isOn
        return VStack(alignment: .leading, spacing: Self.mixLabelSpacing) {
            // 悬停就把字提到 `.primary`：这一列是可点的控件，得有个"压上去有反应"的样子
            let tone: Color = isOn || signalHover == key ? .primary : .secondary
            HStack(spacing: 3) {
                if width >= Self.mixNameMinWidth {
                    Text(Self.signalTypeLabel(item.0))
                        .foregroundStyle(tone)
                        .lineLimit(1)
                }
                // 三轮跑动中计数会跳，这里保留数字滚动（与改造前的环形中心/图例一致）
                RollingNumber(item.1, font: .caption, color: tone)
            }
            .font(.caption)
            .fontWeight(isOn ? .bold : .regular)
            .frame(height: Self.mixLabelHeight, alignment: .leading)
            // ⚠ 压暗只作用在**段**上：整列一起压会把文字拉到对比度以下
            Capsule()
                .fill(Sem.signal(item.0))
                .frame(height: Self.mixBarHeight)
                .opacity(dimmed ? 0.35 : 1)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { signalHover = key }
            else if signalHover == key { signalHover = nil }
        }
        .onTapGesture { signalFilter = isOn ? nil : key }
        .clickableRow()
        .help("\(Self.signalTypeLabel(item.0))：\(item.1) 只（点击只看这一档，再点一次看全部）")
    }

    /// 右侧清单数据：默认**全部**标的，按**强度序**（最强 → 持续 → 脉冲 → 其他）；
    /// 筛选后只看该档。⚠ 同档内按代码升序 —— 与三轮对比段排序口径一致（保证顺序稳定）。
    private var signalListRows: [SignalClassRow] {
        let base = signalFilter == nil
            ? store.todaySignals
            : store.todaySignals.filter { Self.chartKey(Self.sliceKind($0.signalType)) == signalFilter }
        return base.sorted { a, b in
            let ra = Self.signalRank(a), rb = Self.signalRank(b)
            return ra == rb ? a.code < b.code : ra < rb
        }
    }

    /// 强度序（`SignalType.rank`）；未验证 / 未识别与"其他"同档，排最后
    private static func signalRank(_ row: SignalClassRow) -> Int {
        (SignalType(rawValue: row.signalType) ?? .unverified).rank
    }

    /// 信号清单窗口高 = **恰好放下 5 行**（上下宽度固定，最多放下 5 只）。
    ///
    /// 行高由**实测内容高反推**（`contentH = n 行 + (n-1) × 行距 4`）—— 字号/系统文字大小变了也准；
    /// 实测未到位（首帧）时用同口径估算（callout 行高 ≈ 18 + 行距 4）兜底，避免首帧塌一下。
    /// ⚠ **固定值**：不按当前行数收缩（筛选后只剩两三行时窗口仍占 5 行高）——卡片高度恒定、不跳。
    /// ⚠ 超过 5 行在窗口**内滚**（默认仍列出全部标的，见 `signalListRows`）。
    private static func signalListHeight(contentH: CGFloat, rowCount: Int) -> CGFloat {
        let spacing: CGFloat = 4
        let estRowH: CGFloat = 18
        guard rowCount > 0, contentH > 0 else { return estRowH * 5 + spacing * 4 }
        let rowH = (contentH - spacing * CGFloat(rowCount - 1)) / CGFloat(rowCount)
        guard rowH > 0 else { return estRowH * 5 + spacing * 4 }
        return rowH * 5 + spacing * 4
    }

    /// 标的清单（强度序；筛选后只看该档，超过 5 行在窗口内滚）
    ///
    /// 原来这里上面还挂着一列图例（色点 + 档名 + 计数）—— 堆叠条把那份信息搬到条上去了
    /// （数字压在自己那段上、够宽时带档名），留着就是同一屏两遍。
    private var signalListBlock: some View {
        // ⚠ 清单窗口高固定 = 恰好 5 行（见 `signalListHeight`）：卡片上下不随筛选/条数变化
        let rows = signalListRows
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows, id: \.code) { s in
                    HStack(spacing: 8) {
                        // ⚠ 只显示名称
                        Text(s.nameDash)
                            .lineLimit(1)
                            .stockDetailTap(code: s.code, name: s.nameDash)
                        SignalTag(type: SignalType(rawValue: s.signalType))
                        Spacer()
                        Text(s.trendDash)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.callout)
                }
            }
            // 实测内容高 → 反推单行高度（行距 4；行内容均 lineLimit(1)，行高一致）
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { signalListContentH = $0 }
        }
        // 固定高度 = 恰好放下 5 行（上下固定、最多 5 只）
        //   ⚠ 不随筛选后的行数收缩 —— 卡片高度恒定，筛来筛去页面不跳
        .frame(height: Self.signalListHeight(contentH: signalListContentH, rowCount: rows.count))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 档位短文案（堆叠条上的标注用）：`unverified` 与"其他"合并显示为"其他"（≡ 原先的 `default`）
    private static func signalTypeLabel(_ t: SignalType?) -> String {
        switch t {
        case .strongest: return "最强"
        case .consensus: return "持续"
        case .pulse: return "脉冲"
        case .unverified, nil: return "其他"
        }
    }

    // MARK: 今日结论

    @ViewBuilder var conclusionCard: some View {
        if let cmp = store.compareReport, cmp.isOK, !cmp.suggestions.isEmpty {
            Card("今日结论", subtitle: "\(cmp.suggestions.count)条") {
                conclusionList(cmp.suggestions)
            }
        } else if let cmp = store.dashboardConclusionFallback, !cmp.suggestions.isEmpty {
            // 开盘回退（审查 #1）：当日结论未产出时给最新一份历史结论，标题日期说清是哪天。
            Card("最新结论", subtitle: cmp.date) {
                conclusionList(cmp.suggestions)
            }
        } else {
            Card("今日结论", subtitle: "三轮对比后生成") {
                Text("三轮对比完成后自动生成操作建议")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func conclusionList(_ suggestions: [CompareSuggestion]) -> some View {
        ForEach(suggestions.prefix(3), id: \.text) { s in
            Label {
                // ⚠ `TextMarkup.toCJK`：文案源头已是「」；
                //   保留归一化只为兼容历史落库的 `**` 形态（详见 TextMarkup）。
                Text(TextMarkup.toCJK(s.text)).lineLimit(2)
            } icon: {
                Image(systemName: SuggestionStyle.icon(s.type))
                    .foregroundStyle(SuggestionStyle.color(s.type))
            }
            .font(.callout)
        }
    }
}
