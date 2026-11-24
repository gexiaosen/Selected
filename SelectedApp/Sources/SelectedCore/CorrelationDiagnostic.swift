import Foundation

/// 加分项同源相关性诊断。
///
/// **要回答的问题**：KD / RSI / MACD 都源自同一条价格序列、高度相关 ——
/// 把三个相关读数当三个**独立**证据去加总，会高估可信度；
/// 「三个指标同时看多」在三者本来就不独立时，并不代表可信度是单指标的三倍。
/// 本项目的评分是「12 加分项 + 6 扣分项」**求和**，其中若干项的底层特征本就同源：
/// 均线多头 / MA20 上翘 / 距低点 / 5 日累计 / 连涨天数 —— 在涨势里它们**一起**变好。
/// 本模块在调优池上算这些特征的 **Spearman 秩相关**，把 |ρ| 超阈值的配对报出来，
/// 让人自己判断"这几项是不是在重复计数"。
///
/// ⚠ **只诊断、不阻断**：不自动调权重、不改评分、不参与任何判定。
///
/// ⚠ **量的是特征，不是实际得分**：每个加分项是特征的**单调阶梯函数**（查表命中档位），
///   单调变换保序但不保幅 —— 所以报出的 |ρ| 是"同源程度的上界"，不等于得分本身的相关。
///   UI 文案必须说清这点，否则会被当成"这两项一定重复"。
///
/// ⚠ **用秩相关而不是皮尔逊**：加分项是阶梯函数，与特征之间是非线性单调关系，
///   皮尔逊会低估；秩相关只依赖次序，正合适。
public enum CorrelationDiagnostic {

    /// 参与诊断的特征（键名与调优池内 `deep` / `form_score` 一致）
    public static let features: [(key: String, label: String)] = [
        ("ma_pass", "均线多头"),
        ("ma20_slope_up", "MA20上翘"),
        ("dist_from_low", "距低点"),
        ("dist_from_high", "距高点"),
        ("cum_5d", "5日累计"),
        ("consec_up", "连涨天数"),
        ("vol_mult_5d", "量能倍数"),
        ("form_score", "K线形态"),
        ("prev_1d", "前日涨幅"),
        ("gain_ratio", "保留度"),
        ("shadow_body_ratio", "影体比"),
    ]

    /// 默认阈值：|ρ| ≥ 0.6 视为"同源提示"。
    ///
    /// ⚠ 按真实数据定的：生产库调优池里最高一对 ρ≈0.68，**没有任何一对达到 0.7** ——
    ///   若取 0.7，本诊断在真实数据上**从不触发**，功能等于不存在（比误报更糟：
    ///   用户以为查过了）。取 0.6 命中数对，与"这些特征本就同源"的先验一致。
    ///   阈值本身是启发式，UI 必须把它显示出来，让用户自己判断。
    public static let defaultThreshold = 0.6
    /// 默认最小样本数。少于这个数，秩相关没有意义（与调优的"建议 ≥30 只"口径一致）
    public static let defaultMinSamples = 30

    public struct Pair: Equatable, Sendable {
        public let key1: String
        public let label1: String
        public let key2: String
        public let label2: String
        /// 已 `round(2)`
        public let rho: Double
        /// 成对完整样本数
        public let n: Int

        public init(key1: String, label1: String, key2: String, label2: String,
                    rho: Double, n: Int) {
            self.key1 = key1; self.label1 = label1
            self.key2 = key2; self.label2 = label2
            self.rho = rho; self.n = n
        }
    }

    /// 平均秩（并列取均值）。
    ///
    /// ⚠ 必须处理并列：池里有大量 0/1 型特征（`ma_pass` / `ma20_slope_up`）与重复值，
    /// 若按"排序后位置"直接当秩，Spearman 会被并列扭曲。
    public static func averageRanks(_ xs: [Double]) -> [Double] {
        let n = xs.count
        guard n > 0 else { return [] }
        // 值相同时按下标稳定排序，保证同 seed 同结果
        let order = (0..<n).sorted { xs[$0] == xs[$1] ? $0 < $1 : xs[$0] < xs[$1] }
        var ranks = [Double](repeating: 0, count: n)
        var i = 0
        while i < n {
            var j = i
            while j + 1 < n && xs[order[j + 1]] == xs[order[i]] { j += 1 }
            let avg = Double(i + j) / 2.0 + 1.0
            for k in i...j { ranks[order[k]] = avg }
            i = j + 1
        }
        return ranks
    }

    /// Spearman 秩相关。
    /// 样本 < 3，或任一序列**常量**（秩方差为 0，相关无定义）→ nil（不猜成 0）。
    public static func spearman(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, a.count >= 3 else { return nil }
        let ra = averageRanks(a), rb = averageRanks(b)
        let n = Double(a.count)
        let ma = PyMath.sum(ra) / n, mb = PyMath.sum(rb) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<a.count {
            let x = ra[i] - ma, y = rb[i] - mb
            num += x * y
            da += x * x
            db += y * y
        }
        guard da > 0, db > 0 else { return nil }
        return num / (da * db).squareRoot()
    }

    /// 逐对诊断：只保留 |ρ| ≥ `threshold` 且成对样本 ≥ `minSamples` 的配对，按 |ρ| 降序。
    ///
    /// `samples` 每项是「特征键 → 值」；**缺键即该样本不参与这一对**（成对完整观测），
    /// 而不是补 0 —— 补 0 会把"没有数据"变成"特征值为 0"，直接污染相关系数。
    public static func diagnose(samples: [[String: Double]],
                                threshold: Double = defaultThreshold,
                                minSamples: Int = defaultMinSamples) -> [Pair] {
        var out: [Pair] = []
        for i in 0..<features.count {
            for j in (i + 1)..<features.count {
                let k1 = features[i].key, k2 = features[j].key
                var xs: [Double] = [], ys: [Double] = []
                for s in samples {
                    guard let x = s[k1], let y = s[k2] else { continue }
                    xs.append(x); ys.append(y)
                }
                guard xs.count >= minSamples, let r = spearman(xs, ys) else { continue }
                guard abs(r) >= threshold else { continue }
                out.append(Pair(key1: k1, label1: features[i].label,
                                key2: k2, label2: features[j].label,
                                rho: PyMath.round(r, 2), n: xs.count))
            }
        }
        return out.sorted { abs($0.rho) > abs($1.rho) }
    }

    /// 诊断结果的落库/传输形态（写进调优结果的 `correlation`）
    public static func json(pairs: [Pair], samples: Int, threshold: Double) -> [String: Any] {
        [
            "threshold": threshold,
            "samples": samples,
            "pairs": pairs.map { p -> [String: Any] in
                ["a": p.key1, "a_label": p.label1,
                 "b": p.key2, "b_label": p.label2,
                 "rho": p.rho, "n": p.n]
            },
            // ⚠ 强调用「」不用 `**`：本串经 `TuneEntities.correlationNote` 取出来是 `String`，
            //   UI 侧 `Text(String)` 走 verbatim、不解析 Markdown → 星号会原样显示给用户。
            "note": "量的是「特征」秩相关，不是实际得分 —— 加分项是特征的单调阶梯函数，"
                + "故这里报的 |ρ| 是同源程度的「上界」。仅作提示，不自动调权重。",
        ]
    }
}
