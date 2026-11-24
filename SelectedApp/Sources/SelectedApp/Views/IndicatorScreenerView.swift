import SwiftUI
import SelectedCore

// MARK: - 指标筛选

/// 多条件筛选：勾选若干指标 → 一次查询"同时满足"的股票。
///
/// ## 数据（只读快照，不现取）
/// 收盘后 15:25 调度任务把全市场 × 22 指标末值落 `indicator_snapshots`
/// （`IndicatorSnapshotJob`），本页只查库 —— 与板块热度同一纪律：
/// 快照是**收盘定稿值**，盘中现算会把未定稿行情当结论。
/// 跟随全局 `viewDate`；所选日没有快照时回落到**不晚于它的最近快照日**并在页顶明示
/// （不静默拿别的日子冒充）。判据口径见 `IndicatorScreener`
/// （可调阈值走 B 域 `indicator_params`，右上「设置」就地改）。
///
/// ## 语义
/// - 多个条件之间是 **AND（同时满足）**；一次最多 `IndicatorScreener.maxConditions` 个。
/// - 结果表一个条件一列（该规则的排序键值），点表头换排序键（排序在 SQL 里做，
///   不是只重排前 300 行）。
/// - 每个条件的**单日命中数**在勾选面板与目录里都显示：这些条件会互相矛盾
///   （如上穿均线 + 超卖），不看单独命中数就会频繁撞 0。
/// - 0 命中时给出"去掉哪个条件后能有多少只"的建议（对每个去掉一项的子集实查计数）。
///
/// ## 版面
/// ```
/// 浏览态：快照行 + 条件条（选择指标 / 已选 chips / 筛选）+ 四分区可勾选目录
/// 结果态：快照行 + 条件条 + 结果表（# / 代码 / 名称 / 每个条件一列）
/// 0 命中：同结果态，但正文换成解释 + 逐条件命中数 + 建议
/// ```
///
/// ⚠ 命中列表**上限 300 只**（快照 ~5000 行/日，全量塞进列表会卡；
/// 超出如实标注"仅显示前 300"）。
struct IndicatorScreenerView: View {
    private let store = Store.shared

    /// 已勾选的指标 id（保持勾选顺序 = 结果表列顺序；最多 `maxConditions` 个）
    @State private var selectedIds: [String] = []
    /// 是否已按当前条件跑过（false = 显示目录）
    @State private var hasRun = false
    /// 结果行（与 `selectedIds` 顺序对齐；上限 300）
    @State private var rows: [IndicatorSnapshotStore.ScreenRow] = []
    /// AND 命中总数（可能 > 300；空结果时是 0）
    @State private var hitTotal = 0
    /// 当前排序键（缺省 = 第一个勾选条件）
    @State private var sortKey: String?
    /// 每条规则在当前快照日的单日命中数（nil = 需要前一日但库里没有）
    @State private var singleCounts: [String: Int] = [:]
    /// 当前生效阈值表（标题文案用）
    @State private var thresholds: [String: Double] = [:]
    /// 实际查询用的快照日（≤ viewDate 的最近一天；nil = 这天之前没有任何快照）
    @State private var snapshotDay: String?
    /// 该快照日的覆盖只数
    @State private var snapshotCoverage = 0
    /// 0 命中建议：去掉哪个条件、去掉后有多少只
    @State private var suggestion: (id: String, count: Int)?
    /// 勾选面板（下拉）
    @State private var showPicker = false
    @State private var pickerQuery = ""
    /// B 域设置面板
    @State private var showSettings = false
    /// 设置面板关闭计数 / 快照重算完成计数：并入 `.task(id:)` 让阈值与命中数刷新
    @State private var reloadToken = 0
    /// 后台查询进行中标记与防覆盖令牌（快速切换条件/日期时丢弃过期结果）
    @State private var isScreening = false
    @State private var screenToken = 0
    @State private var screenTask: Task<Void, Never>?
    /// 结果表可用宽度（表头与数据共用同一份列宽计算；几何变化时更新）
    @State private var tableWidth: CGFloat = 900

    private nonisolated static let hitLimit = 300

