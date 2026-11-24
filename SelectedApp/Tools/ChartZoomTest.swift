import Foundation

/// 图表缩放 / 铺满数学自检（ChartZoomMath，纯函数、离线）
///
/// 锁的是一条用户可见的不变量：
///   **缩到最小 = 全部已加载历史正好铺满视口，右侧不留空白；任何缩放级别内容都不窄于视口。**
/// 这条不变量容易回归（"缩小后缺数据没日期"、"缩到头右侧仍有空白"），
/// 故把数学抽成 ChartZoomMath 并由本自检钉死。
@main
struct ChartZoomTest {
    private static var failures = 0

    static func main() {
        print("== chart-zoom ==")
        fitFillsViewport()
        fitMonotonic()
        trailingInsetRules()
        spacingRules()
        minuteSlotRules()

        print(failures == 0 ? "✅ chart-zoom：全部断言通过" : "❌ chart-zoom：\(failures) 项断言失败")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 1) 「铺满」不变量（含两个间距模式）

    private static func fitFillsViewport() {
        // 自适应间距（App 的 K 线口径，`adaptiveSpacing: true`）：任何根数都必须**精确铺满**
        for c in [(500, 800), (250, 800), (120, 800), (12, 800), (1000, 900), (1500, 900), (2000, 1200), (5, 400)] {
            assertFit(c.0, CGFloat(c.1), spacing: 2, adaptive: true, expectExact: true)
        }
        // 固定间距：只在"能铺满"的根数下精确（120/250 根在 800pt 内放得下）
        assertFit(120, 800, spacing: 2, adaptive: false, expectExact: true)
        assertFit(250, 800, spacing: 2, adaptive: false, expectExact: true)
        // 固定间距 + 超多根数：宽度触底 0.1pt 也放不下（固有上限）——
        // 此时仍必须"内容不窄于视口"（不许出现空白），但铺满由自适应间距解决
        assertFit(500, 800, spacing: 2, adaptive: false, expectExact: false)
        assertFit(1000, 900, spacing: 2, adaptive: false, expectExact: false)
        // 放大后同样不得出现空白
        let zoomed = ChartZoomMath.contentWidth(
            count: 500, width: 12, configuredSpacing: 2, adaptive: true,
            viewportWidth: 800, configuredInset: 50)
        check(zoomed > 800, "放大后内容宽于视口（实际 \(round2(zoomed))）")
    }

    private static func assertFit(_ count: Int, _ viewport: CGFloat, spacing: CGFloat,
                                  adaptive: Bool, expectExact: Bool) {
        let fit = ChartZoomMath.fitCandleWidth(count: count, viewportWidth: viewport,
                                               configuredSpacing: spacing, adaptive: adaptive)
        let content = ChartZoomMath.contentWidth(count: count, width: fit,
                                                 configuredSpacing: spacing, adaptive: adaptive,
                                                 viewportWidth: viewport, configuredInset: 50)
        let label = "count=\(count) viewport=\(Int(viewport)) adaptive=\(adaptive)"
        check(content >= viewport - 0.5, "\(label)：内容不窄于视口（实际 \(round2(content))）")
        if expectExact {
            check(abs(content - viewport) < 1,
                  "\(label)：精确铺满（内容 \(round2(content)) vs 视口 \(Int(viewport))）")
        } else {
            check(fit == 0.1, "\(label)：宽度触底 0.1pt（固定间距放不下的固有限制，实际 \(round2(fit))）")
        }
    }

    // MARK: - 2) 单调性（根数越多，铺满宽度越小）

    private static func fitMonotonic() {
        let many = ChartZoomMath.fitCandleWidth(count: 1000, viewportWidth: 800,
                                                configuredSpacing: 2, adaptive: true)
        let few = ChartZoomMath.fitCandleWidth(count: 100, viewportWidth: 800,
                                               configuredSpacing: 2, adaptive: true)
        check(many < few, "根数越多铺满宽度越小（1000 根 \(round2(many)) < 100 根 \(round2(few))）")
    }

    // MARK: - 3) 尾部留白：只有内容超出视口才逐步给

