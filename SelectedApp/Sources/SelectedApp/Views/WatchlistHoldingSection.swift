import SwiftUI
import SwiftTradingView
import SelectedCore

// MARK: - 持仓视图（汇总条 + 持仓行 + 持仓编辑弹窗）
//
// ⚠ 本段依赖的若干 `@State` 是 module-internal（不是 `private`）：
// Swift 的 `@State` 不能声明在 extension 里，且跨文件 extension 访问不到 `private`。

extension WatchlistView {
    // MARK: 持仓视图（汇总条 + 持仓行）

    var holdingsList: some View {
        let visible = store.watchItems.filter { $0.isHolding }
        // 持仓表的排序态单独一份（键 -1 = `selectedGroup` 里"持仓"那侧的哨兵）
        let items: [WatchItemRow]
        if let sort = sortStates[Self.holdingSortGroup] {
            items = WatchSort.sorted(visible, by: sort.key, ascending: sort.ascending) {
                ($0, store.liveQuotes[$0.code])
            }
        } else {
            items = visible
        }
        return Group {
            if items.isEmpty {
                emptyState(text: "暂无持仓", hint: "在股票行右键「添加持仓」填写成本与数量")
            } else {
                GeometryReader { geo in
                    let layout = WatchColumnLayout.compute(available: geo.size.width,
                                                            holdingColumns: holdingOrderedColumns)
                    VStack(spacing: 0) {
                        holdingSummary(items, layout: layout)
                        Divider()
                        holdingHeaderBar(count: items.count, layout: layout)
                        Divider()
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(items, id: \.code) { item in
                                    holdingRow(item, layout: layout)
                                }
                            }
                            .padding(.horizontal, 12).padding(.bottom, 16)
                        }
                    }
                }
            }
        }
    }

    /// 持仓表头行（与自选表头同构：圆角卡片 + 可编辑菜单 + 列宽同源）
    private func holdingHeaderBar(count: Int, layout: WatchColumnLayout) -> some View {
        HStack(spacing: layout.spacing) {
            // ⚠ 名称列必须补 `nameGutterWidth` 前置缩进：数据行那 20pt 是竖排的
            //   持仓标记 + 提醒铃铛，表头没有图标 ⇒ 不缩进就比名称文字左 20pt
            //   （自选表头一直是对的，持仓表头漏了，2026-10-23 老板「对齐方式也得注意」抓到）。
            Text("名称 / 代码")
                .lineLimit(1)
                .padding(.leading, WatchColumnLayout.nameGutterWidth)
                .frame(width: layout.nameWidth, alignment: WatchColumnLayout.nameAlignment)
            WatchHeaderCell(title: "判定", width: layout.judgeWidth,
                            alignment: WatchColumnLayout.judgeAlignment)
            WatchHeaderCell(title: "现价", width: layout.priceWidth,
                            alignment: WatchColumnLayout.priceAlignment,
                            sortKey: .price, active: sortStates[Self.holdingSortGroup],
                            onSort: { toggleHoldingSort($0) })
            ForEach(holdingOrderedColumns) { col in
                WatchHeaderCell(title: col.title, width: layout.width(of: col),
                                alignment: col.alignment, sortKey: col.sortKey,
                                active: sortStates[Self.holdingSortGroup],
                                onSort: { toggleHoldingSort($0) })
            }
            WatchHeaderCell(title: "得分", width: layout.scoreWidth,
                            alignment: WatchColumnLayout.scoreAlignment,
                            sortKey: .score, active: sortStates[Self.holdingSortGroup],
                            onSort: { toggleHoldingSort($0) })
            HStack(spacing: 10) {
                Menu {
                    ForEach(HoldingColumn.allCases) { col in
                        Button {
                            toggleHoldingColumn(col)
                        } label: {
                            if holdingSelectedColumns.contains(col) {
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
                .help("编辑表头：选择列表显示的指标列（\(holdingSelectedColumns.count)/\(HoldingColumn.allCases.count)）")
            }
            .frame(width: 62)
        }
        // 表头字号/颜色走 `TableMetrics`（与自选表头、共享表格同一套；
        // 原先这里自己写 `.caption2 + .secondary`，两张表表头字不一样大）
        .font(TableMetrics.headerFont)
        .foregroundStyle(TableMetrics.headerColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
    }

    /// 持仓表排序（与自选同一套三态，只是状态单独一份，切分组/切持仓不串）
    func toggleHoldingSort(_ key: WatchSortKey) {
        sortStates[Self.holdingSortGroup] =
            WatchSortState.next(sortStates[Self.holdingSortGroup], key)
    }

    /// 持仓汇总栏：无背景，汇总项在整行宽度上平均分布
    private func holdingSummary(_ items: [WatchItemRow], layout: WatchColumnLayout) -> some View {
        var totalCost = 0.0, totalValue = 0.0, dayPnl = 0.0, dayBase = 0.0, missing = 0
        for it in items {
            let cost = it.costPrice
            let shares = it.shares
            guard let q = store.liveQuotes[it.code] else {
                missing += 1
                continue
            }
            totalCost += cost * shares
            totalValue += q.currentPrice * shares
            // 当日盈亏（券商口径）：(现价 − 昨收) × 持仓量 —— 今天的浮动，
            // 与"总盈亏"（相对成本）是两件事。昨收缺失/为 0 时**不摊入**（该只当日
            // 盈亏记 0 会让总额虚低，但行情都没有时上面已计入 missing，这里不重复扣）。
            if q.previousClose > 0 {
                dayPnl += (q.currentPrice - q.previousClose) * shares
                dayBase += q.previousClose * shares
            }
        }
        let pnl = totalValue - totalCost
        let pnlPct = totalCost > 0 ? pnl / totalCost * 100 : 0
        // 当日盈亏率：当日盈亏 ÷ **昨收市值** —— 券商"当日收益率"口径
        //   （基数是昨收盘时的持仓价值；不能拿总成本当分母，那是"买入时"的价值，
        //     会把持仓以来的涨跌摊进今天，日内涨跌幅被稀释成一个小数字）。
        let dayPnlPct = dayBase > 0 ? dayPnl / dayBase * 100 : 0

        // (标题, 数值, **已渲染文本**, 颜色)：数值单列出来是为了让数字在行情刷新时滚动，而不是整块重画。
        // ⚠ 文本**预渲染**：金额要「≤3 位小数 + 去尾随零」，printf 格式串表达不了
        //   （取整到元会与 3 位小数的成本价 × 数量对不上）。
        // ⚠ 顺序（左→右）：总成本、总市值、总盈亏、总盈亏率、当日盈亏、当日盈亏率
        //   —— 先"相对成本"的全貌，再"今天"的增量。
        var cells: [(String, Double, String, Color)] = [
            ("总成本", totalCost, StockFmt.money(totalCost), .primary),
            ("总市值", totalValue, StockFmt.money(totalValue), .primary),
            ("总盈亏", pnl, StockFmt.signedMoney(pnl), Sem.pnl(pnl)),
            ("总盈亏率", pnlPct, String(format: "%+.2f%%", pnlPct), Sem.pnl(pnl)),
            // 当日盈亏：随 AlertMonitor 5s 轮询滚动更新
            //   （`liveQuotes` 一变 body 就重算，RollingNumber 负责数字过渡）
            ("当日盈亏", dayPnl, StockFmt.signedMoney(dayPnl), Sem.pnl(dayPnl)),
            ("当日盈亏率", dayPnlPct, String(format: "%+.2f%%", dayPnlPct), Sem.pnl(dayPnl)),
        ]
        if missing > 0 {
            cells.append(("行情缺失", Double(missing),
                          String(format: "%.0f只", Double(missing)), Sem.warn))
        }

        return HStack {
            // id 用格标题：`cells` 会按条件增删
            // （如"行情缺失"只在 missing>0 时追加），`\.offset` 会让后面的格子串位
            ForEach(Array(cells.enumerated()), id: \.element.0) { _, c in
                VStack(alignment: .center, spacing: 2) {
                    Text(c.0).font(.caption2).foregroundStyle(.secondary)
                    RollingNumber(c.1, text: c.2, font: .callout.bold(), color: c.3)
                }
                if c.0 != cells.last!.0 { Divider().frame(height: 24) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    /// 持仓行（与自选行同构：HStack + 列宽同源 + 圆角卡片 + 右键菜单）
    private func holdingRow(_ item: WatchItemRow, layout: WatchColumnLayout) -> some View {
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
            // 名称列：与自选行**同构** —— 最左竖排两枚开关（上 = 持仓标记 / 下 = 提醒铃铛）。
            // ⚠ 本页每行都是持仓 ⇒ 那枚恒为"亮蓝实心"，点它开「编辑持仓信息」。
            // ⚠ 「编辑持仓」不放行尾悬停区（同一个动作不留两条入口）。
            HStack(spacing: 4) {
                VStack(spacing: 2) {
                    holdingToggle(item: item)
                    alertBell(code: code, name: name)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.callout.bold()).lineLimit(1).help(name)
                    MarketCodeLabel(code: code)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: layout.nameWidth, alignment: WatchColumnLayout.nameAlignment)
            // 判定列
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
            // 现价列
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
            // 动态指标列（自选指标 + 持仓专属）
            ForEach(holdingOrderedColumns) { col in
                Text(col.text(item: item, live: live))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(col.color(item: item, live: live))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: layout.width(of: col), alignment: col.alignment)
            }
            ScoreBadge(score: score, tier1: store.tier1Min, tier2: store.tier2Min,
                       pill: true, zeroPlaceholder: true)
                .frame(width: layout.scoreWidth, alignment: WatchColumnLayout.scoreAlignment)
            // 末尾操作区（与自选行同一套：常态只露判定，悬停补出「清仓」）
            // ⚠ 「编辑持仓」开关**不在本区** → 在名称列与提醒铃铛并排
            //   （本页恒为已持仓 ⇒ 那枚是亮蓝的实心公文包）。
            HStack(spacing: 2) {
                if isHover {
                    rowAction(icon: "xmark", help: "清仓", tint: Sem.up) {
                        rowRemoval = RowRemoval(code: code, name: name, isHolding: true)
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
        // ⚠ **键盘可达**：若整行只有 `onTapGesture`
        //   ⇒ 键盘完全够不着（Tab 也跳不过去），而"打开个股详情"是本页最高频动作。
        //   ⚠ macOS 上 `.focusable()` 默认**不在 Tab 循环里** —— 用户要在
        //     「系统设置 → 键盘 → 键盘导航」里开启"全键盘控制"才会被 Tab 到；
        //     那是**系统行为**，不是本项目的 bug（别当缺陷去"修"）。
        //   ⚠ 其余列表（选股结果 / 自选页 / 对比 / 复盘）**未做** —— 焦点顺序与
        //     焦点环外观要逐个实机确认（见 `docs/specs/README.md`「键盘可达验证」）。
        .focusable()
        // 关掉鼠标点击留下的常驻蓝焦点环，键盘回车照常
        //   （理由与细节见 `stockDetailTap` 的同款注释）
        .focusEffectDisabled()
        .onKeyPress(.return) {
            store.showStockDetail(code: code, name: name)
            return .handled
        }
        .contextMenu {
            Button("编辑持仓信息") { openHoldingEdit(item) }
            Button("手动判定") { store.runWatchJudge(code: code) }
            Divider()
            // ⚠ 清仓走 `rowRemoval` 确认：它会清掉成本价与持仓量（⌘Z 可撤销，见 `StoreWatch`），
            //   必须与同一动作的另两条入口（行内悬停钮、自选页右键）同一标准 ——
            //   同一动作不许两条入口两套标准。
            Button("清仓") {
                rowRemoval = RowRemoval(code: code, name: name, isHolding: true)
            }
        }
    }

    // MARK: 持仓编辑弹窗

    /// 行内危险操作的目标（移出自选 / 清仓）
    struct RowRemoval: Identifiable {
        let code: String
        let name: String
        let isHolding: Bool
        var id: String { code }
    }

    struct HoldingEditTarget: Identifiable {
        let item: WatchItemRow
        var id: String { item.code.isEmpty ? UUID().uuidString : item.code }
    }

    func openHoldingEdit(_ item: WatchItemRow) {
        // ⚠ 必须用 `StockFmt.exact`（保真预填），不能 `%.2f`：
        //   成本价可以是 3 位（实测库里 `1.249` / `55.879`），`%.2f` 预填成 `1.25` 之后
        //   用户只要点一下「保存」→ 库里的成本价被**静默改写成 1.25**，
        //   此后市值/盈亏全部跟着错，而且没有任何提示。
        holdCost = StockFmt.exact(item.costPrice)
        holdShares = StockFmt.exact(item.shares)
        editingHolding = item
    }

    /// ⚠ 自动聚焦：弹窗一开就把光标放进「成本价」——
    ///   否则键盘用户得先 Tab 两次才能开始输入。
    ///   ⚠ `@FocusState` 是**存储属性** ⇒ 只能声明在 `WatchlistView` 的**主声明**里
    ///     （本文件是 `extension WatchlistView`，extension 不许有存储属性）。
    ///     声明在 `WatchlistView.swift`，本文件只负责绑定与置位。
    var holdingEditSheet: some View {
        let item = editingHolding
        let code = item?.code ?? ""
        let name = item?.displayName ?? code
        let price = store.liveQuotes[code]?.currentPrice
        return VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("编辑持仓 · \(name)").font(.headline)
                if let p = price {
                    Text("现价 \(String(format: "%.2f", p))").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("成本价").font(.caption).foregroundStyle(.secondary)
                    // 提示语用 3 位小数的例子（摊薄成本 / ETF 净值就是 3 位）
                    TextField("如 16.505", text: $holdCost)
                        .focused($holdCostFocused)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("持有数量（股）").font(.caption).foregroundStyle(.secondary)
                    TextField("如 500", text: $holdShares)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
            }
            if let c = Double(holdCost), let s = Double(holdShares), c > 0, s > 0, let p = price {
                let pnlPct = (p - c) / c * 100
                Text("按当前价：盈亏 \(String(format: "%+.2f%%", pnlPct))")
                    .font(.caption)
                    .foregroundStyle(Sem.pnl(pnlPct))
            }
            HStack(spacing: 12) {
                Button("取消") { editingHolding = nil }
                    .keyboardShortcut(.cancelAction)
                    .btnSecondary()
                Button("保存") {
                    if let c = Double(holdCost), let s = Double(holdShares), c > 0, s > 0 {
                        store.setWatchHolding(code: code, cost: c, shares: s)
                        editingHolding = nil
                    }
                }
                .btnPrimary()
                .disabled(!((Double(holdCost) ?? 0) > 0 && (Double(holdShares) ?? 0) > 0))
                // ⚠ 回车即保存：同项目的 `ParamEditor` / `AlertEditSheet` 的确认键都有
                //   `.defaultAction`，这里漏了 → 键盘用户得 Tab 到按钮再按空格。
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360, height: 250)
        // ⚠ 与 `.focused` 配对：`.focused` 只声明绑定，
        //   要**主动置 true** 才会把焦点放进去。
        .onAppear { holdCostFocused = true }
    }

}
