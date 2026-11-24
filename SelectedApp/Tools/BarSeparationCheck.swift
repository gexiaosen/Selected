import Foundation

// 图形档的**分离度**检查 —— 护栏 `bar_separation` 的实现（纯 Swift，全仓零 Python）。
//
// 管两族色（同一个判据体系，分开取色）：
//   1. 比例条图形档 `ThemeColors.bar`（BreadthBar 等红绿相邻色块）；
//   2. 图表系列档 `ThemeColors.series`（复盘页四层胜率走势，四支当一个集合解）。
//
// 防的是什么：多支语义色**相邻、要靠颜色分辨谁是谁**的界面元素。
// 2026-10-22 实测：涨/跌 **text 档**在二色觉（Viénot–Brettel deutan）下
// ΔE 只有 0.030–0.082 —— 本仓自己的判据是 <0.10 = 不可分（拉开要 ≥0.115）。
// 所以图形档单独解了一组色（同色相同彩度、只挪 OKLab L）。
// **解出来的色如果不被钉住，下一次"顺手统一一下色值"就会把它抹平回去** —— 那不会让任何测试变红，
// 因为对比度、主题自检、像素基线全都照过。⇒ 这条护栏算的是"分不分得开"，不是"好不好看"。
//
// 判据（浅/深各一组）：
//   1. deutan ΔE ≥ 0.115（二色觉下仍分得开；比例条 1 对，系列档 6 对全要过）
//   2. 每支对**卡片底** ≥3.0:1（非文本图形，WCAG 1.4.11 口径；
//      比例条取"纯卡片底"与"卡片底叠 `Tok.row` 行叠层"里更差的——它在表格里；
//      系列档只查纯卡片底——折线图坐在卡片上，没有行叠层）
//   3. **只许挪明度**：与同名 text 档比，OKLab 色相角差 <2°、彩度差 <0.01
//      （改色相等于改语义 —— 这条与 `sem_contrast` 文件头同一条纪律）
//   4. 覆盖数必须等于 2×(5+14)：少一组就是判据空转
//      （同 `sem_contrast` 从"正则抽源码"换成"链接真类型"的理由 —— 护栏空转比没有护栏更糟）
//
// 退出码：0 达标 / 1 有不达标项（逐条列出）/ 2 工具链或结构问题（护栏没跑成，必须报红）

let DE_TARGET = 0.115      // deutan 下可分下限（本仓判据：<0.10 不可分，留一点余量）
let GRAPHIC_MIN = 3.0      // 非文本图形的最低对比度
let EXPECTED_PAIRS = 2     // 浅/深

// ⚠ **豁免表是棘轮，只准变短**（与 `SemContrastCheck.swift` 的 `legacyExempt` 同一套做法）：
//   · 表外的新不达标项 ⇒ 报红（不许靠加豁免过关）
//   · 表里的项被修好了 ⇒ **也报红**（逼着把豁免删掉，否则清单只会变长）
//   · 每一项都必须写清"为什么解不出来"，而不是"先记一笔"
//
// `深` 是唯一**在 sRGB 内解不出明度阶梯**的一对：
//   涨 #FB6D5D 的 L≈0.716 已贴边界（抬到 0.721 就出域、R 被裁 ⇒ 彩度被动改变，违反"只许挪明度"）；
//   把跌往下压则让两支在 deutan 空间里**靠得更近**（实测扫遍 δ∈[0.10,0.34] 的对称解
//   与"只压跌 / 只抬涨"两种非对称解，都到不了 0.115）。
//   ⇒ 深色的图形档就等于 text 档，ΔE 0.082 —— 两对里本来就最高的那一个，
//     分界由 2pt 缝 + 位置 + 宽度三条**结构**通道承担（那三条与色觉无关，永远在）。
let gamutExempt: Set<String> = ["深"]

