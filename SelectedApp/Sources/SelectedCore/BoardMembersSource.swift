import Foundation

/// 板块**成份股**涨幅榜的一条（板块详情「强势股」）。
///
/// ## 数据源与字段口径
///
/// 东财 `clist` 板块成份域（`fs=b:BK1295`，`total` = 板块成份数）：
///
/// | 字段 | 含义 |
/// |------|------|
/// | `f12` | 个股代码（6 位） |
/// | `f14` | 个股名称 |
/// | `f3`  | 涨跌幅（%） |
/// | `f6`  | 成交额（**元**） |
///
/// ⚠ 成份接口按**板块代码**（`BKxxxx`）直查，
///   不存在 `hybk` 截断 / 申万粒度对不上的问题（见 `BoardHeatSource` 的粒度警告）。
public struct BoardMemberPoint: Equatable, Sendable {
    /// 个股代码（6 位）
    public let code: String
    public let name: String
    /// 涨跌幅（%）
    public let changePct: Double
    /// 成交额（**元**）
    public let amount: Double

    public init(code: String, name: String, changePct: Double, amount: Double) {
        self.code = code
        self.name = name
        self.changePct = changePct
        self.amount = amount
    }
}

/// 板块成份的**抓取 + 纯解析**（分开是为了让解析可离线单测，同 `BoardHeatSource`）。
///
/// ## 为什么只要一页
/// 消费方只取涨幅 Top N（板块详情「强势股」），`pz` 给到 50 足够覆盖；
/// 成份域按 `fid=f3` 降序**服务端排序**，一页即取到榜头，无需翻页。
///
/// ## ⚠ 两条抓取纪律（同 `BoardHeatSource`）
/// 1. 每次网络后 `throttleAfterNetwork()`（东财按出口 IP 限流）；
/// 2. 空页/失败重试到秒级退避；**不返回空数组冒充成功**（失败返回 `nil`）。
public enum BoardMembersSource {

    static let host = DataSourceEndpoints.eastmoneyPush2
    static let referer = DataSourceEndpoints.eastmoneyReferer

    /// 失败归属范围（`fs=b:` 板块成份域，与基本面 / 板块热度隔离）
    public static let failureScope = host + "/api/qt/clist/get?fs=b:"

    /// 字段清单（含义见 `BoardMemberPoint` 的字段表）
    static let fields = "f12,f14,f3,f6"
    /// 单页取多少只（榜头够用即可；成份域服务端已按涨幅降序）
    static let pageSize = 50
    /// 最多抓几页（多数板块成份 < 50，一页即收；留余量防源调整）
    static let maxPages = 2
    /// 每页最多抓几次（秒级退避）
    static let pageAttempts = 3

    /// 拼 URL。**排序键用 `fid=f3`（涨幅降序）** —— 成份域只要榜头，
    /// 分页漂移不影响（消费方只取前几条；与 `BoardHeatSource` 要 496 全量、必须稳定键不同）。
    public static func url(boardCode: String, page: Int) -> String {
        host + "/api/qt/clist/get?pn=\(page)&pz=\(pageSize)&po=1&np=1&fltt=2&invt=2"
            + "&fid=f3&fs=b:\(boardCode)&fields=\(fields)"
    }

    /// 纯解析：**一页**响应 → `(记录, 源报总数)`（全有或全无）。
    /// ⚠ `data.diff` 在 `np=1` 时是**数组**；不带 `np` 时是**字典** —— 两种都认。
    public static func parse(_ text: String) -> (rows: [BoardMemberPoint], total: Int) {
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let obj = any as? [String: Any],
              let d = obj["data"] as? [String: Any] else { return ([], 0) }
        let total = (d["total"] as? NSNumber)?.intValue ?? 0
        let raw: [[String: Any]]
        if let arr = d["diff"] as? [[String: Any]] {
            raw = arr
        } else if let dict = d["diff"] as? [String: [String: Any]] {
            raw = dict.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.compactMap { dict[$0] }
        } else {
            return ([], total)
        }
        var out: [BoardMemberPoint] = []
        out.reserveCapacity(raw.count)
        for row in raw {
            // 个股代码必须是 6 位数字；非法 = 筛选条件被改错，整行跳过（宁缺勿错）。
            guard let code = row["f12"] as? String,
                  DataSourceEndpoints.isSixDigitCode(code) else { continue }
            let name = (row["f14"] as? String) ?? ""
            guard !name.isEmpty, name != "-" else { continue }
            out.append(BoardMemberPoint(
                code: code, name: name,
                changePct: Num.doubleOrZero(row["f3"]),
                amount: Num.doubleOrZero(row["f6"])))
        }
        return (out, total)
    }

    /// 抓某板块成份的涨幅榜（按 `changePct` 降序）。
    ///
    /// - Returns: `nil` = 没拿到（源故障 / 板块代码非法 / 整批为空）。**不返回空数组**。
    public static func fetchTop(boardCode: String) -> [BoardMemberPoint]? {
        guard boardCode.hasPrefix("BK"), boardCode.count == 6 else { return nil }
        var collected: [BoardMemberPoint] = []
        var seen = Set<String>()
        var expected = -1
        for page in 1...maxPages {
            var pageRows: [BoardMemberPoint]?
            for attempt in 0..<pageAttempts {
                if let text = DataSources.httpGet(url(boardCode: boardCode, page: page),
                                                  referer: referer) {
                    let r = parse(text)
                    // 首页空且源报 total>0 = 可疑截断，重试；其余正常返回
                    if !(r.rows.isEmpty && page == 1 && r.total > 0) {
                        pageRows = r.rows
                        if page == 1 { expected = r.total }
                        break
                    }
                }
                if attempt < pageAttempts - 1 {
                    Thread.sleep(forTimeInterval: 0.8 * Double(attempt + 1))
                }
            }
            DataSources.throttleAfterNetwork()
            guard let rows = pageRows else {
                return page == 1 ? nil : collected.isEmpty ? nil : collected
            }
            if rows.isEmpty { break }   // 翻到底
            for r in rows where seen.insert(r.code).inserted { collected.append(r) }
            if expected > 0 && collected.count >= expected { break }
        }
        guard !collected.isEmpty else { return nil }
        return collected.sorted { $0.changePct > $1.changePct }
    }
}
