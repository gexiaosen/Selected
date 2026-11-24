import SwiftUI
import AppKit
import SelectedCore

// MARK: - 设计 token（全 App 唯一写死颜色值的地方）
//
// 业务侧一律走语义入口：
//   Sem —— 业务含义（涨跌/灯级/信号/风险/状态/品牌）
//   Tok —— 表面与线条（行底/嵌底/胶囊/细线/描边/占位/阴影）
// 视图里不要就地写死表面色（如 Color.secondary.opacity(...)）：
// 浅色下尚可，暗色下会与卡片层级糊成一片。
//
// 明暗两套色值都由 NSColor 动态色承载（本项目无 .xcassets），
// 随系统外观或设置页「外观」开关**实时**切换，无需重启。

extension Color {
    /// 明暗双色值 → 外观自适应色
    ///
    /// - Parameters:
    ///   - highContrastLight / highContrastDark: 「提高对比度」外观（Increase Contrast）下的
    ///     变体；不传则回退基础档。
    ///
    /// ⚠ 高对比度外观显式分支，不并入基础明暗档。
    ///   表面色（`Tok.*`）、语义色（`Sem.*`）、图表均线及 `Tok.tint` 均已提供 HC 变体。
    static func adaptive(light: Color, dark: Color,
                         highContrastLight: Color? = nil,
                         highContrastDark: Color? = nil) -> Color {
        // 闭包外先转 NSColor：闭包内只做外观判断，避免每次解析都做一次转换
        let lightNS = NSColor(light), darkNS = NSColor(dark)
        let hcLightNS = highContrastLight.map(NSColor.init) ?? lightNS
        let hcDarkNS = highContrastDark.map(NSColor.init) ?? darkNS
        return Color(nsColor: NSColor(name: nil) { appearance in
            // 高对比度外观优先判定，不并入基础明暗档
            let hc = appearance.bestMatch(from: [.accessibilityHighContrastAqua,
                                                 .accessibilityHighContrastDarkAqua])
            if hc == .accessibilityHighContrastAqua { return hcLightNS }
            if hc == .accessibilityHighContrastDarkAqua { return hcDarkNS }
            return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkNS : lightNS
        })
    }
}

/// 16 进制取色 + 叠加型表面色（仅本文件内部使用，外部请走 Sem/Tok）
private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255.0,
                  green: Double((hex >> 8) & 0xff) / 255.0,
                  blue: Double(hex & 0xff) / 255.0)
    }

    /// 叠加型表面色：浅色下叠黑、深色下叠白（同一 alpha 语义在两个外观下都成立）
    ///
    /// - Parameters:
    ///   - highContrastLight / highContrastDark: 「提高对比度」外观下的叠加强度（更强 → 层级更分明）；
    ///     不传则回退基础档。
    static func surface(light: Double, dark: Double,
                        highContrastLight: Double? = nil,
                        highContrastDark: Double? = nil) -> Color {
        .adaptive(light: Color.black.opacity(light),
                  dark: Color.white.opacity(dark),
                  highContrastLight: Color.black.opacity(highContrastLight ?? light),
                  highContrastDark: Color.white.opacity(highContrastDark ?? dark))
    }
}

// MARK: - 色值 → 明暗自适应色
//
// 单套配色后不再需要"档位缓存"：下面这些 token 只建一次（`static let`），
// 取值是一次字段读取，与改造前的 `static let` 同价。

private extension Quad {
    /// 四档（浅 / 深 / 高对比度浅 / 高对比度深）→ 动态色
    var color: Color {
        .adaptive(light: Color(hex: light), dark: Color(hex: dark),
                  highContrastLight: Color(hex: hcLight),
                  highContrastDark: Color(hex: hcDark))
    }

    /// 承白字的填充位（无 fill 值时退回 text 位；深色 HC 用更深 fill 保障白字对比度）
    var fillColor: Color {
        .adaptive(light: Color(hex: fillLight ?? light),
                  dark: Color(hex: fillDark ?? dark),
                  highContrastLight: Color(hex: hcFillLight ?? fillLight ?? hcLight),
                  highContrastDark: Color(hex: hcFillDark ?? fillDark ?? hcDark))
    }
}

