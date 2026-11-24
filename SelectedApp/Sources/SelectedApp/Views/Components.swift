import SwiftUI
import AppKit          // NSEvent 本地监视器（可点击行的按下态，见 MousePressCenter）
import Observation
import SelectedCore
// 长任务用的点阵动效（本地 vendor，只给 UI 层）。
// ⚠ 用法白名单见 docs/specs/README.md
import ThinkingOrbs

// 色板已抽到 Tokens.swift（Sem 业务语义 / Tok 表面与线条，明暗自适应）。
// 本文件只放组件，不再定义颜色。

// MARK: - 动效口径：「减弱动态」的统一出口
//
// 两个 View 修饰器（动效出口唯一化）：
//
//   `.motionAware(_:value:)`         ↔ `.animation(_:value:)`
//   `.motionAwareTransition(_:)`     ↔ `.transition(_:)`
//
// **退化目标是"瞬时到位"，不是"换个更柔的动效"**：本 App 的自绘动效全是
// 位置类 / 弹性类（滑块位移、Toast 滑入、数字按位滚动、展开折叠）—— 正是
// 「减弱动态」要消除的那一类；而它们承载的信息（谁被选中、提示来了、数字变了、
// 面板开了）在瞬时到位后一个都没丢。
//
// 有意**不**处理的（不是遗漏，是口径）：
//   · 纯不透明度淡入淡出（`.transition(.opacity)`、挂在 `.opacity(...)` 上的 animation）
//     —— 它本来就是系统给 reduced motion 的等价形态，再退化等于删掉反馈
//   · `symbolEffect` 状态指示（忙碌旋转 / 运行脉冲 / 完成弹一下）
//     —— 体量小、非装饰，且旁边都有等价文字（"执行中：…"）
//   · sheet / popover 的转场由系统自行响应辅助功能开关
//
// 事务级 API（`withAnimation`）包不进修饰器：**带位移过渡**的两处（选股结果的详情展开、
// 调优候选的展开）在各视图内读 `accessibilityReduceMotion` 传 nil；
// 只影响不透明度的 withAnimation 不在此列 —— 同上面第一条口径。

private struct MotionAwareAnimation<V: Equatable>: ViewModifier {
    let animation: Animation?
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

private struct MotionAwareTransition: ViewModifier {
    let transition: AnyTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .opacity : transition)
    }
}

extension View {
    /// `.animation(_:value:)` 的「减弱动态」感知版：开关打开时**瞬时到位**
    func motionAware<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(MotionAwareAnimation(animation: animation, value: value))
    }

    /// `.transition(_:)` 的「减弱动态」感知版：开关打开时退化为纯淡入淡出
    func motionAwareTransition(_ transition: AnyTransition) -> some View {
        modifier(MotionAwareTransition(transition: transition))
    }
}

// MARK: - 动效时长口径：`Mot`（**曲线 + 时长的唯一来源**）
//
// 上面两个修饰器只收住了「出口」，没收「时长」：20 个调用点上写的是 6 个互不相干的
// 字面量（0.12 / 0.15 / 0.18 / 0.20 / 0.22 / 0.25），散在 7 个文件里。后果不是不好看，
// 是**改不动** —— "全站动效再利落一点"要 20 处逐个找，新增一个动效则没人知道该填几秒，
// 于是档位只会越来越多（和表格列宽三套算法同一个病，见 `ColumnLayout`）。
//
// 命名按**用途**、不按快慢：`fast/slow` 半年后没人记得谁该用哪一档。
//
// ⚠ 每个 token 的 (曲线, 时长) 就是收口前各调用点**在用**的那一个 —— 这一步是收口，
//   不是重新设计，必须零视觉变化；要调手感是另一件事，改这里一个数、全站跟着走。
// ⚠ 护栏 `motion_whitelist` 会扫 Components.swift 之外出现字面量 `duration:` 或系统
//   曲线构造器，出现即报红：绕开 `Mot` 零编译代价，只是让口径重新散开。
enum Mot {
    /// 悬浮淡底（`SidebarTab` / `IconHoverFeedback`）
    static let hover: Animation = .easeOut(duration: 0.12)
    /// 自选分组切换（行位置移动）
    static let move: Animation = .easeOut(duration: 0.15)
    /// 重跑期间旧数据淡化（`staleWhileBusy`）
    static let dim: Animation = .easeOut(duration: 0.18)
    /// 长页回顶滚动
    static let scroll: Animation = .easeOut(duration: 0.20)
    /// 列表项换位（对称曲线，两边同时进出）
    static let swap: Animation = .easeInOut(duration: 0.20)
    /// 详情 / 调优候选展开（**事务级** `withAnimation` 专用，包不进修饰器）
    static let expand: Animation = .snappy(duration: 0.20)
    /// 数字与价格按位滚动（`.contentTransition(.numericText)` 的搭档）
    static let value: Animation = .snappy(duration: 0.22)
    /// Toast 滑入（位移最长的一档）
    static let toast: Animation = .snappy(duration: 0.25)
    /// 按下反馈（`clickableRow()` 的轻淡）——比 hover 还短，按下必须"跟着手"
    static let press: Animation = .easeOut(duration: 0.10)
}

