import Foundation

/// 一次「收盘后全市场资金流快照」的抓取结果。
///
/// `date` 是**新浪给的权威交易日**（不是墙上时钟），见 `authoritativeTradeDate()`。
public struct FundFlowDay: Sendable {
    public let date: String
    public let points: [FundFlowPoint]
    public init(date: String, points: [FundFlowPoint]) {
        self.date = date
        self.points = points
    }
}

/// 个股资金流向（主力净流入）—— 数据源层（新浪）
///
/// ⚠ **只展示、不参与任何判定**（与 `ChipDistribution` 同一原则）。
/// 本文件**不碰** `ScanRunner` / `ScanStore` / 任何评分口径。落层决策见 `docs/specs/README.md`。
///
/// ## 为什么用新浪（候选源全部用真实请求验过）
///
/// | 候选 | 结果 |
/// |------|------|
/// | 腾讯 `qt.gtimg.cn/q=ff_sh600000` | `v_pv_none_match="1"` → **接口已下线** |
/// | 东财 `push2.eastmoney.com/api/qt/clist/get`（批量排行） | **HTTP 000 不可达** |
/// | 东财 `push2…/fflow/kline/get` | 当日只给 1 行、`push2delay2` 给空 —— **不能当历史序列** |
/// | 东财 `push2his…/fflow/daykline/get` | ✅ 可用（2026-11-02 复核，见下） |
/// | **新浪 `vip.stock.finance.sina.com.cn`** | ✅ 可用，且**项目已在用这个主机** |
///
/// ⚠ **更正一条早先记错的结论**（原先这里写"东财 `fflow/kline` 恒空 ⇒ 只能当备选"）：
///   恒空的是 `push2delay2` 那台 host，`push2his` 的 `fflow/daykline/get` 一直能用。
///   但复核同时发现**两家口径不可互换**：600000 于 2026-10-30，新浪 `r0_net` = -17,866,501，
///   东财"主力净流入" = +7,525,885（**反号**）—— 大单/特大单的分档与主动买卖认定规则不同。
///   ⇒ 东财那条已单独实现在 `EastmoneyFundFlowSource`，**在册但绝不写进本表的列**；
///     本文件的 `.fundFlow` 仍是**单一源**（换源等于换语义，宁可没有也不给错数）。
///
/// 走新浪**零新增 provider**：既有 UA / 超时 / 重试 / 熔断 / `data_source_logs` 全部直接复用。
///
/// ## 两个接口（各司其职）
///
/// · **全市场当日快照** `MoneyFlow.ssl_bkzj_ssggzj`：按 `symbol` 升序分页。
///   `num=1000` 可用，**7 页**（1000×6 + 435）= 6435 个标的
///   （`bj` 517 / `sh` 2809 / `sz` 3109）。
///   ⚠ 榜单**含北交所 + ETF / 债券** → 必须按 `securities` 过滤。
///   过滤后覆盖率 ≈ 0.999（缺的几只为新上市/停牌）。
/// · **个股多日序列** `MoneyFlow.ssl_qsfx_zjlrqs?daima=<symbol>`：详情页用。
///   ⚠ **`num` 被彻底忽略**：传 1/5/20 都返回**全部历史**（约 4000 行 / 1 MB，约 16 年）。
///   → 取用必须自己 `prefix(days)`；**不能指望接口省流量**。
///   → 这也是「详情页必须落库」的直接原因：每开一次详情页就是 1MB 下载，
///     第一次取回后从库里读才是可接受的开销。
///
/// ## ⚠ 快照**不带日期字段** —— 必须用锚点定日期
///
/// 快照响应里**没有任何日期字段**（键里没有 `date` / `opendate`）。
/// 若直接按"今天是几号"落库，一旦抓取发生在新浪尚未刷新（或当天其实休市）的时刻，
/// 就会把**上一交易日的数据写在今天的日期下** —— 静默的数据污染，而且没有任何测试
/// 能发现（数据看着完全正常）。
/// 故 `authoritativeTradeDate()` 用个股历史端点（它**带 `opendate`**）取权威日期。
///
/// ## ⚠ 历史端点返回的是 **DESC（新→旧）**
///
/// 直接 `suffix(n)` 会取到**最老的 n 天**；直接 `.last` 会取到**最老的日期**当"最新"。
/// 本文件统一约定：**对外返回的序列一律升序（旧→新）**，与 `FundFlowStore.history` 一致，
/// 从源头消除 DESC/ASC 混用。
///
/// ## 字段口径（两个端点对同一只票同一天返回**逐字段相同**，用真实响应交叉验过）
///
/// · `r0_net`    = **主力净额**（超大单 + 大单；`r0_in - r0_out` 恒等）。
/// · `netamount` = **总净流入**（`inamount - outamount` 恒等）。
///
/// ⚠ 两者**不是一回事**，展示时必须写清用的是哪个（口径不能含混）。
///
/// ## 可测性
///
/// 解析与网络**分离**：`parseSnapshot` / `parseHistory` 是纯函数，单测用**真实捕获**的
/// 响应文本驱动（`Tests/SelectedCoreTests/Fixtures/fundflow_*.json`）。
public enum FundFlowSource {

