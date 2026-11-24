import Foundation

/// 行业板块的一条**当日行情**（板块热度排行）
///
/// ## 数据源与字段口径
///
/// 东财 `clist` 板块域（`fs=m:90+t:2`，约 496 个行业板块）：
///
/// | 字段 | 含义 |
/// |------|------|
/// | `f12` | 板块代码（`BK1296`） |
/// | `f14` | 板块名称 |
/// | `f2`  | 板块指数点位 |
/// | `f3`  | 涨跌幅（%） |
/// | `f6`  | 成交额（**元**） |
/// | `f8`  | 换手率（%） |
/// | `f20` | 总市值（**元**） |
/// | `f62` | **主力净流入**（元，与个股资金流 `f62` 同字段号同含义） |
/// | `f104` | 上涨家数 |
/// | `f105` | 下跌家数 |
/// | `f106` | 平盘家数 |
/// | `f128` / `f140` / `f141` | 领涨股名称 / 代码 / 市场 |
///
/// ⚠ **粒度**：`m:90+t:2` 返回的板块混了申万 **Ⅰ/Ⅱ/Ⅲ 三级**。
/// · **不要**拿板块名与涨停池的 `hybk` 做 join —— 它被**截断到 4 个汉字**，拼不回完整板块名。
/// → 本模块只做**板块级排行**，个股归属交叉留给未来的成份接口。
public struct BoardHeatPoint: Equatable, Sendable, Identifiable {

    /// 展示行身份键（单日排行内 `boardCode` 唯一；跨日历史查询不直接进 ForEach）
    public var id: String { boardCode }

    /// 交易日 `yyyy-MM-dd`（**由请求日期盖章**，响应不带日期 —— 与涨停池同一纪律）
    public let date: String
    /// 板块代码（`BK1296`）
    public let boardCode: String
    public let boardName: String
    /// 板块指数点位
    public let index: Double
    /// 涨跌幅（%）
    public let changePct: Double
    /// 成交额（**元**）
    public let amount: Double
    /// 换手率（%）
    public let turnoverRate: Double
    /// 总市值（**元**）
    public let totalCap: Double
    /// 主力净流入（**元**，可为负）
    public let mainNet: Double
    /// 板块内上涨家数
    public let upCount: Int
    /// 板块内下跌家数
    public let downCount: Int
    /// 板块内平盘家数
    public let flatCount: Int
    /// 领涨股名称
    public let leaderName: String
    /// 领涨股代码（6 位；源缺失 → 空串）
    public let leaderCode: String
    /// 领涨股市场（源 `f141`：0=深 / 1=沪）；`-1` = 源没给
    public let leaderMarket: Int

    public init(date: String, boardCode: String, boardName: String, index: Double,
                changePct: Double, amount: Double, turnoverRate: Double, totalCap: Double,
                mainNet: Double, upCount: Int, downCount: Int, flatCount: Int,
                leaderName: String, leaderCode: String, leaderMarket: Int) {
        self.date = date
        self.boardCode = boardCode
        self.boardName = boardName
        self.index = index
        self.changePct = changePct
        self.amount = amount
        self.turnoverRate = turnoverRate
        self.totalCap = totalCap
        self.mainNet = mainNet
        self.upCount = upCount
        self.downCount = downCount
        self.flatCount = flatCount
        self.leaderName = leaderName
        self.leaderCode = leaderCode
        self.leaderMarket = leaderMarket
    }
}

/// 板块行情的**抓取 + 纯解析**（分开是为了让解析可离线单测）。
///
/// ## ⚠ 三条约束（都会静默出错）
///
/// 1. **`pz` 服务端上限 100** → 约 496 个板块要**分页 5 次**。
///    每次分页之间**必须** `throttleAfterNetwork()`：东财按出口 IP 限流，连发会被封。
/// 2. **完整性**：实得 < 源报 `total` → 某一页失败/被截断 → **宁可返回 nil**。
///    半份板块表会让排行页把"没抓到"显示成"没上榜"——假否定。
/// 3. **不返回空数组**：`[]` 会被调用方当成"今天一个板块都没有"而写一天空记录。
public enum BoardHeatSource {

    static let host = DataSourceEndpoints.eastmoneyPush2
    static let referer = DataSourceEndpoints.eastmoneyReferer

    /// 失败归属范围（含 `fs=` 业务域，与基本面 / 板块成份隔离）：给 `DataSources.lastFetchFailureReason(matching:)` 用
    public static let failureScope = host + "/api/qt/clist/get?fs=" + fs