/// 两档色值（比例条图形档只给浅/深）→ 动态色
private func dualColor(light: UInt32, dark: UInt32) -> Color {
    .adaptive(light: Color(hex: light), dark: Color(hex: dark))
}


// MARK: - 业务语义色板
// 规则：同一种业务含义只允许使用同一个语义入口，禁止视图内散写系统色
//（如：涨跌一律走 Sem.pnl，灯级一律走 Sem.light，信号一律走 Sem.signal……）。
//
// ⚠ **色值不在本文件** —— 本文件只定义「语义入口 → 哪支色」这一层映射；
//   具体 hex 全在 `Palette.swift` 的单套色值表里。
//
// 8 个语义入口都带「提高对比度」变体 —— 涨跌红绿、警示橙、信号蓝是本 app 的主要信息通道，
// HC 开启时必须增强。判据固化在护栏 `sem_contrast`（按 WCAG 相对亮度公式实算，
// 背景实读卡片底，不写死常量）。
//
// ⚠ 改色相等于改语义（警示橙偏红就成了「危险」）；只许同色相拉开一档明度。

enum Sem {
    // MARK: 基础色（取自 `Palette.swift` 的单套色值）

    /// A股上涨 / 危险操作 / 红灯（同一红色系）
    static let up = ThemeColors.base(.up).color
    /// A股下跌 / 完成 / 绿灯（同一绿色系）
    static let down = ThemeColors.base(.down).color
    /// 警示 / 黄灯 / 中风险 / 脉冲（同一橙色系）
    static let warn = ThemeColors.base(.warn).color
    /// 执行中 / 持续信号 / 信息（同一蓝色系）
    static let info = ThemeColors.base(.info).color
    /// 最强信号 / 极高风险（同一紫色系）
    static let accent = ThemeColors.base(.accent).color
    /// 品牌主色（主操作按钮）
    static let brand = ThemeColors.base(.brand).color
    /// 选中高亮（列表/日期选中底色，与品牌色一致但语义独立）
    static let selection = ThemeColors.base(.selection).color
    /// 尾盘强化（末轮新增信号，区别于持续蓝与脉冲橙的青绿色系）
    static let tailEnhance = ThemeColors.base(.tailEnhance).color

    /// **填充位**：只给"系统自己配白字"的控件（`btnPrimary` / `btnDangerFilled`）用。
    /// 与同名 text 位分开的原因见 `Quad.fillDark` 的注释 —— 一支色同时满足
    /// "深底上文字 ≥4.5" 与 "白字压在它上面 ≥4.5" 在物理上不可能。
    /// ⚠ 反方向也成立：**文字/图标位置一律用 `Sem.up` / `Sem.brand`，不要用这两个 Fill。**
    static let upFill = ThemeColors.base(.up).fillColor
    static let brandFill = ThemeColors.base(.brand).fillColor

    /// **图形档**：给"两色相邻、要靠颜色分辨谁是谁"的**色块**用
    /// （消费者：BreadthBar、对比页迷你涨跌条/区间条、参数中心 delta 条）。
    /// 与 text 位的差别是**明度分梯**（同色相同彩度，只挪 OKLab L）——
    /// text 档两支明度齐平，二色觉下 ΔE 只有 0.030–0.082（不可分）；图形档拉到 ≥0.115。
    /// ⚠ 别把它们用到文字或图标上 —— 那是 `Sem.up` / `Sem.down` 的活。
    /// 判据固化在护栏 `bar_separation`（逐档实算 deutan ΔE + 对卡片底 ≥3:1）。
    static let upGraph = dualColor(light: ThemeColors.bar(.up).light,
                                   dark: ThemeColors.bar(.up).dark)
    static let downGraph = dualColor(light: ThemeColors.bar(.down).light,
                                     dark: ThemeColors.bar(.down).dark)

