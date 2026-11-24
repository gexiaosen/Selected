import Foundation

/// 全市场涨跌家数（大盘环境里的「涨跌家数比」`涨:平:跌`）。
///
/// ## 口径
///
/// **严格按涨跌额符号**判定（与东财 / 同花顺 / 通达信的标准涨跌家数一致）：
///
/// | 判定 | 条件 |
/// |------|------|
/// | 涨 | `现价 > 昨收` |
/// | 跌 | `现价 < 昨收` |
/// | 平 | `现价 == 昨收`（含停牌：最新价就是昨收） |
///
/// `现价 <= 0` 或 `昨收 <= 0` 的行情**不参与统计**。
///
/// ⚠ 不用百分比死区判平盘：一跳的百分比取决于价格（3 元股一跳 0.33%、
/// 1600 元股一跳 0.0006%），死区等于给不同价位的股票不同的"平盘"定义。
///
/// ⚠ 这不只是显示口径：`ratio = up / down` 是评分输入（`ratio_ok` →
/// `scoring.bonus.market_ok_ok`，阈值 0.8），比值贴近阈值时会改变分档。
public enum MarketBreadth {

    /// 涨 / 平 / 跌家数
    public struct Counts: Equatable, Sendable {
        public var up: Int = 0
        public var down: Int = 0
        public var flat: Int = 0

        public init(up: Int = 0, down: Int = 0, flat: Int = 0) {
            self.up = up
            self.down = down
            self.flat = flat
        }

        /// 参与统计的只数（现价与昨收都 > 0 的那些）
        public var total: Int { up + down + flat }
    }

    /// 统计涨跌家数（口径见类型文档）
    public static func counts(_ quotes: [String: EngineQuote]) -> Counts {
        var c = Counts()
        for q in quotes.values {
            guard q.price > 0, q.preClose > 0 else { continue }
            if q.price > q.preClose { c.up += 1 }
            else if q.price < q.preClose { c.down += 1 }
            else { c.flat += 1 }
        }
        return c
    }

    /// 涨跌比 `up / down`；`down == 0` 时返回 `999`。
    ///
    /// ⚠ `999` 是落库的既有除零分支值，不要"顺手改成 0 或 nil"。
    /// ⚠ 落库时要保留 int/float 形态差异（`999` 保持 int），见 `Screener.buildMarketEnv` 里的注释。
    public static func ratio(_ c: Counts) -> Double {
        c.down > 0 ? Double(c.up) / Double(c.down) : 999
    }
}