    /// 板块域筛选（`m:90` = 板块市场，`t:2` = 行业板块）
    static let fs = "m:90+t:2"
    /// 字段清单（含义见 `BoardHeatPoint` 的校验表）
    static let fields = "f12,f14,f2,f3,f6,f8,f20,f62,f104,f105,f106,f128,f140,f141"

    /// ⚠ 服务端强制上限（`pz>100` 只回 100）
    static let pageSize = 100
    /// 翻页上限：496/100 = 5 页，给到 12 留余量（板块数会随源调整）
    static let maxPages = 12
    /// 每页最多抓几次（秒级退避）
    static let pageAttempts = 3
    /// 板块数**下界**：低于它判为抓取失败（实测 496 个；拦住"筛选条件写错/整批拿不到"）
    public static let minBoards = 300

    /// 抓**一页**（失败 / 可疑空页都重试，退避到秒级）。
    ///
    /// ⚠ "空页也重试"：还没到源报总数时返回空 = 可疑截断，不是正常收尾。
    static func fetchPage(_ page: Int, expected: Int, collected: Int)
        -> (rows: [BoardHeatPoint], total: Int)? {
        for attempt in 0..<pageAttempts {
            if let text = DataSources.httpGet(url(page: page), referer: referer) {
                let r = parse(text, date: DataSources.runDate())
                let suspiciousEmpty = r.rows.isEmpty && expected > 0 && collected < expected
                if !suspiciousEmpty { return r }
            }
            if attempt < pageAttempts - 1 {
                Thread.sleep(forTimeInterval: 0.8 * Double(attempt + 1))    // 0.8s / 1.6s
            }
        }
        return nil
    }

    /// 拼 URL。**排序键必须用 `fid=f12`（板块代码，稳定）**，不是 `f3`（涨幅）——
    ///
    /// ⚠ 用 `fid=f3` 时源**每次请求都按实时涨幅重排**，分页之间列表漂移，
    ///   5 页拼完去重后会缺条（完整性校验会如实丢弃）。`f12` 是稳定键，分页确定性由它保证；
    ///   排行顺序由**消费侧**排（`BoardHeatStore.dayRows` 按涨幅降序）。
    public static func url(page: Int) -> String {
        host + "/api/qt/clist/get?pn=\(page)&pz=\(pageSize)&po=1&np=1&fltt=2&invt=2"
            + "&fid=f12&fs=\(fs)&fields=\(fields)"
    }

