import AppKit
import SwiftUI
import SelectedCore

/// 自选页「搜索添加」
///
/// 位于内容区顶部、水平居中：输入代码或名称做**模糊匹配**，直接在结果里加自选。
///   · 覆盖**A 股 + 场内基金 + 港股**：基金按名称中文模糊匹配（如"恒生"→恒生ETF）；
///     港股按 5 位代码直接添加（如 00700 → 腾讯控股，实时行情取名称）
///   · 结果行带市场徽章 + 交易所前缀（创 SZ300221 / 基 SH510300 / 港 HK00700），
///     与自选列表同源（`StockQuotes.marketInfo`）
///   · 点结果行主体 = 加到**当前选中分组**（沿用旧习惯，不打断浏览）
///   · 鼠标在行尾「+」上**停留 0.3 秒（或直接点它）**→ 就地弹出分组菜单，指定加到哪个分组
///   · 无匹配且输入像代码（5~6 位数字，含港股 5 位）→ 「直接添加」（实时行情取名称）
///
/// 数据来源：`Store.stockList`（securities 表）+ `Store.fundList`（funds 表，懒加载）。
/// 两者独立成池 —— 基金不进选股扫描池（见 FundCache 注释）。
///
/// ⚠ 两条交互约束（实测踩坑后定稿，勿回退）：
///   1. 结果面板**不用系统 popover**：popover 是独立窗口，首次点击会被"激活窗口"吞掉，
///      表现为「点结果行没反应」。改为同一窗口内的 overlay 浮层（点击稳定可达），
///      并由调用方（WatchlistView）给搜索框所在行加 `zIndex` 保证浮层盖住下方列表。
///   2. 分组菜单用 **NSMenu**（`menu.popUp`）而不是 SwiftUI `Menu`/popover：
///      悬浮弹出要求"窗口出现即可点"，系统菜单是模态跟踪、不会吞首次点击。
///   3. 面板只在**输入非空**时出现（空内容点搜索框不弹，清空/ Esc 立即收起）。
struct WatchSearchField: View {
    /// 点结果行 / 回车时加入的分组（= 页面上当前选中的分组）
    let defaultGroup: Int
    /// 输入框宽度（自选页顶部居中一行用 320；窄场景可传小值）
    var fieldWidth: CGFloat = 180
    /// 外部聚焦触发器：空态按钮点一下 +1，搜索框接收键盘焦点
    @Binding var focusTick: Int

    private let store = Store.shared

    @State private var query = ""
    @State private var showResults = false
    /// 指针是否停留在结果面板上（用于"失去焦点但不收起面板"的判定）
    @State private var panelHovered = false
    /// 行高亮（结果行悬浮底色）
    @State private var hoveredCode: String?
    /// 行尾「+」悬浮计时（停留 0.3s 弹菜单；移开即取消）
    @State private var hoverTask: Task<Void, Never>?
    /// 分组菜单的动作桥（菜单项 → 分组 id）
    @State private var menuTarget = GroupMenuTarget()
    /// popUp 是模态循环，持有菜单到返回为止（保底不被释放）
    @State private var activeMenu: NSMenu?
    @State private var directAdding = false
    @FocusState private var focused: Bool

    /// 键盘高亮项（结果列表里的下标）。
    ///
    /// ⚠ 回车加**高亮项**（不是永远第一条）——用户必须能用键盘选中目标项（↑↓ / Tab 移动）。
    ///   每次输入变化重置为 0（= 保持"不改习惯的人按回车仍是第一条"的行为）。
    @State private var highlighted = 0

    /// 结果面板固定尺寸（浮层用 offset 定位，依赖这两个常量）
    private static let panelWidth: CGFloat = 380
    private static let panelHeight: CGFloat = 340
    /// 面板与输入框的间距
    private static let panelGap: CGFloat = 6

