import Foundation

/// 历史日K —— 供「历史日期批量重跑」重建历史某天的全市场数据
///
/// ## 为什么需要它
/// 「跑任意历史日期」要求能重建**历史某一天的全市场行情**。而硬过滤要吃
/// 涨幅 / 振幅 / 成交额 / 换手率 / 量比 —— 现用的新浪日K**只有 OHLCV**，缺其中 3 项。
/// 东财 kline 端点一次请求就能给出含这些字段、且按**日期区间**取的日K。
///
/// ## 端点与字段口径（真实请求验过）
/// ```
/// https://push2his.eastmoney.com/api/qt/stock/kline/get
///   ?secid=1.600519&fields1=f1,f2,f3,f4,f5,f6
///   &fields2=f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61
///   &klt=101&fqt=1&beg=20220101&end=20500101
/// → 字段下标：
///   f51 日期 / f52 开 / f53 收 / f54 高 / f55 低 / f56 量(手) / f57 额(元)
///   f58 振幅% / f59 涨跌幅% / f60 涨跌额 / f61 换手率%
/// ```
/// 指数同端点（`secid=1.000001`）。北交所（`0.920427` 写法）可用。
///
/// ## ⚠ 与新浪日K的三条口径差异（会静默出错的地方）
/// 1. **含当日 bar**：新浪 `scale=240` 盘中**不含**当日（见 `DataSourcesKline.swift` 文件头）；
///    东财含，且当日那根是**盘中未走完**的部分数据。
///    → 两者**不可互换**；本模块只服务回放，且**回放日必须早于今天**（当日 bar 不完整）。
/// 2. **前复权（`fqt=1`）**：价格是复权价，而量 / 额 / 换手率是**原始值**（复权只改价格）。
///    所以跨除权日时 `close` 序列自洽（可直接用前一根 `close` 当 `pre_close`），
///    但**成交额不能被复权缩放** —— 与 live 口径一致。
/// 3. **单位差异**：东财 `amount` 是**元**，而腾讯行情的 `amount` 是**万元**
///    （`DataSourcesKline.swift` 文件头）。缓存里存**东财原值（元）**，
///    折算成引擎口径放在重建层（`HistoryReplay.quote`）—— 存原始值、在边界处换算。
///
/// ## 解析纪律
/// **全有或全无**：任一行字段数不足 / 非数值 → 整体返回 `[]` ——
/// 半截数据比没有数据更危险（会被当成"完整的一天"）。
public struct HistoryBar: Equatable, Sendable {

    /// 个股是 6 位代码（不带市场前缀）；**指数是引擎符号**（`sh000001`，见 `fetchIndex`）
    public let code: String
    /// 交易日 `yyyy-MM-dd`
    public let day: String
    public let open: Double
    public let close: Double
    public let high: Double
    public let low: Double
    /// 成交量（**手**，东财原值）
    public let volume: Double
    /// 成交额（**元**，东财原值 —— 引擎口径是万元，换算见 `HistoryReplay.quote`）
    public let amount: Double
    /// 振幅（%，东财原值）
    public let amplitude: Double
    /// 涨跌幅（%，东财原值）
    public let changePct: Double
    /// 换手率（%，东财原值）
    public let turnover: Double

    public init(code: String, day: String, open: Double, close: Double,
                high: Double, low: Double, volume: Double, amount: Double,
                amplitude: Double, changePct: Double, turnover: Double) {
        self.code = code
        self.day = day
        self.open = open
        self.close = close
        self.high = high
        self.low = low
        self.volume = volume
        self.amount = amount
        self.amplitude = amplitude
        self.changePct = changePct
        self.turnover = turnover
    }

    /// 供引擎用的 OHLCV 视图（`HistoryBar` 是它的**超集**，多出额/振幅/换手率）。
    /// 回放模式下 `DataSources.fetchDailyKline` 就是靠这个把缓存喂给引擎的。
    public var klineBar: KLineBar {
        KLineBar(day: day, open: open, high: high, low: low, close: close, volume: volume)
    }
}

/// 指标库直接吃 `HistoryBar`（P1 快照 Job 用；字段天然满足协议，volume=手 与
/// `daily_bars` 落库单位一致 —— **不要**绕道 `klineBar`：那层为引擎另有单位换算，
/// 快照链路必须保持"手"贯通，FI/EMV/MFV 的量纲才不错）。
extension HistoryBar: OHLCBar, VolumeBar {}

