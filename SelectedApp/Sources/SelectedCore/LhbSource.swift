import Foundation

/// 一条龙虎榜**上榜记录**（某标的 · 某交易日 · 某条上榜规则）
///
/// ⚠ 主键是 `(date, code, changeType)` 而**不是** `(date, code)` —— 实测有 68 行
/// 但只有 60 个标的：部分票一天上榜多次（不同规则）。
///
/// ⚠ 金额单位是**元**（原始值不折算，折算留给展示层）。
public struct LhbRecord: Equatable, Sendable {

    /// 交易日 `yyyy-MM-dd`（源字段是 `"2026-09-21 00:00:00"`，解析时截断前 10 位）
    public let date: String
    /// 6 位代码
    public let code: String
    /// **规则码**（如 `137001004001`）—— 稳定标识，**进主键**
    public let changeType: String
    public let name: String
    /// 上榜原因文案。⚠ **不进主键**：同一个 `changeType` 有多个文本变体
    /// （供应商的历史文案修订），拿它当键会让"改文案"变成"新行"。
    public let explanation: String
    /// `SZ` / `SH` / `BJ`
    public let market: String
    /// 板块名（`深交所主板` / `上交所科创板` / `北京证券交易所` / `深交所风险警示板` …）
    public let tradeMarket: String
    public let close: Double
    /// 涨跌幅（%）
    public let changePct: Double
    /// 换手率（%）
    public let turnoverRate: Double
    /// 龙虎榜净买入额（元）= 买 − 卖
    public let netAmount: Double
    public let buyAmount: Double
    public let sellAmount: Double
    /// 龙虎榜成交额（元）
    public let dealAmount: Double
    /// 当日**全天**成交额（元）—— 与 `dealAmount` 不是一回事，展示时必须写清
    public let accumAmount: Double
    /// 流通市值（元）
    public let freeMarketCap: Double
    /// 龙虎榜成交额 / 全天成交额（%）
    public let dealAmountRatio: Double
    /// 龙虎榜净额 / 全天成交额（%）
    public let dealNetRatio: Double
    /// 买入额 / 全天成交额（%）
    public let buyRatio: Double
    /// 卖出额 / 全天成交额（%）
    public let sellRatio: Double
    /// 供应商的记录号（仅留痕，**不保证唯一**）
    public let tradeId: Int

    public init(date: String, code: String, changeType: String, name: String,
                explanation: String, market: String, tradeMarket: String,
                close: Double, changePct: Double, turnoverRate: Double,
                netAmount: Double, buyAmount: Double, sellAmount: Double,
                dealAmount: Double, accumAmount: Double, freeMarketCap: Double,
                dealAmountRatio: Double, dealNetRatio: Double,
                buyRatio: Double, sellRatio: Double, tradeId: Int) {
        self.date = date
        self.code = code
        self.changeType = changeType
        self.name = name
        self.explanation = explanation
        self.market = market
        self.tradeMarket = tradeMarket
        self.close = close
        self.changePct = changePct
        self.turnoverRate = turnoverRate
        self.netAmount = netAmount
        self.buyAmount = buyAmount
        self.sellAmount = sellAmount
        self.dealAmount = dealAmount
        self.accumAmount = accumAmount
        self.freeMarketCap = freeMarketCap
        self.dealAmountRatio = dealAmountRatio
        self.dealNetRatio = dealNetRatio
        self.buyRatio = buyRatio
        self.sellRatio = sellRatio
        self.tradeId = tradeId
    }
}

/// 一条**席位明细**（某上榜记录 · 某侧 · 第 n 位营业部）
///
/// ⚠ `rank` 是**响应顺序**（1..5），**不是金额名次** —— 实测第 1 位买 1.05 亿、
/// 第 3 位买 1.60 亿。拿"名次"当键是错的，`rank` 只是"同组内的第几条"。
public struct LhbSeat: Equatable, Sendable {

