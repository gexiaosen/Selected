import Foundation

/// 个股基本面。
///
/// ## 数据源：东财 `clist`（板块热度同族接口的个股域）
///
/// ```
/// https://push2.eastmoney.com/api/qt/clist/get?pn=N&pz=100&np=1&fltt=2&invt=2&fid=f12
///   &fs=m:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23
///   &fields=f12,f14,f9,f23,f37,f40,f41,f45,f46,f57,f112,f113,f114,f115
/// ```
///
/// ## ⚠ 字段口径（东财 `f` 编号的含义在第三方文档里各家不同，逐个用**算术恒等式**在真实响应上验过）
///
/// | 字段 | 含义 |
/// |------|------|
/// | `f9` | 市盈率(动态) |
/// | `f23` | 市净率 |
/// | `f112` | 每股收益 |
/// | `f113` | 每股净资产 |
/// | `f114` / `f115` | 市盈率(静态) / (TTM) |
/// | `f37` | ROE |
/// | `f40` / `f41` | 营业收入 / 同比 |
/// | `f45` / `f46` | 净利润 / 同比 |
/// | `f57` | 资产负债率 |
///
/// ⚠ **未能校验的一律不用**：`f48` / `f61` / `f129` / `f130` / `f131` / `f132` / `f133` / `f173`
/// 在算术上都不自洽（对不上任何已知量）→ **宁缺勿错**。
/// 这也是「**股本股东**」那一组做不了的原因 —— 它的字段（总股本 / 流通股本 / 股东人数）
/// 全在这批未校验字段里，而股东人数（`f134`）实测直接返回 `"-"`。
///
/// ## ⚠ 定性：慢变量，**只展示、不进评分、不进筛选**
///
/// ## ⚠ 为什么**独立抓取**（而不是和别的批量取数共用一轮）
/// 1. **数据集各自演进** —— 基本面还要继续校验更多字段（`f132`/`f133`…），
///    共用一个抓取会让"加一个字段"波及另一个模块
/// 2. **可以独立刷新** —— 手动按钮各管各的，失败互不牵连
/// 3. ⚠ 代价是**手动刷新一次 56 个请求**（季度级慢变量，可忽略）
///
/// ⚠ `pz` 有**服务端上限 100**（不是想调多大就多大），要压缩请求数先看这条。
public enum Fundamental {

    /// 全市场只数**下界**：低于它判为抓取失败（拦住半截数据）。
    public static let minStocks = 4000

    /// 数值的**量纲** —— 决定界面怎么格式化，也提醒"不同量纲不能直接比"。
    public enum Unit: String, Sendable {
        case multiple   // 倍（PE / PB）
        case percent    // 百分数（ROE / 同比 / 资产负债率）
        case perShare   // 元/股（EPS / 每股净资产）
        case money      // 元（营收 / 净利润）→ 界面折成亿元
    }

    /// 一个展示项。`value == nil` = **源没给**（`"-"` 哨兵或字段缺失），
    /// ⚠ 与 `0` 是两回事（负债率 0% 与"没数据"完全不同的结论）。
    public struct Metric: Sendable {
        public let label: String
        public let value: Double?
        public let unit: Unit
    }

    /// 一组。
    public struct MetricGroup: Sendable, Identifiable {
        public let title: String
        public let metrics: [Metric]
        public var id: String { title }
    }

    /// 一条"个股 → 基本面"
    public struct Item: Equatable, Sendable {
        public let code: String
        public let name: String
        // ① 估值指标
        public let peDynamic: Double?
        public let peStatic: Double?
        public let peTtm: Double?
        public let pb: Double?
        // ② 每股指标
        public let eps: Double?
        public let bvps: Double?
        // ③ 盈利能力
        public let roe: Double?
        public let revenue: Double?
        public let netProfit: Double?
        // ④ 成长能力
        public let revenueYoy: Double?
        public let netProfitYoy: Double?
        // ⑤ 资本结构与偿债能力
        public let debtRatio: Double?

        /// 五组（「股本股东」组字段校验不过 → 不做，见类型注释）。
        ///
        /// ⚠ 放 Core 而不是视图里，是为了**分组口径可测**（"哪个字段属于哪一组"是口径，不是排版）。
        public var groups: [MetricGroup] {
            [
                MetricGroup(title: "估值指标", metrics: [
                    Metric(label: "市盈率(动态)", value: peDynamic, unit: .multiple),
                    Metric(label: "市盈率(TTM)", value: peTtm, unit: .multiple),
                    Metric(label: "市盈率(静态)", value: peStatic, unit: .multiple),
                    Metric(label: "市净率", value: pb, unit: .multiple),
                ]),
                MetricGroup(title: "每股指标", metrics: [
                    Metric(label: "每股收益", value: eps, unit: .perShare),
                    Metric(label: "每股净资产", value: bvps, unit: .perShare),
                ]),
                MetricGroup(title: "盈利能力", metrics: [
                    Metric(label: "净资产收益率", value: roe, unit: .percent),
                    Metric(label: "营业收入", value: revenue, unit: .money),
                    Metric(label: "净利润", value: netProfit, unit: .money),
                ]),
                MetricGroup(title: "成长能力", metrics: [
                    Metric(label: "营收同比", value: revenueYoy, unit: .percent),
                    Metric(label: "净利同比", value: netProfitYoy, unit: .percent),
                ]),
                MetricGroup(title: "资本结构与偿债能力", metrics: [
                    Metric(label: "资产负债率", value: debtRatio, unit: .percent),
                ]),
            ]
        }
    }

