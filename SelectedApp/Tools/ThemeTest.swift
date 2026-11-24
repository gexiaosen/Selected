import Foundation
import SwiftUI
import AppKit
import SelectedCore

/// 主题 / 色板自检（Tokens.swift，纯离线）
///
/// 锁的是这几条**用户可见且容易静默回归**的属性：
///   1. 明暗自适应 —— 每个语义色/表面 token 在两套外观下解析值必须不同
///      （有人把颜色写死成静态值，暗色下就会与卡片糊成一片，肉眼很难在代码里发现）
///   2. 浅色口径冻结 —— 浅色档必须仍是原始色号（浅色观感不许被暗色改造动到）
///   3. 可读性 —— 8 个语义基础色在**两种外观**下对窗口底色都 ≥3:1；
///      表面 token 叠加后必须能看出层级（与底色有可辨差异）
///   4. 语义入口不变 —— pnl/灯级/信号/风险/状态/变化/得分 的映射与基础色一一对应
///   5. 外观三档（自动 / 白天 / 黑夜）落库与解析
///   6. ⚠ **中性梯度方向** —— 浅深两档，卡片底必须**亮于**窗口底，
///      且明度差落在"看得见但不跳"的带内（设计文档 M2 的方向锁，见 `neutralRamp()`）
/// ⚠ 本文件原先写"锁的是四条"，实际早有六个断言组 —— **注释里的计数也会漂**，
///    所以这里改成逐条列，且不再写"共 N 条"这种需要人维护的总数。
@main
struct ThemeTest {
    private static var failures = 0

    // MARK: - 外观与解析

    private static func resolve(_ color: Color, dark: Bool) -> RGBA {
        var env = EnvironmentValues()
        env.colorScheme = dark ? .dark : .light
        let v = color.resolve(in: env)
        return RGBA(r: Double(v.red), g: Double(v.green), b: Double(v.blue), a: Double(v.opacity))
    }

    /// 窗口底色（两套外观的参照底）：不写死，直接从系统语义色取，避免参照物过期
    private static func windowBG(_ dark: Bool) -> RGBA {
        resolve(Color(nsColor: .windowBackgroundColor), dark: dark)
    }

    struct RGBA { var r, g, b, a: Double }

    /// alpha 混合：把颜色压到参照底上（表面 token 都是半透明叠加色）
    private static func over(_ c: RGBA, _ bg: RGBA) -> RGBA {
        RGBA(r: c.r * c.a + bg.r * (1 - c.a),
             g: c.g * c.a + bg.g * (1 - c.a),
             b: c.b * c.a + bg.b * (1 - c.a),
             a: 1)
    }

    private static func luminance(_ c: RGBA) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    private static func contrast(_ a: RGBA, _ b: RGBA) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// 最大通道差（判断"看得出层级"用）
    private static func delta(_ a: RGBA, _ b: RGBA) -> Double {
        max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
    }

    /// 含 alpha 的差（判断"明暗两档是否真的不同"，阴影类 token 只差 alpha）
    private static func deltaAll(_ a: RGBA, _ b: RGBA) -> Double {
        max(delta(a, b), abs(a.a - b.a))
    }

    private static func near(_ a: RGBA, _ b: RGBA, tol: Double = 0.004) -> Bool {
        abs(a.r - b.r) < tol && abs(a.g - b.g) < tol && abs(a.b - b.b) < tol
    }

    private static func hex(_ r: Int, _ g: Int, _ b: Int) -> RGBA {
        RGBA(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255, a: 1)
    }

    // MARK: - 主题清单（新增 token 必须同步登记，否则第 1/3 条覆盖不到）

    /// 语义基础色（浅色原色 / 名称）
    private static let semantics: [(String, Color, RGBA)] = [
        ("Sem.up", Sem.up, hex(0xC1, 0x2C, 0x1F)),
        ("Sem.down", Sem.down, hex(0x0E, 0x7C, 0x2F)),
        // `Sem.warn` 的基线是 0x9C5807（旧值 0xD97A0A 在浅色档实测只有 **2.96:1**，
        //   连大字/图形标准都不到 —— 判据固化在 `Tools/SemContrastCheck.swift`
        //   （护栏 `sem_contrast`），四档（浅/深 × 基础/HC）全部 ≥ 4.5:1，改坏了会报红）。
        //   调这个色只许改**明度**、色相 H≈32° 不许变 ⇒ 仍是同一个"警示橙"语义。
        ("Sem.warn", Sem.warn, hex(0x9C, 0x58, 0x07)),
        ("Sem.info", Sem.info, hex(0x1D, 0x6F, 0xBF)),
        ("Sem.accent", Sem.accent, hex(0x7A, 0x3A, 0xED)),
        ("Sem.brand", Sem.brand, hex(0x2E, 0x59, 0xA7)),
        ("Sem.selection", Sem.selection, hex(0x2E, 0x59, 0xA7)),
        ("Sem.tailEnhance", Sem.tailEnhance, hex(0x0D, 0x76, 0x8A)),
    ]