// MARK: - 按钮角色（**按钮样式的唯一出口**）
//
// 全部是原生样式的**薄封装**（不自绘 ButtonStyle），只有 4 个角色：
//
//     主操作 primary   实底品牌蓝   —— 每个界面**最多一个**（选股 / 保存 / 确定 / 生成）
//     次操作 secondary 系统描边（跟随品牌 accent） —— 取消 / 关闭 / 反馈 / 重看引导 / 一切"非主要"动作
//     破坏性 danger    红字描边     —— 删除 / 移出自选 / 清仓（确认弹窗里允许实底强调）
//     图标   icon      无边框图标   —— 行内 xmark / 星标 / 编辑
//
// ⚠ 语义色（涨跌 / 灯级 / 信号 / 风险）**不上按钮**：那是数据展示的颜色语言，
//   用在按钮上会让"红色"既表示"上涨"又表示"危险"，两个含义互相污染。
//   按钮只表达**操作分量**（主要 / 次要 / 破坏），不表达业务语义。
// ⚠ 新增按钮一律用下面四个角色，别再就地写 `.buttonStyle + .tint`（静态护栏 `button_style` 会把关）。

extension View {
    /// 主操作：实底品牌蓝（**每个界面最多一个**）
    func btnPrimary() -> some View {
        // ⚠ 用 `brandFill` 不是 `brand`：borderedProminent 由系统配白字，
        //   抬亮后的文字位会把白字压到 2.83:1。原因见 `Quad.fillDark` 注释。
        buttonStyle(.borderedProminent).tint(Sem.brandFill)
    }

    /// 次操作：系统描边（跟随全局品牌 accent；仍低于实底主操作）
    /// ⚠ 全局 `.tint(Sem.brand)` 之后，`.bordered` 的文字/描边取品牌色，不再是系统灰。
    func btnSecondary() -> some View {
        buttonStyle(.bordered)
    }

    /// 破坏性操作：红字描边（删除 / 移出自选 / 清仓）
    func btnDanger() -> some View {
        buttonStyle(.bordered).tint(Sem.up)
    }

    /// 破坏性操作（确认弹窗里的最终确认）：实底红
    func btnDangerFilled() -> some View {
        buttonStyle(.borderedProminent).tint(Sem.upFill)   // 同上：填充位，不是文字位
    }

    /// 图标按钮：无边框 + 次级前景（危险动作传 `Sem.up`）+ hover 淡底微交互
    ///
    /// ⚠ `.borderless` 本身没有任何悬停反馈，淡底走 `Tok.chip`（裸 opacity 撞 `theme_tint` 护栏）。
    /// ⚠ 命中区由调用点的 `.frame`+`.contentShape` 决定（见 DateChip 的 ≥24pt 说明），
    ///   本修饰器只加视觉、不改布局。
    func btnIcon(_ tint: Color = .secondary) -> some View {
        buttonStyle(.borderless)
            .foregroundStyle(tint)
            .modifier(IconHoverFeedback())
    }

    /// 角色的**运行时可变量**版本（如"加自选 / 去掉自选"是同一颗按钮，两种状态下分量不同）。
    /// ⚠ 只在角色确实由运行时决定时用它；写死的调用点直接用 `btnPrimary()` 等。
    @ViewBuilder
    func btn(_ role: BtnRole) -> some View {
        switch role {
        case .primary: btnPrimary()
        case .secondary: btnSecondary()
        case .danger: btnDanger()
        case .dangerFilled: btnDangerFilled()
        }
    }
}

/// 按钮角色（见上方说明）—— 仅用于运行时切换
enum BtnRole { case primary, secondary, danger, dangerFilled }

// MARK: - hover 反馈
//
// 只做「淡底」这一半：原生 List 的选中胶囊与 .borderless 按钮的前景色由系统画，
// 去改亮度容易把明暗档/高对比度弄坏；淡底是纯增量反馈，
// 选中态（系统胶囊）与 hover 态互不干扰。
// 底色一律走 Tok 表面 token（裸 opacity 会撞 `theme_tint` 护栏）；
// 过渡是纯底色淡入淡出 —— opacity 类不走 motionAware（见上方「动效口径」）。

/// 侧栏行 hover：未选中行悬停时整行出现淡底；选中行由系统胶囊承载，不叠加。
/// 主窗口侧栏与设置窗口分类列表共用（动效出口集中在本文件）。
///
/// ## 实机校准定值（别随意改）
/// - **命中区**：内容必须 `.frame(maxWidth:.infinity)` 撑满整行 + `.contentShape(Rectangle())`
///   把命中区定成整行矩形 —— 否则 onHover 只有鼠标压到文字/图标才触发
///   （Text 的命中区是字形，不加 contentShape 等于没修）。
/// - **与系统蓝胶囊严丝合缝**：系统蓝选中胶囊 = 左 inset 10 / 右 inset 10 / 高 32pt（对称缩进）；
///   ⇒ 灰底 `padding(leading:10, trailing:10)` 收到与蓝胶囊同宽同位；**上下不加 padding**
///   —— 行高本就等于胶囊高，加 padding 会把灰底压得比蓝胶囊矮。
///   设置窗口侧栏用同一组定值（macOS 侧栏胶囊缩进是固定 pt、不随列宽缩放），改列宽后要重新核对。
/// - **胶囊高度缩不了**：系统选中胶囊高度 = 行高，而侧栏行高由 AppKit 钉死
///   （负 padding 被 List 忽略）⇒ 唯一能缩的路是弃用系统胶囊、自绘选中底色，
///   但有硬障碍：List 拿到键盘焦点后系统强制选中行白字，自绘底色配白字不可读。
///   ⇒ 保持现状（32pt 胶囊），别再在行高上折腾。
// MARK: - 侧栏标签（MiscKit 风格：clear 玻璃 pill）

