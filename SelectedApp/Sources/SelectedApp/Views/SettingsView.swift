import SwiftUI
import AppKit
import SelectedCore

// MARK: - 设置
//
// ## 字号与间距档位（定稿）
//
// **字号**（全部走语义字号，**不写 pt** —— `AppFont` 那套 9/10/11pt 只给详情页的密集网格）：
//   页名 `.title3.bold()`（15）＞ 卡片标题 `.headline`（13，由 `Card` 统一提供）
//   ＞ 行标签 `.callout(.bold)`（13）＞ 正文/次要 `.caption`（11）＞ 可选提示 `.caption2`（10）
//
// **注脚只许两档**（多于两档会让同一种"小字说明"看着不一样）：
//   · **需要看的信息**（口径说明 / 时间 / 数量 / 行动指引）→ `.caption` + `.secondary`
//   · **可选提示**（占位「尚未…」、「…其余 N 只」这类）→ `.caption2` + `.tertiary`
//   ⚠ 同一个槽位（如 if/else 两分支）**必须同档** —— 否则会像"这行字忽然变大/变小"。
//
// **间距**：页面级卡片之间 **14**、页内边距 **16**（与主窗口各页一致）；**卡内首层一律 10**。
//   ⚠ 卡内第二层（小标题/控件组）用 2/4/6/8，别引入第 5 种值。

struct SettingsView: View {
    /// ⚠ module-internal（不能 `private`）：各段拆到 `Settings*Section.swift` 后，
    ///   跨文件的 extension 访问不到 `private` 成员。
    let store = Store.shared

    // MARK: 分类（设置窗口的左列）
    //
    // ⚠ 持久化用 `@AppStorage`（不是 `@SceneStorage`）：与主窗口的 `sidebar.page` **同一套** ——
    //   `@SceneStorage` 依赖 Scene 状态恢复，而 macOS 默认"退出应用时关闭窗口"⇒ 实机**不恢复**
    //   （理由见 `AppShellView` 的注释）。
    // ⚠ 必须是 module-internal（读写方在 `SettingsCategories.swift` 这个**跨文件** extension 里，
    //   Swift 的 `private` 只对同文件可见）。
    // ⚠ 老用户存过的 "params"/"tune" 坏值自动回落第一个分类（这两个分类已删；
    //   参数版本编辑与参数调优都在主窗口侧栏「参数中心」，单一入口纪律）。
    @AppStorage("settings.category") var categoryRaw = SettingsCategory.dashboard.rawValue

    /// 当前分类（坏值回落第一个分类 —— 枚举改名 / 存储被手改都不会让窗口空白）
    var category: SettingsCategory { SettingsCategory(rawValue: categoryRaw) ?? .dashboard }

    // MARK: 历史回放
    //
    // ⚠ 这两个 `@State` 必须声明在**结构体里**（不能放 extension）：
    // Swift 的存储属性/属性包装器不能声明在 extension 里。放宽到 module-internal
    // 是因为读写方在 `SettingsReplaySection.swift`（跨文件的 extension 看不到 private 成员）。
    /// 回放区间起点（默认一年前）
    @State var replayBeg = Date(timeIntervalSinceNow: -365 * 24 * 3600)
    /// 回放区间终点（默认昨天 —— 今天的数据还没走完）
    @State var replayEnd = Date(timeIntervalSinceNow: -24 * 3600)

    // MARK: 自选提醒

    /// 全局暂停提醒。⚠ 键名走 `AlertPause.defaultsKey`（**唯一**定义处）——
    /// 这里与 `AlertMonitor` 读的键一旦写成两个字面量，改一个忘一个就会变成
    /// "开关看着是开的、实际没生效"，而界面完全看不出来。
    @AppStorage(AlertPause.defaultsKey) var alertsPaused = false
    /// 看板指数直接拖动重排状态（不放 extension 里，读写方在 `SettingsDashboardSection.swift`）。
    @State var draggingIndexSymbol: String?
    @State var draggingIndexOffsetX: CGFloat = 0
    @State var dragStartSlot: Int = 0
    @State var dragStartLocationX: CGFloat = 0
    @State var indexStripWidth: CGFloat = 552
    /// 从设置页直接编辑某只票的提醒（`nil` = 不开弹窗）。
    /// ⚠ 与上面的 `replayBeg` 同一个理由不能是 `private`：读写方在
    /// `SettingsAlertSection.swift`（跨文件的 extension 看不到 private 成员）。
    @State var alertEdit: AlertEditTarget?
    /// 通知授权状态（`.task` 里向系统查，不是拿启动时那次请求的结果）。
    /// ⚠ 同上，读写方在 `SettingsAlertSection.swift`。
    @State var notifyStatus: Bool?
    /// 因"通知未开启"而未能送达的提醒条数。
    /// ⚠ 从 `Notifier.shared.suppressedCount` **拷进 @State** —— `Notifier` 不是 `@Observable`，
    ///   直接读它 SwiftUI 不会跟踪更新；在 `refreshNotifyStatus()` 里同步一次即可。
    @State var notifySuppressedCount = 0
    /// 因"缺行情未判定"的票数。
    /// ⚠ 与 `notifySuppressedCount` **分开存** —— 后者是"系统没授权"，
    ///   这个是"没取到行情（断网/限流）"，处置完全不同，混用会把用户引到错误的修复路径上。
    @State var notifySkippedNoQuote = 0

