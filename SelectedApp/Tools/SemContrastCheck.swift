import Foundation
import SwiftUI

// 语义色的 WCAG 对比度检查 —— 护栏 `sem_contrast` 的实现（纯 Swift，全仓零 Python）。
//
// ⚠ **实现方式在 2026-10-21 换过一次，理由是"护栏空转比没有护栏更糟"**：
//   旧版用正则从 `Tokens.swift` 里抽 `static let X = Color.adaptive(light: Color(hex: …))`。
//   色值搬进 `Palette.swift` 之后，旧版抽到 0 个色 —— 它**报了红**（这算运气好）；
//   只要结构变化刚好让正则匹配到空集合又写了 `>= 0` 之类的判据，它就会静默通过。
//   ⇒ 现在**直接链接 `Palette.swift` / `Tokens.swift` 真类型**，遍历 `SemKey.allCases`。
//     解析器与数据结构之间不再有"漂移"这一类错误：加一个 SemKey 本检查自动覆盖到；
//     漏给颜色则编译不过（`base(_:)` 是穷尽 switch）。
//
// **判据**：四档（浅 / 深 / 高对比度浅 / 高对比度深）全部 ≥ **4.5:1**。
//   这些色都用来显示**文字**，不是仅图形 ⇒ 不能用 3.0。
// **背景**：单套色值的卡片底（`ThemeColors.neutral(dark:).card`）之上叠 `Tok.rowAlphas`。
//   深色底是**实机取像素**的卡片底，不是"把行底色叠在近黑上"；后者会虚高约 1.4 倍。
//
// **色相不能改**：改色相会把一种语义变成另一种（警示橙偏红就成了「危险」）。
//   只允许同色相再拉开一档明度（浅更深、深更亮）—— 本文件的豁免项也只能这么修。
//
// 退出码：
//   0 = 达标（含"豁免项仍在豁免表内且数量没涨"）
//   1 = 有不达标 / 豁免表过期（已修好的项没被删掉）
//   2 = 抽取失败（结构变了 / 工具链缺失）—— 护栏必须报红，不能静默通过
//
// 用法：SemContrastCheck [--count]

let targetRatio = 4.5
let slotLabels = ["light": "浅", "dark": "深", "hcLight": "浅HC", "hcDark": "深HC"]

func fail(_ msg: String) -> Never {
    print(msg)
    exit(2)
}

func hexValueOf(_ q: Quad, _ slot: String) -> UInt32? {
    switch slot {
    case "light": return q.light
    case "dark": return q.dark
    case "hcLight": return q.hcLight
    case "hcDark": return q.hcDark
    default: return nil
    }
}

// MARK: - 豁免表（**只准变短**）
//
// 深色档改造前的色值，是在"深色卡片底 ≈ 近黑"这个**错误前提**下定的；
// 换成实机测得的卡片底之后 `up` 只有 4.01、`brand`/`selection` 只有 3.37。
// 2026-10-22 已修：抬亮 text 位（up→#FB6D5D、brand→#6199F9），
// 同时给"系统配白字"的 `btnPrimary`/`btnDangerFilled` 拆出 **fill 位钉住原色**
// （否则白字会从 3.88 掉到 2.83）⇒ 按钮像素不变、文字达标。清单归零。
//
// ⚠ 这张表是**棘轮**：
//   · 出现表外的新不达标项 ⇒ 立即报红（不许靠加豁免来过关）
//   · 表里的项被修好了 ⇒ 也报红（逼着把豁免删掉，否则清单只会变长不会变短）
// 格式："语义槽位/档位"
let legacyExempt: Set<String> = []  // 2026-10-22 清空：深色档已用 text/fill 分档修达标

@main
struct SemContrastCheck {
    static func main() {
        let keys = SemKey.allCases
        var checked = 0
        var bad: [String] = []
        var exemptHits = 0

        // ⚠ 槽位必须与**外观档**配对：`light`/`hcLight` 是浅色档的取值，只能跟浅色卡片底比；
        //   拿浅色文字去比深色底会得到 1.7:1 这种荒谬数字（第一版就犯了这个错）。
        for (lightMode, slots) in [(true, ["light", "hcLight"]), (false, ["dark", "hcDark"])] {
            let n = ThemeColors.neutral(dark: !lightMode)
            let base = n.card
            let a = Tok.rowAlphas
            for k in keys {
                let q = ThemeColors.base(k)
                for slot in slots {
                    let alpha = slot == "light" ? a.light : (slot == "hcLight" ? a.hcLight
                                            : (slot == "dark" ? a.dark : a.hcDark))
                    let bg = ColorMath.overlay(alpha, over: base, lightMode: lightMode)
                    guard let fg = hexValueOf(q, slot) else { continue }
                    checked += 1
                    let r = ColorMath.contrast(fg, bg)
                    let id = "\(k.rawValue)/\(slot)"
                    if r < targetRatio {
                        if legacyExempt.contains(id) { exemptHits += 1 }
                        else {
                            bad.append(String(format: "%@/%@ #%@ → %.2f:1（<%.1f，底 #%@）",
                                              k.rawValue, slotLabels[slot] ?? slot,
                                              ColorMath.hexString(fg), r, targetRatio, ColorMath.hexString(bg)))
                        }
                    } else if legacyExempt.contains(id) {
                        bad.append("⚠ 豁免项已达标，请把它从 legacyExempt 删掉（豁免清单只准变短）：\(id)")
                    }
                }
            }
        }

        if CommandLine.arguments.contains("--count") {
            print(checked)
            exit(0)
        }

        if !bad.isEmpty {
            print(bad.joined(separator: "\n"))
            exit(1)
        }

        print("单套配色 × \(keys.count) 个语义槽位 × 四档 = \(checked) 项，"
              + "全部 ≥ \(targetRatio):1（背景=卡片底叠 Tok.row，深色底为实机取像素值）"
              + (legacyExempt.isEmpty ? "" : "；豁免 \(legacyExempt.count) 项（只准变短）"))
        exit(0)
    }
}