    public let date: String
    public let code: String
    public let changeType: String
    /// `BUY` / `SELL`
    public let side: String
    /// 同 `(code, changeType, side)` 组内的序号，1 起
    public let rank: Int
    public let deptCode: String
    /// 营业部名称。`机构专用` / `沪股通专用` / `深股通专用` 是**可判读**的参与方类型
    public let deptName: String
    /// 该席位买入额（元）。⚠ 源字段可能为 `null` = **该侧无成交** → 按 0 处理
    public let buy: Double
    /// 该席位卖出额（元）。同上，可能为 `null`
    public let sell: Double
    /// 净额（元）。实测 `net == buy - sell` **680 行 0 反例**；源字段为 null 时按此式回算
    public let net: Double

    public init(date: String, code: String, changeType: String, side: String, rank: Int,
                deptCode: String, deptName: String, buy: Double, sell: Double, net: Double) {
        self.date = date
        self.code = code
        self.changeType = changeType
        self.side = side
        self.rank = rank
        self.deptCode = deptCode
        self.deptName = deptName
        self.buy = buy
        self.sell = sell
        self.net = net
    }

    /// 是否为**机构专用**席位（含 `机构专用` 字样）
    public var isInstitution: Bool { deptName.contains("机构专用") }

    /// 是否为**沪深股通**席位（`沪股通专用` / `深股通专用`）
    public var isStockConnect: Bool {
        deptName.contains("沪股通专用") || deptName.contains("深股通专用")
    }
}

/// 一个交易日的完整龙虎榜（上榜记录 + 买卖席位）
public struct LhbDay: Sendable {
    public let date: String
    public let records: [LhbRecord]
    public let seats: [LhbSeat]
    public init(date: String, records: [LhbRecord], seats: [LhbSeat]) {
        self.date = date
        self.records = records
        self.seats = seats
    }
}

/// 龙虎榜 —— 数据源层（东方财富 `datacenter-web`）。
///
/// ⚠ **只展示、不参与任何判定**（与 `ChipDistribution` / `FundFlowSource` 同一原则）。
/// 本文件**不碰** `ScanRunner` / `ScanStore` / 任何评分口径 —— 不影响打分与黄金夹具。
///
/// ## 为什么用东财 `datacenter-web`（全部为真实请求实测）
///
/// | 候选 | 实测 | 判定 |
/// |------|------|------|
/// | **东财 `datacenter-web.eastmoney.com/api/data/v1/get`** | HTTP 200 / 3.5KB，**标准 JSON** | ✅ |
/// | 新浪 `.../kind/lhb/index.phtml` | HTTP 200 但 **275KB HTML** | ❌ 需新写 HTML 解析器 |
/// | 同花顺 `data.10jqka.com.cn/market/longhu/` | HTTP 200 但 **792KB HTML** | ❌ 同上 |
/// | 深交所 / 上交所官方接口 | 只覆盖单市场，且需正确的 `CATALOGID` / `sqlId` | ❌ |
///
/// ⚠ **"新增一个 provider"的成本只有几个常量**：`DataSources.httpGet` **没有主机白名单、
/// 没有按主机的熔断**，日志按调用点分组 —— 换主机不需要新造任何基建。
///
/// ## 三个端点，一个交易日 = 3 次请求
///
/// | `reportName` | 内容 | 实测 |
/// |---|---|---|
/// | `RPT_DAILYBILLBOARD_DETAILSNEW` | 上榜记录 | `count=68`，单页取完 |
/// | `RPT_BILLBOARD_DAILYDETAILSBUY` | 买入席位 | `count=340` = 68×5 |
/// | `RPT_BILLBOARD_DAILYDETAILSSELL` | 卖出席位 | `count=340` |
///
/// ## ⚠ 必须**丢弃**的字段（前瞻 / 供应商加工值）
///
/// · `D1/D2/D5/D10/D20/D30_CLOSE_ADJCHRATE` —— **未来收益**。
///   实测：过去日子的 `D1/D2/D5` 已填充、`D10` 仍 `null` → 明确是**事后回填**。
///   存下来就是时点污染。
/// · `EXPLAIN`（如 `主力做T，成功率27.90%`）—— 供应商"解读" + **全样本事后成功率**。
/// · `RISE_PROBABILITY_3DAY` / `TOTAL_BUYRIO` / `TOTAL_SELLRIO` /
///   `TOTAL_BUYER_SALESTIMES_3DAY` —— 供应商加工的席位统计，非当日事实。
/// · `BUY_SEAT` / `SELL_SEAT` / `BUY_SEAT_NEW` / `SELL_SEAT_NEW` —— 5 位码
///   （`11111` / `33313` …）**语义未确认**，不猜。
/// · `SUM_BUY_AMT` / `SUM_SELL_AMT` / `NET_BS_AMT` —— 与 `BILLBOARD_*` **逐值相同**，重复列。
///
/// ## ⚠ 不做 `securities` 过滤（与 `FundFlowSource` 相反）
///
/// 资金流快照含 ETF / 债券 / 北交所 → 必须按 `securities` 过滤。
/// 龙虎榜端点**本身就只返回股票**（实测 `SECURITY_TYPE_CODE` 全是 `058001001`），
/// 且**北交所会合法上榜**（实测 8 行 `MARKET=BJ`）—— 而 `securities` 表里**没有北交所标的**。
/// 照抄资金流的过滤会把 8 条真实上榜记录**静默丢掉**。故本层不过滤。
///
/// ## 可测性
///
/// 解析与网络**分离**：`parseDay` / `parseSeats` 是纯函数，单测用**真实捕获**的响应
/// 驱动（`Tests/SelectedCoreTests/Fixtures/lhb_*.json`，只裁剪行数、行内容逐字保留
/// —— 不照着代码手写夹具，那是循环论证）。
public enum LhbSource {

