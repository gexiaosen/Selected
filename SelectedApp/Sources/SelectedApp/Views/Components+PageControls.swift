import SwiftUI
import SelectedCore
import ThinkingOrbs

extension View {
    /// 挂在页面主 ScrollView 上：上报滚动进度（内容不足一屏时恒为 0 → 不显示进度线）
    func reportsScrollProgress() -> some View {
        self
            .onScrollGeometryChange(for: Double.self) { geo in
                let scrollable = geo.contentSize.height - geo.containerSize.height
                guard scrollable > 1 else { return 0 }
                return min(max(geo.contentOffset.y / scrollable, 0), 1)
            } action: { _, v in
                ScrollProgress.shared.update(v)
            }
            // ⚠ 归零必须挂在**新页出现**（onAppear），不能挂旧页 onDisappear：切页时新旧视图并存
            //   （`AppShellView` 用 `.id(page)` + 150ms 过渡），旧页的 onDisappear 会把
            //   新页已上报的进度清零，进度在下次滚动前一直是错的。
            .onAppear { ScrollProgress.shared.reset() }
    }
}

// MARK: - FitScrollView（页面级混合布局容器）

/// 顶部一条规则统一所有页面「底部留白」问题的容器：
/// 内容**自然高度**（隐藏叠加实测）≤ 视口 − inset → **等高铺满**：
/// 无滚动容器 ⇒ 高度提案有界 ⇒ 卡片的 `.frame(maxHeight:.infinity)` 拉伸生效，
/// 底部留白被吸进卡片内部（不再是页面底部一片白）；
/// 超出 → **真实滚动**（`ScrollView` + 滚动进度上报，供顶栏时间戳退让），内容不裁切。
///
/// ⚠ 测量叠放必须用「位移出视口」（`.offset(x:-9999,y:-9999)`）+ `allowsHitTesting(false)`，
/// 不能用低透明度（撞 theme_tint「<0.2 裸透明度」护栏）或读屏修饰符（撞 a11y_absent 护栏）。
///
/// ⚠ 两条决定本容器是否生效的约束：
///   ① 测量副本**必须** `fixedSize(horizontal: false, vertical: true)`（对子视图提案 nil 高度）——
///      否则 overlay 把容器视口高度提案给副本，带拉伸的卡片被量成"自然高度 ≈ 视口"，
///      `fits` 永远 false，铺满分支一次都不会跑。
///   ② 各页根部必须是 `VStack` 而非 `LazyVStack` —— LazyVStack **不向子视图分发多余高度**，
///      卡片上的 `.frame(maxHeight:.infinity)` 在它里面不会拉伸，底部留白吸不进卡片。
struct FitScrollView<Content: View>: View {
    @ViewBuilder var content: Content
    /// 判定余量：内容自然高度 ≤ 视口 − inset 即铺满。默认 0（`content` 已含页面内边距）
    var bottomInset: CGFloat = 0
    /// 未测量前用「无穷大」→ 先按滚动渲染（安全：绝不压缩内容），量到后再裁决
    @State private var naturalH: CGFloat = .greatestFiniteMagnitude

    init(bottomInset: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.bottomInset = bottomInset
        self.content = content()
    }

    var body: some View {
        GeometryReader { geo in
            let vh = geo.size.height
            let fits = naturalH <= vh - bottomInset
            Group {
                if fits {
                    content
                        .frame(maxHeight: .infinity, alignment: .top)
                        // 铺满模式没有滚动容器 ⇒ `reportsScrollProgress` 不会挂上 ⇒
                        // 手动归零，避免残留上一页的进度线
                        .onAppear { ScrollProgress.shared.reset() }
                } else {
                    ScrollView {
                        content
                    }
                    .reportsScrollProgress()
                }
            }
            .frame(maxHeight: .infinity)
            // 自然高度测量：同一份内容放到视口外测量。
            // ⚠ `fixedSize(horizontal: false, vertical: true)` 是**必须**的（见类型注释 ①）：
            //   高度提案为 nil ⇒ 卡片回落自然高度 ⇒ 量到的是真·自然高度。
            .overlay(alignment: .topLeading) {
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: -9999, y: -9999)
                    .allowsHitTesting(false)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { naturalH = $0 }
            }
        }
        // 这里**不铺任何底**：内容直接坐在骨架那层全窗玻璃上。
        // ⚠ 别再给这一层加"面板底 + 描边 + 阴影"（2026-10-23 老板实机看完否掉：
        //   「参数和自选页面内容侧没有白底，其他页面也全都去掉。内容直接放」）。
        //   页面自己的 `.padding(16)` 就是内容与玻璃之间唯一的距离，与那两页同一套节奏。
    }
}

// MARK: - 页面操作栏（统一结构：更新时间最左，日期+操作按钮最右；切页零布局变化）