    /// 抓取报告（供设置页展示）
    public struct Report: Equatable, Sendable {
        public var stocks = 0
        /// 至少一项基本面**有值**的只数（其余是源没给的）
        public var withData = 0
        /// 被下界/完整性拦下 → **保留旧数据**
        public var rejected: String?

        public var summary: String {
            if let why = rejected { return "未刷新（保留旧数据）：\(why)" }
            return "已刷新 \(stocks) 只（其中 \(withData) 只有数据）"
        }
    }
}

/// 一次全市场抓取的结果。
///
/// ⚠ 把**源报总数**带出来，让调用方能如实报告"拿到了多少"（不完整就整轮作废）。
public struct FundamentalFetch: Equatable, Sendable {
    public let items: [Fundamental.Item]
    /// 源报的全市场总数（`data.total`）
    public let expected: Int
}

/// 东财基本面的**抓取 + 纯解析**（分开是为了让解析可离线单测）。
public enum FundamentalSource {

    static let host = DataSourceEndpoints.eastmoneyPush2
    static let referer = DataSourceEndpoints.eastmoneyReferer

    /// 本源的"失败归属范围"（含 `fs=` 业务域，与板块热度 / 成份隔离）：给 `DataSources.lastFetchFailureReason(matching:)` 用
    public static let failureScope = host + "/api/qt/clist/get?fs=" + fs

    /// ⚠ **服务端强制上限**（实测 `pz=500` 也只回 100）
    static let pageSize = 100
    static let maxPages = 80
    /// **每页最多抓几次**（秒级退避）
    static let pageAttempts = 3
    /// 沪深 A 股：深主板 + 创业板 + 沪主板 + 科创板。
    /// ⚠ 这四个市场段就是全市场票池的定义，改它等于换口径 —— 必须与 `securities` 同步。
    static let fs = "m:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23"
    /// ⚠ **只列校验过的字段**（见 `Fundamental` 类型注释的字段表）
    static let fields = "f12,f14,f9,f23,f37,f40,f41,f45,f46,f57,f112,f113,f114,f115"

    public static func url(page: Int) -> String {
        host + "/api/qt/clist/get?pn=\(page)&pz=\(pageSize)&po=1&np=1&fltt=2&invt=2"
            + "&fid=f12&fs=\(fs)&fields=\(fields)"
    }