/// 两扇窗口共用的侧栏行：18pt 图标列 + 13pt 文字，选中 = 中性灰 pill + 0.5pt 描边。
///
/// ⚠ 不用原生 `List(selection:)`：系统选中胶囊在 macOS 26 上不吃 `.tint`，
///   也做不出 MiscKit 的「不上色玻璃 pill」观感。这里自绘按钮，点击/悬停/选中都在一处。
struct SidebarTab: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(AppFont.glyph(16))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Sem.brand : Tok.label)
                Text(title)
                    .font(AppFont.body)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(Tok.label)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .frame(maxWidth: .infinity)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .background(isSelected ? Tok.pillFill : (hovering ? Tok.chip : Color.clear), in: shape)
        .overlay(shape.strokeBorder(isSelected ? Tok.hairline : Color.clear, lineWidth: 0.5))
        .onHover { hovering = $0 }
        .animation(Mot.hover, value: hovering)
    }
}

/// 图标按钮 hover 淡底（`btnIcon` 内部使用；行内 `rowAction` 这类 `.plain` 图标钮
/// 也复用本修饰器，见 WatchlistView+Groups.swift）。
/// 禁用态不画淡底：`isEnabled` 由调用点环境传入，避免"灰掉的按钮悬停还亮"。
struct IconHoverFeedback: ViewModifier {
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .background(
                hovering && isEnabled ? Tok.chip : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .onHover { hovering = $0 }
            .animation(Mot.hover, value: hovering)
    }
}

// MARK: - 可点击行的按下态
//
// ⚠ 为什么靠**事件监视器**而不是靠手势：取"按下"的常见写法是
//   `onLongPressGesture(minimumDuration: 0, onPressingChanged:)` 或 `DragGesture(minimumDistance: 0)`，
//   两者都是往行的既有 `onTapGesture` 旁边再塞一个识别器、抢同一次点击 —— 抢赢就整行点不动、
//   行内铃铛/持仓标记也抢不到（这三件同时成立才能抢到的口径写在 `WatchlistView` 的行注释里）。
//   而这件事**验不了**：2026-10-28 试过离屏 `NSHostingView` + 合成 mouseDown/mouseUp，
//   不上屏的窗口里 SwiftUI 的手势系统压根不认合成事件 —— 连"什么修饰器都不加"的正对照
//   都是 0 次触发 ⇒ 装置不可信，任何"没抢赢"的读数都不算数。
//   本地监视器只**观察**、把事件原样返回，点击链路一个字节都没动。
// ⚠ 判据只有一条：`hovering && 左键正被按住`。不必量"按下点是否落在本行"——
//   光标在行内才会 hover 为真，而按下必然发生在光标处。省掉每行存一份 frame
//   （那会和滚动、裁剪、玻璃层打架）。

@Observable
@MainActor
final class MousePressCenter {
    static let shared = MousePressCenter()

    /// 左键当前是否被按住（全 App 一份，不按视图分别记账）
    private(set) var isDown = false

    @ObservationIgnored private var token: Any?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?

    private init() {}

    /// 装监视器（幂等 —— 每个可点击行的 `onAppear` 都会调，只装第一下）
    func start() {
        if token == nil {
            token = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
                switch event.type {
                case .leftMouseDown: self.isDown = true
                case .leftMouseUp:   self.isDown = false
                default: break
                }
                return event      // ⚠ 必须原样返回：返回 nil = 把事件吃掉 = 全站点击失效
            }
        }
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isDown = false
                }
            }
        }
    }
}

/// 行按下时的轻淡（`clickableRow()` 内部使用，不单独对外暴露）
private struct RowPressFeedback: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        let pressing = hovering && MousePressCenter.shared.isDown
        content
            .onHover { hovering = $0 }
            .opacity(pressing ? 0.7 : 1)
            .motionAware(Mot.press, value: pressing)
            .onAppear { MousePressCenter.shared.start() }
    }
}

extension View {
    /// `.plain` 图标按钮的 hover 淡底（`btnIcon` 之外的行内图标钮用，如 `rowAction`）
    func iconHoverFeedback() -> some View {
        modifier(IconHoverFeedback())
    }

    /// **可点击行的指针 + 按压反馈**（唯一出口）——悬停切手型光标，按下整行轻淡。
    ///
    /// 淡底只回答"鼠标在哪"，手型光标才回答"这一行能不能点"，按下轻淡才回答"系统收到我这一下了"。
    /// macOS 上自绘行（`contentShape` + `onTapGesture`）没有按钮那层系统光标语义，不挂它就是箭头。
    ///
    /// ⚠ 用 SwiftUI 的 `.pointerStyle(.link)`，**不要**换成 `NSCursor.pointingHand.push()`
    ///   /`pop()`：那一对靠调用点自己配对，而本 App 的行在悬停中就会被销毁（列表刷新、
    ///   切页、hover 淡出），pop 不掉 ⇒ 光标整段时间卡在手型。`.pointerStyle` 随命中区
    ///   生命周期由系统回收。
    /// ⚠ 按下态**不许**改成挂手势（`onLongPressGesture(minimumDuration: 0)` /
    ///   `DragGesture(minimumDistance: 0)`）：那是往行的既有 `onTapGesture` 旁边再塞一个
    ///   识别器，抢同一次点击，抢赢就把整行点不动 / 行内铃铛抢不到点击。见 `MousePressCenter`。
    /// ⚠ 新增可点击行必须挂它 —— 护栏 `row_cursor` 扫"挂了 `.onTapGesture` 却没挂
    ///   `clickableRow()`"的文件，出现即报红。
    func clickableRow() -> some View {
        pointerStyle(.link)
            .modifier(RowPressFeedback())
    }

