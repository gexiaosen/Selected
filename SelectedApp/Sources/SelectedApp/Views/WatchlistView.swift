import SwiftUI
import SwiftTradingView
import SelectedCore

// MARK: - 自选页 v2：上方分组栏 + 下方分组股票列表（+持仓特殊视图）
// 数据链：SQLite 直读分组/自选/判定 → 引擎 watch-judge（14:50 定时 + 行内单股手动）
// → 盘中批量行情轮询（列表实时价 + 盈亏计算 + 目标/止损触碰提醒）
// 点击股票行 → StockDetailSheet 详情弹窗（行情 + K线 + 今日判定）

struct WatchlistView: View {
    /// ⚠ module-internal（从 `private` 放宽）：持仓段拆到 `WatchlistHoldingSection.swift` 后
    /// 跨文件的 extension 访问不到 `private` 成员。
    let store = Store.shared

    /// 当前选中分组 id；-1 = 持仓视图
    @State var selectedGroup: Int = 1
    /// 分组编辑弹窗：nil=关 / 0=新建 / 其他=重命名该 id
    @State var showGroupEdit: Int?
    @State var groupText = ""
    @State var showDeleteConfirm: Int?
    /// ⚠ 自动聚焦：弹窗一开就把光标放进名称框 ——
    ///   否则键盘用户得先 Tab 一次才能开始输入。
    ///   ⚠ `@FocusState` 是**存储属性**，放在计算属性之间是合法的（顺序不影响）。
    @FocusState var groupNameFocused: Bool
    /// 行内「移出/清仓」待确认（悬停工具条上的危险操作不直接执行，与删分组同一套确认语言）
    @State var rowRemoval: RowRemoval?
    /// 编辑持仓目标
    @State var editingHolding: WatchItemRow?
    /// 拖放悬停中（把别的 App 里含代码的文本拖进来即加入自选）
    @State var dropTargeted = false
    @State var holdCost = ""
    @State var holdShares = ""
    /// 提醒编辑弹窗目标（nil = 关）
    @State var alertEditTarget: AlertEditTarget?
    /// 单股判定中（行内 spinner）
    /// 鼠标悬停的行（代码）：整块高亮 + 补出「持仓/移出」两个行内按钮。
    /// 用"离开时只在仍指向自己才清空"的写法，避免快速掠过时 onHover(false) 后到把新行清掉
    @State var hoveredRow: String?
    /// 次日区间查询弹窗
    @State private var showForecast = false
    /// 表头排序态：**按分组各记一份**（切分组不串味）。键 = `selectedGroup`
    /// （自选↔持仓那侧的 **-1 就是持仓表**自己那份，与 `holdingsList` 同一个哨兵）。
    /// 值 `nil`（不在字典里）= 没排，行序 = 库里的加入顺序。
    /// ⚠ 有意**不持久化**：排序是这一眼想看什么的一次性表达，跨启动记住它
    ///   会让"打开就先按盈亏排好"变成说不清的默认行为。
    @State var sortStates: [Int: WatchSortState] = [:]
    /// 持仓表在 `sortStates` 里的键 —— 复用 `selectedGroup == -1` 那枚哨兵
    /// （-1 = "自选↔持仓"切到持仓侧，见 `WatchlistView.body` 的分支），不另立编号。
    static let holdingSortGroup = -1
    /// 表头可见列（持久化；默认 涨跌幅/量比/换手率）
    @AppStorage("watchlistColumns") private var columnsRaw = "changePct,volumeRatio,turnoverRate"
    /// 持仓页表头可见列（持久化；默认 成本价/市值/盈亏/盈亏率）
    @AppStorage("holdingColumns") private var holdingColumnsRaw = "costPrice,marketValue,pnl,pnlPct"
    /// 场景活跃度：失焦/后台时暂停行情轮询（后台驻留时不该一直打第三方行情）
    @Environment(\.scenePhase) private var scenePhase

    /// 解析选中的列（去非法值、保序；全被清空时回退默认，避免列表无指标可用）
    var selectedColumns: [WatchColumn] {
        let parsed = columnsRaw.split(separator: ",")
            .compactMap { WatchColumn(rawValue: String($0)) }
        return parsed.isEmpty ? [.changePct, .volumeRatio, .turnoverRate] : parsed
    }

    func toggleColumn(_ col: WatchColumn) {
        var cols = selectedColumns
        if let i = cols.firstIndex(of: col) {
            cols.remove(at: i)
        } else {
            cols.append(col)
        }
        columnsRaw = cols.map(\.rawValue).joined(separator: ",")
    }