    private struct LoadKey: Equatable {
        let date: String
        let token: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            PageActionBar {
                // ⚠ 不写 Spacer()（PageActionBar 内部已有，见 BoardView 同款注释）
                DateChip()
                ActionBarButton(title: "设置", icon: "gearshape", secondary: true,
                                helpText: "调整判据阈值、指标周期与超买超卖线（不进选股参数版本，改动即时生效）") {
                    showSettings = true
                }
                ActionBarButton(title: "重算", isBusy: store.busy.contains("indsnap"),
                                isDisabled: store.isHistorical,
                                helpText: store.isHistorical
                                    ? "今日 bar 只能由当日收盘行情合成，历史日不可重算（请回到最新交易日）"
                                    : "用当前历史缓存 + 今日收盘行情重算全市场快照（每日 \(ScheduleTimes.shared.clock("indsnap")) 自动执行）") {
                    store.refreshIndicatorSnapshot()
                }
            }
            FitScrollView {
                content
                    .padding(16)
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            // 关面板 ⇒ 阈值 / 命中数 / 结果即时刷新（周期重算由面板自己触发）
            reloadToken += 1
        }) {
            IndicatorSettingsSheet().toastOverlay()
        }
        // 快照每次刷新（含后台重算完成那一次）都推进 revision → 计数与结果一起重载。
        // ⚠ 不能只看覆盖只数：重算前后通常都是 5217 → onChange 不触发，周期改完像没生效。
        .onChange(of: store.indicatorSnapshotRevision) { _, _ in
            reloadToken += 1
        }
        .task(id: LoadKey(date: store.viewDate, token: reloadToken)) {
            await load()
        }
        .onDisappear {
            screenTask?.cancel()
        }
    }

    // MARK: - 数据装载（视图 body 不查库）

    private func load() async {
        let targetDate = store.viewDate
        let snapshot = await Task.detached(priority: .userInitiated) {
            let th = IndicatorScreener.activeThresholds()
            guard let day = IndicatorSnapshotStore.latestDay(onOrBefore: targetDate) else {
                return (th, String?.none, 0, [String: Int]())
            }
            let cov = IndicatorSnapshotStore.count(on: day)
            let counts = IndicatorScreener.singleCounts(date: day)
            return (th, Optional(day), cov, counts)
        }.value
        guard !Task.isCancelled else { return }

        thresholds = snapshot.0
        guard let day = snapshot.1 else {
            cancelScreening()
            snapshotDay = nil
            snapshotCoverage = 0
            singleCounts = [:]
            rows = []
            hitTotal = 0
            hasRun = false
            suggestion = nil
            return
        }
        snapshotDay = day
        snapshotCoverage = snapshot.2
        singleCounts = snapshot.3
        if hasRun && !selectedIds.isEmpty {
            runScreen()
        } else {
            cancelScreening()
            rows = []
            hitTotal = 0
            suggestion = nil
        }
    }

    private func cancelScreening() {
        screenTask?.cancel()
        screenTask = nil
        screenToken += 1
        isScreening = false
    }

    private func runScreen() {
        guard let day = snapshotDay, !selectedIds.isEmpty else { return }
        if !(sortKey.map { selectedIds.contains($0) } ?? false) {
            sortKey = selectedIds.first
        }
        let ids = selectedIds
        let key = sortKey ?? ids.first
        cancelScreening()
        let token = screenToken
        hasRun = true
        isScreening = true

        screenTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                let matched = IndicatorScreener.screen(indicatorIds: ids, date: day,
                                                       limit: Self.hitLimit, sortBy: key)
                let total = IndicatorScreener.count(indicatorIds: ids, date: day) ?? matched.count
                var best: (id: String, count: Int)?
                if matched.isEmpty && ids.count > 1 {
                    for id in ids {
                        if Task.isCancelled { break }
                        let rest = ids.filter { $0 != id }
                        guard !rest.isEmpty,
                              let n = IndicatorScreener.count(indicatorIds: rest, date: day), n > 0 else { continue }
                        if n > (best?.count ?? -1) { best = (id, n) }
                    }
                }
                return (matched, total, best)
            }.value
            guard !Task.isCancelled, token == screenToken,
                  hasRun, selectedIds == ids, snapshotDay == day else { return }
            rows = result.0
            hitTotal = result.1
            suggestion = result.2
            isScreening = false
        }
    }

    // MARK: - 勾选

    private func toggle(_ id: String) {
        if let i = selectedIds.firstIndex(of: id) {
            selectedIds.remove(at: i)
        } else {
            guard selectedIds.count < IndicatorScreener.maxConditions else {
                ToastCenter.shared.show("一次最多同时选 \(IndicatorScreener.maxConditions) 个指标",
                                        style: .warning)
                return
            }
            selectedIds.append(id)
        }
        if !(sortKey.map { selectedIds.contains($0) } ?? false) {
            sortKey = selectedIds.first
        }
        cancelScreening()
        hasRun = false
        rows = []
        hitTotal = 0
        suggestion = nil
    }

    private func clearSelection() {
        cancelScreening()
        selectedIds = []
        sortKey = nil
        hasRun = false
        rows = []
        hitTotal = 0
        suggestion = nil
        showPicker = false
    }

    private func dropSuggestedCondition() {
        guard let s = suggestion else { return }
        selectedIds.removeAll { $0 == s.id }
        if sortKey == s.id { sortKey = selectedIds.first }
        suggestion = nil
        runScreen()
    }

    /// 按某个条件的值排序（结果表表头点击）。排序键必须仍在已选集合里。
    private func sort(by id: String) {
        guard let day = snapshotDay, selectedIds.contains(id) else { return }
        let ids = selectedIds
        sortKey = id
        cancelScreening()
        let token = screenToken
        isScreening = true

        screenTask = Task {
            let matched = await Task.detached(priority: .userInitiated) {
                IndicatorScreener.screen(indicatorIds: ids, date: day,
                                         limit: Self.hitLimit, sortBy: id)
            }.value
            guard !Task.isCancelled, token == screenToken,
                  hasRun, selectedIds == ids, snapshotDay == day else { return }
            rows = matched
            isScreening = false
        }
    }

    // MARK: - 页面主体

    @ViewBuilder
    private var content: some View {
        if store.indicatorSnapshotLatestDay == nil {
            noSnapshotEverState
        } else if let day = snapshotDay {
            VStack(alignment: .leading, spacing: 0) {
                freshnessLine(day: day)
                filterBar
                if hasRun {
                    if isScreening && rows.isEmpty {
                        Card {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在筛选…").font(AppFont.bodySmall).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                        }
                    } else if rows.isEmpty {
                        emptyResultCard(day: day)
                    } else {
                        resultSection(day: day)
                    }
                } else {
                    browseView
                }
            }
        } else {
            noSnapshotForDateState
        }
    }

    private var noSnapshotEverState: some View {
        VStack(spacing: 12) {
            EmptyStateView(icon: "chart.xyaxis.line",
                           title: "指标快照未入库",
                           hint: "指标快照是筛选结果的数据基础，需要先准备日K缓存。",
                           compact: true,
                           actionTitle: "立即重算",
                           actionDisabled: store.isHistorical || store.busy.contains("indsnap")) {
                store.refreshIndicatorSnapshot()
            }
            // 两段数据依赖拆成两条，替代原先一整段“①…②…”长句
            VStack(alignment: .leading, spacing: 4) {
                Label("设置 › 历史回放：下载日K缓存（首次必须）", systemImage: "1.circle")
                Label("收盘后 \(ScheduleTimes.shared.clock("indsnap")) 自动计算快照", systemImage: "2.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.top, 40)
    }

    /// 所选日之前一天快照都没有（早于库里最早一天）——给一条"去看最新快照日"的路。
    private var noSnapshotForDateState: some View {
        VStack(spacing: 12) {
            EmptyStateView(icon: "calendar.badge.exclamationmark",
                           title: "所选日期之前没有指标快照",
                           hint: snapshotCoverageHint,
                           compact: true,
                           actionTitle: store.indicatorSnapshotLatestDay == nil ? nil : "查看最新快照日",
                           actionDisabled: store.indicatorSnapshotLatestDay == nil) {
                if let latest = store.indicatorSnapshotLatestDay {
                    store.setViewDate(latest)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.top, 40)
    }

    private var snapshotCoverageHint: String {
        if let latest = store.indicatorSnapshotLatestDay {
            return "最近快照日是 \(latest)；指标快照每日 \(ScheduleTimes.shared.clock("indsnap")) 由收盘行情生成。"
        }
        return "指标快照每日 \(ScheduleTimes.shared.clock("indsnap")) 由收盘行情生成。"
    }

    // MARK: - 快照行 / 条件条

    private func freshnessLine(day: String) -> some View {
        HStack(spacing: 7) {
            Circle().fill(Sem.down).frame(width: 6, height: 6)
            Text(freshnessText(day: day))
                .font(AppFont.detail).foregroundStyle(.secondary)
            if store.busy.contains("indsnap") {
                Text("· 快照重算中…")
                    .font(AppFont.detail).foregroundStyle(Sem.info)
            }
            Spacer(minLength: 8)
            if day != store.viewDate {
                Label("所选 \(store.viewDate) 无快照 · 显示最近快照日",
                      systemImage: "info.circle")
                    .font(AppFont.detail).foregroundStyle(Sem.warn)
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 10)
    }

    private func freshnessText(day: String) -> String {
        var s = "收盘快照 \(day) · 覆盖 \(snapshotCoverage) 只"
        if day == store.indicatorSnapshotLatestDay, let at = store.indicatorSnapshotFetchedAt {
            s += " · 更新 \(at.suffix(8))"
        }
        return s
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    showPicker = true
                } label: {
                    Label("选择指标", systemImage: "plus")
                        .font(AppFont.detail)
                }
                .btnSecondary()
                .controlSize(.small)
                .help("按分类勾选指标；每个条件右侧是该快照日的单独命中数")
                .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                    pickerPopover
                }

                if selectedIds.isEmpty {
                    Text("选择 2 个以上指标，筛出同时满足的股票")
                        .font(AppFont.detail).foregroundStyle(.secondary)
                } else {
                    Text("同时满足 \(selectedIds.count) 个条件")
                        .font(AppFont.detail).foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if hasRun {
                    Button("修改条件") {
                        cancelScreening()
                        hasRun = false
                    }
                        .buttonStyle(.plain)
                        .font(AppFont.detail).foregroundStyle(.secondary)
                }
                if !selectedIds.isEmpty {
                    Button("清空") { clearSelection() }
                        .buttonStyle(.plain)
                        .font(AppFont.detail).foregroundStyle(.secondary)
                }
                Button("筛选") {
                    sortKey = selectedIds.first
                    runScreen()
                }
                .btnPrimary()
                .controlSize(.small)
                .disabled(selectedIds.isEmpty)
                .help(selectedIds.isEmpty ? "先勾选至少一个指标" : "查询同时满足全部已选条件的股票")
            }

            if !selectedIds.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(selectedIds, id: \.self) { id in
                            conditionChip(id)
                        }
                    }
                }
                .frame(height: 24)
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 12)
    }

    private func conditionChip(_ id: String) -> some View {
        HStack(spacing: 5) {
            Text(IndicatorRegistry.meta(id: id)?.displayName ?? id)
                .font(AppFont.detail)
                .lineLimit(1)
            Button {
                toggle(id)
            } label: {
                Image(systemName: "xmark")
                    .font(AppFont.micro.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Sem.brand)
            .help("移出这个条件")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Tok.tint(Sem.brand, .block), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Tok.tint(Sem.brand, .chip), lineWidth: 1))
    }

    // MARK: - 勾选面板（下拉）

    private var pickerPopover: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(AppFont.detail).foregroundStyle(.tertiary)
                TextField("搜索指标或判据", text: $pickerQuery)
                    .textFieldStyle(.plain)
                    .font(AppFont.bodySmall)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(pickerGroups, id: \.0) { group in
                        Text(group.0.rawValue)
                            .font(AppFont.detail.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                        ForEach(group.1, id: \.id) { meta in
                            pickerRow(meta)
                        }
                    }
                    if pickerGroups.isEmpty {
                        Text("没有匹配的指标")
                            .font(AppFont.detail).foregroundStyle(.secondary)
                            .padding(16)
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 8)
            }
            Divider()
            HStack(spacing: 10) {
                Text("已选 \(selectedIds.count) 项 · 同时满足")
                    .font(AppFont.detail).foregroundStyle(.secondary)
                Spacer()
                Button("清空") { clearSelection() }
                    .buttonStyle(.plain).font(AppFont.detail)
                Button("完成") { showPicker = false }
                    .btnSecondary().controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 560, height: 460)
    }

    private var pickerGroups: [(IndicatorRegistry.Category, [IndicatorRegistry.Meta])] {
        let q = pickerQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return IndicatorRegistry.Category.allCases.compactMap { category in
            let metas = IndicatorRegistry.all.filter { meta in
                guard meta.category == category else { return false }
                guard !q.isEmpty else { return true }
                let rule = IndicatorScreener.rule(for: meta.id)?.title(thresholds: thresholds) ?? ""
                return meta.displayName.localizedCaseInsensitiveContains(q)
                    || rule.localizedCaseInsensitiveContains(q)
                    || meta.caliber.localizedCaseInsensitiveContains(q)
            }
            return metas.isEmpty ? nil : (category, metas)
        }
    }

    private func pickerRow(_ meta: IndicatorRegistry.Meta) -> some View {
        let on = selectedIds.contains(meta.id)
        let rule = IndicatorScreener.rule(for: meta.id)?.title(thresholds: thresholds) ?? "—"
        let count = singleCounts[meta.id]
        return Button {
            toggle(meta.id)
        } label: {
            HStack(spacing: 8) {
                checkbox(on: on)
                Text(meta.displayName)
                    .font(AppFont.bodySmall.weight(.medium))
                    .lineLimit(1)
                    .frame(width: 176, alignment: .leading)
                Text(rule)
                    .font(AppFont.detail).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                countLabel(count)
                    .frame(width: 46, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(on ? Tok.tint(Sem.brand, .block) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(meta.caliber)
    }

    private func checkbox(on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(on ? Sem.brandFill : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(on ? Color.clear : Tok.stroke, lineWidth: 1)
            }
            .overlay {
                if on {
                    Image(systemName: "checkmark")
                        .font(AppFont.micro.weight(.bold))
                        .foregroundStyle(Tok.onAccent)
                }
            }
            .frame(width: 14, height: 14)
    }

    @ViewBuilder
    private func countLabel(_ n: Int?) -> some View {
        if let n {
            Text("\(n)")
                .font(AppFont.detailSmall)
                .foregroundStyle(n == 0 ? Sem.warn : Color.secondary)
                .monospacedDigit()
        } else {
            Text("—").font(AppFont.detailSmall).foregroundStyle(.tertiary)
                .help("需要前一快照日，库里没有可比的数据")
        }
    }

    // MARK: - 目录（可勾选）

    private var browseView: some View {
        VStack(alignment: .leading, spacing: 15) {
            ForEach(IndicatorRegistry.Category.allCases, id: \.self) { category in
                let metas = IndicatorRegistry.all.filter { $0.category == category }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(category.rawValue)
                            .font(AppFont.bodySmall.weight(.semibold))
                        Text("\(metas.count) 项")
                            .font(AppFont.detail).foregroundStyle(.secondary)
                        Rectangle()
                            .fill(Tok.hairline)
                            .frame(height: 1)
                    }
                    .frame(height: 20)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                        GridItem(.flexible(), spacing: 10)],
                              spacing: 2) {
                        ForEach(metas, id: \.id) { meta in
                            catalogRow(meta)
                        }
                    }
                }
            }
        }
    }

    private func catalogRow(_ meta: IndicatorRegistry.Meta) -> some View {
        let on = selectedIds.contains(meta.id)
        let rule = IndicatorScreener.rule(for: meta.id)?.title(thresholds: thresholds) ?? "—"
        return Button {
            toggle(meta.id)
        } label: {
            HStack(spacing: 9) {
                checkbox(on: on)
                VStack(alignment: .leading, spacing: 1) {
                    Text(meta.displayName)
                        .font(AppFont.bodySmall.weight(.medium))
                        .lineLimit(1)
                    Text(rule)
                        .font(AppFont.detail).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                countLabel(singleCounts[meta.id])
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Tok.tint(Sem.brand, .block) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(meta.caliber)
    }

    // MARK: - 结果

    /// 结果表列宽（表头与数据共用这一份 —— 任何一侧单独写宽度都会错位）。
    private struct TableLayout {
        let widths: [CGFloat]   // [代码, 名称, 收盘, 涨跌幅, 指标…]，与 `selectedIds` 同序
        let gap: CGFloat
        let total: CGFloat      // 列多到放不下时超过视口，由外层横向滚动兜底
    }

    /// 序号栏固定宽（**不参与实测与回摊**：它只有 1–3 位数，摊到富余只会变成"数字浮在空白里"）
    private static let rankWidth: CGFloat = 22
    /// 实测取样上限：列宽只需容纳"看得见的最长内容"，全量 300 行逐列量是每次布局多几毫秒。
    /// 超出样本的更长内容会被 `lineLimit(1)` 截断 —— 改造前写死 58/70 时同样截断，不是回退。
    private static let measureRows = 80

    /// 铺满分摊走 `ColumnLayout`（与选股结果、静态表同一份口径）：
    /// 内容实测 ×1.35+4 起算 → 富余先填**等宽间隙**（≤32pt）→ 封顶后按比例回摊列内。
    /// 原先这里是"名称拿 62%、其余平分 + 各带上限"的第三套算法，同一个 App 里三种列宽行为。
    private func tableLayout(for available: CGFloat) -> TableLayout {
        let sample = Array(rows.prefix(Self.measureRows))
        var titles = ["代码", "名称", "收盘", "涨跌幅"]
        titles += selectedIds.map { IndicatorScreener.rule(for: $0)?.valueLabel ?? $0 }
        let floors: [CGFloat] = [52, 96, 56, 62] + Array(repeating: 60, count: selectedIds.count)
        let cells: [[String]] = [
            sample.map { $0.code },
            sample.map { $0.name.isEmpty ? "—" : $0.name },
            sample.map { StockFmt.price($0.close, code: $0.code) },
            sample.map { changeText($0.changePct) }
        ] + selectedIds.indices.map { i in
            sample.map { valueText(i < $0.values.count ? $0.values[i] : nil) }
        }
        let bases = zip(zip(titles, cells), floors).map { pair, floor in
            ColumnLayout.baseWidth(title: pair.0, cells: pair.1, minWidth: floor,
                                   maxWidth: pair.0 == "名称" ? 300 : nil)
        }
        // 间隙段数 = 实测列数（序号|代码 那一段算在内，代码|名称 … 各一段）
        let (widths, gap) = ColumnLayout.distribute(bases: bases,
                                                    available: available - Self.rankWidth,
                                                    gapCount: CGFloat(bases.count))
        let total = max(available,
                        Self.rankWidth + widths.reduce(0, +) + gap * CGFloat(bases.count))
        return TableLayout(widths: widths, gap: gap, total: total)
    }

    private func resultSection(day: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("同时满足 \(selectedIds.count) 个条件 · 命中 \(hitTotal) 只")
                    .font(AppFont.detail).foregroundStyle(.secondary)
                if let key = sortKey, let rule = IndicatorScreener.rule(for: key) {
                    Text("排序：\(rule.valueLabel) \(rule.ascending ? "↑" : "↓")（点表头切换）")
                        .font(AppFont.detail).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("快照 \(day) 收盘定稿 · 上限 \(Self.hitLimit) 只")
                    .font(AppFont.detail).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)

            Card {
                ScrollView(.horizontal, showsIndicators: false) {
                    let w = tableLayout(for: max(tableWidth, 640))
                    VStack(spacing: 0) {
                        resultHeader(w)
                        TableRule()
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                                resultRow(rank: idx + 1, row: row, widths: w)
                                TableRule()
                            }
                        }
                        if hitTotal > rows.count {
                            Text("仅显示前 \(rows.count) 只（共 \(hitTotal) 只）")
                                .font(AppFont.detail).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 6)
                        }
                    }
                    .frame(width: w.total, alignment: .leading)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tableWidth = $0 }
            }
        }
    }

    private func resultHeader(_ w: TableLayout) -> some View {
        HStack(spacing: w.gap) {
            Text("#").frame(width: Self.rankWidth, alignment: .trailing)
            Text("代码").frame(width: w.widths[0], alignment: .leading)
            Text("名称").frame(width: w.widths[1], alignment: .leading)
            Text("收盘").frame(width: w.widths[2], alignment: .trailing)
            Text("涨跌幅").frame(width: w.widths[3], alignment: .trailing)
            ForEach(Array(selectedIds.enumerated()), id: \.offset) { i, id in
                Button {
                    sort(by: id)
                } label: {
                    HStack(spacing: 2) {
                        Text(IndicatorScreener.rule(for: id)?.valueLabel ?? id)
                        if sortKey == id {
                            Image(systemName: IndicatorScreener.rule(for: id)?.ascending == true
                                  ? "arrow.up" : "arrow.down")
                                .font(AppFont.micro.weight(.bold))
                        }
                    }
                    .frame(width: w.widths[4 + i], alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("按这个指标的值排序")
            }
        }
        .font(TableMetrics.headerFont)
        .foregroundStyle(TableMetrics.headerColor)
        .frame(height: TableMetrics.headerHeight)
    }

    private func resultRow(rank: Int, row: IndicatorSnapshotStore.ScreenRow,
                           widths w: TableLayout) -> some View {
        Button {
            store.showStockDetail(code: row.code, name: row.name)
        } label: {
            HStack(spacing: w.gap) {
                Text("\(rank)")
                    .frame(width: Self.rankWidth, alignment: .trailing)
                    .font(TableMetrics.rowNumericFont).foregroundStyle(Tok.dim)
                Text(row.code)
                    .frame(width: w.widths[0], alignment: .leading)
                    .font(TableMetrics.rowNumericFont)
                Text(row.name.isEmpty ? "—" : row.name)
                    .frame(width: w.widths[1], alignment: .leading)
                    .font(TableMetrics.rowFont).lineLimit(1)
                Text(StockFmt.price(row.close, code: row.code))
                    .frame(width: w.widths[2], alignment: .trailing)
                    .font(TableMetrics.rowNumericFont)
                Text(changeText(row.changePct))
                    .frame(width: w.widths[3], alignment: .trailing)
                    .font(TableMetrics.rowNumericFont)
                    .foregroundStyle(changeColor(row.changePct))
                ForEach(Array(selectedIds.enumerated()), id: \.offset) { i, _ in
                    Text(valueText(i < row.values.count ? row.values[i] : nil))
                        .frame(width: w.widths[4 + i], alignment: .trailing)
                        .font(TableMetrics.rowNumericFont)
                }
            }
            .frame(height: TableMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // `.plain` 在 macOS 不换光标 ⇒ 整行可点却仍是箭头（与 `onTapGesture` 行同一毛病）
        .clickableRow()
    }

    private func changeText(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%+.2f%%", v)
    }

    private func changeColor(_ v: Double?) -> Color {
        guard let v, v != 0 else { return Color.secondary }
        return v > 0 ? Sem.up : Sem.down
    }

    static func formattedValue(_ v: Double?) -> String {
        StockFmt.compact(v)
    }

    private func valueText(_ v: Double?) -> String {
        Self.formattedValue(v)
    }

    // MARK: - 0 命中

    private func emptyResultCard(day: String) -> some View {
        let zeroNames = selectedIds.compactMap { id -> String? in
            guard singleCounts[id] == 0 else { return nil }
            return IndicatorRegistry.meta(id: id)?.displayName ?? id
        }
        let explanation = zeroNames.isEmpty
            ? "这些条件在当天没有交集——方向相反的条件（例如「上穿均线」要求站上均线，而「超卖」要求弱势）常会这样。"
            : "「\(zeroNames.joined(separator: "」「"))」在本快照日单独命中 0 只（规则或数据问题），组合必然为 0。"
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("没有股票同时满足这 \(selectedIds.count) 个条件")
                    .font(.headline)
                Text(explanation)
                    .font(AppFont.bodySmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ForEach(selectedIds, id: \.self) { id in
                        HStack(spacing: 5) {
                            Text(IndicatorRegistry.meta(id: id)?.displayName ?? id)
                                .font(AppFont.detail)
                            countLabel(singleCounts[id])
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Tok.chip, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Tok.stroke, lineWidth: 1))
                    }
                }
                if let s = suggestion {
                    HStack(spacing: 8) {
                        Text("去掉「\(IndicatorRegistry.meta(id: s.id)?.displayName ?? s.id)」后命中 \(s.count) 只。")
                            .font(AppFont.detail)
                            .foregroundStyle(Sem.info)
                        Button("去掉该条件") { dropSuggestedCondition() }
                            .btnSecondary().controlSize(.small)
                    }
                    .padding(.top, 2)
                }
                Text("快照 \(day) 收盘定稿")
                    .font(AppFont.detail).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// ⚠ 预览读**真实开发库**（`Store.shared`），仅置 `previewMode` 抑制网络拉取；
//   空库时正好看空态。预览进程独立，不写生产数据。
#Preview("指标筛选（真实库 · 禁网络）") {
    Store.shared.previewMode = true
    return IndicatorScreenerView()
        .frame(width: 900, height: 620)
}
