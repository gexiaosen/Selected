import SwiftUI
import SelectedCore

// MARK: - 全局日期胶囊（每页右上角；点击弹出年/月/日级联选择，选完全部页面联动）

struct DateChip: View {
    private let store = Store.shared
    @State private var showPicker = false

    var body: some View {
        HStack(spacing: 6) {
            // 固定占位：当日/历史徽章同尺寸，避免切换时操作栏宽度跳动
            if store.isHistorical {
                Label("历史模式", systemImage: "clock.arrow.circlepath")
                    .font(.caption.bold())
                    .foregroundStyle(Sem.warn)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Tok.tint(Sem.warn), in: Capsule())
                    .help("正在查看历史数据，写操作已禁用")
                // ⚠ 走 `Terms.backToLatest`：三处按钮文案的单一来源（各写各的会漂）
                Button(Terms.backToLatest) { store.backToLatest() }
                    .btnPrimary()
                    .help("回到最近有数据的交易日")
            } else if store.viewDate == store.today {
                Label("当日", systemImage: "calendar.day.timeline.left")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Tok.chip, in: Capsule())
                    .help("查看当日实时数据")
            } else {
                Label("最新", systemImage: "calendar.badge.checkmark")
                    .font(.caption.bold())
                    .foregroundStyle(Sem.info)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Tok.tint(Sem.info), in: Capsule())
                    .help("最近有数据的交易日（写操作可用）")
            }

            freshnessBadge

            HStack(spacing: 4) {
                // ⚠ 命中区 ≥24pt：裸 chevron 只有 ~12pt，要精确命中才点得着。
                //   `.frame` 只改布局、不改命中区 —— 两者必须一起用：
                //   `.frame(minWidth:minHeight:)` + `.contentShape(Rectangle())`。
                Button { store.stepDate(-1) } label: {
                    Image(systemName: "chevron.left").font(.callout.bold())
                        .frame(minWidth: 24, minHeight: 24)
                        .contentShape(Rectangle())
                }
                .btnIcon()
                .help("前一天")

                Button {
                    showPicker = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar")
                        Text(store.viewDate).monospacedDigit()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                // 日期选择器是控件不是动作 → 次操作角色：蓝色只留给每个界面真正的主操作
                // （见 Components.swift 的按钮角色说明）
                .btnSecondary()
                .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                    CascadeDatePicker()
                }
                .help("选择查看日期（所有页面联动）")

                Button { store.stepDate(1) } label: {
                    Image(systemName: "chevron.right").font(.callout.bold())
                        .frame(minWidth: 24, minHeight: 24)
                        .contentShape(Rectangle())
                }
                .btnIcon()
                .disabled(store.viewDate >= store.today)
                .help(store.viewDate >= store.today ? "已是最新日期" : "后一天")
            }
        }
    }

    // MARK: - 数据源新鲜度徽章

    /// 聚合等级。`unknown` **不参与**告警（多半只是该源没被用过），见 `DataFreshness.aggregate`。
    private var freshnessLevel: FreshnessLevel {
        DataFreshness.aggregate(store.sourceFreshness)
    }

    private var freshnessColor: Color {
        switch freshnessLevel {
        case .fresh: return Sem.down
        case .lagging: return Sem.warn
        case .expired: return Sem.up
        case .unknown: return .secondary
        }
    }

    /// 等级 → 短文案（唯一消费方是悬停详情 `freshnessHelp`）。
    ///
    /// ⚠ 保留为单一来源：这个徽章只靠颜色表达等级，等级文字是唯一能补上语义的东西；
    ///   两处各写一份 switch 就会漂。
    private static func levelText(_ l: FreshnessLevel) -> String {
        switch l {
        case .fresh: return "正常"
        case .lagging: return "落后 1 个交易日"
        case .expired: return "落后 ≥2 个交易日"
        case .unknown: return "无成功记录"
        }
    }

    /// 徽章上的短文案：与圆点同色，给颜色补一条文字通道。
    /// 三档都是 2 个汉字，胶囊宽度固定 ⇒ 切换日期时操作栏不跳。
    private var freshnessShortText: String {
        switch freshnessLevel {
        case .fresh: return "正常"
        case .lagging: return "落后"
        case .expired: return "过期"
        case .unknown: return ""
        }
    }

    /// 悬停详情：逐源「最近成功日期 + 等级」。
    /// 参照系 = 应用自己观察到的交易日（`dayMeta`），不是日历推算 —— 长假期间不会假报警。
    private var freshnessHelp: String {
        let ref = DataFreshness.reference(DataFreshness.observedDays(store.dayMeta))
        var lines = ["数据源新鲜度（参照最近交易日 \(ref.latest ?? "无")）"]
        for s in store.sourceFreshness {
            lines.append("\(s.label)　\(s.asOf ?? "—")　\(Self.levelText(s.level))")
        }
        return lines.joined(separator: "\n")
    }

    /// 单枚徽章（固定尺寸，不随等级变宽 —— 避免切换日期时操作栏宽度跳动）。
    /// 无任何可判断的源时整枚不显示，不占位。
    @ViewBuilder
    private var freshnessBadge: some View {
        if freshnessLevel != .unknown {
            HStack(spacing: 4) {
                Circle()
                    .fill(freshnessColor)
                    .frame(width: 8, height: 8)
                // 颜色之外再给一条文字通道：只靠色点在浅/深底上都难快速判断
                Text(freshnessShortText)
                    .font(AppFont.detail.weight(.medium))
                    .foregroundStyle(freshnessColor)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Tok.tint(freshnessColor), in: Capsule())
            .help(freshnessHelp)
            // 本项目不做读屏无障碍 ⇒ 不补 accessibilityLabel（项目既定决策）。
        }
    }
}