    /// 一条搜索结果（A 股 / 场内基金 / 港股）
    private struct Hit: Identifiable {
        let code: String
        let name: String
        /// 基金类型（etf/lof/close）或 "hk"（港股）；空串 = A 股
        let kind: String
        var isFund: Bool { ["etf", "lof", "close"].contains(kind) }
        var id: String { code }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption).foregroundStyle(.secondary)
            TextField("搜索代码或名称（A股 / 场内基金 / 港股）", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .frame(width: fieldWidth)
                .focused($focused)
                .onChange(of: focusTick) { _, _ in focused = true }
                .onSubmit {
                    // ⚠ 回车加**高亮项**；列表外代码（`hits` 为空）时走直接添加 ——
                    //   否则同一动作鼠标可达（面板里有「直接添加 <code>」）、键盘不可达。
                    let q = query.trimmingCharacters(in: .whitespaces)
                    if let picked = currentHit {
                        add(picked, to: defaultGroup)
                    } else if isCodeLike(q) {
                        directAdd(code: q)
                    }
                }
                // ⚠ 键盘导航：`↓/Tab` 下移、`↑/Shift+Tab` 上移（**到顶/到底夹住，不环绕** ——
                //   环绕会在"多按一下"时跳到另一端，误加的风险高于便利）；
                //   `Esc` 已有 `onExitCommand`（清空 + 收起 + 失焦，见 body 末尾）。
                .onKeyPress(.downArrow) { moveHighlight(1) }
                .onKeyPress(.upArrow) { moveHighlight(-1) }
                .onKeyPress(.tab, phases: .down) { press in
                    moveHighlight(press.modifiers.contains(.shift) ? -1 : 1)
                }
            if store.fundListLoading || store.hkListLoading {
                ThinkingDot(design: .connecting, diameter: 15)
                    .help("正在加载场内基金 / 港股列表…")
            } else if !query.isEmpty {
                Button {
                    query = ""
                    showResults = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清空")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Tok.chip))
        .help("搜索添加自选：支持 A 股与场内基金（按名称模糊匹配）；点结果加到当前分组，"
              + "「+」上停留可选择分组")
        // 结果浮层：锚在输入框右下角、向下展开（同窗口，不用 popover —— 见类型注释）
        .overlay(alignment: .bottomTrailing) {
            if showResults {
                resultList.offset(y: Self.panelHeight + Self.panelGap)
            }
        }
        .task {
            // 懒加载三个搜索池（都是毫秒级本地读；池子为空/过期才后台抓）。
            // .task 而非 onAppear：与仓库约定一致，视图消失即取消（同步调用无差异）
            store.loadStockList()
            store.loadFundList()
            store.loadHkList()
        }
        .onChange(of: query) { _, newValue in
            showResults = !newValue.trimmingCharacters(in: .whitespaces).isEmpty
            highlighted = 0        // 每次输入变化回到第一条（保持旧行为）
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused {
                showResults = !query.trimmingCharacters(in: .whitespaces).isEmpty
            } else if !panelHovered {
                // 指针不在面板上（点页面别处）才收起；在面板上时不收，
                // 否则"点结果行"会在点击送达前把面板撤掉（正是之前点不动的成因之一）
                showResults = false
            }
        }
        .onExitCommand {
            query = ""
            showResults = false
            focused = false
        }
    }

    // MARK: - 键盘高亮

    /// 当前高亮项（越界 → nil；`hits` 每次按键重算，必须夹范围）
    private var currentHit: Hit? {
        guard !hits.isEmpty else { return nil }
        return hits[min(max(highlighted, 0), hits.count - 1)]
    }

    /// 移动高亮（夹在 0..<count；到底不动）
    private func moveHighlight(_ delta: Int) -> KeyPress.Result {
        guard !hits.isEmpty else { return .ignored }
        highlighted = min(max(highlighted + delta, 0), hits.count - 1)
        return .handled
    }

    // MARK: - 结果列表

    private var resultList: some View {
        // ⚠ 只求值一次：`hits` 是全量扫描三个池（A 股 ~5200 + 基金 ~2100 + 港股）的计算属性，
        // 直接在 if / else if / ForEach 里引用会被求值 2~3 次 → 每次按键就是 2~3 遍全池扫描。
        // 提到局部变量后，一次 body 只扫一遍。
        let h = hits
        // 「已添加」判定也提到这里预建 Set：否则每个结果行都
        // `store.watchItems.contains { … }`，即 O(行数 × 自选数) 的线性扫描。
        let addedCodes = Set(store.watchItems.map(\.code))
        // ⚠ 从已求值的 `h` 取高亮项，**不要**用 `currentHit`（审查 B3）：
        //   `currentHit` 是计算属性，会**再扫一遍全池**（它内部判 `hits.isEmpty` 又取 `hits[i]`，
        //   等于两次），于是"只求值一次"的注释只做到了 `h` 这一行、下一行就漏了。
        let hi = h.isEmpty ? nil : h[min(max(highlighted, 0), h.count - 1)].code

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                if (store.fundListLoading || store.hkListLoading) && h.isEmpty {
                    HStack(spacing: 8) {
                        ThinkingDot(design: .connecting, diameter: 16)
                        Text("正在加载场内基金 / 港股列表（首次约 10 秒）…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                } else if h.isEmpty {
                    emptyState
                } else {
                    ForEach(h) { hit in
                        row(hit, addedCodes: addedCodes, highlighted: hit.code == hi)
                            .id(hit.code)
                    }
                }
                }
                .padding(6)
            }
            .onChange(of: hi) { _, new in
                guard let new else { return }
                // ⚠ 刻意**不做动画**：
                //   ① 键盘连按时逐帧滚动会跟手不及，看起来像卡；瞬时跳转才跟得上；
                //   ② 天然满足"减弱动态"（`motion_whitelist` 护栏要求动效走
                //      Components.swift 的 motionAware*，而"不加动效"是最彻底的合规）。
                proxy.scrollTo(new, anchor: .center)
            }
        }
        .frame(width: Self.panelWidth, height: Self.panelHeight - 22)
        .overlay(alignment: .bottom) {
            // 键位提示：键盘能力必须**可见**，否则等于没有（本项目"出口/入口要写在界面上"的同一条纪律）
            HStack(spacing: 6) {
                Text("↑↓ 或 Tab 选择 · ⏎ 添加 · Esc 取消")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Tok.float)
        }
        // ⚠ 表面色走 Tok 出口（`Tok.float`），不就地写系统色
        .background(RoundedRectangle(cornerRadius: 8).fill(Tok.float))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tok.stroke))
        .shadow(color: Tok.shadow, radius: 10, y: 4)
        .onHover { panelHovered = $0 }
    }

    @ViewBuilder
    private var emptyState: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        // 池子不可用（首次抓取失败 / 老库未建表）：只报"没有匹配"会把
        // "池子没加载"谎报成"确实没有这只标的" —— 必须给出重试入口
        let fundPoolMissing = store.fundList.isEmpty && !store.fundListLoading
        let hkPoolMissing = store.hkList.isEmpty && !store.hkListLoading
        VStack(alignment: .leading, spacing: 1) {
            if fundPoolMissing {
                retryRow("重新加载场内基金列表", hint: "（当前搜索不含基金）",
                         help: "重新抓取 ETF/LOF/封闭式基金列表（约 10 秒）") {
                    store.refreshFundList()
                }
            }
            if hkPoolMissing {
                retryRow("重新加载港股列表", hint: "（当前搜索不含港股）",
                         help: "重新抓取全部港股列表（约 10 秒）") {
                    store.refreshHkList()
                }
            }
            if isCodeLike(q) {
                // 代码形输入但列表里没有 → 实时行情取名称后直接加（覆盖列表外代码）
                Button {
                    directAdd(code: q)
                } label: {
                    HStack(spacing: 8) {
                        if directAdding {
                            ThinkingDot(design: .searching, diameter: 16)
                            Text("正在获取 \(q) 信息…").font(.callout).foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "plus.circle.fill").foregroundStyle(Sem.brand)
                            Text("直接添加 \(q)").font(.callout)
                            Text("（列表外代码，实时取名称）").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(directAdding)
            }
            if !fundPoolMissing && !hkPoolMissing && !isCodeLike(q) {
                Text("没有匹配的股票 / 基金 / 港股").font(.caption).foregroundStyle(.secondary)
                    .padding(12)
            }
        }
    }

    /// 池子不可用时的重试行（结果面板内的唯一动作入口）
    private func retryRow(_ title: String, hint: String, help: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise").foregroundStyle(Sem.brand)
                Text(title).font(.callout)
                Text(hint).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// 结果行：主体点了加到当前分组；行尾「+」停留/点击弹分组菜单
    /// `addedCodes`：已在自选里的代码集合（由 `resultList` 预建一次，避免逐行线性扫描）
    private func row(_ hit: Hit, addedCodes: Set<String>, highlighted: Bool) -> some View {
        let added = addedCodes.contains(hit.code)
        return HStack(spacing: 8) {
            // 行主体（可点区）：刻意排除行尾「+」，避免两个点击热区互相抢事件
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    // 徽章 + 交易所前缀与自选列表同源（StockQuotes.marketInfo 单一实现）；
                    // 优先级高于名称，空间不足时先截断名称而不是代码
                    MarketCodeLabel(code: hit.code, font: .callout)
                        .layoutPriority(1)
                        .help(hit.isFund ? "\(hit.name)（\(kindLabel(hit.kind))）" : hit.name)
                    Text(hit.name).font(.callout).lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture { if !added { add(hit, to: defaultGroup) } }
            .clickableRow()
            .help(added ? "已在自选中" : "加到当前选中分组")

            if added {
                Text("已添加").font(.caption).foregroundStyle(.secondary)
            } else {
                // 「+」：停留 0.3 秒或点击 → 就地弹出分组菜单（NSMenu）
                Button {
                    popGroupMenu(for: hit)
                } label: {
                    Image(systemName: hoveredCode == hit.code ? "plus.circle.fill" : "plus.circle")
                        .font(.callout)
                        .foregroundStyle(Sem.brand)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside {
                        scheduleGroupMenu(for: hit)
                    } else {
                        hoverTask?.cancel()
                    }
                }
                .help("停留在「+」上或点击：选择要加入的分组")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        // 键盘高亮与 hover 都是"当前项"指示：键盘态要能盖过鼠标残留
        .background(highlighted || hoveredCode == hit.code ? Tok.chip : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .leading) {
            if highlighted {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Sem.brand)
                    .frame(width: 2)
                    .padding(.vertical, 3)
            }
        }
        .onHover { hoveredCode = $0 ? hit.code : (hoveredCode == hit.code ? nil : hoveredCode) }
    }

    private func kindLabel(_ kind: String) -> String {
        switch kind {
        case "etf": return "ETF"
        case "lof": return "LOF"
        case "close": return "封基"
        default: return "基金"
        }
    }

    // MARK: - 搜索（A 股 + 场内基金，模糊匹配 + 排序）

    /// 模糊匹配：代码包含 或 名称包含；排序为 精确代码 > 代码前缀 > 名称前缀 > 名称包含，
    /// 同级按代码升序。A 股与基金**同名去重**（极端情况，优先 A 股）。
    private var hits: [Hit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let lower = q.lowercased()

        // ⚠ 排序改**装饰后比较**（2026-10-16 审查 B3）：原先 `rank(_:)` 在比较器里调
        //   `h.name.lowercased()` ⇒ 每次比较都分配小写副本，而单位数查询（如输入 "0"）
        //   会让 `code.contains(q)` 命中近乎全池（~7400 项）⇒ 约 n·log n 次字符串分配，
        //   表现为搜索框每敲一个字符卡一下。现在 rank 在收集时算一次，比较器只做整数/码值比较。
        var out: [(rank: Int, hit: Hit)] = []
        var seen = Set<String>()
        func collect(_ items: [JSONValue], overrideKind: String?) {
            for it in items {
                let code = it["code"].string ?? ""
                let name = it["name"].string ?? ""
                guard !code.isEmpty, !seen.contains(code) else { continue }
                // 名称匹配用 `range(of:options:)` 而不是 `name.lowercased().contains(...)`：
                // 后者对**每一项**都分配一个小写副本，三个池 ~7400 项 × 每次按键 = 数千次纯浪费的字符串分配。
                let nameHit = name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                guard code.contains(q) || nameHit else { continue }
                seen.insert(code)
                let rank: Int
                if code == q { rank = 0 }
                else if code.hasPrefix(q) { rank = 1 }
                // `hasPrefix` 的小写副本：每项**至多一次**（放在这里，不放比较器里）
                else if name.lowercased().hasPrefix(lower) { rank = 2 }
                else { rank = 3 }
                out.append((rank, Hit(code: code, name: name,
                                      kind: overrideKind ?? (it["kind"].string ?? ""))))
            }
        }
        collect(store.stockList, overrideKind: nil)      // A 股（无 kind）
        collect(store.fundList, overrideKind: nil)       // 场内基金（自带 etf/lof/close）
        collect(store.hkList, overrideKind: "hk")        // 港股（徽章由 5 位码派生为"港"）

        return out.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.hit.code < $1.hit.code }
            .prefix(30).map { $0.hit }
    }


    /// 输入是否像代码（5~6 位数字；5 位 = 港股，6 位 = A 股/场内基金）—— 用于"直接添加"兜底
    private func isCodeLike(_ s: String) -> Bool {
        (5...6).contains(s.count) && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    // MARK: - 分组菜单（悬浮停留 / 点击 → 就地弹出）

    /// 悬浮停留 0.3 秒后弹菜单（移开即取消；点「+」是立即弹出，不等待）
    private func scheduleGroupMenu(for hit: Hit) {
        hoverTask?.cancel()
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            popGroupMenu(for: hit)
        }
    }

    /// 在指针位置弹出分组菜单（NSMenu 模态跟踪：不吞首次点击）
    private func popGroupMenu(for hit: Hit) {
        hoverTask?.cancel()
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let content = window.contentView else { return }
        let menu = NSMenu()
        for g in store.watchGroups {
            let gid = g.id
            let item = NSMenuItem(title: "加到「\(g.name)」",
                                  action: #selector(GroupMenuTarget.fire(_:)), keyEquivalent: "")
            item.target = menuTarget
            item.representedObject = gid
            item.state = (gid == defaultGroup) ? .on : .off   // 勾出"当前分组"
            menu.addItem(item)
        }
        menuTarget.onSelect = { gid in add(hit, to: gid) }
        activeMenu = menu
        // 屏幕坐标 → 窗口内容视图坐标（convert 自动处理 flipped，勿手写翻转）
        let viewPoint = content.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        menu.popUp(positioning: nil, at: NSPoint(x: viewPoint.x - 8, y: viewPoint.y + 2), in: content)
        activeMenu = nil
    }

    // MARK: - 加入自选

    private func add(_ hit: Hit?, to group: Int) {
        guard let hit else { return }
        store.addWatch(code: hit.code, name: hit.name, group: group > 0 ? group : 1)
        query = ""
        focused = false
        showResults = false
    }

    /// 列表外代码：实时行情取名称后加入（名称拿不到时 `addWatch` 会明确拒绝，不写空名字）
    private func directAdd(code: String) {
        guard !directAdding else { return }
        directAdding = true
        Task {
            // ⚠ 走 `Store.addWatchByCode`（**唯一入口**，失败语义见该方法注释；
            //   视图里别各写一份添加逻辑）。
            //   ⚠ `Task {}` 在 View 里继承 MainActor ⇒ 不需要再包 `MainActor.run`。
            await store.addWatchByCode(code, group: defaultGroup > 0 ? defaultGroup : 1)
            directAdding = false
            query = ""
            focused = false
            showResults = false
        }
    }
}

/// NSMenu 目标/动作桥：菜单项（representedObject = 分组 id）→ 回调
private final class GroupMenuTarget: NSObject {
    var onSelect: ((Int) -> Void)?

    @objc func fire(_ sender: NSMenuItem) {
        if let gid = sender.representedObject as? Int { onSelect?(gid) }
    }
}