/// 东财历史日K的**抓取 + 纯解析**。
///
/// 抓取与解析**分开**：`parse` 是纯函数（可单测，不需要网络），`fetch` 只是
/// 「拼 URL → `httpGet` → `parse`」三步。这与 `FundFlowSource` / `LhbSource` 同构。
public enum HistoryBarsSource {

    static let host = DataSourceEndpoints.eastmoneyPush2His
    /// 东财对 `quote.eastmoney.com` 来源有防盗链；不带 Referer 也能返回，但带上更稳
    static let referer = DataSourceEndpoints.eastmoneyReferer

    /// `f51..f61` —— 顺序即解析时的下标（**不要重排**）
    static let fields = "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61"

    /// 东财 `secid` = `<market>.<code>`，`market` 1=沪 0=深/北。
    /// 与 `DataSources.marketOf` **同一口径**（6 开头 → 1，其余 → 0），北交所同样可用。
    public static func secid(_ code: String) -> String {
        "\(DataSources.marketOf(code)).\(code)"
    }

    /// 拼 URL。`beg` / `end` 用 `yyyy-MM-dd`（会自动去掉横线 —— 东财要 `yyyyMMdd`）。
    /// `adjust` = 是否前复权：个股 `true`（`fqt=1`），**指数 `false`**（指数无复权概念）。
    public static func url(secid: String, beg: String, end: String, adjust: Bool) -> String {
        let b = beg.replacingOccurrences(of: "-", with: "")
        let e = end.replacingOccurrences(of: "-", with: "")
        return host + "/api/qt/stock/kline/get?secid=\(secid)"
            + "&fields1=f1,f2,f3,f4,f5,f6&fields2=\(fields)"
            + "&klt=101&fqt=\(adjust ? 1 : 0)&beg=\(b)&end=\(e)"
    }

    /// 抓个股日K（前复权）。
    ///
    /// **失败 / 无数据 → `[]`，不回落任何其它数据源。**
    /// 这条是回放正确性的地基：一旦回落到实时网络，就会「拿今天的 K 线冒充历史」，
    /// 而且**不会报错**（与 fixture 层那条静默回落是同一类风险）。
    ///
    /// ⚠ **抓完必须节流**：`HistoryReplayJob` 是
    /// `concurrentPerform(concurrency: 6)` + **每票一次请求**（5000+ 票）——
    /// 没有全局限速时连发会把出口 IP 送进东财 `push2*` 的限流名单
    /// （真实发生过：一次下载 1904 个 URL 全失败，此后同族的基本面/板块刷新几乎全被拒）。
    /// 走 `throttleAfterNetwork()`：默认 0.05s，6 并发下 5000 票约多花 40 秒；
    /// fixture 模式为 0，离线跑批一秒不付。
    public static func fetch(_ code: String, beg: String, end: String) -> [HistoryBar] {
        let u = url(secid: secid(code), beg: beg, end: end, adjust: true)
        guard let text = DataSources.httpGetWithHostFallback(u, referer: referer) else { return [] }
        DataSources.throttleAfterNetwork()
        // ⚠ 窗口外的行必须丢（2026-10-16 审查 B4）：请求里本来就带了 `beg`/`end`，
        //   源却可能返回越界甚至未来的日期（字段错位 / 半截响应 / 该票停牌后仍返回旧行）。
        //   不丢的话它会被写进 `daily_bars` 并被 `markCoverage` 冻结为"已覆盖"，
        //   回放再也不会重抓 —— 而 `yyyy-MM-dd` 的字符串序就是时间序，比较成本为零。
        let bars = parse(text, code: code)
        guard !beg.isEmpty, !end.isEmpty else { return bars }
        return bars.filter { $0.day >= beg && $0.day <= end }
    }


    /// 指数的 `secid`：`sh000001` → `1.000001`，`sz399001` → `0.399001`。
    ///
    /// ⚠ 与 `secid(_:)` **不是同一套规则**，不能互相替代：那个按「6 开头 → 沪」判个股，
    /// 而指数代码 `000001` 以 0 开头 → 会拼出 `0.000001`（**深市 000001 = 平安银行**），
    /// 拿到的是一只有的票的数据、格式完全合法、只是**不是指数**。
    public static func secidIndex(_ symbol: String) -> String {
        let s = symbol.lowercased()
        if s.hasPrefix("sh") { return "1." + s.dropFirst(2) }
        if s.hasPrefix("sz") { return "0." + s.dropFirst(2) }
        // 没带市场前缀 → 退回个股规则（北交所 `0.920427` 那类写法）
        return secid(symbol)
    }