    /// 纯解析：**一页**响应 → `(记录, 源报总数)`
    ///
    /// **全有或全无**：整体不是预期形状 → `([], 0)`。
    /// ⚠ `data.diff` 在 `np=1` 时是**数组**；不带 `np` 时是**字典**（键是序号）—— 两种都认，
    ///   防参数被改后静默拿到空。
    public static func parse(_ text: String, date: String)
        -> (rows: [BoardHeatPoint], total: Int) {
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
        var out: [BoardHeatPoint] = []
        out.reserveCapacity(raw.count)
        for row in raw {
            // 板块代码必须是 `BK` + 数字。非 BK 前缀 = 筛选条件被改错，整行跳过（宁缺勿错）。
            guard let code = row["f12"] as? String,
                  code.hasPrefix("BK"), code.count == 6,
                  code.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }
            let name = (row["f14"] as? String) ?? ""
            guard !name.isEmpty, name != "-" else { continue }
            out.append(BoardHeatPoint(
                date: date,
                boardCode: code,
                boardName: name,
                index: num(row["f2"]),
                changePct: num(row["f3"]),
                amount: num(row["f6"]),
                turnoverRate: num(row["f8"]),
                totalCap: num(row["f20"]),
                mainNet: num(row["f62"]),
                upCount: intNum(row["f104"]),
                downCount: intNum(row["f105"]),
                flatCount: intNum(row["f106"]),
                // ⚠ 休市时段源对领涨股三项给 `"-"` 哨兵 → 折成空串（哨兵不是数据）。
                leaderName: str(row["f128"]),
                leaderCode: leaderCode(row["f140"]),
                leaderMarket: (row["f141"] as? NSNumber)?.intValue ?? -1))
        }
        return (out, total)
    }

    /// 领涨股代码：源可能给字符串、数字或 `"-"` → 统一取数字串
    static func leaderCode(_ v: Any?) -> String {
        if let s = v as? String, DataSourceEndpoints.isSixDigitCode(s) { return s }
        if let n = v as? NSNumber {
            let s = String(format: "%06d", n.intValue)
            return n.intValue > 0 ? s : ""
        }
        return ""
    }

    /// 字符串取值：`"-"` 哨兵（休市时段源给）折成空串（哨兵不是数据）。
    static func str(_ v: Any?) -> String {
        let s = (v as? String) ?? ""
        return s == "-" ? "" : s
    }

    /// 源字段 → Double（NSNumber / 数字字符串都认，收敛到 `Num.doubleOrZero`）
    static func num(_ v: Any?) -> Double { Num.doubleOrZero(v) }

    /// 源字段 → Int（字符串形态也认）
    static func intNum(_ v: Any?) -> Int {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) ?? 0 }
        return 0
    }

    /// 轻量 TopN（**单页一次请求**，按涨幅降序）。
    ///
    /// 看板「领涨板块」盘中每 60 秒刷新用：只取 5~10 个板块，不翻 5 页、不写库，
    /// 避免把 496×12 行的全量抓取压到 1 分钟一次（东财按出口 IP 限流）。
    ///
    /// ⚠ 排序键 `fid=f3` 只影响**这一页**的顺序，没有全量分页的漂移问题。
    /// - Returns: `nil` = 没拿到。**不返回空数组**（调用方保留上一轮）。
    public static func fetchTop(limit: Int = 6) -> [BoardHeatPoint]? {
        DataSourceRegistry.timed(.boardHeat) { fetchTopImpl(limit: limit) }
    }

    static func fetchTopImpl(limit: Int) -> [BoardHeatPoint]? {
        let n = max(1, min(limit, 20))
        let u = host + "/api/qt/clist/get?pn=1&pz=\(n)&po=1&np=1&fltt=2&invt=2"
            + "&fid=f3&fs=\(fs)&fields=\(fields)"
        guard let text = DataSources.httpGet(u, referer: referer) else {
            // 60 秒一次，不写 data_source_logs（避免把诊断页淹掉；失败保留上一轮）
            NSLog("[NOTICE] 板块盘中 Top%d 取数失败", n)
            return nil
        }
        DataSources.throttleAfterNetwork()
        let parsed = parse(text, date: DataSources.runDate())
        guard !parsed.rows.isEmpty else {
            NSLog("[NOTICE] 板块盘中 Top%d 返回空", n)
            return nil
        }
        return Array(parsed.rows.sorted { $0.changePct > $1.changePct }.prefix(n))
    }

    /// 抓全部板块（**分页 5 次**，每页之间走全局限速）。
    ///
    /// - Returns: `nil` = 没拿到（源故障 / 条数不足 / 不完整）。**不返回空数组**。
    public static func fetchAll() -> [BoardHeatPoint]? {
        DataSourceRegistry.timed(.boardHeat) { fetchAllImpl() }
    }

    static func fetchAllImpl() -> [BoardHeatPoint]? {
        var collected: [BoardHeatPoint] = []
        var seen = Set<String>()
        var expected = -1
        for page in 1...maxPages {
            guard let (rows, total) = fetchPage(page, expected: expected,
                                                collected: collected.count) else {
                if page == 1 {
                    DataSources.logDataSource("boardheat", "http_failed",
                                              "首页无数据（已重试 \(pageAttempts) 次）")
                    return nil
                }
                break     // 中途失败 → 下面的完整性校验会作废整轮并记下原因
            }
            DataSources.throttleAfterNetwork()
            if page == 1 {
                expected = total
                if total <= 0 {
                    DataSources.logDataSource("boardheat", "empty", "首页 total=\(total)")
                    return nil
                }
            }
            if rows.isEmpty { break }   // 空页 = 翻到底了（源筛选条件可能变化）
            for r in rows where seen.insert(r.boardCode).inserted { collected.append(r) }
            if collected.count >= expected { break }
        }
        guard !collected.isEmpty else { return nil }
        // ⚠ 下界：板块数骤降 = 拿错了筛选条件 / 整批异常 → 判失败（宁缺勿错）
        if collected.count < minBoards {
            let why = "只取到 \(collected.count) 个板块（下界 \(minBoards)）"
            DataSources.logDataSource("boardheat", "below_min", "\(why) → 丢弃")
            DataSources.recordFetchFailure(url(page: 1), why)
            return nil
        }
        // ⚠ 完整性：实得 < 源报总数 → 某一页失败/被截断 → 丢弃整轮
        if expected > 0 && collected.count < expected {
            let why = "只取到 \(collected.count)/\(expected) 个板块（源返回被截断）"
            DataSources.logDataSource("boardheat", "incomplete", "\(why) → 丢弃")
            DataSources.recordFetchFailure(url(page: 1), why)
            return nil
        }
        return collected
    }
}