    /// 后台重跑期间的**「旧数据仍在场」**表现：淡化 + 禁交互，**不清屏**。
    ///
    /// ⚠ 为什么不用整块 `LoadingView` 顶掉内容：重跑期间用户最想看的恰恰是
    ///   "上一轮选出了什么"（对比这一轮的变化），清屏等于在他最需要参照的时刻拿走参照；
    ///   而且长页会被弹回顶部，滚动位置一起丢。进度由页栏的「第N轮扫描中 · mm:ss」
    ///   胶囊承担，不需要靠"整页消失"来表达"在跑"。
    /// ⚠ 无数据的场景**仍然**要走 `LoadingView` / 空态（那时确实没东西可留），
    ///   判据写在调用点：`if let 报告 { …staleWhileBusy } else if busy { LoadingView }`。
    /// ⚠ 自选/持仓页一直是这个口径（只加忙碌徽章、行留着），本修饰器把它收成出口，
    ///   护栏 `row_cursor` 同族纪律：不许再出现第二套"忙碌时怎么表现"。
    @ViewBuilder
    func staleWhileBusy(_ busy: Bool) -> some View {
        self.opacity(busy ? 0.45 : 1)
            .allowsHitTesting(!busy)
            .motionAware(Mot.dim, value: busy)
    }
}

// MARK: - 卡片表面（单套玻璃主题）

/// 卡片视觉层级：hero（首要指标）/ standard（默认）/ subtle（嵌入式提示）
///
/// ⚠ 本枚举**不影响表面材质**（三档同一材质），只影响内边距（20/16/12）与标题字号。
enum CardProminence { case hero, standard, subtle }

struct CardSurface: ViewModifier {
    /// 设置窗口是“整页一张卡”：卡片高度被拉到视口，画描边会得到一个包住大片空白的大框。
    /// 该子树通过环境关闭描边；主窗口的数据卡保持描边。
    @Environment(\.cardSurfaceBordered) private var bordered

