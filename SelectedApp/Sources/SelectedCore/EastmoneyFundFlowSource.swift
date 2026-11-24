import Foundation

/// 个股资金流（**东财口径**）—— 独立在册，**不是新浪那条的备用源**。
///
/// ## 为什么不能和 `FundFlowSource` 合并成"双源"
/// 2026-11-02 同日同票逐字段核对（600000 浦发银行，新浪历史端点 vs 东财 `fflow/daykline`）：
///
/// | 日期 | 新浪 `r0_net` | 东财 主力净流入 | 差 |
/// |------|--------------|----------------|----|
/// | 10-23 | -39,701,734.84 | -85,856,115 | 46,154,380 |
/// | 10-26 | +32,889,390.45 | -77,455,847 | 110,345,237（**反号**）|
/// | 10-29 | +38,236,488.06 | +74,623,998 | -36,387,510 |
/// | 10-30 | -17,866,501.02 | +7,525,885 | -25,392,386（**反号**）|
///
/// 两家都叫"主力净流入"，但**大单/特大单的分档阈值与主动买卖认定规则不同** ⇒ 同一天的数
/// 可以差到反号。把东财的行写进 `stock_fund_flows.main_net` 那一列，等于**同一列里混两种定义**，
/// 而且没有任何测试能发现（数字看着都正常）。所以：
///   · 本类型的值**永不写入** `stock_fund_flows`；
///   · 数据集在 `DataSourceRegistry` 里**单独立册**（`.eastmoneyFundFlow`），与 `.fundFlow` 并列；
///   · 要上界面就必须带"东财口径"字样，与新浪那条分开显示。
///
/// ## 单位（已按项目口径归一）
/// 东财给的是**百分数**（涨跌幅 `0.30` = +0.30%、占比 `1.16` = 1.16%），
/// 而 `FundFlowPoint.changePct` / `mainRatio` 全项目是**小数** ⇒ 解析时 ÷100，
/// 与新浪那条同口径（新浪 10-30 的 `changeratio` = `0.003003`，东财 `0.30` ÷100 = `0.0030` ✓ 对得上）。
/// 净额单位是**元**。
///
/// ## 恒等式（用来钉住字段顺序，接口改版时会立刻报红）
/// · 主力净流入 = 大单 + 超大单（实测 600000 于 10-30：-12,045,144 + 19,571,029 = 7,525,885 ✓）
/// · 小单 + 中单 + 主力 ≈ 0（10-30 那天正好为 0；09-21 差 2 元 —— 各档分别四舍五入到元）
///   ⇒ 东财**没有"总净流入"这个概念**（它把全市场看成零和），所以本类型不提供 `netAmount`；
///     新浪那条的 `netamount` 是 `inamount - outamount`，两者不可对照。
public enum EastmoneyFundFlowSource {

    /// 一天一行（东财口径）。
    public struct Point: Equatable, Sendable {
        /// 交易日 `yyyy-MM-dd`
        public let date: String
        /// 6 位代码（不带市场前缀）
        public let code: String
        public let close: Double
        /// 涨跌幅（**小数**）
        public let changePct: Double
        /// 主力净流入（元）= 大单 + 超大单（**东财口径**，与新浪 `r0_net` 不同义）
        public let mainNet: Double
        /// 超大单净流入（元）
        public let superLargeNet: Double
        /// 大单净流入（元）
        public let largeNet: Double
        /// 中单净流入（元）
        public let mediumNet: Double
        /// 小单净流入（元）
        public let smallNet: Double
        /// 主力净占比（**小数**）
        public let mainRatio: Double

        public init(date: String, code: String, close: Double, changePct: Double,
                    mainNet: Double, superLargeNet: Double, largeNet: Double,
                    mediumNet: Double, smallNet: Double, mainRatio: Double) {
            self.date = date
            self.code = code
            self.close = close
            self.changePct = changePct
            self.mainNet = mainNet
            self.superLargeNet = superLargeNet
            self.largeNet = largeNet
            self.mediumNet = mediumNet
            self.smallNet = smallNet
            self.mainRatio = mainRatio
        }
    }

    /// 详情页默认取多少天（与新浪那条保持同一个默认值）
    public static let defaultHistoryDays = 20
    /// 单次最多取多少天（东财 `lmt` 给到多少没实测过上限，这里按需求夹住）
    public static let maxDays = 250