    /// **系列档**：多序列图表的线条/色块用（消费者：复盘页四层胜率走势）。
    /// 四支当一个集合解出明度阶梯（6 对 deutan ΔE 全 ≥0.115）；
    /// 与 `*Graph` 分开 —— 比例条那对已定稿，不为四序列重解。
    /// ⚠ 线尾标签是文字，仍走 text 档（本档只保图形 3:1，不保文字 4.5:1）。
    static let upSeries = dualColor(light: ThemeColors.series(.up).light,
                                    dark: ThemeColors.series(.up).dark)
    static let downSeries = dualColor(light: ThemeColors.series(.down).light,
                                      dark: ThemeColors.series(.down).dark)
    static let warnSeries = dualColor(light: ThemeColors.series(.warn).light,
                                      dark: ThemeColors.series(.warn).dark)
    static let accentSeries = dualColor(light: ThemeColors.series(.accent).light,
                                        dark: ThemeColors.series(.accent).dark)

    // MARK: 语义入口

    /// A股涨跌：红涨绿跌（唯一涨跌语义入口）
    static func pnl(_ v: Double?) -> Color {
        guard let v else { return .secondary }
        if v > 0 { return up }
        if v < 0 { return down }
        return .secondary
    }

    /// 得分徽章配色 —— **唯一口径**（选股结果 / 自选 / 个股详情共用）。
    ///
    /// ⚠ 门槛**没有缺省值**：编译器强制每个调用点显式传
    ///   `Store.shared.tier1Min/tier2Min`，防止某处悄悄用别的门槛判定。
    static func scoreColor(_ score: Int, tier1: Int, tier2: Int) -> Color {
        if score >= tier1 { return up }      // 入档（A股：红=可买）
        if score >= tier2 { return warn }    // 观察
        return down                          // 回避
    }

    /// 按**落库档位**取色（M6 的正解，老板 2026-10-22 拍板）。
    ///
    /// 与上面那个重载的区别：上面按"当前生效门槛"重算，下面按"这批票当时被分到哪一档"。
    /// 选股结果页的**分组**读的是落库 tier，若颜色仍按当前门槛算，就会出现
    /// 「二档候选卡里 58/53 分被画成回避绿」—— 同一行里"它属于二档"和"按今天的尺子它不够"打架。
    /// ⇒ 卡内颜色与分组同源（都是落库那一刻的口径）；要看新参数的判法请去参数中心重跑。
    /// tier 取值与 `ScanResult.tier1/tier2/tier3` 三个数组一一对应（1/2/3）。
    static func scoreColor(tier: Int) -> Color {
        switch tier {
        case 1: return up        // 一档 = 当时已达标可买
        case 2: return warn      // 二档 = 当时在观察线之上、未入档
        default: return down     // 三档（含未识别）= 当时分数不足
        }
    }

    /// 目标价语义色（上看空间 → 红）。与个股详情页保持一致。
    static let targetPrice = up
    /// 止损价语义色（下方防线 → 绿）。与个股详情页保持一致。
    static let stopLossPrice = down

    /// 灯级（唯一入口）——入参是 Core 的枚举，`nil` = 缺失/未识别 → 灰。
    /// 收枚举的理由见 `MarketLightLevel`：文案不再以字符串形式散落在视图里比较
    static func light(_ level: MarketLightLevel?) -> Color {
        switch level {
        case .green: return down
        case .yellow: return warn
        case .red: return up
        case nil: return .gray
        }
    }

    /// 灯级**文案的唯一来源**。
    ///
    /// ⚠ **盘中实时灯故意不在这里**：`DashboardView.realtimeLightText` 要标注"盘中上涨"
    ///   以与引擎正式灯区分 —— 那是**产品语义**，别顺手合并。
    static func lightText(_ level: MarketLightLevel?) -> String {
        switch level {
        case .green: return "绿灯 · 可操作"
        case .yellow: return "黄灯 · 降仓≤40%"
        case .red: return "红灯 · 空仓观望"
        case nil: return "未知"
        }
    }