    // MARK: 数据源诊断
    //
    // ⚠ 这三个必须在**主声明**里 —— `SettingsDiagSection.swift` 是 extension，
    //   而 Swift 不允许 extension 含存储属性（报 "extensions must not contain
    //   stored properties"）。
    // ⚠ 可见性**必须**是 module-internal（不能 private）—— 读写方在
    //   SettingsDiagSection.swift 这个**跨文件 extension** 里，而 Swift 的
    //   `private` 只对同文件可见。
    @State var diagStoreRef = DataSourceLogStore()
    /// 手动刷新计数。⚠ `DataSourceLogStore` **不是** `@Observable`
    ///   （Core 层禁 `Observation`，见 `DataSourceLogStore.swift` 的说明）
    ///   ⇒ 属性变化不会自动触发 View 刷新，必须在每个动作后 `diagTick += 1`。
    @State var diagTick = 0

    /// 历史回放结果是否展开：收起态只显示最近 5 天。
    /// ⚠ 必须声明在**主声明**里 —— 读写方在 `SettingsReplaySection.swift`（extension）
    ///   → 不能是 `private`（跨文件看不到）。
    @State var replayExpanded = false
    /// 「清空日K缓存」的确认开关（读写方在 `SettingsReplaySection.swift`，不能 private）
    @State var confirmClearReplayCache = false


    var body: some View {
        mainShell
    }

    private var mainShell: some View {
        // 设置窗口是「左分类 + 右内容」，壳用与主窗口**同一个** `FixedTwoColumnShell`
        // 固定两列骨架（0.5.37 起；原生 `NavigationSplitView` 的分隔条光标/拖拽/收起整族
        // 问题三轮 AppKit 补丁全失败，结构性拆除 —— 整窗一层玻璃铺到窗口顶，红绿灯坐其上，
        // 右侧内容面板坐在玻璃上）。
        FixedTwoColumnShell(sidebarWidth: 144) {
            settingsCategoryList
        } detail: {
            VStack(spacing: 0) {
                // ⚠ 顶栏**只在有错误横幅时渲染**：设置页没有页名、没有更新时间戳、
                //   没有操作按钮（日期/刷新都在主窗口那侧），空顶栏只剩占高 ⇒
                //   把右侧卡片整体压低，与侧栏首行不对齐。错误横幅（`bannerError`）仍要可见可关。
                // ⚠ 判据必须是**非空串**而不是 `!= nil`：`lastError` 会被写成空串
                //   （如 `tune.errorDash` 无错时就是 `""`）⇒ `!= nil` 为真 ⇒ 渲染出
                //   一条**没有内容**的空顶栏。
                // ⚠ 判据与主窗口**同读 `Store.bannerError`**（横幅唯一判据，内含白名单）——
                //   两处各写一份必然漂。
                if Store.shared.bannerError != nil {
                    PageActionBar(showsUpdateStamp: false) { }
                }
                FitScrollView {
                    VStack(spacing: 14) {
                        settingsPage(category)
                    }
                    .padding(16)
                    // 设置页每类只有一张“整页卡”，末卡会拉伸吞掉视口剩余高度。
                    // 给拉伸卡画 hairline ⇒ 一个包住大片空白的大框（2026-10-20 审查截图）。
                    // 这里只关描边，不动拉伸（取消拉伸会让 Settings scene 打开时布局不收敛）。
                    .environment(\.cardSurfaceBordered, false)
                }
            }
            // ⚠ 空工具栏带（红绿灯由系统标题栏承载）把详情列顶下 ⇒ 负 padding 回收。
            //   校准（0.5.41 老板重拍：设置页**没有**主窗口那条功能顶栏（PageActionBar），
            //   详情列第一块就是内容卡片 —— 贴到 18（与红绿灯齐平）"顶到最上面不好看"）。
            //   基准：**页标题与侧栏首行同排**（旧设置窗口"两列首元素对齐"的设计语言）。
            //   ⚠ 改骨架几何（列宽 / 面板内缩 / 带高）后要重新截图像素校准这个数。
            .padding(.top, -12)
        }
        // 摘掉标题项（与主窗口同款）
        .toolbar(removing: .title)
        // ⚠ **别用 `.toolbar(.hidden, for: .windowToolbar)`** —— 它把整条工具栏宿主连红绿灯一起摘了。
        //   去 hairline 用只隐"工具栏背景"的 `.toolbarBackground(.hidden, …)`：
        //   工具栏宿主与红绿灯保留、底部分隔线随之消失。
        .toolbarBackground(.hidden, for: .windowToolbar)
        .dismissKeyboardOnOutsideTap()
        .task { store.refreshParams(); store.loadStockList(); store.refreshReplayCache()
                store.loadIndexMemberStats()
                store.loadFundamentalStats() }
        // ⚠ 离开设置页时释放回放的**逐日结果** —— 它挂在 `Store.shared`（进程级），
        //   不清就会一直驻留。⚠ 回放正在跑时 `clearReplayResults()` 自己会挡（不丢进行中的结果）。
        .onDisappear { store.clearReplayResults() }
        .sheet(item: $alertEdit) { t in
            // sheet 层级之上看不到窗口根的 toast ⇒ 内容自己挂（审查 B6）
            AlertEditSheet(code: t.code, name: t.name).toastOverlay()
        }

    }