    // MARK: - 常量（改动等于改口径）

    static let host = DataSourceEndpoints.eastmoneyDataCenter
    static let referer = DataSourceEndpoints.eastmoneyDataCenterReferer

    static let dayReport = "RPT_DAILYBILLBOARD_DETAILSNEW"
    static let buyReport = "RPT_BILLBOARD_DAILYDETAILSBUY"
    static let sellReport = "RPT_BILLBOARD_DAILYDETAILSSELL"

    /// 上榜记录单页大小。实测当日 68 行 → 500 足够单页取完
    static let dayPageSize = 500
    /// 席位单页大小。实测单侧 340 行（= 记录数 × 5）→ 2000 足够
    static let seatPageSize = 2000

    /// 一个交易日**至少**多少条上榜记录才算"已发布完整"。
    ///
    /// 实测正常交易日 68 条。取 20 是**防"尚未发布完整"**（数据分批入库时可能先看到几条），
    /// 不是防抓漏 —— 龙虎榜的条数由当日触发规则的票数决定，**没有覆盖率分母**
    /// （不像资金流有 `securities` 可算覆盖率）。
    public static let minRows = 20

    /// 两个侧别
    public static let sides = ["BUY", "SELL"]

    // MARK: - 抓取

    /// 抓一个交易日（上榜记录 + 买卖席位）。任一步拿不到有效数据返回 `nil`。
    ///
    /// 三道闸门（与 `FundFlowSource.fetchDaily` 同一取向：宁可今天没有，也不要错数据）：
    ///   1. 上榜记录为空 → `nil`（尚未发布，或取数失败）
    ///   2. 上榜记录 < `minRows` → `nil`（疑似尚未发布完整）
    ///   3. 任一侧席位为空 → `nil`（同上；席位与记录同一批发布）
    public static func fetch(_ date: String) -> LhbDay? {
        DataSourceRegistry.timed(.lhb) { fetchImpl(date) }
    }