struct PageActionBar<Content: View>: View {
    /// 页名（可选，显示在**顶栏最左**）。
    ///
    /// ⚠ 设置窗口的标题栏文字已隐藏，窗口身份由这里承载 —— 形态对齐 macOS「系统设置」：
    ///   标题栏无字、页名在内容区左上角。主窗口各页仍传空（页名在侧栏选中项上，不重复显示）。
    var title: String? = nil
    /// 是否显示「更新 hh:mm:ss」时间戳（设置页各页传 `false` —— 各设置项的变动时间
    /// 已在对应位置显示；主窗口各页照旧）。
    var showsUpdateStamp = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            // 错误横幅：**只留给库级故障**（判据唯一来源 `Store.bannerError`，
            // 内含 `ToastPolicy.allowsBanner` 白名单 = dbBootstrap / dbIntegrity）。
            // ⚠ 普通写操作失败走 toast（瞬时事件的一次性反馈，自动消失 / error 档点别处消失），
            //   这条持久红条不能跨日期、跨页面赖着不走；只有"库损坏 / 建库失败"需要
            //   持续可见 + 给恢复线索，才保留横幅。
            if let err = Store.shared.bannerError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Sem.up)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(Sem.up)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        Store.shared.lastError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Tok.dim)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Tok.tint(Sem.up, .block))
            }
            // ⚠ 回放进行中必须让**每个页面**都知道（2026-10-16 审查 B6）：
            //   `HistoryReplayMode` 是**进程级**开关 —— 它一打开，引擎侧的
            //   `fetchTencentQuotes` / `fetchIndexQuote` / `runDate()` / `isTradingDay()`
            //   全部改从历史库取数，而自选价与看板 hero 走的是另两条**不查该开关**的
            //   直连路径（`QuoteAPI.batch` / `QuoteAPI.indexes`）。
            //   原先全 App 只有「设置 › 历史回放」一张卡读这个状态，
            //   于是回放跑的那几十分钟里，主窗口看起来与平时**完全一样**：
            //   DateChip 仍是蓝色「最新」、判定与统计却按历史日市场环境算 ——
            //   这是本项目可能造成误判的最大的一个静默态。
            //   放在 `PageHeader`（主窗口与设置页共用）⇒ 一处加、处处有。
            if Store.shared.busy.contains("replay") || Store.shared.busy.contains("replayDownload") {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(Sem.warn)
                    Text(HistoryReplayMode.isBusy
                         ? "历史回放进行中（\(HistoryReplayMode.activeDay ?? "整段会话")）· 引擎取数走历史库，"
                            + "行情与提醒仍为实时口径，两侧不同日"
                         : "日K缓存下载中 · 期间请勿开始历史回放或手动写操作")
                        .font(.caption)
                        .foregroundStyle(Sem.warn)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Tok.tint(Sem.warn, .block))
            }

            HStack(spacing: 8) {
                if let title {
                    Text(title)
                        .font(.title3.bold())
                    // 细竖线把「页名」与「数据更新时间」分开（两者不是一回事）
                    // ⚠ 高度 16：配合 15pt 粗体页名（比字面矮一截会看着像断了一角）
                    Divider().frame(height: 16)
                }
                // 滚动到下方时时间戳退让（"更新 14:23:04" 只在页首需要看清）
                if showsUpdateStamp {
                    UpdateStampView(date: Store.shared.lastRefreshAt)
                        .opacity(scrolled ? 0.45 : 1)
                        .animation(Mot.scroll, value: scrolled)
                }
                Spacer()
                content
            }
        }
        // ⚠ 左右 18（2026-10-19 老板要求：右上角按钮右缘留 18pt，与红绿灯左/上 18pt 同一套边距）。
        //   原 16 ⇒ 按钮右缘距窗口 16，与侧栏顶部 18 的边距不齐。
        .padding(.horizontal, 18)
        // ⚠ 上 13 / 下 8（2026-10-19）：老板要求右上角按钮**上缘**留 18pt。
        //   实测原「vertical 8」下按钮顶只有 ~12.8pt（详情列的 -37 负 padding 把整条上提后
        //   落在带区里）⇒ 补 5pt 才到 18。改这个值要连带复核 `AppShellView` 的 -37 注释。
        .padding(.top, 13)
        .padding(.bottom, 8)
        // ⚠ 页栏**不再有自带底**，也不再 `zIndex` 置顶、也不再画底边 `Divider`。
        //   旧结构里它是 sticky header：详情列被 `-37` 提进带区，页栏与滚动区叠在同一个容器里，
        //   没有不透明底就会被穿过的内容压住、且**后绘制的滚动内容在命中测试里赢过先绘制的兄弟**
        //   ⇒ 点按钮没反应。现在内容被关进内缩的实底面板（见 `FitScrollView` 的面板段），
        //   页栏在面板**之外**、直接坐在整窗那一层玻璃上 —— 没有东西会从它下面滚过去，
        //   那套"挡穿透 + 置顶 + 补一条分隔线"的补丁结构性不再需要，留着反而正好造成
        //   老板点名的那个毛病：**在内容层上面又叠一条带子**。
        //
        // ⚠⚠ 拖动区仍然**必须**挂在它这里（页栏这片就是标题栏带区，老板要求「内容栏上边也能拖窗口」）。
        //   命中顺序 = 按钮/文字先拿点击，只有空白处落到 `WindowDragStrip`。
        //   ⚠ 别改成 `.overlay` —— 页栏按钮会整排失灵（三条"更原生"的替代路都试过、全部不生效，
        //   见 `Components.swift` 的 `WindowDragStrip` 注释）。
        .background(WindowDragStrip())
        // 长页滚动进度线**已去掉**（与右侧滚动条重复）。`ScrollProgress` 上报保留 ——
        // 顶栏时间戳的滚动退让（`scrolled`）仍依赖它。
    }

    /// 是否已离开页首（进度线上 5% 之后算"滚下去了"）
    private var scrolled: Bool { ScrollProgress.shared.value > 0.05 }
}