    /// 判定动作 → 颜色。**唯一来源**。
    ///
    /// ⚠ 语义色不靠透明度表达强弱（明暗两档下观感不一致）。
    static func actionColor(_ action: String?) -> Color {
        switch action {
        case "买入", "止盈卖出", "空仓观望": return up
        case "持有": return info
        case "止损卖出", "清仓卖出", "观察": return warn
        case "回避": return down
        default: return .secondary
        }
    }

    /// 信号类型（唯一入口）——入参是 Core 的枚举；
    /// `unverified` 与 `nil`（缺失/空串/未识别）都落灰（≡ 原先的 `default`）
    static func signal(_ type: SignalType?) -> Color {
        switch type {
        case .strongest: return accent
        case .consensus: return info
        case .pulse: return warn
        case .unverified: return .gray
        case nil: return .gray
        }
    }

    /// 风险级别（唯一入口）——入参是 Core 的枚举，`nil` = 缺失/未识别 → 次级色
    static func risk(_ level: RiskLevel?) -> Color {
        switch level {
        case .low: return down
        case .medium: return warn
        case .high: return up
        case .extreme: return accent
        case nil: return .secondary
        }
    }

    /// 回测变化（good→绿 / bad→红 / 无变化→次级）
    static func change(_ c: String) -> Color {
        switch c {
        case "good": return down
        case "bad": return up
        default: return .secondary
        }
    }
}

// MARK: - 表面 / 线条 / 阴影 token

enum Tok {
    /// 窗口玻璃底衬的**基色**：导航层、顶部控件区、直接坐在玻璃上的内容共用这一层底。
    /// 实际渲染时乘 0.74/0.80 透明度（见 `windowBacking`）。
    /// ⚠ 不许给它加彩度（判据见 `theme` 自检第 8 组）——
    ///   它存在的唯一理由是不让白桌面把玻璃洗成纯白、把卡面与玻璃的分界抹平。
    /// 整窗玻璃的**半透明底衬**（MiscKit 做法：浅 0.74 / 深 0.80）。
    /// 它只决定“透多少 + 白不白”，玻璃本身由 `WindowGlass` 的原生 `.glassEffect` 承担。
    static let windowBacking = Color.adaptive(
        light: Color(hex: ThemeColors.neutral(dark: false).glass).opacity(0.74),
        dark: Color(hex: ThemeColors.neutral(dark: true).glass).opacity(0.80))

    /// 内容层卡片底：整窗玻璃上的**极淡中性灰**（MiscKit 同款；不再是白色）
    static let cardFill = Color.adaptive(light: Color.black.opacity(0.04),
                                         dark: Color.white.opacity(0.055))
    /// 侧栏选中 pill：浅色用中性灰（不是白），深色用白纱；hover 更淡一档
    static let pillFill = Color.adaptive(light: Color.black.opacity(0.085),
                                         dark: Color.white.opacity(0.12))

    /// `Tok.row` 的四档叠加强度。**唯一来源** —— `row` 由它构造，`sem_contrast` 自检也读它。
    /// （自检里再抄一份常量的话，改了 `row` 自检不会跟着改，判据就成了摆设）
    static let rowAlphas = (light: 0.025, dark: 0.040, hcLight: 0.050, hcDark: 0.075)