    /// 抓指数日K（**不复权**）。`symbol` 用引擎既有写法 `sh000001` / `sz399001`。
    ///
    /// ⚠ 返回的 bar 里 `code` 存的是**引擎符号本身**（`"sh000001"`），不是裸代码。
    /// 这不是笔误：`HistoryBarStore.indexBars(symbol:)` / `bar_coverage` 都用
    /// `DataSources.fetchIndexDailyKline(symbol: "sh000001")` 那个写法当键。
    /// 若这里存 `"000001"`，写入与读取的键就永远对不上 —— 而且**读侧只会安静地返回空**，
    /// 表现为"回放日没有指数数据"，看不出是键错。
    public static func fetchIndex(_ symbol: String, beg: String, end: String) -> [HistoryBar] {
        let u = url(secid: secidIndex(symbol), beg: beg, end: end, adjust: false)
        guard let text = DataSources.httpGetWithHostFallback(u, referer: referer) else { return [] }
        DataSources.throttleAfterNetwork()      // 与 `fetch` 同一条（见那里说明）
        return parse(text, code: symbol)
    }

    /// 纯解析（可单测）。输入是东财的完整 JSON 响应体。
    ///
    /// 返回按 `day` **升序**排好的 bar（东财本来就是升序，这里仍显式排序：
    /// 下游的「前一根 `close` 当 `pre_close`」完全依赖顺序，不能靠数据源的好意）。
    public static func parse(_ text: String, code: String) -> [HistoryBar] {
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let obj = any as? [String: Any],
              // `data` 为 null（代码非法 / 退市 / 无权限）时这里就断了 → []
              let d = obj["data"] as? [String: Any],
              let rows = d["klines"] as? [String] else { return [] }
        var out: [HistoryBar] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            // omittingEmptySubsequences: false —— 空字段要保留，否则下标会整体左移
            let f = row.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 11 else { return [] }
            guard let open = Double(f[1]), let close = Double(f[2]),
                  let high = Double(f[3]), let low = Double(f[4]),
                  let volume = Double(f[5]), let amount = Double(f[6]),
                  let amplitude = Double(f[7]), let changePct = Double(f[8]),
                  let turnover = Double(f[10]) else { return [] }
            let day = String(f[0])
            // ⚠ 值域校验（2026-10-16 审查 B4）：这条路径原先**一个都不查**，
            //   而 `HistoryReplayJob` 只要"存了 ≥1 根"就 `markCoverage` 把该票该区间
            //   标成已覆盖、**之后永不再抓** ⇒ 一次字段错位 / 半截响应灌进来的
            //   0 价与越界日期会被永久冻结成"缓存已完整"。
            //   判据取自本已有的正确写法 `IndicatorSnapshotJob.makeTodayBar`（那里是查的）。
            //   ⚠ 任一行不合格就**整响应判废**（与上面 `return []` 的既有纪律一致）：
            //   字段错位时剩下的行同样不可信，收下等于把错数据标成已覆盖。
            guard isDayText(day), sane(open: open, close: close, high: high, low: low) else {
                return []
            }
            out.append(HistoryBar(code: code, day: day,
                                  open: open, close: close, high: high, low: low,
                                  volume: volume, amount: amount,
                                  amplitude: amplitude, changePct: changePct,
                                  turnover: turnover))
        }
        return out.sorted { $0.day < $1.day }
    }

    /// `yyyy-MM-dd`（必须 ASCII 数字 + 分隔符位置对）
    static func isDayText(_ s: Substring) -> Bool { isDayText(String(s)) }
    static func isDayText(_ s: String) -> Bool {
        let p = s.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2 else { return false }
        return p.allSatisfy { part in part.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// 价格结构：全为正、且 `high ≥ max(open,close)`、`low ≤ min(open,close)`
    static func sane(open: Double, close: Double, high: Double, low: Double) -> Bool {
        guard open.isFinite, close.isFinite, high.isFinite, low.isFinite else { return false }
        guard open > 0, close > 0, high > 0, low > 0 else { return false }
        return high >= max(open, close) && low <= min(open, close)
    }
}