// MARK: - 代码市场标识（徽章 + 交易所前缀）

/// 单字徽章 + 带交易所前缀的代码：创 SZ300221 / 基 SH510300 / 港 HK01276 / 科 SH688981
///
/// 徽章与前缀由 `StockQuotes.marketInfo` **单一派生**（自选列表/搜索结果共用），
/// 勿在视图里另写一套判断 —— 两处判断必然漂移。
struct MarketCodeLabel: View {
    let code: String
    var font: Font = .caption2

    var body: some View {
        let info = StockQuotes.marketInfo(code)
        HStack(spacing: 3) {
            if !info.tag.isEmpty {
                Text(info.tag)
                    .font(AppFont.micro.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 13, height: 13)
                    .background(RoundedRectangle(cornerRadius: 3)
                        .fill(Tok.chipStrong))
                    .help(StockQuotes.marketTagHelp(info.tag))
            }
            // 徽章+前缀比纯数字长（创 SZ300221），列宽被压缩时**必须缩字不折行**
            // （折行会把行高撑成两行，整列对不齐）
            Text(info.display)
                .font(font.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}

// MARK: - 统一操作按钮（背景色 + 旋转箭头；busy 时箭头旋转并禁用）

struct ActionBarButton: View {
    let title: String
    var icon: String = "arrow.clockwise"
    /// 次操作：设置/批量重跑这类辅助动作。**同一页最多一个 primary**
    /// （指标筛选的「设置」、自选的「全量判定」都走这档，避免两颗实底蓝互相抢）。
    var secondary = false
    var isBusy = false
    var isDisabled = false
    var helpText = ""
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .symbolEffect(.rotate, isActive: isBusy)
                .contentShape(Rectangle())
        }
        .modifier(ActionBarButtonRole(secondary: secondary))
        .disabled(isDisabled || isBusy)
        .help(helpText.isEmpty ? title : helpText)
    }
}

private struct ActionBarButtonRole: ViewModifier {
    let secondary: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if secondary {
            content.btnSecondary()
        } else {
            content.btnPrimary()
        }
    }
}

/// 未生成环节的空态提示（带预计生成时间；右上角操作栏已有手动按钮，这里不再重复放）
/// compact：压缩占位高度（同页多空态一屏放下）；字号与各页 EmptyStateView 保持一致
struct PendingStageView: View {
    let stageName: String
    let eta: String

    var body: some View {
        EmptyStateView(icon: "clock.badge.checkmark",
                       title: "\(stageName)未生成",
                       hint: "预计生成时间：\(eta)（自动执行，无需手动操作）",
                       compact: true)
    }
}

/// 最近记录跳转提示（今天模式下替代静默回退）
/// lead：该环节的生成时机描述（按环节实际时点，对比是当天 15:02，预判/复盘是 T+1）
struct RecentRecordHint: View {
    private let store = Store.shared
    var lead: String = "该记录将在 T+1 生成"
    var onJump: (String) -> Void

    var body: some View {
        let candidates = store.dayMeta.keys.filter { $0 < store.viewDate }.sorted()
            if let latest = candidates.last {
            HStack(spacing: 6) {
                Image(systemName: "info.circle").foregroundStyle(Sem.info)
                Text("\(lead) · 最近可查看：")
                    .font(.caption)
                Button(latest) { onJump(latest) }
                    .font(.caption.bold())
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Tok.tint(Sem.info, .block), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// 最后更新时间标签（跟随全局刷新时间）
struct UpdateStampView: View {
    let date: Date?

    var body: some View {
        Text("更新 " + (date.map { Self.fmt($0) } ?? "--:--:--"))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    /// ⚠ 缓存为 `static let`：本视图挂在每个页面的操作栏上、随 Store 每次变更重算，
    /// `DateFormatter` 构造约 0.1~1ms，属高频路径上的纯浪费。走 `ChinaTime.formatter`（含 locale/时区）。
    private static let stampFmt = ChinaTime.formatter("HH:mm:ss")

    private static func fmt(_ d: Date) -> String { stampFmt.string(from: d) }
}