    // ⚠ 每个表面色都带「提高对比度」变体：HC 外观下叠加强度更高 → 层级更分明。
    //   数值为经验值，待 macOS 高对比度实测微调；
    //   必须保持 row < sunken < chip < chipStrong < skeleton < hairline < stroke < dim 的层级递增。
    /// 列表行底（最淡一档）
    static let row = Color.surface(light: rowAlphas.light, dark: rowAlphas.dark,
                                   highContrastLight: rowAlphas.hcLight,
                                   highContrastDark: rowAlphas.hcDark)
    /// 悬浮面板底（搜索面板等浮动层；系统 windowBackgroundColor 承载明暗自适应，
    ///   表面色一律走 Tok 统一出口；系统色在 HC 外观下由系统自行增强，无需 HC 变体）
    static let float = Color(nsColor: .windowBackgroundColor)
    /// 嵌入式区块底（口径条 / 内嵌面板 / 表格内的次级块）
    static let sunken = Color.surface(light: 0.045, dark: 0.065,
                                      highContrastLight: 0.080, highContrastDark: 0.110)
    /// 胶囊 / 标签底
    static let chip = Color.surface(light: 0.060, dark: 0.090,
                                    highContrastLight: 0.100, highContrastDark: 0.140)
    /// 徽章底（比 chip 再实一档）
    static let chipStrong = Color.surface(light: 0.090, dark: 0.140,
                                          highContrastLight: 0.140, highContrastDark: 0.200)
    /// 骨架占位底（加载中的灰块）
    static let skeleton = Color.surface(light: 0.100, dark: 0.120,
                                        highContrastLight: 0.160, highContrastDark: 0.220)
    /// 细线（分隔线 / 图表网格线 / 坐标轴）
    static let hairline = Color.surface(light: 0.120, dark: 0.160,
                                        highContrastLight: 0.220, highContrastDark: 0.300)
    /// 控件描边（输入框 / 日期格 / 进度条槽）
    static let stroke = Color.surface(light: 0.180, dark: 0.240,
                                      highContrastLight: 0.300, highContrastDark: 0.400)
    /// 未激活 / 占位前景（比 .tertiary 更弱，用于图标与"—"占位）
    static let dim = Color.surface(light: 0.250, dark: 0.320,
                                   highContrastLight: 0.380, highContrastDark: 0.500)
    /// 浮层阴影（浅色下靠投影落地，深色下加重才看得出来）
    static let shadow = Color.adaptive(light: Color.black.opacity(0.18),
                                       dark: Color.black.opacity(0.55))

    // MARK: 系统文字色（兜底）
    //
    // ⚠ macOS 26 + ViewThatFits / glassEffect 实测：窗口已按 NSApp.appearance 变暗，
    //   SwiftUI 环境 colorScheme 仍可能按浅色解析 `.primary` → 深色底上黑字。
    //   这两枚直接取 NSColor 动态色（跟随窗口 effectiveAppearance），
    //   给"必须绝对可读"的大数字/指标值兜底；普通正文仍优先 `.primary/.secondary`。
    static let label = Color(nsColor: .labelColor)
    static let labelSecondary = Color(nsColor: .secondaryLabelColor)

    // MARK: 语义色底（徽章 / 标签 / 提示块）

    /// 语义色底的强度档位。
    ///
    /// 为什么需要它：裸透明度散写在视图里，同一个含义会漂出好几个值；
    /// 收敛到三档后，语义由档位承载：
    /// - `block`  大面积提示块底（ErrorView / 告警条 / 内嵌提示）
    /// - `chip`   胶囊 / 标签底（状态徽章、日期标签、筛选胶囊）—— **默认档**
    /// - `strong` 强调底（当前选中项、强提示）
    ///
    /// ⚠ 静态护栏 `theme_tint` 禁止视图里出现 < 0.2 的裸透明度 ——
    /// 这一族**只应该**是本函数的三个值。
    enum Tint {
        case block, chip, strong

        /// 浅色下叠得淡一些、深色下要更实 —— 否则深色底上几乎看不出差别
        fileprivate var alpha: Double {
            switch self {
            case .block:  return 0.08
            case .chip:   return 0.12
            case .strong: return 0.18
            }
        }

        /// 「提高对比度」外观下的语义底叠加强度
        fileprivate var hcAlpha: Double {
            switch self {
            case .block:  return 0.14
            case .chip:   return 0.20
            case .strong: return 0.28
            }
        }
    }

    /// 把语义色按档位混到底色上（**语义色底的唯一出口**，支持「提高对比度」强化）。
    ///
    /// 视图里写 `Tok.tint(Sem.warn)` 而不是 `Sem.warn.opacity(0.12)`。
    static func tint(_ color: Color, _ level: Tint = .chip) -> Color {
        Color.adaptive(
            light: color.opacity(level.alpha),
            dark: color.opacity(level.alpha),
            highContrastLight: color.opacity(level.hcAlpha),
            highContrastDark: color.opacity(level.hcAlpha)
        )
    }