@main
struct BarSeparationCheck {
    static func main() {
        var checked = 0
        var bad: [String] = []
        var exemptHits = 0

        for lightMode in [true, false] {
            let tag = lightMode ? "浅" : "深"
            let upBar = ThemeColors.bar(.up)
            let downBar = ThemeColors.bar(.down)
            let fgUp = lightMode ? upBar.light : upBar.dark
            let fgDown = lightMode ? downBar.light : downBar.dark

            // --- 1) deutan ΔE ---
            let de = ColorMath.deltaE(ColorMath.simulateDeutan(fgUp), ColorMath.simulateDeutan(fgDown))
            checked += 1
            if de < DE_TARGET {
                if gamutExempt.contains(tag) {
                    exemptHits += 1
                } else {
                    bad.append("\(tag) deutan ΔE \(String(format: "%.3f", de)) < \(DE_TARGET)"
                        + "（涨 #\(ColorMath.hexString(fgUp)) vs 跌 #\(ColorMath.hexString(fgDown)) 在二色觉下不可分）")
                }
            } else if gamutExempt.contains(tag) {
                bad.append("⚠ 豁免项 \(tag) 现已达标（ΔE \(String(format: "%.3f", de))），"
                    + "请把它从 gamutExempt 删掉 —— 豁免清单只准变短")
            }

            // --- 2) 对卡片底 ≥3:1（取"纯底"与"叠行底"里更差的那个）---
            let card = ThemeColors.neutral(dark: !lightMode).card
            let rowSurface = ColorMath.overlay(lightMode ? Tok.rowAlphas.light : Tok.rowAlphas.dark,
                                               over: card, lightMode: lightMode)
            for (name, fg) in [("涨", fgUp), ("跌", fgDown)] {
                let worst = min(ColorMath.contrast(fg, card), ColorMath.contrast(fg, rowSurface))
                checked += 1
                if worst < GRAPHIC_MIN {
                    bad.append("\(tag) \(name) #\(ColorMath.hexString(fg)) 对卡片底只有 "
                        + "\(String(format: "%.2f", worst)):1 < \(GRAPHIC_MIN)"
                        + "（底 #\(ColorMath.hexString(card)) / 行底 #\(ColorMath.hexString(rowSurface))）")
                }
            }

            // --- 3) 只许挪明度：色相与彩度必须与同名 text 档一致 ---
            for (k, fg) in [(SemKey.up, fgUp), (SemKey.down, fgDown)] {
                let q = ThemeColors.base(k)
                let text: UInt32 = lightMode ? q.light : q.dark
                let dh = abs(ColorMath.hueAngle(fg) - ColorMath.hueAngle(text))
                let dhAdj = min(dh, 360 - dh)
                let dc = abs(ColorMath.chroma(fg) - ColorMath.chroma(text))
                checked += 1
                if dhAdj > 2.0 || dc > 0.01 {
                    bad.append("\(tag) \(k.rawValue) 图形档相对 text 档偏了 色相 \(String(format: "%.1f", dhAdj))°"
                        + " / 彩度 \(String(format: "%.3f", dc)) —— 图形档**只许挪明度**，"
                        + "改色相等于改语义（#\(ColorMath.hexString(text)) → #\(ColorMath.hexString(fg))）")
                }
            }

            // --- 图表系列档（四层胜率走势）：6 对 deutan + 4 对比度 + 4 同色相同彩度 ---
            let seriesSem: [SemKey] = [.up, .down, .warn, .accent]
            let seriesSlots: [SeriesKey] = [.up, .down, .warn, .accent]
            let fgSeries: [UInt32] = seriesSlots.map { k in
                let s = ThemeColors.series(k)
                return lightMode ? s.light : s.dark
            }
            for i in 0..<4 {
                for j in (i+1)..<4 {
                    let de = ColorMath.deltaE(ColorMath.simulateDeutan(fgSeries[i]),
                                              ColorMath.simulateDeutan(fgSeries[j]))
                    checked += 1
                    if de < DE_TARGET {
                        bad.append("\(tag) 系列 \(seriesSem[i].rawValue)↔\(seriesSem[j].rawValue)"
                            + " deutan ΔE \(String(format: "%.3f", de)) < \(DE_TARGET)"
                            + "（#\(ColorMath.hexString(fgSeries[i])) vs #\(ColorMath.hexString(fgSeries[j])) 在二色觉下不可分）")
                    }
                }
            }
            for (i, k) in seriesSem.enumerated() {
                // 折线图坐在卡片上、无行叠层 ⇒ 只查纯卡片底（与比例条的双背景口径不同）
                let ct = ColorMath.contrast(fgSeries[i], card)
                checked += 1
                if ct < GRAPHIC_MIN {
                    bad.append("\(tag) 系列 \(k.rawValue) #\(ColorMath.hexString(fgSeries[i])) 对卡片底只有 "
                        + "\(String(format: "%.2f", ct)):1 < \(GRAPHIC_MIN)（底 #\(ColorMath.hexString(card))）")
                }
                let q = ThemeColors.base(k)
                let text: UInt32 = lightMode ? q.light : q.dark
                let dh = abs(ColorMath.hueAngle(fgSeries[i]) - ColorMath.hueAngle(text))
                let dhAdj = min(dh, 360 - dh)
                let dc = abs(ColorMath.chroma(fgSeries[i]) - ColorMath.chroma(text))
                checked += 1
                if dhAdj > 2.0 || dc > 0.01 {
                    bad.append("\(tag) 系列 \(k.rawValue) 相对 text 档偏了 色相 \(String(format: "%.1f", dhAdj))°"
                        + " / 彩度 \(String(format: "%.3f", dc)) —— 系列档**只许挪明度**"
                        + "（#\(ColorMath.hexString(text)) → #\(ColorMath.hexString(fgSeries[i]))）")
                }
            }
        }

        // --- 4) 覆盖数断言：判据空转比没有判据更糟 ---
        // 比例条每组 5 项（1 deutan + 2 对比度 + 2 色相彩度）；系列档每组 14 项（6+4+4）
        let expected = EXPECTED_PAIRS * (1 + 2 + 2) + EXPECTED_PAIRS * (6 + 4 + 4)
        if checked != expected {
            print("❌ 覆盖数 \(checked) ≠ 预期 \(expected)（\(EXPECTED_PAIRS) 组 × (5+14) 项）"
                  + "—— 循环或数据结构变了，本护栏正在空跑")
            exit(2)
        }

        if !bad.isEmpty {
            print(bad.joined(separator: "\n"))
            exit(1)
        }
        print("\(EXPECTED_PAIRS) 组（浅/深）图形档：比例条 + 图表系列 deutan ΔE 全部 ≥ \(DE_TARGET)、"
              + "对卡片底 ≥ \(GRAPHIC_MIN):1、且与 text 档同色相同彩度（只挪明度）"
              + (gamutExempt.isEmpty ? "" :
                 "；豁免 \(gamutExempt.count) 组（\(gamutExempt.sorted().joined(separator: " ")) 在 sRGB 内解不出明度阶梯，"
                 + "靠缝/位置/宽度三条结构通道兜住，实命中 \(exemptHits)）"))
        exit(0)
    }
}