    // MARK: - 常量（改动等于改口径）

    /// 快照分页大小（`num` 支持到 1000）
    public static let pageSize = 1000
    /// 分页安全上限（全市场约 7 页，12 页留足余量；新股上市会让页数慢慢涨）
    public static let maxPages = 12
    /// 页间休眠（秒）。收盘后一次性抓取，对数据源压力小，但仍留一点节流
    public static let pageDelay: Double = 0.15
    /// 详情页默认取多少天
    public static let defaultHistoryDays = 20
    /// 日期锚点用的金丝雀标的（浦发银行：老票、必有数据）
    public static let anchorCode = "600000"
    /// 快照覆盖率下限：过滤后不足 `securities` 的这个比例 → 判定"抓漏了"，不落库。
    ///
    /// ⚠ 正常覆盖率 ≈ 0.999；取 0.8 是给"新股刚上市尚未进榜单"与"临时停牌"留余量 ——
    ///   但**必须显著低于 1**：否则几只新股上市就会天天判"抓漏了"拒写、任务天天报红。
    public static let minCoverage = 0.8

    static let host = DataSourceEndpoints.sinaHost
    static let referer = DataSourceEndpoints.sinaFinanceReferer

    // MARK: - 抓取：全市场当日快照

    /// 全市场当日快照（**未过滤**，含北交所 / ETF / 债券；`date` 为空串，待 `stamp` 注入）。
    ///
    /// 按 `symbol` 升序分页 —— 用**稳定键**排序而不是 `netamount`：
    /// 净额有大量并列（0 值尤其多），按它分页会重复/漏行。
    ///
    /// ⚠ 分页判定用的是**解析出的行数**（含北交所），不是过滤后的行数：
    /// 若先过滤再判"不满一页"，第 1 页会因为剔掉 500 多只北交所票而假性"不满页"，
    /// 直接在首页收工 —— 全市场只抓到 1000 条，且**不报错**。
    ///
    /// - Returns: 解析出的全部行；一页都没拿到时返回 `[]`（并已记 `data_source_logs`）
    public static func fetchSnapshot() -> [FundFlowPoint] {
        var out: [FundFlowPoint] = []
        var seen = Set<String>()
        for page in 1...maxPages {
            let url = host + "/quotes_service/api/json_v2.php/MoneyFlow.ssl_bkzj_ssggzj"
                + "?page=\(page)&num=\(pageSize)&sort=symbol&asc=1&bankuai=&shangzhang="
            guard let text = DataSources.httpGet(url, referer: referer) else {
                DataSources.logDataSource("fundflow", "snapshot_page_fail",
                              "第 \(page) 页取数失败，已得 \(out.count) 条")
                break
            }
            let rows = parseSnapshot(text)
            // 去重：跨页边界理论上不该重复，但一旦接口分页语义变了就会静默灌重复行
            var fresh = 0
            for r in rows where seen.insert(r.code).inserted {
                out.append(r); fresh += 1
            }
            // 不满一页 = 已是最后一页
            if rows.count < pageSize { break }
            // 满页但一条新的都没有 → 分页语义异常（在原地打转），立即收工避免死循环
            if fresh == 0 {
                DataSources.logDataSource("fundflow", "snapshot_page_stuck",
                              "第 \(page) 页满页但无新标的，分页疑似失效，提前收工（已得 \(out.count) 条）")
                break
            }
            Thread.sleep(forTimeInterval: pageDelay)
        }
        return out
    }