    static func fetchImpl(_ date: String) -> LhbDay? {
        guard isDate(date) else {
            DataSources.logDataSource("lhb", "bad_date", "非法交易日：\(date)")
            return nil
        }
        guard let dayFetch = fetchDayWithTotal(date) else {
            DataSources.logDataSource("lhb", "day_fetch_failed", "\(date) 上榜记录取数失败（无响应）")
            return nil
        }
        let records = dayFetch.records
        guard !records.isEmpty else {
            DataSources.logDataSource("lhb", "day_empty", "\(date) 上榜记录为空（尚未发布或取数失败）")
            return nil
        }
        guard records.count >= minRows else {
            DataSources.logDataSource("lhb", "day_too_few",
                          "\(date) 只有 \(records.count) 条 < \(minRows)，疑似尚未发布完整")
            return nil
        }
        // ⚠ 完整性闸门：`apiURL` 固定 `pageNumber=1`，而 `dayPageSize = 500` ——
        //   上榜记录 > 500 条的日子会被**静默截断**成半截，
        //   而上面三道闸门（非空 / ≥ `minRows` / 两侧非空）**都拦不住"半截"**。
        //   实得 < 源报总数 → 宁可"今天没数据"（`LhbJob` 会回看最近几个交易日补漏）。
        //   ⚠ 源没给总数时**不能默认完整**（旧写法 `total > 0,` 让 -1 直接跳过本闸门）：
        //     改为"取数已顶到分页上限 ⇒ 无法排除截断 ⇒ 拒绝"；未到上限则截断在数学上不可能。
        if let total = dayFetch.total {
            if records.count < total {
                DataSources.logDataSource("lhb", "day_incomplete",
                              "\(date) 只取到 \(records.count)/\(total) 条"
                              + "（分页上限 \(dayPageSize)）→ 丢弃，不落库")
                return nil
            }
        } else if records.count >= dayPageSize {
            DataSources.logDataSource("lhb", "day_total_unknown",
                          "\(date) 源未报总数且实得 \(records.count) 条已达分页上限 \(dayPageSize)"
                          + "（无法排除截断）→ 丢弃，不落库")
            return nil
        }
        var seats: [LhbSeat] = []
        for side in sides {
            guard let seatFetch = fetchSeatsWithTotal(date, side: side) else {
                DataSources.logDataSource("lhb", "seats_fetch_failed",
                              "\(date) \(side) 席位取数失败（无响应）→ 本次不落库")
                return nil
            }
            let got = seatFetch.seats
            guard !got.isEmpty else {
                DataSources.logDataSource("lhb", "seats_empty",
                              "\(date) \(side) 席位为空（记录 \(records.count) 条）→ 本次不落库")
                return nil
            }
            // ⚠ 同上：单侧席位 > `seatPageSize` 也会被截断；源未报总数时按同一规则处理
            if let total = seatFetch.total {
                if got.count < total {
                    DataSources.logDataSource("lhb", "seats_incomplete",
                                  "\(date) \(side) 只取到 \(got.count)/\(total) 条"
                                  + "（分页上限 \(seatPageSize)）→ 本次不落库")
                    return nil
                }
            } else if got.count >= seatPageSize {
                DataSources.logDataSource("lhb", "seats_total_unknown",
                              "\(date) \(side) 源未报总数且实得 \(got.count) 条已达分页上限 \(seatPageSize)"
                              + "（无法排除截断）→ 本次不落库")
                return nil
            }

            seats += got
        }
        DataSources.logDataSource("lhb", "fetch_ok",
                      "\(date) 上榜 \(records.count) 条 / 席位 \(seats.count) 条")
        return LhbDay(date: date, records: records, seats: seats)
    }

    /// 抓上榜记录（**未过滤**，含北交所）
    public static func fetchDay(_ date: String) -> [LhbRecord] {
        fetchDayWithTotal(date)?.records ?? []
    }

    /// 抓上榜记录 + **源报总数**（完整性判定用，见 ``dataTotal(_:)``）。
    /// - Returns: `nil` = 取数失败（非法日期 / 无响应）；`total == nil` = 源未给总数
    static func fetchDayWithTotal(_ date: String) -> (records: [LhbRecord], total: Int?)? {

        guard isDate(date) else { return nil }
        let url = apiURL(report: dayReport, date: date, pageSize: dayPageSize)
        guard let text = DataSources.httpGet(url, referer: referer) else { return nil }
        // ⚠ 取数后必须过全局限速（2026-10-16 审查 B4）：本文件与 `fetchSeats` 原先
        //   都不调 `throttleAfterNetwork()` —— 而 `LhbJob.pickDay` 是
        //   「今日 + 回看 5 日 × 3 个端点」≈ 18 个 URL，每个还带 `httpGet` 的 3 次重试
        //   ⇒ 最坏 ~54 次**连发**打 datacenter-web。这正是本项目记录过的封禁形态。
        DataSources.throttleAfterNetwork()
        return (parseDay(text), dataTotal(text))
    }