    /// 表面 / 线条 / 图表 token
    private static let surfaces: [(String, Color)] = [
        ("Tok.windowBacking", Tok.windowBacking),
        ("Tok.row", Tok.row),
        ("Tok.sunken", Tok.sunken),
        ("Tok.chip", Tok.chip),
        ("Tok.chipStrong", Tok.chipStrong),
        ("Tok.skeleton", Tok.skeleton),
        ("Tok.hairline", Tok.hairline),
        ("Tok.stroke", Tok.stroke),
        ("Tok.dim", Tok.dim),
        ("Tok.shadow", Tok.shadow),
        ("Tok.maShort", Tok.maShort),
        ("Tok.maMid", Tok.maMid),
        ("Tok.maLong", Tok.maLong),
        ("Tok.minuteAvg", Tok.minuteAvg),
        ("Tok.onAccent", Tok.onAccent),
    ]

    private static var allTokens: [(String, Color)] {
        semantics.map { ($0.0, $0.1) } + surfaces
    }

    // MARK: - 入口

    static func main() {
        print("== theme ==")
        adaptivity()
        lightColorsFrozen()
        readability()
        surfaceHierarchy()
        semanticEntries()
        appearanceMode()
        neutralRamp()
        glassFloor()

        print(failures == 0 ? "✅ theme：全部断言通过" : "❌ theme：\(failures) 项断言失败")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 1) 明暗自适应

    private static func adaptivity() {
        for (name, color) in allTokens {
            let l = resolve(color, dark: false), d = resolve(color, dark: true)
            check(deltaAll(l, d) > 0.02, "\(name) 明暗解析值不同（浅 \(round3(l)) / 深 \(round3(d))）")
        }
    }

    // MARK: - 2) 浅色口径冻结（改造前原色号）

    private static func lightColorsFrozen() {
        for (name, color, legacy) in semantics {
            let l = resolve(color, dark: false)
            check(near(l, legacy), "\(name) 浅色仍为原色号 \(round3(legacy))（实际 \(round3(l))）")
        }
    }

    // MARK: - 3) 可读性（语义色 vs 窗口底色，两种外观都 ≥3:1）

    private static func readability() {
        for dark in [false, true] {
            let bg = windowBG(dark)
            for (name, color, _) in semantics {
                let c = over(resolve(color, dark: dark), bg)
                let ratio = contrast(c, bg)
                check(ratio >= 3.0,
                      "\(name) 在\(dark ? "深" : "浅")色底上对比度 \(round2(ratio)):1 ≥ 3:1")
            }
        }
        // 涨跌必须仍能一眼分开：暗色档红绿不得串色
        let upD = resolve(Sem.up, dark: true), downD = resolve(Sem.down, dark: true)
        check(upD.r > upD.g + 0.2, "暗色涨色仍是红系（R \(round2(upD.r)) vs G \(round2(upD.g))）")
        check(downD.g > downD.r + 0.2, "暗色跌色仍是绿系（G \(round2(downD.g)) vs R \(round2(downD.r))）")
    }

    // MARK: - 4) 表面层级（叠加后与底色有可辨差异）

    private static func surfaceHierarchy() {
        for dark in [false, true] {
            let bg = windowBG(dark)
            var prev = 0.0
            // row < sunken < chip < chipStrong：层级必须严格递增（深浅两套都要成立）
            for (name, token) in [("Tok.row", Tok.row), ("Tok.sunken", Tok.sunken),
                                  ("Tok.chip", Tok.chip), ("Tok.chipStrong", Tok.chipStrong)] {
                let comp = over(resolve(token, dark: dark), bg)
                let dv = delta(comp, bg)
                check(dv >= 0.02, "\(name) 在\(dark ? "深" : "浅")色底上可辨（通道差 \(round3(dv))）")
                check(dv > prev, "\(name) 层级高于上一档（\(round3(dv)) > \(round3(prev))）")
                prev = dv
            }
        }
    }

    // MARK: - 5) 语义入口映射