    /// 快照响应的权威交易日。取不到返回 `nil`（调用方必须**放弃**而不是猜）。
    ///
    /// 用个股历史端点（带 `opendate`）而不是墙上时钟 —— 见文件头「快照不带日期字段」。
    ///
    /// ⚠ 代价：**1.09 MB / 次**（该端点忽略 `num`，总是返回全部历史）。每天一次，可接受。
    /// ⚠ 必须取 `last`（`fetchHistory` 已统一为升序）—— 取 `first` 会拿到 16 年前的第一天。
    public static func authoritativeTradeDate() -> String? {
        fetchHistory(code: anchorCode, days: 1).last?.date
    }

    // MARK: - 抓取：个股多日序列

    /// 个股近 `days` 个交易日（**按日期升序**返回）。
    ///
    /// ⚠ 接口忽略 `num`（总是返回全部历史），这里做客户端截断：
    /// 升序序列的 `suffix(days)` = 最近 `days` 天。
    public static func fetchHistory(code: String,
                                    days: Int = defaultHistoryDays) -> [FundFlowPoint] {
        guard days > 0 else { return [] }
        let url = host + "/quotes_service/api/json_v2.php/MoneyFlow.ssl_qsfx_zjlrqs"
            + "?daima=\(sinaSymbol(code))&num=\(days)"
        guard let text = DataSources.httpGet(url, referer: referer) else { return [] }
        return Array(parseHistory(text, code: code).suffix(days))
    }

    // MARK: - 抓取：收盘后日更（调度器入口）

    /// 收盘后抓一次全市场快照并按 `expectedCodes` 过滤。
    ///
    /// 三道闸门，任何一道不过都返回 `nil`（**不落库**，宁可今天没有也不要错数据）：
    ///   1. 拿不到权威日期 → 放弃（不知道这是哪天的数据）
    ///   2. 快照一行都没解析出来 → 放弃
    ///   3. 过滤后覆盖率 < `minCoverage` → 放弃（抓漏了，落库会写进一批"凭空 0"）
    ///
    /// - Parameter expectedCodes: 应被覆盖的标的集合（`securities` 全表）
    /// - Returns: 该交易日的全部记录（已按 `expectedCodes` 过滤）
    public static func fetchDaily(expectedCodes: Set<String>) -> FundFlowDay? {
        DataSourceRegistry.timed(.fundFlow) { fetchDailyImpl(expectedCodes: expectedCodes) }
    }

    static func fetchDailyImpl(expectedCodes: Set<String>) -> FundFlowDay? {
        guard let date = authoritativeTradeDate() else {
            DataSources.logDataSource("fundflow", "no_authoritative_date",
                          "取不到权威交易日（锚点 \(anchorCode) 历史为空）→ 本次不落库")
            return nil
        }
        let raw = fetchSnapshot()
        guard !raw.isEmpty else {
            DataSources.logDataSource("fundflow", "snapshot_empty", "快照一行都没解析出来 → 本次不落库")
            return nil
        }
        let stamped = stamp(raw, date: date)
        // 过滤掉北交所 / ETF / 债券：它们不在 `securities` 里，落库只会污染按票查询
        let points = expectedCodes.isEmpty ? stamped : stamped.filter { expectedCodes.contains($0.code) }
        if !expectedCodes.isEmpty {
            let coverage = Double(points.count) / Double(expectedCodes.count)
            if coverage < minCoverage {
                DataSources.logDataSource("fundflow", "coverage_low",
                              "覆盖率 \(String(format: "%.4f", coverage)) < \(minCoverage)"
                                + "（过滤后 \(points.count) / 应覆盖 \(expectedCodes.count)）→ 本次不落库")
                return nil
            }
        }
        return FundFlowDay(date: date, points: points)
    }

    // MARK: - 解析（纯函数，单测入口）