    func body(content: Content) -> some View {
        // MiscKit 风格：内容层不再叠第二层玻璃，而是一层极淡中性灰 + 0.5pt 描边。
        // 卡片直接坐在整窗玻璃上，颜色通道只负责"这是一块面"，不再抢玻璃的层次。
        content
            .background(Tok.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if bordered {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Tok.hairline, lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct CardSurfaceBorderedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 卡片是否绘制 hairline（设置窗口整页卡可关闭）
    var cardSurfaceBordered: Bool {
        get { self[CardSurfaceBorderedKey.self] }
        set { self[CardSurfaceBorderedKey.self] = newValue }
    }
}

extension View {
    func cardSurface() -> some View {
        modifier(CardSurface())
    }
}

// MARK: - 通用卡片

struct Card<Content: View>: View {
    var prominence: CardProminence = .standard
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, subtitle: String? = nil,
         prominence: CardProminence = .standard,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.prominence = prominence
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                // MiscKit 风格：卡片标题不再压在卡片里，而是作为分组标题坐在卡面上方。
                // 一处改、所有页面统一 —— 视图里不要再各写一套 section header。
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppFont.detail.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let subtitle {
                        Text(subtitle)
                            .font(AppFont.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 2)
            }
            content
                .padding(paddingFor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var paddingFor: CGFloat {
        switch prominence {
        case .hero: return 18
        case .standard: return 14
        case .subtle: return 12
        }
    }
}

// MARK: - 灯级徽章

struct LightBadge: View {
    /// 已识别的灯级；`nil` = 缺失 / 未识别 → 显示"未知"、配色灰
    ///
    /// ⚠ 「非空但认不出」的值归一到"未知"：值域只有三个（+空），
    ///   认不出的值不该被当成有效灯级展示。
    let level: MarketLightLevel?

    // ⚠ 文案走 `Sem.lightText`（唯一来源在 `Tokens.swift`），视图里不就地写灯级文案
    private var text: String { Sem.lightText(level) }

    private var color: Color { Sem.light(level) }

    var body: some View {
        Label(text, systemImage: "circle.fill")
            .font(.callout.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Tok.tint(color), in: Capsule())
    }
}

// MARK: - 信号标签

struct SignalTag: View {
    /// 已识别的信号类型；`nil` = 缺失 / 空串 / 未识别 → 文案空串、配色次级
    let type: SignalType?

    /// 统一的信号文案（其他视图不要再自己写二分判断，避免"非脉冲即持续"的反向假设）
    ///
    /// ⚠ 「非空但认不出」的值与空串一并归为 nil → 返回空串：
    ///   值域只有四个（+缺失），认不出的值本就不该被当成有效信号展示。
    static func label(for type: SignalType?) -> String {
        switch type {
        case .strongest: return "最强信号"
        case .consensus: return "持续信号"
        case .pulse: return "脉冲信号"
        // 轮次不足（某轮缺失）→ 无法验证持续性，绝不能与"持续"混同
        case .unverified: return "未验证"
        case nil: return ""
        }
    }

    private var text: String { Self.label(for: type) }

    private var color: Color {
        type == .unverified ? .secondary : Sem.signal(type)
    }

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Tok.tint(color), in: Capsule())
    }
}

// MARK: - A股涨跌色

extension Color {
    static func pnl(_ v: Double?) -> Color { Sem.pnl(v) }
}

struct PnlText: View {
    let value: Double?
    var suffix: String = "%"

    /// ⚠ 可见文本**必须**带正负号（`%+.2f`）—— 这是"涨跌不只靠颜色"的唯一保障，
    ///   色觉障碍用户靠符号即可分辨。别为了排版好看把 `+` 去掉。
    var body: some View {
        // 极小负值归零：-0.001% 显示成 "-0.00%" 会让人以为在亏
        // ⚠ 「无数据」占位符统一成全角 `—`（2026-10-16 审查 B6）：原先这里是 ASCII `-`，
        //   而各表格列（`WatchColumns` / `StockDetailSheet+Strategy` 等）用的是 `—`。
        //   本组件又是恒带 `%+` 的涨跌渲染器，于是同一列里「`-`」(无数据) 与
        //   「`-1.23%`」(下跌) 并排 —— 快速扫读时"一个减号"极易被看成被截断的跌幅。
        Text(value.map { v in
            (abs(v) < 0.005 ? String(format: "%.2f", 0.0) : String(format: "%+.2f", v)) + suffix
        } ?? "—")

            .foregroundStyle(Color.pnl(value))
            .monospacedDigit()
            // 涨跌数字变化时按位数滚动（数值→方向的 .numericText 变体；
            // animation 必须挂在本视图上，否则外层没人驱动、过渡不生效）
            .contentTransition(.numericText(value: value ?? 0))
            .motionAware(Mot.value, value: value)
    }
}

// MARK: - 会滚动的统计数字（值变化时按位数滚动）

/// 统计数字：值变化时以系统 `numericText` 过渡滚动（约 220ms，方向随增减）。
/// 只用于**数字本身在变**的统计位（候选数/档位数/胜率/盈亏），不做装饰性动效；
/// 列表内容、文案一律不套 —— 动效克制是本项目的既定口径。
struct RollingNumber: View {
    private let value: Double
    private let text: String
    private var font: Font
    private var color: Color

    /// 整数计数（候选数 / 档位数 / 分组条数）
    init(_ value: Int, font: Font = .callout, color: Color = .primary) {
        self.value = Double(value)
        self.text = "\(value)"
        self.font = font
        self.color = color
    }

    /// 百分比 / 金额等（自带格式，如 "%.1f%%"、" %+.0f"）
    init(_ value: Double, format: String, font: Font = .callout, color: Color = .primary) {
        self.value = value
        self.text = String(format: format, value)
        self.font = font
        self.color = color
    }

    /// **预渲染文本**（金额这类无法用 printf 表达的格式，如 `StockFmt.money` 会去掉尾随零）
    ///
    /// ⚠ `value` 只用来驱动数字滚动动画，**显示的是 `text`** —— 两者必须同源
    ///   （都由同一个数值算出），否则会滚出与文本不符的位数。
    init(_ value: Double, text: String, font: Font = .callout, color: Color = .primary) {
        self.value = value
        self.text = text
        self.font = font
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(font)
            .monospacedDigit()
            .foregroundStyle(color)
            .contentTransition(.numericText(value: value))
            .motionAware(Mot.value, value: value)
    }
}

// MARK: - 极小的说明图标（点击弹 popover / 悬浮出 tooltip）

/// 把「很长、但只需要看一次」的口径说明收进一个 ~11pt 的灰色问号里。
/// 默认只占 ~11pt，**悬浮**看 tooltip、**点击**弹 popover 读全文/复制。
///
/// ⚠ **两个入口都要有**：悬浮给"顺手瞄一眼"（系统 tooltip）；
///   点击给"要读完 / 要选中复制"（popover 里开了 `textSelection`）。
/// ⚠ 图标必须是**灰的**（`Tok.dim`）且**很小**：它是附属信息，
///   不能跟同一行里的主操作（刷新按钮）抢注意力。
/// ⚠ 用 `questionmark.circle` 而不是 `info.circle`：前者在 macOS 里更常用于"这条是什么"。
/// ⚠ 文案里**不要写 `**`**：这是给用户看的普通字符串，不是 Markdown（护栏 `md_literal` 盯这一类）。
struct InfoTip: View {
    let text: String
    var title: String = ""
    /// popover 宽度（默认 360，够放 3~5 行中文；内容更长的用 420）
    var width: CGFloat = 360

    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(AppFont.detail)
                .foregroundStyle(Tok.dim)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)                       // 悬浮
        .popover(isPresented: $show, arrowEdge: .bottom) {   // 点击
            VStack(alignment: .leading, spacing: 6) {
                if !title.isEmpty { Text(title).font(.callout.bold()) }
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: width, alignment: .leading)
            .textSelection(.enabled)
        }
    }
}

// MARK: - 口径行（收起态：只留一个小问号）

/// **口径说明的收起态**（2026-10-19 老板要求：口径收进小符号，点击浮窗才出现）。
///
/// ## 为什么要有这个组件（而不是每处自己写 `InfoTip`）
/// 口径文案在详情页有 **11 处**（形态 / 技术指标 / 早盘抢筹 / 涨停池 / 回撤风险 /
/// 策略 / 尾盘结构 / 振荡 / 基本面 / 资金流 / 龙虎榜），散在 4 个文件里。
/// 之前它们是**整段常显文字**（每处 3~6 行）⇒ 详情页要往下滚很久才能看完一张卡，
/// 而这些文字**看一眼就够、偶尔才要细读**。
/// ⇒ 统一收成「一行小问号」，点开是 `InfoTip` 的 popover（可选中复制）。
///
/// ## 为什么挂在**内容末尾**而不是卡片标题旁
/// `Card` 的标题区只接受 `String`（`title` / `subtitle`）⇒ 要在标题旁加符号
/// 得改 `Card` 的公开接口，**那会影响全 App 每一张卡片**（看板 / 自选 / 设置…）。
/// ⇒ 折中：放在卡片**内容的最后一行**，位置固定、视觉统一，
///   且改动只落在详情页这 11 个调用点。
///
/// ## 显示什么
/// 只显示「口径」两个字 + 一个灰问号 —— **不显示任何数值**。
/// 数值全在浮窗里。这样收起态不会泄露"阈值是多少"（那些是要点开才读的细节），
/// 也不会让收起态变成一行噪声。
struct CaliberTip: View {
    /// 浮窗里的完整口径正文。
    let text: String
    /// 浮窗标题（通常是卡片名，如「K 线形态口径」）。
    var title: String = "口径"
    /// popover 宽度（默认 420 —— 口径普遍 4~6 行，360 会太窄）。
    var width: CGFloat = 420