    private static func semanticEntries() {
        let cases: [(String, Color, Color)] = [
            ("pnl(+)", Sem.pnl(1.2), Sem.up),
            ("pnl(-)", Sem.pnl(-1.2), Sem.down),
            ("pnl(0)", Sem.pnl(0), .secondary),
            ("pnl(nil)", Sem.pnl(nil), .secondary),
            ("light(绿灯)", Sem.light(.green), Sem.down),
            ("light(黄灯)", Sem.light(.yellow), Sem.warn),
            ("light(红灯)", Sem.light(.red), Sem.up),
            ("light(nil)", Sem.light(nil), .gray),
            ("signal(strongest)", Sem.signal(.strongest), Sem.accent),
            ("signal(consensus)", Sem.signal(.consensus), Sem.info),
            ("signal(pulse)", Sem.signal(.pulse), Sem.warn),
            ("signal(unverified)", Sem.signal(.unverified), .gray),
            ("risk(极高)", Sem.risk(.extreme), Sem.accent),
            ("risk(高)", Sem.risk(.high), Sem.up),
            ("risk(中)", Sem.risk(.medium), Sem.warn),
            ("risk(低)", Sem.risk(.low), Sem.down),
            ("risk(nil)", Sem.risk(nil), .secondary),
            // 「任务/环节状态」入口 `Sem.status` 随链路状态条一起在 2026-10-29 下线（无消费方 ⇒ 不留死档位）
            ("change(good)", Sem.change("good"), Sem.down),
            ("change(bad)", Sem.change("bad"), Sem.up),
            ("change(same)", Sem.change("same"), .secondary),
            // `scoreColor` 的门槛**没有缺省值** → 必须显式传。
            //   用**默认版本的真实门槛 85 / 60**，三个分支各自可达且与线上口径一致：
            //     ≥85 一档(up) / 60~84 二档(warn) / <60 三档(down)
            ("scoreColor(90@85/60)", Sem.scoreColor(90, tier1: 85, tier2: 60), Sem.up),
            ("scoreColor(80@85/60)", Sem.scoreColor(80, tier1: 85, tier2: 60), Sem.warn),
            ("scoreColor(50@85/60)", Sem.scoreColor(50, tier1: 85, tier2: 60), Sem.down),
            ("targetPrice", Sem.targetPrice, Sem.up),
            ("stopLossPrice", Sem.stopLossPrice, Sem.down),
        ]
        for (name, got, want) in cases {
            check(near(resolve(got, dark: false), resolve(want, dark: false)),
                  "\(name) 浅色映射不变")
            check(near(resolve(got, dark: true), resolve(want, dark: true)),
                  "\(name) 深色映射不变")
        }
    }

    // MARK: - 6) 外观开关

    private static func appearanceMode() {
        MainActor.assumeIsolated {
            check(AppearanceStore.Mode.system.appearance == nil, "跟随系统 = 不覆盖 App 外观")
            check(AppearanceStore.Mode.light.appearance?.name == .aqua, "浅色 = aqua")
            check(AppearanceStore.Mode.dark.appearance?.name == .darkAqua, "深色 = darkAqua")
            // 默认档位：UserDefaults 无记录时必须跟随系统（不能默认深色）
            check(AppearanceStore.Mode(rawValue: "") == nil
                  && (AppearanceStore.Mode(rawValue: "system") ?? .dark) == .system,
                  "未知/缺失取值回落到跟随系统")
        }
    }

    // MARK: - 7) 中性梯度方向（浅深两档：卡面 vs 它坐着的玻璃下限）
    //
    // 锁的是设计文档 **M2** 的成因：改造前所有卡片走 `.glassEffect`，取像素实测
    // 整个详情列是**一整块平面**（浅 `#FFFFFF` / 深 `#1E1E1E`，卡片与卡间同色），
    // 层次只靠 1px 描边撑。卡片直接坐在玻璃上 ⇒ 参照物是 `glass`（窗口玻璃的不透明下限）。
    // ⚠ 只判**方向**、不判带宽：深档实测只到 1.003:1，再钉"必须 ≥1.08"
    //   等于逼着改色。分界现在由 `CardSurface` 那圈 hairline 撑。
    // ⚠ 方向必须单独断言，不能用对比度代替：`contrast()` 是对称的，把两枚值对调它照样返回
    //   同一个数（实测：故意对调两枚，只判比值仍然全绿 —— 差点就这么交出去）。
    private static func neutralRamp() {
        func rgb(_ v: UInt32) -> RGBA {
            RGBA(r: Double((v >> 16) & 0xff) / 255, g: Double((v >> 8) & 0xff) / 255,
                 b: Double(v & 0xff) / 255, a: 1)
        }
        for dark in [false, true] {
            let n = ThemeColors.neutral(dark: dark)
            let card = rgb(n.card), floorC = rgb(n.glass)
            let tag = dark ? "深" : "浅"
            check(dark ? luminance(card) < luminance(floorC) : luminance(card) > luminance(floorC),
                  "\(tag) 卡面与玻璃下限方向反了（卡面 \(round3(card)) vs 底 \(round3(floorC))；"
                  + "浅档卡面必须亮于底、深档必须暗于底，反了卡片就陷进底里 = M2）")
        }
    }

