import Foundation

/// 涨停池的**一条记录**。
///
/// ⚠ 口径：涨停**原因文本拿不到**（东财 `datacenter-web` 的原因报表不存在、
/// `push2ex` 涨停池无原因字段、同花顺 `reason_type` 实测为 `null`）
/// → 本模块做「**涨停统计**」：连板数 / N天M板 / 首末封板时间 / 炸板次数 / 行业 / 封板资金。
/// **结构化的"为什么涨"比一句题材文本更可核对**（题材文本无法验证，且会随时间改写）。
public struct LimitUpRecord: Equatable, Sendable {

    /// 交易日 `yyyy-MM-dd`
    ///
    /// ⚠ **由请求日期盖章，不是从响应里读的**：响应的 `qdate` 实测恒为**服务器当天**
    /// （请求历史日期也返回今天的 `qdate`）→ 拿它当数据日期会把历史数据盖成今天。
    /// 而日期参数**实测被尊重**（周六/周日请求返回 `tc=0`，工作日返回真数据）。
    public let date: String
    public let code: String
    public let name: String
    /// 价格（源字段 `p` 是 **×1000** 的整数：`12110` → 12.11 元）
    public let price: Double
    /// 涨跌幅（%）
    public let changePct: Double
    /// 成交额（**元**）
    public let amount: Double
    /// 换手率（%）
    public let turnoverRate: Double
    /// 流通市值（**元**）
    public let floatCap: Double
    /// 总市值（**元**）
    public let totalCap: Double
    /// **连板数**（源字段 `lbc`）
    public let boards: Int
    /// 涨停统计的"N 天"（源字段 `zttj.days`）
    public let statDays: Int
    /// 涨停统计的"M 板"（源字段 `zttj.ct`）
    public let statBoards: Int
    /// 首次封板时间 `HH:MM:SS`（源字段 `fbt` 是 `92500` 这类整数）
    public let firstSeal: String
    /// 最后封板时间 `HH:MM:SS`
    public let lastSeal: String
    /// **炸板次数**（源字段 `zbc`）
    public let brokenCount: Int
    /// 封板资金（**元**）
    public let sealFund: Double
    /// 行业板块（源字段 `hybk`）
    public let industry: String

    /// 展示用：`"3 天 3 板"` / `"首板"`
    public var streakText: String {
        if boards <= 1 { return "首板" }
        return statDays > boards ? "\(statDays) 天 \(boards) 板" : "\(boards) 连板"
    }
}

/// 东财涨停池的**抓取 + 纯解析**（抓取与解析分开 → 解析可离线单测）。
///
/// ## 接口
/// `https://push2ex.eastmoney.com/getTopicZTPool`（**已用 provider 的新子域**，
/// 与 `push2his` / `datacenter-web` 同属 eastmoney.com → 仍满足"零新第三方"）
///
/// ## ⚠ 两条实测约束（都会静默出错）
/// 1. **只覆盖最近约 10 余个交易日**（实测更早的日期返回 `tc=0`）。
///    → **历史回放不能回放涨停池**；本模块也**不补历史**（补不了）。
/// 2. **`tc == 0` 不能当成"今天没有涨停股"**：A股几乎每个交易日都有涨停股，
///    工作日拿到 `tc=0` 意味着**这天没有数据**（超出覆盖窗口 / 源故障）。
///    → 调用方（`LimitUpPoolJob`）必须把它当**失败**，而不是写一天空记录。
public enum LimitUpPoolSource {

    static let host = DataSourceEndpoints.eastmoneyPush2Ex
    static let referer = DataSourceEndpoints.eastmoneyReferer

    /// 东财网页端用的公开 token（`ut`）。它是个**固定值**，不是用户凭证。
    /// ⚠ 值已收敛到 `DataSourceEndpoints.eastmoneyUT`。
    static let ut = DataSourceEndpoints.eastmoneyUT
    /// 榜单标识（`dpt=wz.ztzt` = 涨停池）
    static let dpt = "wz.ztzt"

    /// 每页条数。实测 57 条一天 → 1 页；给 200 留足余量（涨停家数极端时可达 300+）
    static let pageSize = 200
    /// 翻页上限（防"tc 异常巨大"时无限翻页）
    static let maxPages = 5

    /// 拼 URL。`date` 用 `yyyy-MM-dd`（会去掉横线 —— 东财要 `yyyyMMdd`）
    public static func url(date: String, page: Int) -> String {
        let d = date.replacingOccurrences(of: "-", with: "")
        return host + "/getTopicZTPool?ut=\(ut)&dpt=\(dpt)"
            + "&Pageindex=\(page)&pagesize=\(pageSize)&sort=fbt%3Aasc&date=\(d)"
    }

    /// 合法日期（`yyyy-MM-dd`，长度与数字都要对）
    static func isDate(_ s: String) -> Bool {
        let parts = s.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2
        else { return false }
        return parts.allSatisfy { $0.allSatisfy { c in c.isASCII && c.isNumber } }
    }

    /// 抓某一天的涨停池（翻页取全）。
    ///
    /// - Returns: `nil` = **没有拿到**（源故障 / 超出覆盖窗口 / 该日非交易日）。
    ///   ⚠ **不返回空数组**：`[]` 会被调用方当成"这天没有涨停股"而写一天空记录。
    public static func fetchDay(_ date: String) -> [LimitUpRecord]? {
        DataSourceRegistry.timed(.limitUpPool) { fetchDayImpl(date) }
    }