    var body: some View {
        HStack(spacing: 3) {
            Text("口径")
                .font(AppFont.detailSmall)
                .foregroundStyle(Tok.dim)
            InfoTip(text: text, title: title, width: width)
        }
        // ⚠ `.help` 挂在整行上：鼠标停在「口径」两个字上也能出提示，
        //   不必精确指到那个 ~11pt 的问号（小图标很难点中）。
        .help(text)
    }
}

// MARK: - 分数徽章

/// 得分徽章 —— **唯一口径**（看板 / 选股结果 / 自选 / 个股详情共用本组件渲染）。
///
/// ⚠ 颜色口径在 `Sem.scoreColor`：低分段用 `down`（A股语义 = 回避），不用灰色。
struct ScoreBadge: View {
    let score: Int
    /// 生效参数的档位门槛（一档 / 二档）。
    ///
    /// ⚠ **由调用方从 `Store.shared.tier1Min/tier2Min`（缓存值）传入** ——
    ///   门槛随参数版本变化，写死会把二档票误画成"达标"红胶囊。
    /// ⚠ `nil` = 读不到参数 → **不表态**（不画达标胶囊、落中性灰），
    ///   而不是拿一个写死的数冒充生效门槛。
    /// ⚠ 可选参数有隐式 `nil` 缺省，漏传的后果是"不表态" —— 失效方向朝保守。
    var tier1: Int?
    var tier2: Int?
    /// **落库档位**（1/2/3）。给了它，颜色与"达标"就按当时分组算，不再拿当前门槛重算 ——
    /// 选股结果页必须传（那里的分组本来就是落库 tier，见 M6）。
    /// `nil` = 这个分数不属于任何已落库的分组（个股详情 / 自选行内），才走当前门槛。
    var storedTier: Int?
    /// 该分数是否**被规则压制过**（如均线未多头 → 归入三档）。
    /// 为 true 时用警示色，避免把"被纪律否决的高分票"显示成"达标可买"的样子。
    var suppressed: Bool = false
    /// 胶囊底 —— 列表行内用（与相邻列拉开层次）；看板 / 详情页用纯文字，避免抢视觉。
    /// ⚠ 只在**达标**（`score >= tier1`）时才真的画胶囊：否则一屏三档票全是色块，
    ///   胶囊就不再表示"达标"这件事了。
    var pill: Bool = false
    /// 0 分时显示 "—"（自选行内占位）；false 时由调用方决定要不要渲染
    var zeroPlaceholder: Bool = false

    /// 是否达标。⚠ 有落库档位时**以档位为准**（分组与颜色同源）；
    /// 否则按当前门槛；门槛未知 → **一律不达标**（宁可不表态，也不拿写死的数冒充门槛）
    private var isQualified: Bool {
        if let t = storedTier { return t == 1 }
        guard let t1 = tier1 else { return false }
        return score >= t1
    }

    private var color: Color {
        if suppressed { return Sem.warn }
        if let t = storedTier { return Sem.scoreColor(tier: t) }
        guard let t1 = tier1, let t2 = tier2 else { return .secondary }
        return Sem.scoreColor(score, tier1: t1, tier2: t2)
    }

    var body: some View {
        if score <= 0, zeroPlaceholder {
            Text("—").font(.callout).foregroundStyle(Tok.dim)
        } else if pill {
            if isQualified {
                RollingNumber(score, font: .callout.bold(), color: color)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Tok.tint(color)))
            } else {
                // 非达标项用常规字重（胶囊里加粗、胶囊外常规，
                // 让"有没有胶囊"这一件事同时承载字重差异，不必再叠一层颜色）
                RollingNumber(score, font: .callout, color: color)
            }
        } else {
            // ⚠ `Text + Text` 在 macOS 26 已废弃，且这两段样式**不同**（分数是 callout 粗圆体、
            //   后缀是 caption2），**不能**换字符串插值 ⇒ 用 `HStack` + `.firstTextBaseline`。
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(score)")
                    .font(.system(.callout, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                Text(suppressed ? " 分·未多头" : " 分")
                    .font(.caption2).foregroundStyle(suppressed ? Sem.warn : .secondary)
            }
            // ⚠ 单行钉死：锁档后缀「分·未多头」是 5 个字，列宽一不够就在 32pt 的行高里
            //   折成两行、断在「未/多头」中间（2026-11-04 深选 v2.0 后三档几乎行行带它，
            //   整页都是半截词）。装不下时宁可截断，也不许把行撑高弄歪整张表。
            .lineLimit(1)
        }
    }
}

// MARK: - 涨跌平比例条（看板 / 选股结果共用）