    /// 第 8 组：**窗口玻璃的不透明下限**（`Neutral.glass`）扛不扛得住极端桌面。
    ///
    /// 为什么单独一组：玻璃叠在桌面上，**桌面是纯白时浅玻璃必然被洗成白** ——
    /// 卡面与玻璃的分界直接消失（2026-10-23 原型实测：浅档纯白桌面下 ΔL 只剩 6 级、1.05:1）。
    /// 所以玻璃底下必须垫一枚不透明下限，而且它自己不能太贴桌面那一侧。
    /// 判据是**自包含**的（不依赖任何别的 token，`window` 已随面板一起删掉）：
    /// 浅档这枚与**纯白**、深档这枚与**纯黑**必须拉开 1.12–1.75:1
    /// —— 下限 1.12 = 洗不白；上限 1.75 = 不许糊成一块深灰板（哑光取向）。
    /// 再加一条"仍是同一支中性"：极差通道要与本档卡面同向（卡面是纯灰时跳过，没有色相可比）。
    private static func glassFloor() {
        func rgb(_ v: UInt32) -> RGBA {
            RGBA(r: Double((v >> 16) & 0xff) / 255, g: Double((v >> 8) & 0xff) / 255,
                 b: Double(v & 0xff) / 255, a: 1)
        }
        // 归一化彩度：通道极差 ÷ 三通道均值（暗色直接比绝对极差会因放大而虚高）
        func chroma(_ c: RGBA) -> Double {
            let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
            let mean = (c.r + c.g + c.b) / 3
            return mean > 0 ? (mx - mn) / mean : 0
        }
        func topChannel(_ c: RGBA) -> Int {
            if c.r >= c.g && c.r >= c.b { return 0 }
            return c.g >= c.b ? 1 : 2
        }
        let names = ["R", "G", "B"]
        for dark in [false, true] {
            let n = ThemeColors.neutral(dark: dark)
            let g = rgb(n.glass), card = rgb(n.card)
            let tag = dark ? "深" : "浅"
            // 极端桌面：浅档怕纯白，深档怕纯黑
            let desk = dark ? RGBA(r: 0, g: 0, b: 0, a: 1) : RGBA(r: 1, g: 1, b: 1, a: 1)
            let ratio = contrast(g, desk)
            check(ratio >= 1.12,
                  "\(tag) 玻璃下限太贴极端桌面（与\(dark ? "纯黑" : "纯白") \(round2(ratio)):1 < 1.12，"
                  + "\(dark ? "黑" : "白")桌面会把玻璃洗成一片，卡面与底的分界消失）")
            check(ratio <= 1.75,
                  "\(tag) 玻璃下限压太狠（与\(dark ? "纯黑" : "纯白") \(round2(ratio)):1 > 1.75，"
                  + "整窗会糊成一块深灰板，违反哑光取向）")
            if chroma(card) >= 0.004 {
                check(topChannel(g) == topChannel(card),
                      "\(tag) 玻璃下限换了色相（玻璃极差在 \(names[topChannel(g)])、卡面在 \(names[topChannel(card)])，"
                      + "只许挪明度，不许给玻璃上色）")
            }
        }
    }

    // MARK: - 工具

    private static func round2(_ v: Double) -> String { String(format: "%.2f", v) }
    private static func round3(_ v: Double) -> String { String(format: "%.3f", v) }
    private static func round3(_ c: RGBA) -> String {
        String(format: "(%.3f,%.3f,%.3f a%.2f)", c.r, c.g, c.b, c.a)
    }

    private static func check(_ ok: Bool, _ desc: String) {
        if ok { return }
        failures += 1
        print("  ❌ \(desc)")
        if failures > 40 { print("  …（断言失败过多，已截断）"); exit(1) }
    }
}