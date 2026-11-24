import Foundation

/// 折线**末端直接标注**的落位与回落判定（纯几何，不碰绘图框架）。
///
/// ## 为什么要把这一步放进 Core
/// 多层折线本来靠一条图例（圆点 + 层名）说明哪条线是谁，读者要在图和图例之间来回比对。
/// 改成把层名直接标在线尾，省掉那条带子，代价是一个新风险：
/// **几条线的终点挨得太近时，标签会叠成一块糊字** —— 比图例更糟，而且是那种"看着像坏了"的糟。
///
/// 所以规则必须能用数字说死：
///   1. 标签中心两两至少隔 `minGap` 像素；
///   2. 挤的时候自上而下推开；推开后**越过下边界**就改自下而上压回；
///   3. 任一标签离它自己的线尾超过 `maxDrift` 像素 ⇒ **不再画标签，整组回落到图例**。
///      标签离了本尊就是骗人，宁可退回图例，也不能"凑合标"。
///
/// 这三条里 ① ③ 都是纯判据、没有 UI 参与 ⇒ 放这里，`TrendLabelLayoutTests` 用手算整数钉死；
/// 视图侧只负责把算出来的 y 画出来（`ReviewView` 的四层胜率走势）。
public enum TrendLabelLayout {

    /// 一个待标注的线尾：`id` 由调用点解释（层 key），`value` 是**数据值**（不是像素）
    public struct Anchor: Equatable {
        public let id: String
        public let value: Double
        public init(id: String, value: Double) {
            self.id = id
            self.value = value
        }
    }

    /// 落位结果：`y` = 标签中心距绘图区**顶部**的像素，`drift` = 相对真实终点的位移（≥0）
    public struct Placed: Equatable {
        public let id: String
        public let y: Double
        public let drift: Double
    }

    public enum Outcome: Equatable {
        /// 按**输入顺序**返回（调用点可按下标与自己的层数组对齐）
        case labels([Placed])
        /// 挤不下 ⇒ 一条标签都不画，调用点回落到图例
        case crowded
    }

    /// - Parameters:
    ///   - domain: y 轴数据域（本项目四层胜率固定 `0...100`，线性）
    ///   - plotHeight: 绘图区高度（像素，不含坐标轴带）
    ///   - minGap: 相邻标签中心的最小间距
    ///   - maxDrift: 允许的最大位移，超过即判 `crowded`
    ///   - inset: 上下留白（半张标签高，防止贴边被裁）
    public static func place(anchors: [Anchor],
                             domain: ClosedRange<Double>,
                             plotHeight: Double,
                             minGap: Double,
                             maxDrift: Double,
                             inset: Double) -> Outcome {
        guard anchors.count > 1 else {
            // 0 条或 1 条：不可能互相挤，单条只需夹进边界
            if anchors.isEmpty { return .labels([]) }
            guard plotHeight > 0, domain.upperBound > domain.lowerBound else { return .crowded }
            let y = rawY(anchors[0], domain: domain, plotHeight: plotHeight, inset: inset)
            return .labels([Placed(id: anchors[0].id, y: y, drift: 0)])
        }
        guard plotHeight > 0, domain.upperBound > domain.lowerBound else { return .crowded }

        let target = anchors.map { rawY($0, domain: domain, plotHeight: plotHeight, inset: inset) }
        // 上→下顺序的下标（同值按下标定序，保证结果可复现）
        let order = target.indices.sorted { a, b in
            target[a] != target[b] ? target[a] < target[b] : a < b
        }
        var y = target
        for k in 1..<order.count {
            y[order[k]] = max(y[order[k]], y[order[k - 1]] + minGap)
        }
        let lowest = order.last!
        if y[lowest] > plotHeight - inset {
            // 往下推已经顶出下边界 ⇒ 从下往上压回，先看最底下那条贴住边界
            y[lowest] = plotHeight - inset
            var k = order.count - 2
            while k >= 0 {
                y[order[k]] = min(y[order[k]], y[order[k + 1]] - minGap)
                k -= 1
            }
            if y[order.first!] < inset { return .crowded }   // 上面也没地方了
        }
        var placed: [Placed] = []
        placed.reserveCapacity(anchors.count)
        for i in anchors.indices {
            let drift = abs(y[i] - target[i])
            if drift > maxDrift { return .crowded }
            placed.append(Placed(id: anchors[i].id, y: y[i], drift: drift))
        }
        return .labels(placed)
    }

    /// 数据值 → 像素（值大靠上），并夹在 `[inset, plotHeight - inset]` 内
    private static func rawY(_ anchor: Anchor, domain: ClosedRange<Double>,
                             plotHeight: Double, inset: Double) -> Double {
        let t = (domain.upperBound - anchor.value) / (domain.upperBound - domain.lowerBound)
        return min(max(t * plotHeight, inset), plotHeight - inset)
    }
}