    /// 抓某一侧的席位明细
    public static func fetchSeats(_ date: String, side: String) -> [LhbSeat] {
        fetchSeatsWithTotal(date, side: side)?.seats ?? []
    }

    /// 抓某一侧的席位明细 + **源报总数**（完整性判定用）
    static func fetchSeatsWithTotal(_ date: String, side: String) -> (seats: [LhbSeat], total: Int?)? {

        guard isDate(date) else { return nil }
        let report = side == "BUY" ? buyReport : sellReport
        let url = apiURL(report: report, date: date, pageSize: seatPageSize)
        guard let text = DataSources.httpGet(url, referer: referer) else { return nil }
        DataSources.throttleAfterNetwork()   // 同 `fetchDayWithTotal`：不让席位抓取连发
        return (parseSeats(text, side: side), dataTotal(text))
    }

    /// 组装请求 URL。
    ///
    /// ⚠ `filter` 里的 `=` 与 `'` 必须百分号编码（实测 `%3D` / `%27` 可用），
    /// 且 `date` 必须**先过 `isDate`** —— 它是唯一进入查询表达式的外部输入。
    static func apiURL(report: String, date: String, pageSize: Int) -> String {
        host + "/api/data/v1/get"
            + "?reportName=\(report)&columns=ALL"
            + "&filter=(TRADE_DATE%3D%27\(date)%27)"
            + "&pageNumber=1&pageSize=\(pageSize)"
            + "&sortColumns=SECURITY_CODE&sortTypes=1&source=WEB&client=WEB"
    }

    // MARK: - 解析（纯函数，单测入口）

    /// 解析上榜记录响应。
    ///
    /// 缺字段的行**跳过**而不是整批失败 —— 与资金流快照解析同一取向。
    public static func parseDay(_ text: String) -> [LhbRecord] {
        dataRows(text).compactMap { row in
            guard let date = dayOf(row["TRADE_DATE"]) else { return nil }
            let code = DataSources.pyStr(row["SECURITY_CODE"])
            let ct = DataSources.pyStr(row["CHANGE_TYPE"])
            guard !code.isEmpty, !ct.isEmpty else { return nil }
            return LhbRecord(
                date: date,
                code: code,
                changeType: ct,
                name: DataSources.cleanName(DataSources.pyStr(row["SECURITY_NAME_ABBR"])),
                explanation: DataSources.pyStr(row["EXPLANATION"]),
                market: DataSources.pyStr(row["MARKET"]),
                tradeMarket: DataSources.pyStr(row["TRADE_MARKET"]),
                close: DataSources.jsonNum(row["CLOSE_PRICE"]) ?? 0,
                changePct: DataSources.jsonNum(row["CHANGE_RATE"]) ?? 0,
                turnoverRate: DataSources.jsonNum(row["TURNOVERRATE"]) ?? 0,
                netAmount: DataSources.jsonNum(row["BILLBOARD_NET_AMT"]) ?? 0,
                buyAmount: DataSources.jsonNum(row["BILLBOARD_BUY_AMT"]) ?? 0,
                sellAmount: DataSources.jsonNum(row["BILLBOARD_SELL_AMT"]) ?? 0,
                dealAmount: DataSources.jsonNum(row["BILLBOARD_DEAL_AMT"]) ?? 0,
                accumAmount: DataSources.jsonNum(row["ACCUM_AMOUNT"]) ?? 0,
                freeMarketCap: DataSources.jsonNum(row["FREE_MARKET_CAP"]) ?? 0,
                dealAmountRatio: DataSources.jsonNum(row["DEAL_AMOUNT_RATIO"]) ?? 0,
                dealNetRatio: DataSources.jsonNum(row["DEAL_NET_RATIO"]) ?? 0,
                buyRatio: DataSources.jsonNum(row["BUY_RATIO"]) ?? 0,
                sellRatio: DataSources.jsonNum(row["SELL_RATIO"]) ?? 0,
                tradeId: Int(DataSources.jsonNum(row["TRADE_ID"]) ?? 0))
        }
    }

