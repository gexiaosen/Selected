import SwiftUI

// MARK: - 单套配色（玻璃主题）
//
// 本文件是颜色值的**唯一数据源**；`Tokens.swift` 把色值包成明暗自适应色，
// 视图只写 `Sem.*` / `Tok.*`，不感知具体 hex。
//
// 2026-10-30「主题」整条功能下线：此前的五档可切换配色
// （classic / ink / rice / amber / graphite）只保留 classic ——
// 原生玻璃 + 改造前原色。`theme` 自检把浅色档钉成原色号。

/// 一个色槽位的四档色值（浅 / 深 / 高对比度浅 / 高对比度深）。
struct Quad {
    let light: UInt32, dark: UInt32, hcLight: UInt32, hcDark: UInt32
    /// **承白字的填充色**（仅 `borderedProminent` 按钮这类"系统自己配白字"的位置用）。
    /// nil = 与 text 同色。
    ///
    /// ⚠ 为什么必须有第二个值：一支色**不可能同时**满足"在深底卡片上作为文字 ≥4.5:1"
    ///   与"作为填充时白字压得住 ≥4.5:1"。实测深色档 `brand` `#4A80DE`：
    ///   当文字对卡片底只有 **3.37:1**（不达标），抬亮到 `#6199F9` 才够 4.6:1，
    ///   但那时白字压上去从 3.88 掉到 **2.83**（更差）。`up` 同理（4.01 ↔ 白字 2.82）。
    ///   ⇒ 文字位抬亮、填充位保持原值，按钮像素与改造前一致，文字可读性修好。
    let fillLight: UInt32?, fillDark: UInt32?
    let hcFillLight: UInt32?, hcFillDark: UInt32?

    init(_ l: UInt32, _ d: UInt32, _ hl: UInt32, _ hd: UInt32,
         fillLight: UInt32? = nil, fillDark: UInt32? = nil,
         hcFillLight: UInt32? = nil, hcFillDark: UInt32? = nil) {
        light = l; dark = d; hcLight = hl; hcDark = hd
        self.fillLight = fillLight; self.fillDark = fillDark
        self.hcFillLight = hcFillLight; self.hcFillDark = hcFillDark
    }
}

/// 语义槽位。`base(_:)` 是穷尽 `switch`，漏一个编译不过（不给 `default:`）。
enum SemKey: String, CaseIterable {
    case up, down, warn, info, accent, brand, selection, tailEnhance
}

/// 图表专用槽位（与语义色分家：均线是图形，对比度基准 3:1 而非 4.5:1）
enum ChartKey: String, CaseIterable {
    case maShort, maMid, maLong, minuteAvg
}

/// 图形档（比例条专用）的槽位。与 `SemKey` 分开是故意的：
/// 只有**成对相邻、要靠颜色分辨谁是谁**的那两支需要分梯，徽章/文字仍走 text 档。
enum BarKey: CaseIterable {
    case up, down
}

/// 多序列图表的图形档槽位（四层胜率走势）。与 `BarKey` 分开：
/// 比例条那对已定稿，不为四序列的集合约束重解、改动它的像素。
enum SeriesKey: CaseIterable {
    case up, down, warn, accent
}

/// 内容层的中性色：卡片底 + 整窗玻璃底衬的基色。
struct ThemeNeutral {
    /// 卡片底（玻璃主题下它是"玻璃离屏渲染实测值"，只作 `sem_contrast` 的对比度基准，不填卡片）
    let card: UInt32
    /// 窗口玻璃底衬的**基色**（导航、顶部控件区、直接坐在玻璃上的内容共用这一层底；
    /// 渲染时乘 0.74/0.80 透明度）。
    let glass: UInt32
}

enum ThemeColors {

    static func base(_ k: SemKey) -> Quad {
        switch k {
        case .up:
            return Quad(0xC12C1F, 0xFB6D5D, 0x8E1D14, 0xFF8878,
                        fillLight: 0xC12C1F, fillDark: 0xEE6152,
                        hcFillLight: 0x8E1D14, hcFillDark: 0xC8382A)
        case .down:        return Quad(0x0E7C2F, 0x3FC46B, 0x0A5C24, 0x6AE39A)
        case .warn:        return Quad(0x9C5807, 0xEFB03C, 0x7A4205, 0xFFC46B)
        case .info:        return Quad(0x1D6FBF, 0x5AA9EE, 0x155A9C, 0x7FC0FF)
        case .accent:      return Quad(0x7A3AED, 0xA98BF7, 0x5B24B8, 0xC6AEFB)
        case .brand:
            return Quad(0x2E59A7, 0x6199F9, 0x20447F, 0x6BA3F0,
                        fillLight: 0x2E59A7, fillDark: 0x4A80DE,
                        hcFillLight: 0x20447F, hcFillDark: 0x3568C0)
        case .selection:
            return Quad(0x2E59A7, 0x6199F9, 0x20447F, 0x6BA3F0,
                        fillLight: 0x2E59A7, fillDark: 0x4A80DE,
                        hcFillLight: 0x20447F, hcFillDark: 0x3568C0)
        case .tailEnhance: return Quad(0x0D768A, 0x35B6C9, 0x085560, 0x5FD6E6)
        }
    }