/// 涨跌家数比例条：**红涨 / 灰平 / 绿跌**（A 股口径），一眼看出多空力量对比。
///
/// ⚠ 单一实现（2026-10-19 从看板 hero 里抽出来）：看板与选股结果的涨跌比**必须同一种画法**，
///   两处各写一份必然漂（宽度系数、平盘是否显示、颜色取哪个 token 都会慢慢分叉）。
/// ⚠ 调用方负责判断"有没有数据"：全 0 时本组件会画成一条纯绿（跌），那是误导 ——
///   看板用 `u + d > 0` 门控，选股结果同款。
/// ⚠ 平盘为 0 时不画灰段（省掉一条 0 宽的 Rectangle，避免 HStack 里出现 0 宽元素的取整缝）。
/// ⚠ **段间留 2pt 缝 + 走图形档明度分梯**（2026-10-22 P5 / D2-2）：这条条只有两三种颜色相邻，
///   而实测涨/跌 **text 档明度几乎齐平**（ΔL 0.001–0.033，这是刻意的 —— 数字列不能
///   因颜色跳行），代价是二色觉下两支红绿糊成同一种橄榄色（deutan ΔE 仅 **0.030–0.082**，
///   本仓自己的判据是 <0.10 = 不可分）。⇒ 两条通道一起补：
///   ① **结构**：缝（任何色觉下都在）+ 位置（读序与旁边"涨跌比 906:0:4157"一致）+ 宽度；
///   ② **明度**：改走 `Sem.upGraph` / `Sem.downGraph` 图形档（同色相同彩度、只挪 L，
///      deutan ΔE 拉到 ≥0.115），判据由护栏 `bar_separation` 逐档实算钉死。
struct BreadthBar: View {
    let up: Int
    let flat: Int
    let down: Int
    /// 4pt 在 8pt 高的旁边细得像根线，且色觉障碍下更读不出分段（P5 实测）
    var height: CGFloat = 8

    var body: some View {
        // 分母保底 1：调用方理论上已经门控过，这里再兜一次（0/0 会算出 NaN 宽度）
        let total = max(up + flat + down, 1)
        GeometryReader { geo in
            HStack(spacing: 2) {
                // ⚠ 计数为 0 的段**不画**（不是画一条 0 宽的）：0 宽段会在 `spacing: 2`
                //   下凭空多出一道缝，把"涨/跌两段"看成"三段"。
                if up > 0 {
                    segment(geo.size.width * CGFloat(up) / CGFloat(total), Sem.upGraph)
                }
                if flat > 0 {
                    segment(geo.size.width * CGFloat(flat) / CGFloat(total), Tok.stroke)
                }
                if down > 0 {
                    segment(geo.size.width * CGFloat(down) / CGFloat(total), Sem.downGraph)
                }
            }
        }
        .frame(height: height)
        .help("上涨 \(up) 只 · 平盘 \(flat) 只 · 下跌 \(down) 只")
    }

    /// 一段 = 一枚胶囊（整条再套 `clipShape(Capsule())` 会让缝变成直角断口，读不出"两段"）
    private func segment(_ w: CGFloat, _ color: Color) -> some View {
        Capsule().fill(color).frame(width: max(w - 2, 2))
    }
}

// MARK: - 长页滚动进度（顶栏时间戳滚动退让；只上报，不画进度线）

/// 滚动进度（0=顶部 1=到底）：由各页主 ScrollView 经 `.reportsScrollProgress()` 上报，
/// 操作栏只做展示 —— 不在这里算，避免每个页面各写一套滚动监听。
@Observable @MainActor
final class ScrollProgress {
    static let shared = ScrollProgress()

    private(set) var value: Double = 0

    func update(_ v: Double) {
        let clamped = min(max(v, 0), 1)
        if abs(clamped - value) > 0.001 { value = clamped }
    }

    /// 离开页面时归零：否则残留上一页的进度线
    func reset() { value = 0 }
}

// MARK: - 固定两列骨架（主窗口 / 设置窗口的分栏壳，替代 NavigationSplitView）

/// 左定宽侧栏 + 右自适应内容的**纯 SwiftUI 骨架**。
///
/// ## 为什么不用 `NavigationSplitView`
/// 原生分栏的宿主是 `NSSplitView`，带来一整族摘不干净的问题（2026-10-15 三轮补丁全失败，
/// 台账 `docs/specs/README.md`「主窗口侧栏开关删除」）：
///   ① 分隔条永远注册 resizeLeftRight 光标矩形（列宽钉死也照注册，纯误导）；
///   ② 摘光标的三条 AppKit 路全堵死：`removeTrackingArea` 是 no-op（光标矩形不走
///      tracking area）；换 `NSSplitView.delegate` **同步卡死主线程**（`setDelegate`
///      内部重入，插桩实测 1962 层递归 0 返回）；往分栏塞挡板子视图会**打乱
///      SwiftUI 的分栏管理**（真机回归：侧栏被收起且无按钮可恢复）；
///   ③ 开合按钮/⌃⌘S 收起路径（已整族删除，但系统随时可能再给一条）。
/// 本骨架**结构性不存在**这三条：没有 `NSSplitView` ⇒ 没有分隔条、没有光标、
/// 没有拖拽、没有收起路径，也不需要任何 AppKit 探针去"摘"。
///
/// ## 材质与顶距
/// 玻璃层 `ignoresSafeArea()` 铺到窗口顶（空工具栏带把红绿灯摆在材质上，(18,18) 由
/// `MainWindowToolbarBandInstaller`/`WindowTitleHider` 负责）；两列内容仍留在 safe area 内
/// （详情列靠负 padding 上提回收带区）。
/// ⚠ 侧栏 `SidebarTab` 的首行内边距 10 是"safe area（标题栏带）之下"的值，
///   绝对位置落在 40；改骨架/标题栏几何必须重新截图像素校准。
struct FixedTwoColumnShell<Side: View, Detail: View>: View {
    /// 侧栏**定宽**（不可拖、不可收 —— 这是整个骨架的存在理由）
    let sidebarWidth: CGFloat
    @ViewBuilder var side: () -> Side
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        // 整窗**只有一种底**：MiscKit 同款的「半透明白底衬 + 原生 glass」两层，
        // 内容直接坐在它上面。窗口本身设为透明（`WindowTransparencyProbe`），桌面才能透进来。
        // ⚠ 不再用 NSVisualEffectView 叠 .behindWindow：MiscKit 的观感来自 SwiftUI glass，
        //   透明窗口 + 半透明底衬已经能给出同样的“透 + 白”。
        ZStack {
            HStack(spacing: 0) {
                side()
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity)
                detail()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(WindowGlass().ignoresSafeArea())
        }
    }
}