    /// 解析某一侧的席位响应，并按 `(code, changeType)` 分组编号 `rank`（1 起）。
    ///
    /// ⚠ `rank` 是**同组内的出现序号**，不是金额名次 —— 实测响应顺序**不是**金额降序
    /// （第 1 位买 1.05 亿、第 3 位买 1.60 亿）。它只用来给"没有自然键"的席位表一个
    /// 稳定的行标识。
    ///
    /// ⚠ `BUY` / `SELL` 可能为 `null`（该侧无成交）→ 按 0 处理。
    /// `NET` 为 null 时按 `buy - sell` 回算 —— 实测该式**零反例**。
    public static func parseSeats(_ text: String, side: String) -> [LhbSeat] {
        var counters: [String: Int] = [:]
        return dataRows(text).compactMap { row in
            guard let date = dayOf(row["TRADE_DATE"]) else { return nil }
            let code = DataSources.pyStr(row["SECURITY_CODE"])
            let ct = DataSources.pyStr(row["CHANGE_TYPE"])
            guard !code.isEmpty, !ct.isEmpty else { return nil }
            let key = code + "|" + ct
            let n = (counters[key] ?? 0) + 1
            counters[key] = n
            let buy = DataSources.jsonNum(row["BUY"]) ?? 0
            let sell = DataSources.jsonNum(row["SELL"]) ?? 0
            return LhbSeat(
                date: date, code: code, changeType: ct, side: side, rank: n,
                deptCode: DataSources.pyStr(row["OPERATEDEPT_CODE"]),
                deptName: DataSources.pyStr(row["OPERATEDEPT_NAME"]),
                buy: buy, sell: sell,
                net: DataSources.jsonNum(row["NET"]) ?? (buy - sell))
        }
    }

    // MARK: - 内部

    /// 取出 `result.data`。`result` 为 `null`（无数据）时返回 `[]`。
    static func dataRows(_ text: String) -> [[String: Any]] {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let rows = result["data"] as? [[String: Any]]
        else { return [] }
        return rows
    }

    /// 响应里的**源报总数**（`result.count`）。缺失 / 非数字 → `nil`（= **无法验证**）。
    ///
    /// ⚠ 为什么要它：`apiURL` 固定 `pageNumber=1`，而
    ///   `dayPageSize = 500` / `seatPageSize = 2000` —— 超过上限的日子会被**静默截断**，
    ///   而 `fetch` 原有的三道闸门（非空 / ≥ `minRows` / 两侧非空）**都拦不住"半截"**。
    ///   对照 `FundamentalSource.fetchAll` 已有的"实得 < 源报总数 → 返回 nil"。
    ///
    /// ⚠ 原先缺失时返回 `-1`，而两个闸门写作 `total > 0, count < total` ——
    ///   `-1` 让闸门**整体跳过**，于是"源没给总数"被当成"完整"，> 上限的半截日子照样落库
    ///   （2026-10-16 审查 B2）。现在返回 `Int?`：`nil` 表示不可验证，
    ///   调用方按"不可验证 + 取数已顶到分页上限 ⇒ 视为可能被截断 ⇒ 拒绝"处理。
    /// ⚠ `count` 是 `NSNumber`（`JSONSerialization` 给的），**不是** `Int`；
    ///   且必须走 `Num.intOrNil`（`n.intValue` 是 Int32，大数会回绕）。
    static func dataTotal(_ text: String) -> Int? {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = obj["result"] as? [String: Any]
        else { return nil }
        return Num.intOrNil(result["count"])
    }

    /// `"2026-09-21 00:00:00"` → `"2026-09-21"`。长度不对返回 `nil`（跳过该行）。
    static func dayOf(_ v: Any?) -> String? {
        let s = DataSources.pyStr(v)
        guard s.count >= 10 else { return nil }
        let d = String(s.prefix(10))
        return isDate(d) ? d : nil
    }

    /// `yyyy-MM-dd` 校验（同时是**注入防线**：`date` 会进入查询表达式）
    static func isDate(_ s: String) -> Bool {
        guard s.count == 10 else { return false }
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2
        else { return false }
        return parts.allSatisfy { $0.allSatisfy { c in c.isASCII && c.isNumber } }
    }
}
