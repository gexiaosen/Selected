import SwiftUI
import SelectedCore

/// 「数据源诊断」卡片 —— `data_source_logs` 的**唯一界面出口**。
///
/// ## 为什么要有
/// `data_source_logs` 一直在被写（`DataSources.logDataSource` / `ParamStore` 两处，30 天保留），
/// 但没有读取方就是"写了没人看"。真实事故的教训：界面只有一句笼统的
/// 「抓取失败（源无响应或返回不完整）」，真因（`The network connection was lost.`）
/// 要在这张表里翻很久才找到。⇒ 本卡把「用户报障 → 开发者翻 Issue」变成「用户自己看得到」。
///
/// ## 为什么限高 + 筛选
/// 诊断是**排查用**、不是日常用；200 行日志会把设置页撑得很长。
/// ⇒ 列表 300pt 内滚 + 顶部筛选条（胶囊 + 库内条数）；翻页按钮在列表**下方**
///   （它是"往下看更早的"，放列表上方与视觉流向相反）。
///
/// ## 与 `selftestCard`（数据源自检）的分工
/// · 自检 = **现在**能不能用（每个源通不通、拿到几个）
/// · 本卡 = **过去**出了什么事（错误原文、发生时刻、哪个源）
/// ⇒ 两个都要：自检说「基本面抓取失败」，本卡给出「`The network connection was lost.`」。
extension SettingsView {

    /// 日志列表的高度上限（超出即内部滚动）。
    ///
    /// ⚠ 为什么是固定 240：设置窗口默认 500 高，240 ≈ 8~9 行，看"最近出了什么事"够用，
    ///   又不会在纵向堆叠四卡时把下方「个股档案 / 历史回放」推太远。翻更早记录用列表下方「再往前」。
    private static let diagListHeight: CGFloat = 240

    /// 三个 `@State` 在 `SettingsView` 的**主声明**里（Swift 不允许 extension
    /// 含存储属性，编译报 "extensions must not contain stored properties"）。
    /// ⚠ `diagStore` 必须用 `@State` 持有：`@Observable` 的追踪依赖存在 State 里，
    ///   裸 `let` 属性不会订阅（与 `StockDetailSheet` 的 `detailStore` 同一个约束）。
    private var diagStore: DataSourceLogStore { diagStoreRef }