/// 整窗玻璃（MiscKit 同款）：半透明中性底衬 + 原生 `.glassEffect`。
/// 底衬控制“透多少 / 白不白”，玻璃本身不上色。
struct WindowGlass: View {
    var body: some View {
        ZStack {
            Tok.windowBacking
            Color.clear.glassEffect(.regular, in: Rectangle())
        }
        .background(WindowTransparencyProbe())
    }
}

/// 让承载窗口真正透明：SwiftUI 的 `WindowGroup` / `Settings` 默认仍是不透明底。
private struct WindowTransparencyProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ProbeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
        }
    }
}

/// 窗口拖动区：把一块 SwiftUI 区域变成"标题栏"——按住空白处拖整个窗口。
///
/// ## 为什么需要它（2026-10-19 老板实测：「内容栏上边不能拖动窗口」）
/// 主窗口的标题栏是一条**空工具栏带**（`.unifiedCompact`，高 ~30），带区里没有可拖的 AppKit 视图：
/// 详情列被 `-37` 负 padding 提上来，带区里铺的是 SwiftUI 画的 `PageActionBar` ——
/// 那是 `NSHostingView` 的**绘制内容**，不是 NSView ⇒ 按住拖，窗口纹丝不动（死区）。
/// 侧栏那半边能拖，是因为窗口标题栏带仍由 AppKit 承载；详情列的空白处由 `WindowDragStrip` 接管。
///
/// ## ⚠⚠ 试过但**不管用**的三条路（别再走一遍）
/// 命中链探针（`NSThemeFrame.hitTest` + `mouseDownCanMoveWindow`）已证实的结论：
///   ① 挂一个 `NSView` 并 `mouseDownCanMoveWindow = true` ⇒ 命中确实是它、属性确实为 true，
///      **窗口仍不动**（`mouseDown` 被正常调用，只是 AppKit 不接管拖动）；
///   ② 换 `NSVisualEffectView`（想复刻侧栏那种"系统认"的视图）⇒ 一样不动；
///   ③ 在 `mouseDown` 里显式 `window.performDrag(with:)`（`performWindowDragWithEvent:` 的
///      Swift 名）⇒ 返回了，窗口也不动。
///   ⇒ 判断：**`NSHostingView` 里的"真 NSView"拿不到 AppKit/Window Server 的窗口拖动**，
///     与 `mouseDownCanMoveWindow` 的取值无关。**别再用这三条去试**。
///
/// ## 现在的做法：自己接管拖动
/// `mouseDown` 记下屏幕坐标与窗口原点，`mouseDragged` 按**位移差** `setFrameOrigin`
/// （用 `NSEvent.mouseLocation` 而不是 `event.locationInWindow`：后者随窗口移动而变，
/// 拿它算差会自激）。`mouseDownCanMoveWindow` 显式 `false`，确保只走这一条路。
/// 代价（已知、可接受）：不走 Window Server ⇒ 没有"拖到另一个 Space"的系统集成，
/// 双击这条带也不会缩放窗口。它只是页栏，不是真标题栏。
///
/// ## 用法与命中顺序（⚠ 挂错就吃掉按钮点击）
/// 必须挂在 `.background`，且**在材质底之前**：
/// ```swift
/// VStack { … }.padding(…)
///     .background(WindowDragStrip())      // 先挂 = 在材质之上、内容之下
///     .background(.regularMaterial)
/// ```
/// ⇒ 按钮/文字在上层先拿到点击；只有**空白处**落到本视图 → 拖窗口。
/// ⚠ 别改成 `.overlay` / 把 `zIndex` 挪到它前面：那会把页栏按钮的点击一起吃掉。
struct WindowDragStrip: NSViewRepresentable {
    final class Strip: NSView {
        /// ⚠ 显式 `false`：让 AppKit **不要**尝试它自己的窗口拖动路径（那条路在
        /// `NSHostingView` 里不生效，见类型注释 ①），全部交给下面手写的三件套。
        override var mouseDownCanMoveWindow: Bool { false }

        private var startMouse: NSPoint = .zero
        private var startOrigin: NSPoint = .zero
        private var dragging = false

        override func mouseDown(with event: NSEvent) {
            guard let w = window else { return }
            startMouse = NSEvent.mouseLocation      // 屏幕坐标（原点左下，不随窗口移动而变）
            startOrigin = w.frame.origin
            dragging = true
        }

        override func mouseDragged(with event: NSEvent) {
            guard dragging, let w = window else { return }
            let now = NSEvent.mouseLocation
            w.setFrameOrigin(NSPoint(x: startOrigin.x + now.x - startMouse.x,
                                     y: startOrigin.y + now.y - startMouse.y))
        }

        override func mouseUp(with event: NSEvent) {
            dragging = false
        }
    }

    func makeNSView(context: Context) -> Strip { Strip() }
    func updateNSView(_ nsView: Strip, context: Context) {}
}