    static let host = DataSourceEndpoints.eastmoneyPush2His
    static let referer = DataSourceEndpoints.eastmoneyReferer

    /// `fields2` 的顺序就是解析依赖的字段顺序（f51…f65）。
    static let fields2 = "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61,f62,f63,f64,f65"

    /// 个股近 `days` 个交易日（**按日期升序**）。取不到返回 `[]`。
    public static func fetchHistory(code: String, days: Int = defaultHistoryDays) -> [Point] {
        DataSourceRegistry.timed(.eastmoneyFundFlow) {
            guard let url = historyURL(code: code, days: days), days > 0 else { return nil }
            defer { DataSources.throttleAfterNetwork() }      // push2* 家族必须全局限速
            guard let text = DataSources.httpGet(url, referer: referer) else {
                DataSources.logDataSource("eastmoney", "fflow_fail",
                                          "\(code)："
                                            + (DataSources.lastFetchFailureReason(matching: url) ?? "无响应"))
                return nil
            }
            let rows = parseHistory(text, code: code)
            if rows.isEmpty {
                // HTTP 200 但一行都没有：要么这只票没有资金流数据，要么接口改版 —— 两者都得留痕
                DataSources.logDataSource("eastmoney", "fflow_empty",
                                          "\(code) 解析不出任何一天（响应 \(text.count) 字符）")
                return nil
            }
            return rows
        } ?? []
    }

    /// 端点 URL。`secid` 的沪深/北交所编号口径见 `DataSources.marketOf`。
    public static func historyURL(code: String, days: Int) -> String? {
        guard DataSourceEndpoints.isSixDigitCode(code) else { return nil }
        let span = max(1, min(days, maxDays))
        return host + "/api/qt/stock/fflow/daykline/get?lmt=\(span)&klt=101"
            + "&secid=\(DataSources.marketOf(code)).\(code)"
            + "&fields1=f1,f2,f3,f7&fields2=\(fields2)"
            + "&ut=" + DataSourceEndpoints.eastmoneyUT
    }

    /// 响应 → 升序序列（纯函数，单测入口）。
    ///
    /// 行形状：`yyyy-MM-dd,主力,小单,中单,大单,超大单,主力占比,小单占比,中单占比,大单占比,
    /// 超大单占比,收盘价,涨跌幅,…`（**东财自己就是按这个顺序给的**，不是我们挑的）。
    /// 单行字段不足 / 日期不合法 → 跳过该行（不整批作废）。
    public static func parseHistory(_ text: String, code: String) -> [Point] {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let klines = payload["klines"] as? [String] else { return [] }
        var out: [Point] = []
        for line in klines {
            let f = line.components(separatedBy: ",")
            guard f.count >= 13, isDay(f[0]),
                  let mainNet = decimal(f[1]), let smallNet = decimal(f[2]),
                  let mediumNet = decimal(f[3]), let largeNet = decimal(f[4]),
                  let superLargeNet = decimal(f[5]), let mainRatio = decimal(f[6]),
                  let close = decimal(f[11]), let changePct = decimal(f[12]) else { continue }
            out.append(Point(date: f[0], code: code, close: close,
                             changePct: changePct / 100.0,
                             mainNet: mainNet, superLargeNet: superLargeNet,
                             largeNet: largeNet, mediumNet: mediumNet, smallNet: smallNet,
                             mainRatio: mainRatio / 100.0))
        }
        return out
    }

    /// 东财给的数就是升序（实测 10-21 … 10-30 顺序给出），这里**不做反转**；
    /// 与新浪那条（DESC，必须反转）的区别写在这里，避免以后有人"顺手对齐"。
    static func isDay(_ s: String) -> Bool {
        guard s.count == 10, s[s.index(s.startIndex, offsetBy: 4)] == "-",
              s[s.index(s.startIndex, offsetBy: 7)] == "-" else { return false }
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { c in c.isASCII && c.isNumber } }
    }

    /// 数值字段（缺失 / 非法 / inf / nan → nil；`Num.doubleOrNil` 已把后三者折掉）。
    static func decimal(_ s: String) -> Double? { Num.doubleOrNil(s) }
}