// MARK: - 环节完整度圆点（6 环节位掩码）

struct LinkDots: View {
    /// bit0 选股 · bit1 对比 · bit2 预判 · bit3 验证 · bit4 复盘 · bit5 迭代
    ///
    /// ⚠ bit0 叫「选股」（与链路条 `Components.swift` 的 `Stage(name:)` 统一，同一环节不能两个词）。
    ///   「第 N 轮」的用法保留 —— 那是量词，不是环节名。
    let mask: Int

    private static let names = ["选股", "对比", "预判", "验证", "复盘", "迭代"]

    private var presentNames: [String] {
        (0..<6).filter { mask & (1 << $0) != 0 }.map { Self.names[$0] }
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<6, id: \.self) { i in
                Circle()
                    .fill(mask & (1 << i) != 0 ? Sem.selection : Tok.stroke)
                    .frame(width: 5, height: 5)
            }
        }
        .help(presentNames.isEmpty ? "无数据" : "已有环节：\(presentNames.joined(separator: "·"))")
    }
}

// MARK: - 年/月/日三级级联选择浮层（日列表仅显示有数据的日期 + 完整度标记）

struct CascadeDatePicker: View {
    private let store = Store.shared
    @State private var year = ChinaTime.calendar.component(.year, from: Date())
    @State private var month = ChinaTime.calendar.component(.month, from: Date())
    /// 选日后自动收起弹层（年/月列仍保持切换浏览，只有明确选定某天才关闭）
    @Environment(\.dismiss) private var dismiss

    private var meta: [String: Int] { store.dayMeta }

    private var years: [Int] {
        Set(meta.keys.compactMap { Int($0.prefix(4)) }).sorted(by: >)
    }

    private var months: [Int] {
        let prefix = String(format: "%04d-", year)
        return Set(meta.keys.filter { $0.hasPrefix(prefix) }
            .compactMap { Int($0.dropFirst(5).prefix(2)) }).sorted(by: >)
    }

    private var days: [DayItem] {
        let prefix = String(format: "%04d-%02d-", year, month)
        let f = ChinaTime.dayFormatter
        let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
        return meta.keys.filter { $0.hasPrefix(prefix) }
            .compactMap { d -> DayItem? in
                guard let day = Int(d.suffix(2)),
                      let date = f.date(from: d) else { return nil }
                let wd = weekdays[ChinaTime.calendar.component(.weekday, from: date) - 1]
                return DayItem(date: d, day: day, weekday: "周\(wd)", mask: meta[d] ?? 0)
            }
            .sorted { $0.date > $1.date }
    }

    struct DayItem: Identifiable {
        let date: String
        let day: Int
        let weekday: String
        let mask: Int
        var id: String { date }
    }

    var body: some View {
        VStack(spacing: 0) {
            if meta.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.title2).foregroundStyle(.secondary)
                    Text("暂无历史数据\n运行选股后自动积累")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    // ⚠ 走术语表：三处按钮文案的单一来源
                    Button(Terms.backToLatest) { store.backToLatest() }
                        .btnPrimary()
                        .controlSize(.small)
                }
                .padding(30)
                .frame(width: SheetMetrics.datePickCompact.width, height: SheetMetrics.datePickCompact.height)
            } else {
                HStack(spacing: 0) {
                    yearColumn
                    Divider()
                    monthColumn
                    Divider()
                    dayColumn
                }
                .frame(width: SheetMetrics.datePickFull.width, height: SheetMetrics.datePickFull.height)

                Divider()

                HStack(spacing: 8) {
                    LinkDots(mask: 63)
                        .help("完整度：轮次·对比·预判·验证·复盘·迭代")
                    Text("完整度（6 环节）")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if store.isHistorical {
                    // ⚠ 走术语表：三处按钮文案的单一来源
                    Button(Terms.backToLatest) { store.backToLatest() }
                        .btnPrimary()
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .onAppear { alignSelection() }
    }

    /// 选中态对齐当前查看日期；该年月无数据时跳到最新有数据的年月
    private func alignSelection() {
        let current = store.viewDate
        if let y = Int(current.prefix(4)),
           let m = Int(current.dropFirst(5).prefix(2)),
           meta[current] != nil {
            year = y; month = m
            return
        }
        if let latest = meta.keys.max() {
            year = Int(latest.prefix(4)) ?? year
            month = Int(latest.dropFirst(5).prefix(2)) ?? month
        }
    }

    // MARK: 三列

    private var yearColumn: some View {
        listColumn(title: "年", width: 74) {
            ForEach(years, id: \.self) { y in
                row(label: "\(y)年", selected: y == year) {
                    year = y
                    if !months.contains(month) { month = months.first ?? month }
                }
            }
        }
    }

    private var monthColumn: some View {
        listColumn(title: "月", width: 62) {
            ForEach(months, id: \.self) { m in
                row(label: "\(m)月", selected: m == month) {
                    month = m
                }
            }
        }
    }

    private var dayColumn: some View {
        listColumn(title: "日 · 完整度", width: 192) {
            ForEach(days) { item in
                Button {
                    store.setViewDate(item.date)
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Text("\(item.day)日")
                            .frame(width: 34, alignment: .leading)
                        Text(item.weekday)
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .leading)
                        Spacer()
                        LinkDots(mask: item.mask)
                        if item.date == store.today {
                            Text("今天")
                                .font(.caption2.bold())
                                .foregroundStyle(Sem.info)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(item.date == store.viewDate ? Tok.tint(Sem.selection, .strong) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func listColumn<Content: View>(title: String, width: CGFloat,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    content()
                }
                .padding(.vertical, 6)
            }
        }
        .frame(width: width)
    }

    private func row(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Tok.tint(Sem.selection, .strong) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}