    /// 解析快照响应（JSON 数组）。非法/缺字段的行**跳过**而不是整批失败 ——
    /// 快照含非个股品种，本来就有解析不了的行。
    ///
    /// ⚠ 返回的 `date` 是**空串**（快照不带日期）→ 调用方必须 `stamp(_:date:)` 补上。
    /// ⚠ 不过滤市场：北交所行也照收，否则调用方无从判断"是不是抓漏了"（见 `fetchSnapshot`）。
    public static func parseSnapshot(_ text: String) -> [FundFlowPoint] {
        guard let data = text.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { row in
            guard let code = codeFromSymbol(DataSources.pyStr(row["symbol"])) else { return nil }
            return FundFlowPoint(
                date: "",
                code: code,
                name: DataSources.cleanName(DataSources.pyStr(row["name"])),
                close: DataSources.jsonNum(row["trade"]) ?? 0,
                changePct: DataSources.jsonNum(row["changeratio"]) ?? 0,
                netAmount: DataSources.jsonNum(row["netamount"]) ?? 0,
                mainNet: DataSources.jsonNum(row["r0_net"]) ?? 0,
                mainRatio: DataSources.jsonNum(row["r0_ratio"]) ?? 0)
        }
    }

    /// 解析个股历史响应（JSON 数组，带 `opendate`）。
    ///
    /// ⚠ 输入是新浪的 **DESC（新→旧）** 序列，**输出统一反转为升序**（见文件头）。
    /// ⚠ 历史端点**不返回 `symbol` 也不返回 `name`**（响应里没有这两个键）——
    ///   代码必须由调用方传入，名称留空（展示层从 `securities` 取）。
    public static func parseHistory(_ text: String, code: String) -> [FundFlowPoint] {
        guard let data = text.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        let rows = arr.compactMap { row -> FundFlowPoint? in
            let d = DataSources.pyStr(row["opendate"])
            guard d.count == 10 else { return nil }        // 形如 yyyy-MM-dd
            return FundFlowPoint(
                date: d,
                code: code,
                name: "",
                close: DataSources.jsonNum(row["trade"]) ?? 0,
                changePct: DataSources.jsonNum(row["changeratio"]) ?? 0,
                netAmount: DataSources.jsonNum(row["netamount"]) ?? 0,
                mainNet: DataSources.jsonNum(row["r0_net"]) ?? 0,
                mainRatio: DataSources.jsonNum(row["r0_ratio"]) ?? 0)
        }
        return rows.reversed()
    }

    /// 给快照行补上日期（快照本身不带日期 → 由锚点统一注入）
    static func stamp(_ rows: [FundFlowPoint], date: String) -> [FundFlowPoint] {
        rows.map { r in
            FundFlowPoint(date: date, code: r.code, name: r.name, close: r.close,
                          changePct: r.changePct, netAmount: r.netAmount,
                          mainNet: r.mainNet, mainRatio: r.mainRatio)
        }
    }

    // MARK: - 符号 ↔ 代码

    /// 新浪返回的 `symbol`（`sh600000` / `sz000001` / `bj430017`）→ 6 位代码。
    ///
    /// 只要求"2 位前缀 + 6 位数字"：**不在这里过滤市场**（过滤交给 `securities`），
    /// 否则分页的"满页判定"会因为剔掉北交所而失真。
    static func codeFromSymbol(_ sym: String) -> String? {
        guard sym.count == 8 else { return nil }
        let digits = sym.dropFirst(2)
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return String(digits)
    }

    /// 6 位代码 → 新浪 `symbol`。
    ///
    /// ⚠ `DataSourcesKline.symbolPrefix` 只认 `6` 开头（→ `sh`，其余一律 `sz`），
    /// 对北交所（4/8 开头）会拼出 `sz430017` 这种不存在的 symbol。
    /// `securities` 表**目前没有北交所标的**，但将来若支持，这里必须保留分支 ——
    /// 否则取数静默返回空。
    static func sinaSymbol(_ code: String) -> String {
        if code.hasPrefix("4") || code.hasPrefix("8") || code.hasPrefix("92") {
            return "bj" + code
        }
        return DataSources.symbolPrefix(code)
    }
}