    var diagnosticsCard: some View {
        // ⚠ `diagTick` 只为建立依赖：读它就等于声明"本视图依赖 Store 的刷新"，
        //   但它本身不进 UI（否则会显示一个无意义的数字）。
        let _ = diagTick
        return Card("数据源诊断", subtitle: "取数日志 · 库内保留 30 天") {
            VStack(alignment: .leading, spacing: 10) {
                summaryRow

                if let err = diagStore.loadError {
                    // 表不存在与「查询失败」要分开说 —— 前者的解法是「去跑迁移」
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(Sem.warn)
                } else if diagStore.loadedAt == nil {
                    // ⚠ "没有"与"没查"不能长得一样：用户**还没点「加载日志」**时
                    //   不能无条件写「暂无日志（数据源还没被调用过）」—— 这正是本卡要消灭的歧义。
                    HStack(spacing: 6) {
                        if diagStore.isLoading {
                            ProgressView().controlSize(.small)
                            Text("正在读取…").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("点上方「加载日志」查看最近 \(DataSourceLogStore.defaultLimit) 条取数日志。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    filterBar
                    if diagStore.entries.isEmpty {
                        Text(diagStore.diagFilter.isEmpty
                             ? "暂无日志（数据源还没被调用过）"
                             : "该筛选下没有记录")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        logList
                        loadOlderButton
                    }
                }
            }
        }
    }

    // MARK: 摘要行

    private var summaryRow: some View {
        // ⚠ 用 `VStack` 包而不是裸 HStack：既要一行按钮，又要下面的「覆盖范围」提示
        //   ⇒ 多语句的 some View 必须**显式 return**（Swift 只在单表达式时隐式返回）。
        VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
            Button {
                diagStore.reload()
                diagTick += 1
            } label: {
                Label(diagStore.loadedAt == nil ? "加载日志" : "刷新",
                      systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(diagStore.isLoading)

            if diagStore.loadedAt != nil {
                statusBadge
                if let t = diagStore.loadedAt {
                    Text("截至 \(Self.hm(t))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        // ⚠ **必须显示覆盖范围**（最近 200 条只覆盖约 9 天）：不说的话，
        //   用户查不到近期那次事故会以为「日志里没有 = 没发生过」——
        //   而「没有」和「没查」在界面上长得一模一样，这正是本条要消灭的歧义。
        if let from = diagStore.coveredFrom, !from.isEmpty {
            Text(coverageText(from))
                .font(.caption).foregroundStyle(.secondary)
        }
        }
    }

    /// 一行状态徽章。
    ///
    /// ⚠ 两种口径：
    ///   · 无筛选 → 「最近 N 条里有 M 条错误」（**窗口**口径：这一窗的出错密度）
    ///   · 有筛选 → 「「错误」共 2,065 条 · 已加载 200 条」（**库内**口径）
    ///     筛选状态下窗口里全是这一类，再说"200 条里有 200 条错误"是**循环论证**；
    ///     用户此时要知道的是"这一类总共有多少、我翻到哪儿了"。
    @ViewBuilder
    private var statusBadge: some View {
        let loaded = diagStore.entries.count
        if diagStore.diagFilter.isEmpty {
            let errCount = diagStore.entries.filter { $0.event == "error" }.count
            if errCount > 0 {
                badgeText("最近 \(loaded) 条里有 \(errCount) 条错误", color: Sem.up)
            } else {
                Label("最近 \(loaded) 条无错误", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            let f = diagStore.diagFilter
            let total = diagStore.eventCounts.first { $0.event == f }?.count ?? 0
            badgeText("「\(DataSourceLogStore.eventLabel(f))」共 \(Self.grouped(total)) 条 · 已加载 \(loaded) 条",
                      color: Sem.info)
        }
    }

    /// 徽章胶囊（**底色走 `Tok.tint`、文字用语义色本身**）。
    ///
    /// ⚠ `Tok.onAccent` 是"**实底**彩底上的文字"（浅色=白、深色=近黑），
    ///   配在 8% 透明度的淡色底上 ⇒ 浅色外观下白字压浅底、几乎看不见。
    ///   正确写法与 `LightBadge` / `SignalTag` 一致：淡底 + **语义色本身**当文字色。
    private func badgeText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Tok.tint(color, .block), in: Capsule())
            .foregroundStyle(color)
    }

    /// 覆盖范围 + 库内总量（`totalCount` 来自 `GROUP BY`）。
    private func coverageText(_ from: String) -> String {
        let head = "已加载 \(diagStore.entries.count) 条，最早一条 \(Self.hmOnly(from))。"
        guard diagStore.totalCount > 0 else { return head }
        return head + "库中共 \(Self.grouped(diagStore.totalCount)) 条 / 保留 30 天 —— 用「再往前」翻到更早。"
    }

    /// 千分位（`2065` → `2,065`）。
    ///
    /// ⚠ 用 `formatted()` 而不是手写分组：跟随系统 locale（本项目界面语言只有中文，
    ///   中文 locale 的分组符就是逗号）。诊断数字动辄四位数，不分组读不出量级。
    private static func grouped(_ n: Int) -> String { n.formatted() }

    // MARK: 事件筛选（顶部筛选条）

    /// 一行筛选胶囊：`全部` + 排前几类（各带**库内**条数）+ 其余收进「更多」。
    ///
    /// ⚠ **无条件显示**（有日志就显示）：若显示条件是"已选中"而唯一写选中态的地方是它自己，
    ///   筛选条就永远不会出现（死代码）。选中态直接读 `diagStore.diagFilter`
    ///   （不另存一份 `@State` —— 两份状态早晚不一致）。
    private var filterBar: some View {
        DiagChipFlow(hSpacing: 6, vSpacing: 6) {
            Text("只看").font(.caption).foregroundStyle(.secondary)
            filterChip("", label: "全部", count: diagStore.totalCount)
            ForEach(chipEvents) { ec in
                filterChip(ec.event, label: DataSourceLogStore.eventLabel(ec.event), count: ec.count)
            }
            if diagStore.eventCounts.count > DataSourceLogStore.quickFilterMax {
                moreEventsMenu
            }
        }
    }

    /// 筛选条上**摆出来的**那几类。
    ///
    /// ⚠ 除 `quickFilterEvents`（排前的几类）之外，**当前选中的那一类必须也在** ——
    ///   从「更多」菜单里选中的事件（如 `host_fallback_failed`）若不在前几类里，
    ///   筛选条上就没有任何胶囊是选中态，用户会以为"点了没生效"（而列表其实已经筛了）。
    private var chipEvents: [DataSourceLogStore.EventCount] {
        let quick = diagStore.quickFilterEvents
        let sel = diagStore.diagFilter
        guard !sel.isEmpty, !quick.contains(where: { $0.event == sel }) else { return quick }
        let count = diagStore.eventCounts.first { $0.event == sel }?.count ?? 0
        return [DataSourceLogStore.EventCount(event: sel, count: count)] + quick
    }

    /// 一枚筛选胶囊。
    ///
    /// ⚠ 选中态用 `Tok.tint(Sem.brand, .strong)` 打底（与侧栏选中项 / 日期格**同一档**）——
    ///   筛选选中哪一类必须**一眼可见**，只改文字 tint 太弱。
    @ViewBuilder
    private func filterChip(_ event: String, label: String, count: Int) -> some View {
        let selected = diagStore.diagFilter == event
        Button {
            // ⚠ 换筛选必须**清空游标重新从头查**（`setFilter` 里做）—— 游标只在同一筛选下有效
            //   （否则会拿"上一类"的游标去查"这一类"，结果是错的）。
            diagStore.setFilter(event)
            diagTick += 1
        } label: {
            HStack(spacing: 4) {
                Text(label)
                Text(Self.grouped(count))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Tok.tint(Sem.brand, .strong) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(selected ? Color.clear : Tok.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("只看「\(label)」：库内 \(Self.grouped(count)) 条")
    }

    /// 摆不下的其余事件 —— 全量清单 + 条数，避免筛选项被"截断在 5 个"。
    private var moreEventsMenu: some View {
        Menu {
            ForEach(diagStore.eventCounts) { ec in
                Button {
                    diagStore.setFilter(ec.event)
                    diagTick += 1
                } label: {
                    Text("\(DataSourceLogStore.eventLabel(ec.event))（\(Self.grouped(ec.count))）")
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("更多")
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(Tok.stroke))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("全部 \(diagStore.eventCounts.count) 类事件（含条数）")
    }

    // MARK: 日志列表

    /// 限高滚动的日志列表。
    ///
    /// ⚠ 用 `LazyVStack` 而不是 `VStack`：`VStack` 会一次构造全部行 ——
    ///   翻几页后 `entries` 可能上千条，虽然限高只画十行，构造开销仍全付。
    private var logList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let rows = diagStore.entries
                ForEach(rows) { e in
                    logRow(e)
                    if e.id != rows.last?.id {
                        Divider().opacity(0.4)
                    }
                }
            }
            .padding(.trailing, 2)   // 让内容别贴着滚动条
        }
        .frame(height: Self.diagListHeight)
    }

    /// 「再往前」——**放在列表下方**。
    ///
    /// ⚠ 它的语义是"往下看更早的"，而翻页拿到的新记录**追加在列表末尾**
    ///   ⇒ 放在列表**上方**时，点完按钮要往下滚才能看到新内容，方向是反的。
    @ViewBuilder
    private var loadOlderButton: some View {
        if diagStore.hasMore {
            let suffix = diagStore.diagFilter.isEmpty
                ? "" : "「\(DataSourceLogStore.eventLabel(diagStore.diagFilter))」"
            Button {
                diagStore.loadMore(event: diagStore.diagFilter)
                diagTick += 1
            } label: {
                Label("再往前 \(DataSourceLogStore.defaultLimit) 条\(suffix)（更早）", systemImage: "arrow.down")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(diagStore.isLoading)
        }
    }

    private func logRow(_ e: DataSourceLogStore.Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(Self.hmOnly(e.ts))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(DataSourceLogStore.eventLabel(e.event))
                    .font(.caption.bold())
                    .foregroundStyle(e.event == "error" ? Sem.up : .secondary)
                if !e.source.isEmpty {
                    Text(e.source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !e.detail.isEmpty {
                    Button {
                        toggleDiagRow(e.id)
                    } label: {
                        Image(systemName: diagStore.expandedDiag.contains(e.id)
                              ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .help(diagStore.expandedDiag.contains(e.id) ? "收起" : "展开明细")
                }
            }
            if diagStore.expandedDiag.contains(e.id) {
                // ⚠ detail 可能是完整 URL + 响应体开头（≤500 字）⇒ 必须可选中复制，
                //   否则用户看到关键信息却抄不出来（那等于没显示）
                Text(e.detail)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(.leading, 2)
            } else if !e.detail.isEmpty {
                // 折叠态给一行摘要：多数事故的关键词在这一行里
                Text(e.detail.prefix(90) + (e.detail.count > 90 ? "…" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !e.detail.isEmpty else { return }
            if diagStore.expandedDiag.contains(e.id) {
                diagStore.expandedDiag.remove(e.id)
            } else {
                diagStore.expandedDiag.insert(e.id)
            }
        }
        .clickableRow()
    }

    /// 展开/收起某行的明细（抽出来是因为按钮与整行点击两处共用）。
    private func toggleDiagRow(_ id: Int) {
        if diagStore.expandedDiag.contains(id) {
            diagStore.expandedDiag.remove(id)
        } else {
            diagStore.expandedDiag.insert(id)
        }
        diagTick += 1
    }

    // MARK: 时间格式化

    /// `2026-09-25T23:45:43` → `09-25 23:45`
    private static func hmOnly(_ iso: String) -> String {
        // ⚠ 格式是定长（写入侧 `ISO8601DateFormatter` 产出），可安全按位置切；
        //   不走 DateFormatter 是为了避开时区/本地化在诊断场景里的干扰。
        let parts = iso.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let time = parts[1].prefix(5) as Substring? else {
            return iso
        }
        let date = parts[0].suffix(5)   // MM-dd
        return "\(date) \(time)"
    }

    /// `截至 21:05`（今天）或 `截至 09-25`（更早）
    private static func hm(_ d: Date) -> String {
        let cal = Calendar.current
        let hmStr = String(format: "%02d:%02d", cal.component(.hour, from: d),
                           cal.component(.minute, from: d))
        if cal.isDateInToday(d) { return "今天 " + hmStr }
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f.string(from: d) + " " + hmStr
    }
}

/// 筛选胶囊自适应换行容器：760pt 窄设置窗下避免 6+ 个胶囊横向溢出。
private struct DiagChipFlow: Layout {
    var hSpacing: CGFloat = 6
    var vSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(maxWidth: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() where index < layout.origins.count {
            let p = layout.origins[index]
            subview.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y),
                          proposal: .unspecified)
        }
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        origins.reserveCapacity(subviews.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineH: CGFloat = 0
        var usedW: CGFloat = 0

        for subview in subviews {
            let sz = subview.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxWidth {
                x = 0
                y += lineH + vSpacing
                lineH = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += sz.width + hSpacing
            usedW = max(usedW, x - hSpacing)
            lineH = max(lineH, sz.height)
        }
        return (origins, CGSize(width: usedW, height: y + lineH))
    }
}