    static func fetchDayImpl(_ date: String) -> [LimitUpRecord]? {
        guard isDate(date) else {
            DataSources.logDataSource("limitup", "bad_date", "非法交易日：\(date)")
            return nil
        }
        var collected: [LimitUpRecord] = []
        var total = -1
        for page in 0..<maxPages {
            defer { DataSources.throttleAfterNetwork() }
            guard let text = DataSources.httpGet(url(date: date, page: page), referer: referer)
            else {
                // 首页就失败 → 整次失败；后续页失败 → 保留已拿到的（但下面会按数量判断）
                if page == 0 {
                    DataSources.logDataSource("limitup", "http_failed", date)
                    return nil
                }
                break
            }
            let (rows, tc) = parsePage(text, date: date)
            if page == 0 {
                total = tc
                if tc <= 0 {
                    DataSources.logDataSource("limitup", "empty_pool",
                                              "\(date) 返回 tc=\(tc)（超出覆盖窗口或非交易日）")
                    return nil
                }
            }
            if rows.isEmpty { break }
            collected.append(contentsOf: rows)
            if collected.count >= total { break }
        }
        guard !collected.isEmpty else { return nil }
        // ⚠ **完整性检查**：源给了 `tc`（当天总数），拿到的不该比它少。
        //   少了 = 某一页失败/被截断 → **宁可返回 nil**（"今天没数据"），
        //   也不要一份半截的池子 —— 后者会让详情页给出**假否定**
        //   （"这只票今天没涨停"，而它其实涨停了、只是那一页没取到）。
        if total > 0 && collected.count < total {
            DataSources.logDataSource("limitup", "incomplete",
                                      "\(date) 只取到 \(collected.count)/\(total) 条 → 丢弃（避免假否定）")
            return nil
        }
        // 按 code 去重（翻页临界点可能重复），再按首次封板时间排序（源本身就是这个序）
        var seen = Set<String>()
        return collected.filter { seen.insert($0.code).inserted }
    }

    /// 纯解析：**一页**响应 → `(记录, 总条数 tc)`
    ///
    /// **全有或全无**：整体不是预期形状 → `([], 0)`。与 `parseSinaKline` 同一条纪律 ——
    /// 半截数据比没有数据更危险（会被当成"完整的一天"）。
    public static func parsePage(_ text: String, date: String) -> (rows: [LimitUpRecord], total: Int) {
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let obj = any as? [String: Any],
              let d = obj["data"] as? [String: Any] else { return ([], 0) }
        let total = (d["tc"] as? NSNumber)?.intValue ?? 0
        guard let pool = d["pool"] as? [[String: Any]] else { return ([], total) }
        var out: [LimitUpRecord] = []
        out.reserveCapacity(pool.count)
        for row in pool {
            guard let code = (row["c"] as? String),
                  DataSourceEndpoints.isSixDigitCode(code) else { continue }
            // ⚠ `p` 是 ×1000 的整数
            let price = ((row["p"] as? NSNumber)?.doubleValue ?? 0) / 1000
            let stat = row["zttj"] as? [String: Any] ?? [:]
            out.append(LimitUpRecord(
                date: date,
                code: code,
                name: DataSources.pyStr(row["n"]),
                price: price,
                changePct: num(row["zdp"]),
                amount: num(row["amount"]),
                turnoverRate: num(row["hs"]),
                floatCap: num(row["ltsz"]),
                totalCap: num(row["tshare"]),
                boards: (row["lbc"] as? NSNumber)?.intValue ?? 0,
                statDays: (stat["days"] as? NSNumber)?.intValue ?? 0,
                statBoards: (stat["ct"] as? NSNumber)?.intValue ?? 0,
                firstSeal: sealTime(row["fbt"]),
                lastSeal: sealTime(row["lbt"]),
                brokenCount: (row["zbc"] as? NSNumber)?.intValue ?? 0,
                sealFund: num(row["fund"]),
                industry: DataSources.pyStr(row["hybk"])))
        }
        return (out, total)
    }

    /// 源字段 → Double（NSNumber / 数字字符串都认）
    /// ⚠ 实现已收敛到 `Num.doubleOrZero`（带 `isFinite` 守卫）。
    static func num(_ v: Any?) -> Double { Num.doubleOrZero(v) }

    /// 封板时间：源是 `92500`（= 09:25:00）这类整数 → `"09:25:00"`。
    ///
    /// ⚠ 补零必须显式做：`92500` 直接 `String` 是 `"92500"`，切分会得到 `9:25:00`，
    /// 而**排序与展示都按字符串比** → 与 `"10:10:27"` 混在一起时顺序会错。
    /// ⚠ 非法/缺失 → `""`（不是 `"00:00:00"` —— 那会被当成"开盘就封板"）。
    public static func sealTime(_ v: Any?) -> String {
        let raw = (v as? NSNumber)?.intValue ?? Int((v as? String) ?? "") ?? 0
        guard raw > 0 else { return "" }
        let h = raw / 10000
        let m = (raw / 100) % 100
        let s = raw % 100
        guard h < 24, m < 60, s < 60 else { return "" }
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