    // MARK: 数据源自检

    var selftestCard: some View {
        Card("数据源自检", subtitle: "全 HTTP 链路 · 三层兜底") {
            VStack(alignment: .leading, spacing: 10) {
                // 上方：已接入数据源胶囊
                VStack(alignment: .leading, spacing: 6) {
                    Text("已接入数据源")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if store.busy.contains("selftest") {
                            ForEach(Self.knownSources, id: \.self) { _ in
                                sourcePill(name: nil)
                            }
                        } else if let srcs = store.selftestReport?["sources"].array, !srcs.isEmpty {
                            // id 用数据源名：`srcs` 会从"占位列表"变成"真实自检结果"，
                            // 行数/内容都变 —— 用 `\.offset` 会让第 0 行被复用到另一个数据源上。
                            ForEach(srcs, id: \.sourceKey) { s in
                                sourcePill(name: s["source"].string,
                                           ok: s["ok"].intOrZero, total: s["total"].intOrZero,
                                           status: s["status"].string)
                            }
                        } else {
                            // 未检测：固定展示三个真实源占位
                            ForEach(Self.knownSources, id: \.self) { n in
                                sourcePill(name: n)
                            }
                        }
                        Spacer()
                    }
                }

                Divider()

                // 下方：能力自检行（渠道计数 + 状态灯）
                VStack(spacing: 4) {
                    ForEach(Self.capItems, id: \.self) { cap in
                        selftestRow(cap)
                    }
                }

                HStack(spacing: 10) {
                    if let t = store.lastSelftestAt {
                        Label("最后自检 " + Self.fmtTime(t), systemImage: "clock")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("尚未自检（启动后自动执行首次检测，每小时自动复检）")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        store.runSelftest()
                    } label: {
                        Label(store.busy.contains("selftest") ? "检测中…" : "立即自检",
                              systemImage: "stethoscope")
                    }
                    .btnPrimary()
                    .disabled(store.busy.contains("selftest"))
                }
            }
        }
    }

    private static let knownSources = ["腾讯", "新浪", "东财"]
    private static let capItems = ["证券列表", "实时行情", "日K线", "指数行情", "分时", "5分钟K线"]

    /// 数据源胶囊：绿=全通 黄=部分通 红=全挂 灰=未检测
    private func sourcePill(name: String?, ok: Int? = nil, total: Int? = nil, status: String? = nil) -> some View {
        let color: Color = {
            guard let status else { return .secondary }
            switch status {
            case "green": return Sem.down
            case "yellow": return Sem.warn
            case "red": return Sem.up
            default: return .secondary
            }
        }()
        return HStack(spacing: 5) {
            Circle().fill(name == nil ? Tok.stroke : color)
                .frame(width: 7, height: 7)
            Text(name ?? "检测中")
            if let ok, let total {
                Text("\(ok)/\(total)")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            // ⚠ 走 `Tok.tint` 而不是裸透明度：三元表达式里的裸透明度（如
            //   `color.opacity(name == nil ? 0.06 : 0.10)`）正好绕过 `theme_tint` 护栏的
            //   正则（它只匹配"括号里直接是数字"），这一处靠自觉。
            //   `Tok.tint` 只有三档：`.block` 0.08 / `.chip` 0.12 / `.strong` 0.18。
            Capsule().fill(Tok.tint(color, name == nil ? .block : .chip))
        )
        .overlay(
            // ⚠ 描边同样收敛到三档 —— 取值集合回到"三档"，下一个人不用再猜该用多少。
            Capsule().strokeBorder(Tok.tint(color, .strong))
        )
        .help(name == nil ? "检测中" : "\(name ?? "") \(ok ?? 0)/\(total ?? 0) 探测通过")
    }

    /// 能力行：名称 + (通/总) 渠道计数 + 状态灯（绿=主源通 黄=降级运行 红=全挂 灰=待检）
    private func selftestRow(_ cap: String) -> some View {
        let checks = store.selftestReport?["checks"].array ?? []
        let c = checks.first { $0["item"].string == cap }
        let running = store.busy.contains("selftest")
        let statusColor: Color = {
            if c == nil { return running ? .secondary : Tok.dim }
            switch c?["status"].string {
            case "green": return Sem.down
            case "yellow": return Sem.warn
            case "red": return Sem.up
            default: return .secondary
            }
        }()
        let countText: String = {
            guard let c else { return running ? "…" : "--" }
            return "\(c["ok_count"].intOrZero)/\(c["total"].intOrZero)"
        }()
        return HStack(spacing: 10) {
            Text(cap)
                .frame(width: 76, alignment: .leading)
            Text("(\(countText))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(c?["detail"].stringOrDash.isEmpty == true ? (running ? "检测中…" : "待检测") : (c?["detail"].string ?? ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            HStack(spacing: 4) {
                Text(statusLabel(c, running: running))
                    .font(.caption2)
                    .foregroundStyle(statusColor)
                Circle().fill(statusColor).frame(width: 8, height: 8)
            }
            .frame(width: 64, alignment: .trailing)
        }
        .font(.callout)
    }

    private func statusLabel(_ c: JSONValue?, running: Bool) -> String {
        guard let c else { return running ? "检测中" : "待检测" }
        switch c["status"].string {
        case "green": return "正常"
        case "yellow": return "降级"
        case "red": return "中断"
        default: return "—"
        }
    }

    private static func fmtTime(_ d: Date) -> String {
        // ⚠ 委托 ChinaTime（en_US_POSIX + Asia/Shanghai 逐字等价）
        ChinaTime.formatter("HH:mm:ss").string(from: d)
    }

    // MARK: 外观（明暗）
    //
    // ⚠ 设置窗口**没有**外观控件：三档外观在**主窗口侧栏左下角**
    //   （见 `AppShellView.appearanceIcons`），同一个动作不留两条入口。
    //   ⚠ 别在这里"顺手加回来一个"：`AppearanceStore` 不是 `@Observable`，
    //     两边各持一个 `@State` 就一定会不同步。

    // MARK: 关于

    var aboutCard: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .shadow(color: Tok.shadow, radius: 14, y: 6)
            Text("Selected")
                .font(.title2.bold())
                .padding(.top, 14)
            Text("A股尾盘量化选股")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 3)
            Text("版本 v\(AppInfo.version) · 构建 \(AppInfo.buildDate)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            // 静默检查发现的新版本（`UpdateCenter` 每日查一次，不弹窗只提示）
            if let newVersion = UpdateCenter.shared.availableVersion {
                Text("发现新版本 v\(newVersion)")
                    .font(.caption.bold())
                    .foregroundStyle(Sem.info)
                    .padding(.top, 4)
            }
            HStack(spacing: 10) {
                Button("检查更新…") {
                    UpdateCenter.shared.checkForUpdates()
                }
                .btnSecondary()
                .help("立即检查是否有新版本（与菜单栏「检查更新…」同一入口）")
                Button("重看新手引导") {
                    AppDelegate.reopenOnboarding?()
                }
                .btnSecondary()
                // ⚠ 唯一的用户反馈通道 —— 打开仓库 Issue 新建页
                Button("反馈问题") {
                    if let url = URL(string: AppInfo.issuesURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .btnSecondary()
                .help("打开 GitHub 仓库的 Issue 新建页（需网络）")
            }
            .padding(.top, 16)
            Text("三轮对比选股 × 四阶段验证闭环 × 菜单栏常驻")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 18)
            Text("本应用为信号分析与决策辅助工具，不构成投资建议，不含下单交易功能。"
                 + "所有买卖决策由用户在券商端人工执行，盈亏自负。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
                .padding(.top, 6)
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