    // MARK: 持仓页列管理

    var holdingSelectedColumns: [HoldingColumn] {
        let parsed = holdingColumnsRaw.split(separator: ",")
            .compactMap { HoldingColumn(rawValue: String($0)) }
        return parsed.isEmpty ? [.costPrice, .marketValue, .pnl, .pnlPct] : parsed
    }

    var holdingOrderedColumns: [HoldingColumn] {
        let selected = Set(holdingSelectedColumns)
        return HoldingColumn.allCases.filter { selected.contains($0) }
    }

    func toggleHoldingColumn(_ col: HoldingColumn) {
        var cols = holdingSelectedColumns
        if let i = cols.firstIndex(of: col) {
            cols.remove(at: i)
        } else {
            cols.append(col)
        }
        holdingColumnsRaw = cols.map(\.rawValue).joined(separator: ",")
    }

    @State private var searchFocusTick = 0

    var body: some View {
        VStack(spacing: 0) {
            PageActionBar {
                ActionBarButton(title: "全量判定", icon: "circle.hexagongrid", secondary: true,
                                isBusy: store.busy.contains("watch"),
                                isDisabled: store.watchItems.isEmpty) {
                    store.runWatchJudge()
                }
                .help("对全部自选执行今日判定（市场灯 → 打分 → 持仓）；每日 \(ScheduleTimes.shared.clock("watch")) 自动执行")
                ActionBarButton(title: "区间预测", icon: "scope",
                                helpText: "手动输入股票代码，估算次日高低点区间（统计估计，非预测承诺）") {
                    showForecast = true
                }
            }
            // 搜索添加（F15）：内容区顶部独立一行、水平居中；
            // 结果浮层锚在搜索框正下方，zIndex 保证它盖住下方列表（同窗口 overlay，非 popover）
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                WatchSearchField(defaultGroup: selectedGroup > 0 ? selectedGroup : 1,
                                 fieldWidth: 320,
                                 focusTick: $searchFocusTick)
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .padding(.bottom, 6)
            .zIndex(1)
            VStack(spacing: 0) {
                groupBar
                Divider()
                // 切分组 / 切自选↔持仓：整块 150ms 淡入淡出（形变过渡，不做滑动——
                // 列表内容与新页首行位置对不上，滑动会像"内容乱飞"）
                Group {
                    if selectedGroup == -1 {
                        holdingsList
                    } else {
                        groupList
                    }
                }
                .id(selectedGroup)
                .transition(.opacity)
                .animation(Mot.move, value: selectedGroup)
            }
        }
        // ⚠ 拖放加自选：从浏览器 / 笔记 / 聊天里把含代码的文本拖进来
        //   即加入**当前分组** —— 提取规则见 `WatchDrop.extractCode`（Core 纯函数，有单测）；
        //   提取不到给 `.warning` toast 而不是默默无反应（"拖了没动静"是最难查的形态）。
        .dropDestination(for: String.self) { items, _ in
            handleDrop(items)
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
        // 悬停提示：先告诉用户"松手会发生什么"，避免误拖把无关文本当成加自选
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Tok.tint(Sem.brand, .block))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Sem.brand, lineWidth: 2)
                    }
                    .overlay {
                        Text("松手加入自选")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Sem.brand)
                    }
                    .allowsHitTesting(false)
                    .padding(6)
            }
        }
        .task { store.refreshWatch() }
        // ⚠ 行情轮询挂在 `AlertMonitor`（App 级常驻），不在本页：若挂在视图上，视图一销毁
        //   任务就被取消 → **切页即不再评估告警，且没有任何提示**。
        //   本页只读 `store.liveQuotes`，不自己拉行情（也避免两路重复请求）。
        .sheet(isPresented: $showForecast) { ForecastSheet().toastOverlay() }
        .sheet(item: $alertEditTarget) { t in
            // sheet 是盖在窗口之上的独立层级 ⇒ 内容根必须自己挂 toast 层
            //   （否则这里保存提醒失败的提示会被自己的 sheet 挡住，见审查 B6）
            AlertEditSheet(code: t.code, name: t.name).toastOverlay()
        }
        .sheet(item: Binding(
            get: { editingHolding.map { HoldingEditTarget(item: $0) } },
            set: { if $0 == nil { editingHolding = nil } }
        )) { _ in holdingEditSheet.toastOverlay() }

        .alert("删除分组", isPresented: Binding(
            get: { showDeleteConfirm != nil },
            set: { if !$0 { showDeleteConfirm = nil } }
        )) {
            Button("删除（含组内股票）", role: .destructive) {
                if let g = showDeleteConfirm {
                    store.deleteWatchGroup(id: g)
                    if selectedGroup == g { selectedGroup = 1 }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            let g = store.watchGroups.first { $0.id == showDeleteConfirm }
            Text("将删除「\(g?.name ?? "")」及组内 \(g?.stockCount ?? 0) 只自选股，判定历史保留。此操作不可撤销。")
        }
        .alert(rowRemoval?.isHolding == true ? "清仓确认" : "移出自选", isPresented: Binding(
            get: { rowRemoval != nil },
            set: { if !$0 { rowRemoval = nil } }
        )) {
            Button(rowRemoval?.isHolding == true ? "清仓" : "移出自选", role: .destructive) {
                if let r = rowRemoval {
                    if r.isHolding { store.clearWatchHolding(code: r.code) }
                    else { store.removeWatch(code: r.code) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let r = rowRemoval {
                // ⚠ 这两个动作在 `StoreWatch` 里都登记了 UndoManager（⌘Z 可撤销），
                //   文案不许再声称"不可撤销" —— 低估安全性会让用户以为错过就没了，
                //   而真正不可撤销的「删除分组」（`deleteWatchGroup` 无 undo）仍照实写。
                Text(r.isHolding
                     ? "将清空「\(r.name)」的成本与持有数量（从持仓视图移出），自选列表保留，可按 ⌘Z 撤销。"
                     : "将把「\(r.name)」从自选移除，判定历史保留，可按 ⌘Z 撤销。")
            }
        }
    }

    // MARK: 添加自选 / 持仓编辑弹窗焦点

    /// ⚠ 持仓编辑弹窗的自动聚焦。
    ///   ⚠ **必须声明在这里、且不能是 `private`**：那个弹窗在 `extension WatchlistView`
    ///     （`WatchlistHoldingSection.swift`）里 —— **extension 不许有存储属性**，
    ///     而 `private` 又是**文件作用域**、跨文件访问不到。
    ///     （拆文件时"若干 `@State` 从 `private` 放宽到 module-internal"是**已知代价**。）
    @FocusState var holdCostFocused: Bool

    // MARK: 拖放加自选

    /// 处理拖入的文本：提取代码 → 加入**当前分组**。
    /// 返回 `false` = 这次拖放**没有被接受**（SwiftUI 会放回"禁止"图标）——
    /// ⚠ 必须**同时**给 toast：只放回图标、不说话，用户不知道是"格式不对"还是"功能坏了"。
    func handleDrop(_ items: [String]) -> Bool {
        guard let code = items.compactMap({ WatchDrop.extractCode(from: $0) }).first else {
            ToastCenter.shared.show("拖入的内容里没找到代码（支持 5~6 位数字）", style: .warning)
            return false
        }
        // 与搜索框/右键菜单同一条入口（唯一实现：先取行情校验、取不到即拒绝）
        let gid = selectedGroup > 0 ? selectedGroup : 1
        Task { await store.addWatchByCode(code, group: gid) }
        return true
    }

    // MARK: 行内状态开关（持仓标记 / 提醒铃铛）

    /// 提醒铃铛：**未设置 = 划斜杠的铃铛（灰）/ 已设置 = 实心铃铛（警示橙）**。
    ///
    /// 点击打开「修改提醒」弹窗（`AlertEditSheet`）。
    /// ⚠ 形状与颜色约束写在共用的 `rowIconButton` 上（**别在这里再写一套**）。
    ///
    /// ⚠ module-internal（从 `private` 放宽）：持仓段拆在 `WatchlistHoldingSection.swift`，
    /// 跨文件的 extension 访问不到 `private` 成员（与该文件头部的说明同一条）。
    func alertBell(code: String, name: String) -> some View {
        let configured = !(store.alertRulesByCode[code] ?? []).isEmpty
        return rowIconButton(icon: configured ? "bell.fill" : "bell.slash",
                             help: configured ? "已设置提醒（点击修改）" : "未设置提醒（点击添加）",
                             tint: configured ? Sem.warn : Tok.dim) {
            alertEditTarget = AlertEditTarget(code: code, name: name)
        }
    }

    /// 持仓标记开关：**已持仓 = 亮色实心 / 未持仓 = 灰色空壳**（与提醒铃铛同一套逻辑）。
    ///
    /// 点击打开「编辑持仓信息」弹窗（成本 / 数量）—— **未持仓时也是这个弹窗**
    /// （填完即成为持仓，见 `openHoldingEdit`）。
    ///
    /// ⚠ 这是**常驻开关**（不是悬停才出现的行尾按钮）：与提醒铃铛并排 ——
    ///   两个都是"这只票的我的状态"，放一起才成体系；纯悬停入口键盘 / 触控板用户很难发现，
    ///   且未持仓时那一行需要能看出"持仓了没有"。同一个动作不留两条入口。
    ///
    /// ⚠ 颜色：已持仓用 `Sem.brand` —— 项目里"持仓"一直是这个蓝（「持仓」分组胶囊的图标同色）；
    ///   未持仓用 `Tok.dim`（与铃铛的"未设置"同色）。
    ///   ⚠ 两枚并排必须能区分：铃铛"已设置"是**橙**（`Sem.warn`）、持仓是**蓝**（`Sem.brand`）。
    ///   ⚠ 与 `alertBell` 注释里那条"不用 brand 蓝"不冲突 —— 那条针对的是**铃铛**
    ///     （怕与"已设置"的语义色混），而"选中态"在本项目是**整块底色**、不是图标色。
    func holdingToggle(item: WatchItemRow) -> some View {
        let held = item.isHolding
        return rowIconButton(icon: held ? "briefcase.fill" : "briefcase",
                             help: held ? "持仓中（点击编辑成本/数量）" : "未持仓（点击添加持仓）",
                             tint: held ? Sem.brand : Tok.dim) {
            openHoldingEdit(item)
        }
    }

    /// 自选行内**小图标按钮**的统一形状（当前消费方：提醒铃铛、持仓标记）。
    ///
    /// ⚠⚠ 三条同时成立才点得着（**读代码推不出来**，由静态护栏 `alert_bell_hit` 钉住）：
    ///   ① 必须是 `Button`（不是 `Image` + `onTapGesture`）；
    ///   ② 必须 `.buttonStyle(.plain)` —— 少了会退回默认按钮样式，命中区与手势优先级都变；
    ///   ③ label 上自带 `.contentShape(Rectangle())` —— 少了可点区会缩到**字形墨迹**，
    ///      16pt 的小图标就变成"看着有、点不着"。
    ///   ⚠ 原因是**整行**挂着 `.onTapGesture`（打开个股详情），只有这三件同时成立才抢得到点击。
    ///   ⚠ SwiftUI 的手势优先级读代码推不出来 —— 改这里必须**真点一次**验证。
    ///
    /// ⚠ 只能出现在**名称列第一行**内 —— 名称列是固定宽，插图标不改列宽；
    ///   插到别的列会破坏 `WatchColumnLayout` 那套"表头与数据行严格对齐"的几何。
    /// ⚠ 尺寸 16×16：两枚并排时视觉重量必须相同。
    /// ⚠ 颜色由调用方传**语义色**（`Sem.warn` / `Sem.brand` / `Tok.dim`），不就地写死 ——
    ///   `theme_*` 护栏盯着裸色值。
    func rowIconButton(icon: String, help: String, tint: Color,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: 通用

    /// 空态统一走共用 `EmptyStateView`（审查 #15）：原先手搓的 VStack 与其他页面的
    /// 系统 `ContentUnavailableView` 两套视觉并存。
    /// `searchAction`：是否给「去搜索添加」按钮 —— 分组空态要（动作就是去搜索框），
    /// 持仓空态**不要**（它的补救动作是右键行菜单，搜索按钮答非所问）。
    func emptyState(text: String, hint: String, searchAction: Bool = false) -> some View {
        let act: (() -> Void)? = searchAction ? { searchFocusTick += 1 } : nil
        return EmptyStateView(icon: "star.circle", title: text, hint: hint,
                              actionTitle: searchAction ? "去搜索添加" : nil, action: act)
            // 外层铺满：保持原先"区域正中"的摆位（`EmptyStateView` 自身只有 minHeight 下界）
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - SwiftUI Preview
// ⚠ 预览读**真实开发库**（`Store.shared`），仅置 `previewMode` 抑制网络拉取；
//   空库时正好看自选空态。预览进程独立，不写生产数据。
#Preview("自选（真实库 · 禁网络）") {
    Store.shared.previewMode = true
    return WatchlistView()
        .frame(width: 900, height: 640)
}