    // MARK: 图表专用（K线 / 分时）—— 色值同样取自 `Palette.swift`

    /// 均线 MA7（短）：库默认 .yellow 在白底上几乎看不见 → 压成琥珀；深色下提亮
    static let maShort = ThemeColors.chart(.maShort).color
    /// 均线 MA25（中）：库默认 .brown 在深底上只有 2.4:1
    static let maMid = ThemeColors.chart(.maMid).color
    /// 均线 MA99（长）
    static let maLong = ThemeColors.chart(.maLong).color
    /// 分时均价线（A股惯例黄色）
    static let minuteAvg = ThemeColors.chart(.minuteAvg).color
    /// 彩底上的文字（图表最新价胶囊）：深色下涨跌色更亮，白字会糊 → 配深字
    static let onAccent = Color.adaptive(light: .white, dark: Color(hex: 0x14171C))
    /// 系统选中行上的文字（侧栏 / 列表的系统选中胶囊）。
    ///
    /// ⚠ 不能用 `onAccent`：它的深色档是近黑，而侧栏选中胶囊在深色下是黑底。
    ///   `NSColor.selectedMenuItemTextColor` 在两个外观下都是亮色，正是这个语义。
    ///   `theme_accent` 护栏禁止视图里散写 `.white`，此 token 是唯一出口。
    static let onSelection = Color(nsColor: .selectedMenuItemTextColor)
}

// MARK: - 字号档位（唯一出口）
//
// ## 档位依据
// macOS 11 个文本样式实际只用 8 个字号（26/22/17/15/13/12/11/10）+ 3 个字重档
// （Regular / Medium / Bold）⇒ 本项目按这个梯子切，**不新增字号**：
//   · 正文层级 5 档：body(13) / bodySmall(12) / detail(11) / detailSmall(10) / micro(9)
//     （原有第 6 档 `detailStrong` = 10pt Medium，**全仓零使用已删除**：
//       留着它只会让人以为"强调 10pt"有出口，实际各处都直接用 `.bold()` 或换档。
//       真要 Medium 档时重新加，比留一枚没人用的 token 好。）
//   · 标题**继续用系统语义**（`.title` / `.title2` / `.title3` / `.headline`）——
//     不进本枚举（进了反而丢掉 Dynamic Type）
//   · 数字**单列一根轴**：本项目所有会跳动的数字都要等宽（否则位数变化时列会抖）
//   · 超大号 `display` / `glyph` 是**图形化字号**（不参与正文层级，允许比正文大很多）
//
// ⚠ 用法纪律：视图里**只许**用本枚举或系统语义字号；散写 `.system(size:)` 由
//   护栏 `font_outlet` 挡住（`Tokens.swift` 之外出现即报红）。
//
// ⚠ 对比度纪律（2026-10-20 设计审查）：9/10pt 只给角标 / 密集网格；
//   **可读说明文字至少 11pt 且用 `.foregroundStyle(.secondary)`**。
//   `.tertiary` 只留给 "— / ·" 占位与装饰性图标 —— 它在浅/深底上只有约 2–3:1。
enum AppFont {
    // ── 正文层级 ────────────────────────────────────────────────────────
    /// 13pt —— 正文（列表正文、说明）
    static let body = Font.system(size: 13)
    /// 12pt —— 卡内正文 / 表格单元格（**本 App 最主力的一档**）
    static let bodySmall = Font.system(size: 12)
    /// 11pt —— 卡内小标题 / 标签
    static let detail = Font.system(size: 11)
    /// 10pt —— 密集网格 / 角标（**次主力**）
    static let detailSmall = Font.system(size: 10)
    /// 9pt —— 最密集的指标格 / 删除钮
    static let micro = Font.system(size: 9)