    /// 源字段 → `Double`；**源没给 / 非法 → `nil`**（不折成 0）。
    ///
    /// ⚠⚠ **只有 `NSDecimalNumber` 走字符串，普通 `NSNumber` 必须走 `doubleValue`** ——
    /// 两个方向都有实测证据（直接验 `JSONSerialization` 的输出）：
    ///
    /// | 输入文本 | 解析成的类型 | `doubleValue` | `Double(stringValue)` |
    /// |---------|------------|--------------|---------------------|
    /// | `0.070000000000000007` | **`NSDecimalNumber`** | `0.07000000000000003` ❌ | `0.07` ✅ |
    /// | `1.6992965936660767` | `__NSCFNumber` | `1.6992965936660767` ✅ | `1.699296593666077` ❌ |
    ///
    /// → **同一个"长小数"，两个方向都会错**：
    /// · `NSDecimalNumber.doubleValue` **不是正确舍入**（差 1 ULP）
    /// · `NSNumber.stringValue` 会把普通 `NSNumber` **重新格式化成 ~15 位有效数字**（丢精度）
    ///
    /// 所以分支顺序与转换方式**都不能省**：`NSDecimalNumber` 分支必须**先判**
    /// （它也是 `NSNumber`）且走 `stringValue`；其余 `NSNumber` 走 `doubleValue`。
    /// ⚠ 源用 `"-"` 表示"没有"（字符串）→ 落到最后的 `nil`，正是我们要的。
    /// ⚠ 两条路都有测试钉住（`testLongDecimalIsCorrectlyRounded` /
    /// `testPlainNSNumberKeepsFullPrecision`）。
    public static func num(_ v: Any?) -> Double? {
        if let dec = v as? NSDecimalNumber {
            let d = Double(dec.stringValue)
            return d?.isFinite == true ? d : nil
        }
        if let n = v as? NSNumber {
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// 纯解析：**一页**响应 → `(记录, 源报总数)`
    ///
    /// ⚠ `data.diff` 在 `np=1` 时是**数组**、不带 `np` 时是**字典**（键是序号）。两种都认。
    public static func parse(_ text: String) -> (rows: [Fundamental.Item], total: Int) {
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
        var out: [Fundamental.Item] = []
        out.reserveCapacity(raw.count)
        for row in raw {
            // ⚠ 6 位纯数字代码才算（源里混着代码非法的行）
            guard let code = row["f12"] as? String,
                  DataSourceEndpoints.isSixDigitCode(code) else { continue }
            out.append(Fundamental.Item(
                code: code,
                name: (row["f14"] as? String) ?? "",
                peDynamic: num(row["f9"]),
                peStatic: num(row["f114"]),
                peTtm: num(row["f115"]),
                pb: num(row["f23"]),
                eps: num(row["f112"]),
                bvps: num(row["f113"]),
                roe: num(row["f37"]),
                revenue: num(row["f40"]),
                netProfit: num(row["f45"]),
                revenueYoy: num(row["f41"]),
                netProfitYoy: num(row["f46"]),
                debtRatio: num(row["f57"])))
        }
        return (out, total)
    }

    /// 抓**一页**（失败 / 可疑空页都重试，退避到秒级）。
    /// 三条理由（为何要重试、为何 `httpGet` 自带的 `retries` 不够、为何"空页也要重试"）
    /// 单页最多试 `pageAttempts` 次，退避到**秒级**（`httpGet` 内部只有 0.3/0.6s，穿不过分钟级限流窗口）。
    static func fetchPage(_ page: Int, expected: Int, collected: Int,
                          deadline: Date? = nil)
        -> (rows: [Fundamental.Item], total: Int)? {
        for attempt in 0..<pageAttempts {
            // `push2ex` 无 `clist/get` 路径，直走 `httpGet`（避免无效降级与 host_fallback_failed 噪音）
            if let text = DataSources.httpGet(url(page: page), referer: referer,
                                             deadline: deadline) {
                let r = parse(text)
                let suspiciousEmpty = r.rows.isEmpty && expected > 0 && collected < expected
                if !suspiciousEmpty { return r }
            }
            // ⚠ 超预算即停（审查 B4：不传 deadline 时，一次网络黑洞能让整轮挂几十分钟）
            if let deadline, Date() >= deadline { return nil }
            if attempt < pageAttempts - 1 {
                Thread.sleep(forTimeInterval: 0.8 * Double(attempt + 1))    // 0.8s / 1.6s
            }
        }
        return nil
    }

    /// 整轮取数预算（秒）
    static let roundBudgetSec: TimeInterval = 240


    /// 抓全市场（**分页 56 次**）。
    ///
    /// - Returns: `nil` = **没拿到**（源故障 / 条数不足 / 不完整）。
    ///   ⚠ **不返回空数组** —— `[]` 会被调用方当成"全市场都没有基本面"而覆盖掉好数据。
    public static func fetchAll() -> FundamentalFetch? {
        DataSourceRegistry.timed(.fundamental) { fetchAllImpl() }
    }

    static func fetchAllImpl() -> FundamentalFetch? {
        let deadline = Date().addingTimeInterval(roundBudgetSec)
        var collected: [Fundamental.Item] = []
        var seen = Set<String>()
        var expected = -1
        for page in 1...maxPages {
            if Date() >= deadline {
                DataSources.logDataSource("fundamental", "round_over_budget",
                                          "第 \(page) 页时超过 \(Int(roundBudgetSec))s 预算 → "
                                          + "带已有 \(collected.count) 条返回（完整性校验会据此判废）")
                break
            }
            guard let (rows, total) = fetchPage(page, expected: expected,
                                                collected: collected.count,
                                                deadline: deadline) else {
                if page == 1 {
                    DataSources.logDataSource("fundamental", "http_failed",
                                              "首页无数据（已重试 \(pageAttempts) 次）")
                    return nil
                }
                break     // 中途失败 → 下面的完整性校验会作废整轮并记下原因（带条数）
            }
            // ⚠ 每页之后节流：56 页无间隔 + 每次重试 3 次 = 最多 168 次请求连发 →
            //   会被东财按出口 IP 限流。
            DataSources.throttleAfterNetwork()
            if page == 1 {
                expected = total
                if total <= 0 {
                    DataSources.logDataSource("fundamental", "empty", "首页 total=\(total)")
                    return nil
                }
            }
            if rows.isEmpty { break }
            for r in rows where seen.insert(r.code).inserted { collected.append(r) }
            if collected.count >= expected { break }
        }
        guard !collected.isEmpty else { return nil }
        // ⚠ 完整性：实得 < 源报总数 → 某一页失败/被截断 → **宁可返回 nil**
        if expected > 0 && collected.count < expected {
            let why = "只取到 \(collected.count)/\(expected) 只（源返回被截断）"
            DataSources.logDataSource("fundamental", "incomplete", "\(why) → 丢弃")
            // 写进"抓取失败原因"通道：让卡片能显示具体截断数，而不是含糊的"源无响应"
            DataSources.recordFetchFailure(url(page: 1), why)
            return nil
        }
        return FundamentalFetch(items: collected.sorted { $0.code < $1.code }, expected: expected)
    }
}