    private static func trailingInsetRules() {
        let noOverflow = ChartZoomMath.trailingInset(barsWidth: 400, viewportWidth: 800, configured: 50)
        check(noOverflow == 0, "缩到最小（内容不超视口）→ 留白归零（实际 \(round2(noOverflow))）")
        let full = ChartZoomMath.trailingInset(barsWidth: 1200, viewportWidth: 800, configured: 50)
        check(abs(full - 50) < 0.001, "超出量 ≥ ramp → 给满配置留白（实际 \(round2(full))）")
        let ramp = ChartZoomMath.trailingInset(barsWidth: 880, viewportWidth: 800, configured: 50)
        check(ramp > 0 && ramp < 50, "超出量在 ramp 内 → 线性补齐（实际 \(round2(ramp))）")
        let zeroConfigured = ChartZoomMath.trailingInset(barsWidth: 1200, viewportWidth: 800, configured: 0)
        check(zeroConfigured == 0, "配置为 0（App 的 K 线/分时口径）→ 恒为 0（实际 \(round2(zeroConfigured))）")
        // 留白 = 0 时内容宽必须**恰好等于**全部 K 线宽 —— 最新一根贴右缘，任何缩放级别都无空白
        let noInset = ChartZoomMath.contentWidth(count: 100, width: 8, configuredSpacing: 2,
                                                adaptive: true, viewportWidth: 800, configuredInset: 0)
        check(abs(noInset - 100 * 10) < 0.001,
              "留白=0：内容宽 = 根数 × 步进 = 1000（实际 \(round2(noInset))）")
    }

    // MARK: - 4) 自适应间距规则

    private static func spacingRules() {
        let fixed = ChartZoomMath.spacing(for: 1, configured: 2, adaptive: false)
        check(fixed == 2, "非自适应：间距恒为配置值（实际 \(round2(fixed))）")
        let compressed = ChartZoomMath.spacing(for: 4, configured: 2, adaptive: true)
        check(abs(compressed - 1) < 0.001, "自适应且宽度小：按 25% 压缩（4pt → \(round2(compressed))）")
        let full = ChartZoomMath.spacing(for: 20, configured: 2, adaptive: true)
        check(full == 2, "自适应且宽度大（≥4×间距）：回到配置值（实际 \(round2(full))）")
        let floored = ChartZoomMath.spacing(for: 0.1, configured: 2, adaptive: true)
        check(floored == 0.15, "自适应下限 0.15pt（实际 \(round2(floored))）")
    }

    // MARK: - 工具

    private static func round2(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }

    private static func check(_ cond: Bool, _ msg: String) {
        print(cond ? "   ✅ \(msg)" : "   ❌ \(msg)")
        if !cond { failures += 1 }
    }

    // MARK: - 4) 分时 240 槽「按实测视口铺满」

    /// 分时槽宽原来是写死的 `524/240 - 1`（= "640 详情窗、图表右侧没有盘口列"那一档的解析解）。
    /// 详情页图表右侧加了 168pt 盘口列之后可用宽度只剩 404，写死会让 240 槽画到 524pt
    /// ⇒ 下午那段被推到绘图区外（分时禁缩放，只能平移）。现在改成按实测宽现算，
    /// 这里钉两件事：① 老布局**逐像素不变**（否则等于顺手改了天天看的分时图）；
    /// ② 新布局严格铺满（不溢出、不留白）。
    private static func minuteSlotRules() {
        let legacy: CGFloat = 524.0 / 240 - 1
        // ① 无右列那一档：绘图区 524 ⇒ 解析解必须与旧常量逐位相同
        let sameAsLegacy = ChartZoomMath.fitCandleWidth(count: 240, viewportWidth: 524,
                                                        configuredSpacing: 1, adaptive: false)
        check(abs(sameAsLegacy - legacy) < 1e-9,
              "分时：640 窗无右列时与旧写死常量逐位相同（\(round2(sameAsLegacy)) vs \(round2(legacy))）")
        // ② 有右列那一档：图表实测 404 − Y 轴列 56 = 348 ⇒ 240 槽步进 × 240 必须正好 348
        let narrow = ChartZoomMath.fitCandleWidth(count: 240, viewportWidth: 348,
                                                  configuredSpacing: 1, adaptive: false)
        let filled = 240 * (narrow + 1)
        check(abs(filled - 348) < 0.5,
              "分时：挤到 404pt 图表宽时 240 槽严格铺满 348（实得 \(round2(filled))，不再溢出）")
        check(narrow > 0, "分时：窄视口下槽宽仍为正（\(round2(narrow))）")
        // ③ 边界（**已知会溢出**，写清楚不掩盖）：绘图区小于 240×(0.1+1)=264pt 时
        //    槽宽触底 0.1pt，内容仍宽于视口 ⇒ 只能靠平移看全。详情窗宽 640 不会走到这里。
        let floor = ChartZoomMath.fitCandleWidth(count: 240, viewportWidth: 200,
                                                 configuredSpacing: 1, adaptive: false)
        check(floor == 0.1, "分时：绘图区 < 264pt 时槽宽触底 0.1pt（此档会溢出，登记为已知边界）")
    }

}