    // ── 数字（第三根轴）────────────────────────────────────────────────
    /// 给任意档位加上**等宽数字**（会跳动的数字必须用：价格 / 涨跌 / 统计）
    /// ⚠ 表格列请用 `mono`（等宽 design），单个数字用 `numeric(基准档)`
    static func numeric(_ base: Font) -> Font { base.monospacedDigit() }
    /// 12pt 等宽 —— 表格列（需跨行对齐的代码 / 数字列）
    static let mono = Font.system(size: 12, design: .monospaced)
    /// 11pt 等宽（调用方用 `.weight(.medium)` 组合）
    static let monoSmall = Font.system(size: 11, design: .monospaced)

    // ── 图形化字号（不参与正文层级）─────────────────────────────────────
    /// 大数字（hero / 现价 / 中央数值）：rounded design + semibold~bold
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    /// 大数字 + 等宽数字（重点百分比这类"会被刷新"的大数字）
    static func displayNumeric(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
    /// 图标字号（SF Symbol：工具栏 16 / 空态与引导 28~52）
    static func glyph(_ size: CGFloat) -> Font { .system(size: size) }
}

// MARK: - 弹窗尺寸
//
// 弹窗尺寸只在这里定义，视图里不要就地写 `.frame(width:height:)`。
enum SheetMetrics {
    /// 个股详情（640×720）
    static let stockDetail = CGSize(width: 640, height: 720)
    /// 分组编辑（340×150）
    static let groupEdit = CGSize(width: 340, height: 150)
    /// 区间预测（520×620）
    static let forecast = CGSize(width: 520, height: 620)
    /// 日期选择：紧凑态（330×220）
    static let datePickCompact = CGSize(width: 330, height: 220)
    /// 日期选择：展开态（330×300）
    static let datePickFull = CGSize(width: 330, height: 300)
    /// 指标筛选设置（B 域参数，560×640）
    static let indicatorSettings = CGSize(width: 560, height: 640)
    /// 设置窗口默认/最小尺寸（760×500：紧凑不空旷，适配横向 4 指数与纵向数据卡片）
    static let settingsWindow = CGSize(width: 760, height: 500)
}

// MARK: - 外观设置（跟随系统 / 浅色 / 深色）

/// 外观偏好：持久化到 UserDefaults，切换立即生效（所有窗口/弹窗/菜单栏菜单一起切）。
/// 用 NSApp.appearance 而不是 .preferredColorScheme：后者只管 SwiftUI 视图树，
/// NSColor 动态色（图表 GraphicsContext 里解析的那些）不会跟着变。
@MainActor
final class AppearanceStore {
    static let shared = AppearanceStore()

    enum Mode: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: String { rawValue }

        /// 档位名（只在**悬浮提示**里出现 —— 界面上的三个控件是纯图标；
        /// 文案「自动 / 白天 / 黑夜」跟用户心智模型走）
        var label: String {
            switch self {
            case .system: return "自动"
            case .light: return "白天"
            case .dark: return "黑夜"
            }
        }

        /// 侧栏那个小图标（**当前档由图标本身表达**，不再写字）
        var icon: String {
            switch self {
            case .system: return "circle.lefthalf.filled"   // 半明半暗 = 跟系统
            case .light: return "sun.max"
            case .dark: return "moon"
            }
        }

        /// 悬浮提示（把"自动"到底是跟随什么说清楚）
        var helpText: String {
            switch self {
            case .system: return "外观：自动（跟随系统设置）"
            case .light: return "外观：白天"
            case .dark: return "外观：黑夜"
            }
        }

        /// nil = 跟随系统（清空 App 级覆盖）
        var appearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    private static let defaultsKey = "appearanceMode"

    private(set) var mode: Mode

    private init() {
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: Self.defaultsKey) ?? "") ?? .system
    }

    func set(_ newMode: Mode) {
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.defaultsKey)
        apply()
    }

    /// 应用到整个 App（启动时 + 切换时各调一次）
    func apply() {
        NSApp.appearance = mode.appearance
    }
}