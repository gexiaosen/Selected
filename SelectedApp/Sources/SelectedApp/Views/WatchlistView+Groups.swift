import SwiftUI
import SelectedCore

extension WatchlistView {
    // MARK: 分组栏（胶囊 + 加号 + 右键编辑）

    var groupBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // 持仓视图（特殊：聚合所有 is_holding 股票，不属于任何物理分组）
                    groupChip(id: -1, name: "持仓", count: holdingCount, icon: "briefcase.fill")
                    ForEach(store.watchGroups, id: \.id) { g in
                        let gid = g.id
                        groupChip(id: gid, name: g.name,
                                  count: g.stockCount, icon: nil)
                            .contextMenu {
                                if gid != 1 {
                                    Button("重命名") {
                                        groupText = g.name
                                        showGroupEdit = gid
                                    }
                                    Button("删除（含股票）", role: .destructive) {
                                        showDeleteConfirm = gid
                                    }
                                }
                            }
                    }
                    Button {
                        groupText = ""
                        showGroupEdit = 0   // 0 = 新建模式
                    } label: {
                        Image(systemName: "plus")
                            .font(.callout.bold())
                            .frame(width: 26, height: 26)
                            .background(Tok.chip, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("添加分组")
                    .sheet(isPresented: Binding(
                        get: { showGroupEdit != nil },
                        set: { if !$0 { showGroupEdit = nil } }
                    )) { groupEditSheet }
                }
            }
            // 判定状态徽章（放在表头名称格之外，不与列表内容挤）。
            // 永远显示当前判定日期口径（自选页与全局查看日期无关）
            if store.watchDate == store.today {
                Label("今日已判定", systemImage: "checkmark.seal.fill")
                    .font(.caption2.bold()).foregroundStyle(Sem.down)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Tok.tint(Sem.down), in: Capsule())
                    .help("今日 \(ScheduleTimes.shared.clock("watch")) 自动判定（或手动全量判定）已执行")
            } else if !store.watchItems.isEmpty {
                Label("最近判定 \(String(store.watchDate.dropFirst(5)))",
                      systemImage: "clock")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Tok.chip, in: Capsule())
                    .help("今日尚未判定，显示最近一次判定（\(store.watchDate)）")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var holdingCount: Int {
        store.watchItems.filter { $0.isHolding }.count
    }

    private func groupChip(id: Int, name: String, count: Int, icon: String?) -> some View {
        let sel = selectedGroup == id
        return Button {
            selectedGroup = id
        } label: {
            HStack(spacing: 5) {
                if let i = icon {
                    Image(systemName: i).font(.caption2)
                }
                Text(name).font(.callout.bold())
                RollingNumber(count, font: .caption2,
                              color: sel ? Tok.onAccent.opacity(0.8) : .secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(sel ? Sem.brand : Tok.chip)
            )
            .foregroundStyle(sel ? Tok.onAccent : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: 分组新建/重命名弹窗

    private var groupEditSheet: some View {
        let isNew = showGroupEdit == 0
        return VStack(spacing: 14) {
            Text(isNew ? "新建分组" : "重命名分组")
                .font(.headline)
            TextField("分组名称", text: $groupText)
                .focused($groupNameFocused)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            HStack(spacing: 12) {
                Button("取消") { showGroupEdit = nil }
                    .keyboardShortcut(.cancelAction)
                    .btnSecondary()
                Button(isNew ? "创建" : "保存") {
                    let n = groupText.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    let ok: Bool
                    if isNew {
                        ok = store.addWatchGroup(name: n)
                        // 创建成功才选中新组并关闭弹窗（写失败保留弹窗以便修正输入）。
                        // ⚠ **不要**用 `Task { sleep(...) }` 等落库：`addWatchGroup` 内部是同步写库 + loadWatch()。
                        if ok, let last = store.watchGroups.last {
                            selectedGroup = last.id
                        }
                    } else if let gid = showGroupEdit {
                        ok = store.renameWatchGroup(id: gid, name: n)
                    } else {
                        ok = false
                    }
                    if ok { showGroupEdit = nil }
                }
                .btnPrimary()
                .disabled(groupText.trimmingCharacters(in: .whitespaces).isEmpty)
                // ⚠ 回车即提交：同项目其它确认键都有
                //   `.defaultAction`（`ParamEditorSheet` / `AlertEditSheet` /
                //   `OnboardingSheet`），这两个自选弹窗漏了。
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: SheetMetrics.groupEdit.width, height: SheetMetrics.groupEdit.height)
        // ⚠ 与 `.focused` 配对：`.focused` 只声明绑定，
        //   要**主动置 true** 才会把焦点放进去。
        .onAppear { groupNameFocused = true }
    }

    // MARK: 分组股票列表

    /// 列布局参数（表头与数据行**共用同一套**，保证严格对齐）
    struct WatchColumnLayout {
        /// 名称列最左那排**状态开关**（持仓标记 / 提醒铃铛）占的宽度 = 图标 16 + 与文字的间距 4。
        ///
        /// ⚠ 两枚开关在名称列最左**竖排**（不是名称右侧横排）——
        ///   横排要 36pt 宽（把名称挤成「贵州…」），竖排只占 16pt。
        /// ⚠ 表头的「名称 / 代码」必须用**同一个常量**做前置缩进，否则表头会比名称文字
        ///   左移 20pt —— "表头与数据行严格对齐"是既有约束（`WatchColumnLayout` 的存在理由）。
        static let nameGutterWidth: CGFloat = 20

        /// 固定列的对齐 —— 表头与数据行**必须**都从这里取（指标列的对齐在
        /// `WatchColumn.alignment` / `HoldingColumn.alignment` 上，同一套口径）。
        /// 数值列右对齐（位数才对得上），分类量居中，名称左。
        static let nameAlignment: Alignment = .leading
        static let judgeAlignment: Alignment = .center
        static let priceAlignment: Alignment = .trailing
        static let scoreAlignment: Alignment = .center

        let scale: CGFloat
        let spacing: CGFloat
        /// 各指标列的实际渲染宽度（按 key 索引；压缩后的 frame 宽度，不是字体缩放）
        let columnWidths: [String: CGFloat]
        let nameWidth: CGFloat
        let judgeWidth: CGFloat
        let priceWidth: CGFloat
        let scoreWidth: CGFloat
        let actionsWidth: CGFloat

        /// 某指标列的渲染宽度（自选列）
        func width(of col: WatchColumn) -> CGFloat {
            columnWidths[col.rawValue] ?? col.width
        }

        /// 某指标列的渲染宽度（持仓列）
        func width(of col: HoldingColumn) -> CGFloat {
            columnWidths[col.rawValue] ?? col.width
        }

        /// 布局计算：
        /// 核心规则：**所有列（除末尾操作区）统一参与比例压缩**——
        /// 只压指标列、固定列（名称/判定/现价/得分）不压的话，
        /// 7 列全选时指标列已压到 0.55x 而固定列内部空白巨大，
        /// 前 3 列间距视觉上远大于后续列（"空白不够均匀"）。
        /// 全部纳入压缩后 scale 从 0.55 提升到 ~0.70，所有列等比缩小 → 间距视觉均匀。
        ///
        /// 压缩级联：富余均摊间距（10~28）→ 间距 10 → 全列等比压缩（≥0.50）
        /// → 间距 8 → scale 兜底（≥0.45）。末尾操作区 62pt 永不压缩。
        ///
        /// 对齐几何：
        /// - 左右留空两侧共 44pt（表头外层 12 + 内层 10 = 数据行 ScrollView 12 + 行内 10）；
        /// - 间隙数 = n + 4（n 指标列 + 4 个固定元素间隙）；
        /// - 窗口内容下界 904 = 侧栏 144（固定）+ 详情 minWidth 760 → 可用宽下限 760pt。
        static func compute(available: CGFloat, columns: [WatchColumn]) -> WatchColumnLayout {
            let judgeW: CGFloat = 56, priceW: CGFloat = 72, scoreW: CGFloat = 46, actionW: CGFloat = 62
            // 名称列 108：容纳"徽章 + 交易所前缀"的代码行（创 SZ300221 ≈ 70pt）
            // ⚠ 128 = 108 + 名称列最左状态开关 gutter（20pt），加宽正好补回来、再"稍微长一点点"；
            //   理由见 `nameGutterWidth` 的注释。
            // ⚠ 这里**没有**名称列压缩下限：所有列同步缩放，名称列等比压缩、无特殊保底。
            let nameWFull: CGFloat = 128
            let paddings: CGFloat = 44   // 左右各 22
            let baseSpacing: CGFloat = 10, tightSpacing: CGFloat = 8, maxSpacing: CGFloat = 40
            let gaps: CGFloat = CGFloat(columns.count + 4)

            let indicatorsWidth = columns.reduce(0.0) { $0 + $1.width }
            // 所有列除操作区都参与压缩（含名称/判定/现价/得分，不只压指标列）
            let compressibleFull = nameWFull + judgeW + priceW + scoreW + indicatorsWidth
            let actionFixed = actionW

            // 间距自适应：富余均摊
            let slack = available - paddings - actionFixed - compressibleFull
            var spacing = max(baseSpacing, min(maxSpacing, slack / gaps))

            // 压缩级联
            var scale: CGFloat = 1
            var needed = paddings + actionFixed + compressibleFull + spacing * gaps
            if needed > available {
                spacing = baseSpacing
                needed = paddings + actionFixed + compressibleFull + spacing * gaps
                if needed > available {
                    scale = max(0.50, (available - paddings - actionFixed - spacing * gaps) / max(compressibleFull, 1))
                    needed = paddings + actionFixed + compressibleFull * scale + spacing * gaps
                    if needed > available {
                        spacing = tightSpacing
                        needed = paddings + actionFixed + compressibleFull * scale + spacing * gaps
                        if needed > available {
                            scale = max(0.45, (available - paddings - actionFixed - spacing * gaps) / max(compressibleFull, 1))
                        }
                    }
                }
            }

            var widths: [String: CGFloat] = [:]
            for c in columns { widths[c.rawValue] = c.width * scale }
            // 名称列等比压缩（与其他列同 scale），无特殊保底——
            // v4 核心目标：所有列同步缩放、间距视觉均匀
            let nameW = nameWFull * scale
            return WatchColumnLayout(
                scale: scale, spacing: spacing, columnWidths: widths,
                nameWidth: nameW, judgeWidth: judgeW * scale,
                priceWidth: priceW * scale, scoreWidth: scoreW * scale,
                actionsWidth: actionW
            )
        }

        /// 持仓页布局计算（与自选页同一算法，列集不同）
        static func compute(available: CGFloat, holdingColumns: [HoldingColumn]) -> WatchColumnLayout {
            let judgeW: CGFloat = 56, priceW: CGFloat = 72, scoreW: CGFloat = 46, actionW: CGFloat = 62
            // ⚠ 128 = 108 + 名称列最左状态开关 gutter（20pt），加宽正好补回来、再"稍微长一点点"；
            //   理由见 `nameGutterWidth` 的注释。
            let nameWFull: CGFloat = 128
            let paddings: CGFloat = 44
            let baseSpacing: CGFloat = 10, tightSpacing: CGFloat = 8, maxSpacing: CGFloat = 40
            let gaps: CGFloat = CGFloat(holdingColumns.count + 4)

            let indicatorsWidth = holdingColumns.reduce(0.0) { $0 + $1.width }
            let compressibleFull = nameWFull + judgeW + priceW + scoreW + indicatorsWidth
            let actionFixed = actionW

            let slack = available - paddings - actionFixed - compressibleFull
            var spacing = max(baseSpacing, min(maxSpacing, slack / gaps))
            var scale: CGFloat = 1
            var needed = paddings + actionFixed + compressibleFull + spacing * gaps
            if needed > available {
                spacing = baseSpacing
                needed = paddings + actionFixed + compressibleFull + spacing * gaps
                if needed > available {
                    scale = max(0.50, (available - paddings - actionFixed - spacing * gaps) / max(compressibleFull, 1))
                    needed = paddings + actionFixed + compressibleFull * scale + spacing * gaps
                    if needed > available {
                        spacing = tightSpacing
                        needed = paddings + actionFixed + compressibleFull * scale + spacing * gaps
                        if needed > available {
                            scale = max(0.45, (available - paddings - actionFixed - spacing * gaps) / max(compressibleFull, 1))
                        }
                    }
                }
            }

            var widths: [String: CGFloat] = [:]
            for c in holdingColumns { widths[c.rawValue] = c.width * scale }
            let nameW = nameWFull * scale
            return WatchColumnLayout(
                scale: scale, spacing: spacing, columnWidths: widths,
                nameWidth: nameW, judgeWidth: judgeW * scale,
                priceWidth: priceW * scale, scoreWidth: scoreW * scale,
                actionsWidth: actionW
            )
        }
    }

    var groupList: some View {
        // ⚠ 按**归属**过滤，不是按 `WatchItemRow.groupId`（那只存**主分组**）——
        //   否则"复制到分组"出来的票在目标分组里看不见。
        //   归属缺失时回落到主分组（防御：迁移跑完之前的瞬间）。
        // ⚠ **默认组（1）= 所有分组的去重总量**：直接展示全部自选，
        //   不看归属 —— 从默认组"移到/复制到"别的组的票仍留在默认组里。
        let visible = store.watchItems.filter { item in
            selectedGroup == WatchStore.defaultGroupID
                || (store.watchMemberships[item.code] ?? Set([item.groupId])).contains(selectedGroup)
        }
        // 表头排序（没点表头时原样返回，行序 = 库里加入顺序）
        let items: [WatchItemRow]
        if let sort = sortStates[selectedGroup] {
            items = WatchSort.sorted(visible, by: sort.key, ascending: sort.ascending) {
                ($0, store.liveQuotes[$0.code])
            }
        } else {
            items = visible
        }
        return GeometryReader { geo in
            let layout = WatchColumnLayout.compute(available: geo.size.width,
                                                    columns: orderedColumns)
            VStack(spacing: 0) {
                listHeaderBar(count: items.count, layout: layout)
                Divider()
                if items.isEmpty {
                    emptyState(text: "本组暂无自选", hint: "在上方搜索框输入代码或名称添加",
                               searchAction: true)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            // id 用业务键：`\.self` 会退化成
                            // `JSONValue.hash` = `String(describing: 整个字典)` —— 自选页每 5s 轮询
                            // 刷新时，分数一变就判定为"新行"→ 整行销毁重建，悬停/过渡动画丢失。
                            ForEach(items, id: \.code) { item in
                                stockRow(item, layout: layout)
                            }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 16)
                    }
                    .reportsScrollProgress()
                }
            }
        }
    }

    /// 表头点击 = 三态循环（升 → 降 → 取消），**按分组各记一份**。
    /// 循环本体在 `WatchSortState.next`（自选与持仓共用，别在这儿再写一份）。
    func toggleSort(_ key: WatchSortKey) {
        sortStates[selectedGroup] = WatchSortState.next(sortStates[selectedGroup], key)
    }


    /// 按固定顺序排序可见列（勾选/取消勾选后列位置稳定，不追加到尾部）。
    /// 顺序 = WatchColumn.allCases 定义序（涨跌额→涨跌幅→换手率→振幅→量比→成交量→成交额），
    /// 与编辑表头菜单的展示顺序一致，勾选新列只会"插入"到它的固定位置。
    private var orderedColumns: [WatchColumn] {
        let selected = Set(selectedColumns)
        return WatchColumn.allCases.filter { selected.contains($0) }
    }

    /// 表头行：名称/判定/现价/指标列/得分 + 右侧按钮。
    /// ⚠ 布局与数据行共用 WatchColumnLayout（同一套 spacing/scale/列宽），
    /// 保证严格对齐；左右留空与数据行一致（padding 22 = ScrollView 12 + 行内 10）。
    /// ⚠ 对齐几何（改任何一处必须同步）：
    ///   - 水平起点：表头 padding 22 = 数据行 ScrollView 12 + 行内 10；
    ///   - 末尾区域：62pt 固定容器 = 数据行判定按钮区（容器内只剩滑杆一枚，宽度保留以对齐）；
    ///   - 元素间距统一 10，列宽同源（WatchColumn.width × scale + 固定列不缩）。
    ///   - 判定列 56pt 固定不参与压缩。
    private func listHeaderBar(count: Int, layout: WatchColumnLayout) -> some View {
        HStack(spacing: layout.spacing) {
            // 名称列（固定宽）
            // ⚠ 数据行名称列的最左是**状态开关 gutter**（持仓标记 / 提醒铃铛，竖排）——
            //   表头没有图标，必须补同样的前置缩进，否则「名称 / 代码」会比名称文字左 20pt。
            // 名称列（固定宽，左对齐；不可排 —— 中文名要引拼音排序器，收益不值）
            Text("名称 / 代码")
                .lineLimit(1)
                .padding(.leading, WatchColumnLayout.nameGutterWidth)
                .frame(width: layout.nameWidth, alignment: WatchColumnLayout.nameAlignment)
            WatchHeaderCell(title: "判定", width: layout.judgeWidth,
                            alignment: WatchColumnLayout.judgeAlignment)
            WatchHeaderCell(title: "现价", width: layout.priceWidth,
                            alignment: WatchColumnLayout.priceAlignment,
                            sortKey: .price, active: sortStates[selectedGroup],
                            onSort: { toggleSort($0) })
            // 可见指标列（宽度用压缩后的实际列宽；每列自己声明能不能排）
            ForEach(orderedColumns) { col in
                WatchHeaderCell(title: col.title, width: layout.width(of: col),
                                alignment: col.alignment, sortKey: col.sortKey,
                                active: sortStates[selectedGroup],
                                onSort: { toggleSort($0) })
            }
            WatchHeaderCell(title: "得分", width: layout.scoreWidth,
                            alignment: WatchColumnLayout.scoreAlignment,
                            sortKey: .score, active: sortStates[selectedGroup],
                            onSort: { toggleSort($0) })
            // 末尾操作区（固定 62pt 容器 = 数据行判定按钮区；仅表头编辑滑杆一枚，
            // 添加自选统一走上方搜索框，容器宽度保留以对齐数据行）
            HStack(spacing: 10) {
                Menu {
                    ForEach(WatchColumn.allCases) { col in
                        Button {
                            toggleColumn(col)
                        } label: {
                            if selectedColumns.contains(col) {
                                Label(col.title, systemImage: "checkmark")
                            } else {
                                Text(col.title)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.callout)
                        .frame(width: 26, height: 26)
                        .background(Tok.chip, in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("编辑表头：选择列表显示的指标列（\(selectedColumns.count)/\(WatchColumn.allCases.count)）")
            }
            .frame(width: 62)
        }
        .font(TableMetrics.headerFont)
        .foregroundStyle(TableMetrics.headerColor)
        .padding(.horizontal, 10)       // 行内边距 = 数据行
        .padding(.vertical, 7)          // 垂直边距 = 数据行
        // 表头必须铺满可用宽：之前 HStack 按内容宽居中，空列表时表头浮在页面中间，
        // 左侧空出几百 pt，与数据行的起始位置对不上。
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)       // 外层 = ScrollView 12，与数据行对齐
    }
    /// 股票行：名称/现价/动态指标列/得分/单股判定 + 右键（移组/持仓/判定/移除）。
    /// 指标列由表头「编辑表头」控制，与表头共用 WatchColumnLayout
    /// （同一套 spacing/列宽），严格对齐；列多时按 scale 压缩 + 字体自适应缩小。
    private func stockRow(_ item: WatchItemRow, layout: WatchColumnLayout) -> some View {
        let code = item.code
        let name = item.displayName
        let live = store.liveQuotes[code]
        let score = item.score
        // 判定中：直接读 Store 的 busy 集合 —— **别**用 `judgingCode == code` + `sleep` 定时器猜时长
        // （判定快于定时器时白转、慢于时提前停，与实际状态脱钩）。
        // `runWatchJudgeNative` 用的是同一个 key，且 Store 是 @Observable，
        // busy 变化会自动刷新本行。
        let judging = store.busy.contains("watch-\(code)")
        let isHover = hoveredRow == code
        return HStack(spacing: layout.spacing) {
            // 名称列：**最左竖排两枚状态开关**（上 = 持仓标记 / 下 = 提醒铃铛）＋ 名称/代码。
            // ⚠ 两枚**竖排**在名称列最左（不是名称右侧横排）——
            //   横排要 36pt 宽、把名称挤成「贵州…」；竖排只占 16pt（名称因此长了 20pt）。
            //   ⚠ 上下顺序固定：**上 = 持仓标记、下 = 提醒铃铛**。
            //   ⚠ 表头的「名称 / 代码」用同一个 `nameGutterWidth` 前置缩进，保持列对齐。
            HStack(spacing: 4) {
                VStack(spacing: 2) {
                    holdingToggle(item: item)
                    alertBell(code: code, name: name)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.callout.bold()).lineLimit(1)
                        .help(name)   // 极端长名 hover 看全名
                    MarketCodeLabel(code: code)
                }
                .frame(maxWidth: .infinity, alignment: WatchColumnLayout.nameAlignment)
            }
            .frame(width: layout.nameWidth, alignment: WatchColumnLayout.nameAlignment)
            // 判定列（固定宽居中，红涨绿跌配色；与表头同源，各行严格对齐）
            Group {
                if let j = store.watchJudgments.first(where: { $0.code == code }),
                   j.hasAction {
                    let a = j.action
                    Text(a)
                        .font(.caption.bold())
                        .foregroundStyle(Sem.actionColor(a))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Text("—").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(width: layout.judgeWidth, alignment: WatchColumnLayout.judgeAlignment)
            // 现价列（固定宽；数值 ⇒ 右对齐，与表头同一枚常量）
            Group {
                if let q = live {
                    Text(StockFmt.price(q.currentPrice, code: q.code))
                        .font(.callout.monospacedDigit())
                        // 数字滚动需要 animation 驱动（`contentTransition` 只声明过渡形态、不带时长）——
                        // `motionAware` 顺带满足减弱动态
                        .contentTransition(.numericText(value: q.currentPrice))
                        .motionAware(Mot.value, value: q.currentPrice)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .frame(width: layout.priceWidth, alignment: WatchColumnLayout.priceAlignment)
            // 动态指标列（宽度用压缩后的实际列宽，绝不用字体缩放替代 frame 压缩）
            ForEach(orderedColumns) { col in
                Text(col.text(live))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(col.color(live))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: layout.width(of: col), alignment: col.alignment)
            }
            ScoreBadge(score: score, tier1: store.tier1Min, tier2: store.tier2Min,
                       pill: true, zeroPlaceholder: true)
                .frame(width: layout.scoreWidth, alignment: WatchColumnLayout.scoreAlignment)
            // 末尾操作区（固定宽 62pt，与表头两按钮同源）：
            // 常态只露「手动判定」；悬停补出「移出」——右键菜单里的高频项前置，免右键。
            // ⚠ 「持仓」开关**不在本区** → 在名称列与提醒铃铛并排：
            //   它是个**状态开关**（已持仓 / 未持仓），藏在悬停区等于"看不见自己持仓没有"。
            // ⚠ 容器宽度仍恒定 62pt（`.frame(width: layout.actionsWidth)`）⇒ 悬停不推动前面任何列；
            //   区内的「手动判定」用 `maxWidth: .infinity` 吃满剩余宽度（图标居中位置会随悬停微移，幅度小）。
            HStack(spacing: 2) {
                if isHover {
                    rowAction(icon: "xmark", help: "移出自选", tint: Sem.up) {
                        rowRemoval = RowRemoval(code: code, name: name, isHolding: false)
                    }
                    .transition(.opacity)
                }
                Button {
                    store.runWatchJudge(code: code)
                } label: {
                    Image(systemName: judging ? "arrow.triangle.2.circlepath" : "circle.hexagongrid")
                        .font(.caption)
                        .symbolEffect(.rotate, isActive: judging)
                        .foregroundStyle(judging ? Sem.info : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 20)
                }
                .buttonStyle(.plain)
                .iconHoverFeedback()
                .help("手动判定该股（拉取最新行情与K线打分）")
            }
            .frame(width: layout.actionsWidth)
            .animation(Mot.hover, value: isHover)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        // 悬停整块高亮（比常态行底实一档）：列表里定位当前行，靠块面不靠描边
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isHover ? Tok.chip : Tok.row)
            .animation(Mot.hover, value: isHover))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredRow = code }
            else if hoveredRow == code { hoveredRow = nil }
        }
        .onTapGesture {
            store.showStockDetail(code: code, name: name)
        }
        .clickableRow()
        // ⚠ 键盘可达 —— 与 WatchlistHoldingSection 行同款
        .focusable()
        // 关掉鼠标点击留下的常驻蓝焦点环，键盘回车照常
        //   （理由与细节见 `stockDetailTap` 的同款注释）
        .focusEffectDisabled()
        .onKeyPress(.return) {
            store.showStockDetail(code: code, name: name)
            return .handled
        }
        .contextMenu {
            // ⚠ 分组**不能平铺**：每个分组一条 `移到「xx」`，分组一多菜单就长到把真正的动作挤出屏幕
            //   ⇒ 收进两个子菜单（`Menu` 嵌在 `contextMenu` 里 = 系统子菜单）。
            //   ⚠ 已在该分组的项**带 ✓ 并置灰**：复制的话重复插入没意义；移动的话"原地不动"没意义。
            // ⚠ **默认组（1）= 所有分组的去重总量** ⇒ 每只票都算"已在默认组"，
            //   所以把默认组并进 `mine`：两个子菜单里「默认」都带 ✓ 置灰（复制到/移动到默认组无意义）。
            let mine = (store.watchMemberships[code] ?? Set([item.groupId])).union([WatchStore.defaultGroupID])
            Menu("复制到分组") {
                ForEach(store.watchGroups, id: \.id) { g in
                    let already = mine.contains(g.id)
                    Button {
                        store.copyWatch(code: code, to: g.id)
                    } label: {
                        if already { Label(g.name, systemImage: "checkmark") }
                        else { Text(g.name) }
                    }
                    .disabled(already)
                }
            }
            Menu("移动到分组") {
                ForEach(store.watchGroups, id: \.id) { g in
                    let already = mine.contains(g.id)
                    Button {
                        // ⚠ "移动"是**组内**操作：从**当前分组**移走 + 加到目标组，
                        //   别的分组保留。
                        //   ⚠ 走的是 Core 的 `moveWithin`，**不是** `move(code:group:)`
                        //     —— 后者重置全部归属，是给对账驱动用的单归属语义。
                        store.moveWatch(code: code, from: selectedGroup, to: g.id)
                    } label: {
                        if already { Label(g.name, systemImage: "checkmark") }
                        else { Text(g.name) }
                    }
                    .disabled(already)
                }
            }
            Divider()
            if item.isHolding {
                Button("编辑持仓信息") { openHoldingEdit(item) }
                // ⚠ 走 `rowRemoval` 确认：与同行悬停按钮（`rowAction`）共用同一个确认 ——
                //   同一动作两条入口必须同一标准，否则用户会以为右键是"轻操作"。
                Button("清仓") {
                    rowRemoval = RowRemoval(code: code, name: name, isHolding: true)
                }
            } else {
                Button("添加持仓") { openHoldingEdit(item) }
            }
            Button("手动判定") { store.runWatchJudge(code: code) }
            Divider()
            Button("移出自选", role: .destructive) {
                rowRemoval = RowRemoval(code: code, name: name, isHolding: false)
            }
        }
    }

    /// 行内小图标按钮（悬停工具条）：命中区 ≥24pt，操作区与表头末尾同为 62pt 宽
    /// —— 悬停补出按钮**不会推动任何列**
    func rowAction(icon: String, help: String, tint: Color,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(tint)
                // ⚠ 命中区 ≥24pt：20×20 比 Apple 的最小可点尺寸还小，要精确命中。
                //   ⚠ `.frame` 只改**布局**、不改**命中区**，
                //   所以必须配 `.contentShape(Rectangle())`（下面已有）。
                //   ⚠ 这会让行内动作组变宽 4pt：**列宽几何是共享的**（`WatchColumnLayout`），
                //     调整后要真点一次确认没挤到名称列。
                .frame(minWidth: 24, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .iconHoverFeedback()
        .help(help)
    }

}