    static func chart(_ k: ChartKey) -> Quad {
        switch k {
        case .maShort:   return Quad(0xC8961A, 0xE8C255, 0x9C720D, 0xF7D774)
        case .maMid:     return Quad(0x9A5B3C, 0xD08A63, 0x7A4228, 0xE6A47E)
        case .maLong:    return Quad(0x8A5CF6, 0xB79BF9, 0x6739D4, 0xCEBAFC)
        case .minuteAvg: return Quad(0xD9A21A, 0xF5C542, 0xA87A0B, 0xFFE070)
        }
    }

    /// 涨跌比**条**的取色（图形档）—— 与 `base(.up)/base(.down)` 的 text 档**不同值**，理由：
    ///
    /// text 档涨/跌是**刻意明度齐平**的（数字列不能因颜色跳行），
    /// 实测两支在二色觉（Viénot–Brettel deutan）下 ΔE 只有 **0.030–0.082**
    /// —— 本仓自己的判据是 <0.10 = 不可分 ⇒ 一条只有两色相邻的比例条，对一部分用户
    /// **就是同色**（2026-10-22 实测，见设计文档 §7.4 / D2-2）。
    /// ⇒ 图形档保留**同一色相同一彩度**（只挪 OKLab L，语义与"一家人"感都不变），
    ///   把两支拉开一档明度，deutan ΔE 提到 **≥0.115**。
    /// ⚠ 不是"越大越好"：取的是**刚好跨过 0.115 的最小 δ**。再往上解，涨会解成近黑酱
    ///   （`#6D0502`，12.2:1）、跌解成亮草绿 —— 指标更漂亮，眼睛直接不接受。
    /// ⚠ 浅档把涨压暗、跌提亮；深档反过来（涨更亮、跌更暗）——
    ///   两档里"涨"都是更醒目的那一支，与 A 股"涨为主看"的读序一致。
    /// ⚠ 判据由护栏 `bar_separation` 逐档实算钉死（改坏会报红），别只靠这段注释。
    static func bar(_ k: BarKey) -> (light: UInt32, dark: UInt32) {
        switch k {
        // ⚠ 深档是唯一解不出来的一对：涨 #FB6D5D 已经贴着 sRGB 边界
        //   （L 抬到 0.721 就出域、R 被裁），而把跌往下压会让两支在 deutan 空间里
        //   **靠得更近** —— 扫遍 δ∈[0.10,0.34] 的对称解与两种非对称解都到不了 0.115。
        //   ⇒ 深档图形档 = text 档（deutan ΔE 0.082，两对里本来就最高的那一个），
        //     分界只靠 2pt 缝 + 位置 + 宽度三条结构通道。
        //   豁免登记在护栏 `bar_separation` 的 `gamutExempt` 里（棘轮：修好了会报红）。
        case .up:   return (0xB3_1A0F, 0xFB_6D5D)
        case .down: return (0x23_883B, 0x3F_C46B)
        }
    }

    /// 四层胜率走势的系列色（图形档）—— 与 text 档**同色相同彩度，只挪 OKLab L**。
    ///
    /// text 档四支明度齐平（浅 L 0.51–0.54 / 深 0.71–0.80），deutan 下
    /// 红↔橙 ΔE 0.023、红↔绿 0.053（浅）—— 四条线靠颜色根本分不开。
    /// 解法与 bar 同一口味：**刚好跨过 0.115 的最小 δ**（四支当一个集合解，6 对全要过），
    /// 不是"分得越开越好"（那会把涨压成近黑酱、跌抬成荧光绿）。
    /// ⚠ 只给线条/色块用；线尾标签是文字，仍走 text 档（4.5:1，本档只保 3:1）。
    /// ⚠ 判据由护栏 `bar_separation` 逐档实算钉死（6 对 deutan + 对比度 + 同色相同彩度）。
    static func series(_ k: SeriesKey) -> (light: UInt32, dark: UInt32) {
        switch k {
        case .up:     return (0xA7_0200, 0xEA_5D4F)
        case .down:   return (0x0F_7D30, 0x3C_C169)
        case .warn:   return (0xC6_7F3C, 0xFF_C352)
        case .accent: return (0x7A_3AED, 0xA9_8BF7)
        }
    }

    /// 两枚**不透明中性实底** —— 卡片底 + 整窗玻璃的半透明底衬（渲染时乘 0.74/0.80）。
    ///
    /// ⚠ 玻璃主题下 `card` **不是填充值**，是"玻璃在这条离屏快照链路里实测渲染成什么色"
    ///   （浅 `#FFFFFF` / 深 `#1E1E1E`，2026-10-22 取像素）—— 它只喂 `sem_contrast`
    ///   的文字背景基准。`glass` 是窗口底衬的基色：浅 #ECEDEF / 深 #2B2B2E，
    ///   实际渲染时按 MiscKit 口径乘 0.74（浅）/ 0.80（深）透明度，让桌面透进来。
    ///
    /// ⚠ 两枚必须成对给：梯度的含义是**浅档卡面亮于底衬、深档卡面暗于底衬**。
    ///   方向由 `theme` 自检第 7 组钉死；底衬不许加彩度（第 8 组）。
    static func neutral(dark: Bool) -> ThemeNeutral {
        dark ? ThemeNeutral(card: 0x1E1E1E, glass: 0x2B2B2E)
             : ThemeNeutral(card: 0xFF_FFFF, glass: 0xEC_EDEF)
    }
}
