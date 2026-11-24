import Foundation

/// 图表横向缩放 / 「铺满视口」的纯计算（无 UI 依赖）
///
/// 为什么单独抽出来：这段数学历史上回归过两次 ——
///   · 2026-09-18「缩小到一定程度缺数据、没日期」：可视窗口与绘制用了两套间距；
///   · 2026-09-20「缩到最小右侧仍有空白」：`fitCandleWidth` 用两次迭代近似（内容比视口
///     窄 20~30pt），且把尾部留白也算进了铺满宽度（再多 50pt 空隙）。
/// 抽成纯函数后由 `SelectedApp/Tools/ChartZoomTest.swift` 离线断言，
/// 保证「缩到最小 = 全部已加载历史无缝铺满」这条不变量不再破。
public enum ChartZoomMath {
    /// 自适应间距：宽度小于 4×配置间距时按 25% 同步压缩（下限 0.15pt）。
    /// 放大到宽度 ≥ 4×间距 时与配置值完全一致（常规缩放观感不变）。
    public static func spacing(for width: CGFloat, configured: CGFloat, adaptive: Bool) -> CGFloat {
        guard adaptive else { return configured }
        return max(0.15, min(configured, width * 0.25))
    }

    /// 生效的尾部留白：只有**内容超出视口**时才逐步给（缩到最小 → 0，无缝铺满）。
    ///
    /// 固定留白会在"缩到最小"时留下一块永远填不满的空隙（用户 2026-09-20 报的
    /// "右边出现空白"）。这里按超出量在 `ramp` 内线性补齐，缩放时不会突跳。
    /// ⚠ 自选/个股详情的 K 线现在**传 0**（用户要求任何级别都无空白）；
    ///   本能力留给将来需要"最新一根右侧留呼吸位"的场景。
    public static func trailingInset(barsWidth: CGFloat, viewportWidth: CGFloat,
                                     configured: CGFloat, ramp: CGFloat = 160) -> CGFloat {
        guard configured > 0 else { return 0 }
        guard viewportWidth > 0 else { return configured }   // 首帧尚未拿到视口宽：先按配置值
        let overflow = barsWidth - viewportWidth
        guard overflow > 0 else { return 0 }
        return configured * min(1, overflow / ramp)
    }

    /// 内容总宽（全部 K 线 + 生效尾部留白）—— 画布宽度与滚动偏移换算的唯一基准
    public static func contentWidth(count: Int, width: CGFloat, configuredSpacing: CGFloat,
                                    adaptive: Bool, viewportWidth: CGFloat,
                                    configuredInset: CGFloat) -> CGFloat {
        let step = width + spacing(for: width, configured: configuredSpacing, adaptive: adaptive)
        let barsWidth = CGFloat(count) * step
        return barsWidth + trailingInset(barsWidth: barsWidth, viewportWidth: viewportWidth,
                                         configured: configuredInset)
    }

    /// 「恰好铺满视口」对应的蜡烛宽（**解析解**，不是迭代近似）
    ///
    /// 自适应间距下 spacing = max(0.15, min(s, w*0.25))，三条分支分别求解：
    ///   · 触底区（w < 0.6，spacing 触及 0.15 下限）：count × (w + 0.15) = viewport → w = perBar - 0.15
    ///   · 压缩区（0.6 ≤ w < 4s）：count × 1.25w = viewport → w = perBar / 1.25
    ///   · 常规区（w ≥ 4s）：count × (w + s) = viewport → w = perBar - s
    /// 铺满时尾部留白必然为 0（`trailingInset` 在无溢出时归零），故方程不含留白项。
    public static func fitCandleWidth(count: Int, viewportWidth: CGFloat,
                                      configuredSpacing: CGFloat, adaptive: Bool) -> CGFloat {
        guard count > 0, viewportWidth > 0 else { return 0 }
        let perBar = viewportWidth / CGFloat(count)
        guard adaptive else { return max(0.1, perBar - configuredSpacing) }
        let floorThreshold = min(configuredSpacing, 0.15)
        let compressed = perBar / 1.25
        if compressed * 0.25 < floorThreshold {
            return max(0.1, perBar - floorThreshold)
        }
        if compressed < configuredSpacing * 4 { return max(0.1, compressed) }
        return max(0.1, perBar - configuredSpacing)
    }
}