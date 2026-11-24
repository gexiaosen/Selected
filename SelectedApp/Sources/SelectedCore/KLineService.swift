import Foundation

// MARK: - K 线 / 分时数据服务（腾讯为主，东财分时兜底）

/// 单根 K 线
public struct KLineItem: Sendable {
    public let date: String   // "2026-06-12"
    public let open: Double
    public let high: Double
    public let low: Double
    public let close: Double
    /// 成交量（**手**，腾讯日/周/月线第 6 字段原值）
    public let volume: Double
    /// 成交额（**元**）。腾讯第 9 字段是万元，解析时已 ×10000；
    /// 新浪兜底没有该字段 → 0（整批都没有时副图自动回落到成交量）。
    public let amount: Double

    public init(date: String, open: Double, high: Double, low: Double, close: Double,
                volume: Double, amount: Double = 0) {
        self.date = date
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
        self.amount = amount
    }
}

/// 分时数据点
public struct MinutePoint: Sendable {
    public let time: String   // "09:30"
    public let price: Double
    public let volume: Double // 累计成交量（手）
    /// 累计成交额（**元**）。腾讯分时第 4 字段原值；东财为分钟额逐点累加。
    public let amount: Double

    public init(time: String, price: Double, volume: Double, amount: Double = 0) {
        self.time = time
        self.price = price
        self.volume = volume
        self.amount = amount
    }
}

/// K 线来源（主源腾讯 + 两路兜底）
public enum KLineSource: String, Sendable, Equatable {
    case tencent = "腾讯"
    case ths = "同花顺"
    case sina = "新浪"
}

/// K 线拉取回执：把来源与复权口径**随本次调用一并返回**，避免多只票或并发分支共享全局标志互相覆盖。
public struct KLineResult: Sendable {
    public let items: [KLineItem]
    public let source: KLineSource
    public let adjusted: Bool

    public init(items: [KLineItem], source: KLineSource, adjusted: Bool) {
        self.items = items
        self.source = source
        self.adjusted = adjusted
    }
}

/// 分时拉取回执：携带本次是否走了东财兜底。
public struct MinuteResult: Sendable {
    public let points: [MinutePoint]
    public let usedFallback: Bool

    public init(points: [MinutePoint], usedFallback: Bool) {
        self.points = points
        self.usedFallback = usedFallback
    }
}

/// K 线周期
public enum KLinePeriod: String, CaseIterable, Sendable {
    case minute, daily, weekly, monthly

    public var displayName: String {
        switch self {
        case .minute: return "分时"
        case .daily: return "日K"
        case .weekly: return "周K"
        case .monthly: return "月K"
        }
    }
}

public enum KLineService {
    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

    /// 腾讯前复权 K 线端点。
    /// 原 `web.ifzq.gtimg.cn/appstock/app/fqkline/get` 被腾讯 WAF **整条路径**拦截
    /// （HTTP 501 + waf.tencent.com 跳转页），`proxy.finance.qq.com/ifzqgtimg` 是同一份数据
    /// （字段同为 qfqday/qfqweek/qfqmonth）。
    /// ⚠ 值已收敛到 `DataSourceEndpoints.tencentKLine`，这里只留别名。
    private static let tencentKLineURL = DataSourceEndpoints.tencentKLine

    /// 失败原因分槽前缀（走 `DataSources.recordFetchFailure` 机制）：
    /// 空响应与"真无数据"同形会让详情页笼统报"获取失败" —— 空响应（HTTP 200 但解析不出）
    /// 应如实记"K线源解析失败"，`fetchFailureMessage` 据此区分文案。
    public static let failureScope = tencentKLineURL

    // MARK: - 分时源切换（腾讯镜像 → 备用 host → 东财 1 分钟）

    /// 腾讯两个 host 都失败后的 60s 熔断截止（进程级健康状态，避免 1s 轮询每秒撞墙），
    /// 以及「是否已记过切换日志」去重位（UI 降级标牌走每次调用返回的 `MinuteResult.usedFallback`，不再读全局态）。
    private static let minuteLock = NSLock()
    private nonisolated(unsafe) static var _minuteFallbackLogged = false
    private nonisolated(unsafe) static var _minuteTencentDownUntil: Date?

    private static var minuteTencentDown: Bool {
        minuteLock.withLock {
            guard let until = _minuteTencentDownUntil else { return false }
            if until > Date() { return true }
            _minuteTencentDownUntil = nil
            return false
        }
    }

    private static func markTencentMinuteDown() {
        let firstTime = minuteLock.withLock { () -> Bool in
            let now = Date()
            let already = (_minuteTencentDownUntil ?? .distantPast) > now
            _minuteTencentDownUntil = now.addingTimeInterval(60)
            return !already
        }
        if firstTime {
            DataSources.logDataSource("tencent", "minute_down",
                                      "腾讯分时主/备 host 均不可用 → 60s 内走东财兜底")
        }
    }

    private static func markTencentMinuteRecovered() {
        let wasFallback = minuteLock.withLock { () -> Bool in
            let was = _minuteFallbackLogged
            _minuteFallbackLogged = false
            _minuteTencentDownUntil = nil
            return was
        }
        if wasFallback {
            DataSources.logDataSource("tencent", "minute_recovered", "腾讯分时恢复，停止东财兜底")
        }
    }

    private static func markEastmoneyMinuteActive(fullCode: String, count: Int) {
        let switched = minuteLock.withLock { () -> Bool in
            let was = _minuteFallbackLogged
            _minuteFallbackLogged = true
            return !was
        }
        if switched {
            DataSources.logDataSource("eastmoney", "minute_fallback",
                                      "\(fullCode) 腾讯分时不可用 → 东财 1 分钟兜底（\(count)点）")
        }
    }

    /// 拉取 K 线（日/周/月，前复权）；腾讯不可用时按「同花顺(前复权) → 新浪(不复权)」回落，
    /// 并把 `source` 与 `adjusted` 口径直接封装在返回值 `KLineResult` 里。
    ///
    /// - Parameter before: 分页参数。非 nil 时取「**截止该日期**的 count 根」，
    ///   用于拖到最左边缘时补齐更早历史。注意此时**不做兜底**：兜底接口没有日期区间参数，
    ///   回落会返回最新一页并被当成"更早历史"重复插入 → 宁可返回 nil 让调用方停止分页。
    public static func fetchKLine(fullCode: String, period: KLinePeriod, count: Int = 120,
                           before: Date? = nil) async -> KLineResult? {
        await DataSourceRegistry.timedAsync(.kline) {
            await fetchKLineImpl(fullCode: fullCode, period: period, count: count, before: before)
        }
    }

    static func fetchKLineImpl(fullCode: String, period: KLinePeriod, count: Int = 120,
                           before: Date? = nil) async -> KLineResult? {
        guard period != .minute else { return nil }
        // ⚠ 本轮失败原因**只属于本轮** —— 清掉上次的，避免张冠李戴
        DataSources.clearFetchFailure(matching: failureScope)
        if let items = await fetchTencentKLine(fullCode: fullCode, period: period,
                                               count: count, before: before) {
            return KLineResult(items: items, source: .tencent, adjusted: true)
        }
        guard before == nil else { return nil }
        // 兜底①：同花顺日K（**前复权**，与主源同口径 ⇒ 不会有除权跳空，指标值可直接用）。
        //   单次只有 140 根：日K首屏要 500 根时图会变短，这点由标注如实说明。
        //   只覆盖日K；周K/月K 的同花顺路径码实测取不到（`03`/`04`/`100` 全 404）→ 不猜。
        if period == .daily, !QuoteSymbol.isIndex(fullCode),
           let items = await fetch10jqkaKLine(fullCode: fullCode, count: count), !items.isEmpty {
            DataSources.logDataSource("10jqka", "kline_fallback",
                                      "\(fullCode) 腾讯K线不可用 → 同花顺前复权兜底（\(items.count)根）")
            return KLineResult(items: items, source: .ths, adjusted: true)
        }
        // 兜底②：新浪 K 线（scale 240=日 / 1200=周 / 7200=月）。
        // 注意是**不复权**数据，除权除息日会有价格跳空 —— 仅作降级，保证"有图可看"而非整块空白。
        guard let items = await fetchSinaKLine(fullCode: fullCode, period: period, count: count),
              !items.isEmpty else { return nil }
        return KLineResult(items: items, source: .sina, adjusted: false)
    }

    /// 各周期首屏历史根数（保守口径）。
    /// 数据源上限实测：腾讯日K 单次约 641 根、周K/月K ≥300，日取 500 留余量；
    /// 更早历史由「拖到最左自动加载」分页补齐（每页同为首屏根数）。
    public static func initialCount(for period: KLinePeriod) -> Int {
        switch period {
        case .weekly: return 250
        case .monthly: return 120
        default: return 500
        }
    }

    /// 分页取更早历史时的页大小
    public static func pageSize(for period: KLinePeriod) -> Int { initialCount(for: period) }

    // ⚠ 日期格式化必须走 `ChinaTime`（全项目唯一出口，已钉死 `Asia/Shanghai` + `en_US_POSIX`）：
    //   裸建 `DateFormatter` 只设 `timeZone`、**漏 `locale`** 时，设备设为佛历/和历等非公历
    //   `yyyy` 会输出 2569 之类 → 拼出的腾讯分页 `end=` 参数落到**错误年份**，
    //   静默取回错误的日期区间。
    private static var dateFmt: DateFormatter { ChinaTime.dayFormatter }

    private static func periodKey(_ p: KLinePeriod) -> String {
        switch p {
        case .weekly: return "week"
        case .monthly: return "month"
        default: return "day"
        }
    }

    /// 主源：腾讯前复权 K 线（before 非 nil 时为「截止该日期的 count 根」，即分页取更早历史）
    private static func fetchTencentKLine(fullCode: String, period: KLinePeriod,
                                          count: Int, before: Date? = nil) async -> [KLineItem]? {
        let p = periodKey(period)
        let end = before.map { dateFmt.string(from: $0) } ?? ""
        guard let url = URL(string: "\(tencentKLineURL)?param=\(fullCode),\(p),,\(end),\(count),qfq") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://gu.qq.com", forHTTPHeaderField: "Referer")   // 无 Referer 时腾讯可能返回空
        do {
            let data = try await HTTPFetch.get(req)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dict = json["data"] as? [String: Any],
                  let stockData = dict[fullCode] as? [String: Any] else { return nil }
            // 个股 key 带 qfq 前缀；指数（如 sh000001）无前缀
            // ⚠ 行是**混合类型数组**（newfqkline 第 7 位是 `{}` 字典，旧 fqkline 是纯字符串数组），
            //   必须按 [[Any]] 解析 —— 用 [[String]] 会整体转换失败、静默退回落
            let lines = (stockData["qfq\(p)"] as? [[Any]]) ?? (stockData[p] as? [[Any]]) ?? []
            let items = parseTencentKLines(lines)
            // ⚠ HTTP 200 但解析不出可用行（源改版 / 半截响应）——
            //   与"真无数据"返回同形 nil，但原因不同，必须留痕供 `fetchFailureMessage` 区分
            if items.isEmpty {
                DataSources.recordFetchFailure(tencentKLineURL,
                                               "腾讯K线返回空/解析失败（HTTP 200 但无可用行）")
            }
            return items.isEmpty ? nil : items
        } catch {
            // ⚠ 如实记"请求失败"（网络层原因），与空解析区分
            DataSources.recordFetchFailure(tencentKLineURL,
                                           "腾讯K线请求失败：\(String(describing: error))")
            return nil
        }
    }

    /// 腾讯 K 线行解析（纯函数，可单测）。
    ///
    /// 字段序：`date, open, close, high, low, volume(手), {}, 换手率, 成交额(万元), …`
    /// ⚠ 第 9 字段是**万元**（不是元）；缺失时成交额回落 0，副图在该根画空柱。
    static func parseTencentKLines(_ lines: [[Any]]) -> [KLineItem] {
        var items: [KLineItem] = []
        items.reserveCapacity(lines.count)
        for line in lines {
            guard line.count >= 6,
                  let day = line[0] as? String,
                  let open = num(line[1]), let close = num(line[2]),
                  let high = num(line[3]), let low = num(line[4]),
                  open > 0, close > 0 else { continue }
            let amountWan = line.count > 8 ? (num(line[8]) ?? 0) : 0
            items.append(KLineItem(date: day, open: open, high: high, low: low,
                                   close: close, volume: num(line[5]) ?? 0,
                                   amount: amountWan > 0 ? amountWan * 10_000 : 0))
        }
        return items
    }

    /// 腾讯字段可能是字符串（"1400.00"）或数值（JSON 数字）→ 统一成 Double
    private static func num(_ v: Any) -> Double? {
        if let s = v as? String { return Double(s) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    /// 兜底源①：同花顺日K（`d.10jqka.com.cn/v6/line/hs_{6位代码}/01/last.js`）。
    ///
    /// 2026-11-02 实测：**无需 cookie**（同花顺其它接口要的 `v=` cookie 这条不要）、
    /// JSONP 包裹、单次恒 140 根、**前复权**（与腾讯 `newfqkline` 收盘价逐日一致）。
    /// 盘中**不含当日未完成 bar**（末根 = 前一交易日，与新浪同）→ 调用方要"末根=今日"仍须自合成。
    /// internal（不是 private）：真网自检要点着这条链路单独验一次取数。
    static func fetch10jqkaKLine(fullCode: String, count: Int) async -> [KLineItem]? {
        guard let urlString = thsKLineURL(fullCode: fullCode),
              let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue(DataSourceEndpoints.thsReferer, forHTTPHeaderField: "Referer")
        let items: [KLineItem]
        do {
            let data = try await HTTPFetch.get(req)
            guard let text = String(data: data, encoding: .utf8) else {
                DataSources.recordFetchFailure(urlString, "同花顺K线响应不是 UTF-8")
                return nil
            }
            items = parse10jqkaKLines(text)
        } catch {
            DataSources.recordFetchFailure(urlString, "同花顺K线请求失败：\(String(describing: error))")
            return nil
        }
        if items.isEmpty {
            DataSources.recordFetchFailure(urlString, "同花顺K线返回空/解析失败（HTTP 200 但无可用行）")
            return nil
        }
        return Array(items.suffix(max(1, min(count, items.count))))
    }

    /// 同花顺日K响应 → 升序 bar。
    ///
    /// `data` 是分号分隔的行，每行 `yyyyMMdd,开,高,低,收,量(股),额(元),换手率,…`。
    /// ⚠ 量是**股** → 折成 `KLineItem.volume` 的**手**（÷100）；额是**元** → 与主源同单位直接用。
    ///   标定（2026-11-02，600519 40 个交易日）：同花顺额 与 腾讯"万元×10000"**逐日完全相等**，
    ///   同花顺量 与 腾讯"手×100"最大差 49 股（整手取整），故单位判定不是猜的。
    /// 单行非法只跳过该行（源改版时宁可少给几根）。
    static func parse10jqkaKLines(_ text: String) -> [KLineItem] {
        guard let body = DataSources.jsonpBody(text),
              let root = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let payload = root["data"] as? String, !payload.isEmpty else { return [] }
        var items: [KLineItem] = []
        for row in payload.components(separatedBy: ";") {
            let f = row.components(separatedBy: ",")
            guard f.count >= 7, f[0].count == 8, f[0].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let open = Double(f[1]), let high = Double(f[2]),
                  let low = Double(f[3]), let close = Double(f[4]),
                  open > 0, close > 0 else { continue }
            items.append(KLineItem(date: "\(f[0].prefix(4))-\(f[0].dropFirst(4).prefix(2))-\(f[0].suffix(2))",
                                   open: open, high: high, low: low, close: close,
                                   volume: (Double(f[5]) ?? 0) / 100.0,
                                   amount: Double(f[6]) ?? 0))
        }
        return items
    }

    /// 同花顺日K URL。
    /// ⚠ **指数必须挡掉**：`hs_000001` 返回的是**平安银行**（同数字不同市场），
    ///   一旦放过去，上证指数会画成一只银行股且**没有任何报错**。
    static func thsKLineURL(fullCode: String) -> String? {
        let lower = fullCode.lowercased()
        let market = String(lower.prefix(2))
        let digits = String(lower.dropFirst(2))
        guard ["sh", "sz", "bj"].contains(market),
              DataSourceEndpoints.isSixDigitCode(digits),
              !QuoteSymbol.isIndex(lower) else { return nil }
        return DataSourceEndpoints.thsKLine + "hs_\(digits)/01/last.js"
    }

    /// 兜底源②：新浪 K 线。响应是 JSONP（`var _=([{…}]);`），取首个 `[` 到末个 `]` 即 JSON
    private static func fetchSinaKLine(fullCode: String, period: KLinePeriod, count: Int) async -> [KLineItem]? {
        let scale = period == .daily ? 240 : (period == .weekly ? 1200 : 7200)
        let datalen = min(1023, max(count, 120))          // 新浪单次上限 1023 根
        guard let url = URL(string: DataSourceEndpoints.sinaKLine
            + "var%20_=/CN_MarketDataService.getKLineData?symbol=\(fullCode)&scale=\(scale)&ma=no&datalen=\(datalen)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        do {
            let data = try await HTTPFetch.get(req)
            guard let text = String(data: data, encoding: .utf8),
                  let lo = text.firstIndex(of: "["), let hi = text.lastIndex(of: "]"),
                  let rows = try? JSONSerialization.jsonObject(with: Data(text[lo...hi].utf8)) as? [[String: Any]] else { return nil }
            var items: [KLineItem] = []
            items.reserveCapacity(rows.count)
            for row in rows {
                guard let day = row["day"] as? String,
                      let open = Double(row["open"] as? String ?? ""),
                      let close = Double(row["close"] as? String ?? ""),
                      let high = Double(row["high"] as? String ?? ""),
                      let low = Double(row["low"] as? String ?? ""),
                      open > 0, close > 0 else { continue }
                items.append(KLineItem(date: String(day.prefix(10)), open: open, high: high,
                                       low: low, close: close,
                                       volume: Double(row["volume"] as? String ?? "") ?? 0))
            }
            return items.isEmpty ? nil : items
        } catch {
            return nil
        }
    }

    /// 拉取分时（当日）。
    ///
    /// 链路：腾讯镜像 → 腾讯备用 host → 东财 1 分钟趋势。
    /// ⚠ `web.ifzq.gtimg.cn` 已被腾讯 WAF 拦截（HTTP 501，2026-10-21 实测）；
    ///   这里不再使用该 host。两个腾讯 host 都失败时熔断 60s，期间直接走东财，
    ///   避免 1s 轮询每秒都去撞墙。
    public static func fetchMinute(fullCode: String) async -> MinuteResult? {
        await DataSourceRegistry.timedAsync(.minute) { await fetchMinuteImpl(fullCode: fullCode) }
    }

    static func fetchMinuteImpl(fullCode: String) async -> MinuteResult? {
        if !minuteTencentDown {
            if let pts = await fetchTencentMinute(fullCode: fullCode), !pts.isEmpty {
                markTencentMinuteRecovered()
                return MinuteResult(points: pts, usedFallback: false)
            }
            markTencentMinuteDown()
        }
        if let pts = await fetchEastmoneyMinute(fullCode: fullCode), !pts.isEmpty {
            markEastmoneyMinuteActive(fullCode: fullCode, count: pts.count)
            return MinuteResult(points: pts, usedFallback: true)
        }
        return nil
    }

    /// 腾讯分时：主镜像失败则换备用 host（同数据同格式）。
    private static func fetchTencentMinute(fullCode: String) async -> [MinutePoint]? {
        let hosts = [DataSourceEndpoints.tencentMinute, DataSourceEndpoints.tencentMinuteAlt]
        var failures: [String] = []
        for (index, host) in hosts.enumerated() {
            guard let url = URL(string: "\(host)?code=\(fullCode)") else { continue }
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            do {
                let data = try await HTTPFetch.get(req)
                if let pts = parseTencentMinute(data, fullCode: fullCode), !pts.isEmpty {
                    if index > 0 {
                        DataSources.logDataSource("tencent", "minute_host_degraded",
                                                  "\(host) 生效（首选失败：\(failures.joined(separator: "；"))）")
                    }
                    return pts
                }
                let reason = "腾讯分时返回空/解析失败"
                DataSources.recordFetchFailure(host, reason)
                failures.append("\(host) → \(reason)")
            } catch {
                let reason = "腾讯分时请求失败：\(String(describing: error))"
                DataSources.recordFetchFailure(host, reason)
                failures.append("\(host) → \(String(describing: error))")
            }
        }
        return nil
    }

    /// 东财 1 分钟趋势兜底（`trends2`）。返回的 `volume` 已累加成累计量，与腾讯分时同口径。
    private static func fetchEastmoneyMinute(fullCode: String) async -> [MinutePoint]? {
        guard let urlString = eastmoneyMinuteURL(fullCode: fullCode),
              let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue(DataSourceEndpoints.eastmoneyReferer, forHTTPHeaderField: "Referer")
        // 东财 push2* 家族必须走异步全局限速器（不阻塞 Swift Concurrency 协作线程池）
        do {
            let data = try await HTTPFetch.get(req)
            await DataSources.throttleAfterNetworkAsync()
            if let pts = parseEastmoneyMinute(data), !pts.isEmpty {
                return pts
            }
            DataSources.recordFetchFailure(DataSourceEndpoints.eastmoneyMinute,
                                           "东财分时返回空/解析失败")
            return nil
        } catch {
            await DataSources.throttleAfterNetworkAsync()
            DataSources.recordFetchFailure(DataSourceEndpoints.eastmoneyMinute,
                                           "东财分时请求失败：\(String(describing: error))")
            return nil
        }
    }

    /// 东财 `secid`：沪 1 / 深·北 0；港股等 5 位代码没有对应兜底 → nil。
    static func eastmoneyMinuteURL(fullCode: String) -> String? {
        let lower = fullCode.lowercased()
        let digits = lower.filter { $0.isASCII && $0.isNumber }
        guard digits.count == 6 else { return nil }
        let market: String
        if lower.hasPrefix("sh") {
            market = "1"
        } else if lower.hasPrefix("sz") || lower.hasPrefix("bj") {
            market = "0"
        } else {
            market = String(DataSources.marketOf(digits))
        }
        return DataSourceEndpoints.eastmoneyMinute + "?secid=\(market).\(digits)"
            + "&ndays=1&iscr=0&fields1=f1,f2,f3,f4,f5,f6,f7,f8,f9,f10,f11,f12,f13"
            + "&fields2=f51,f52,f53,f54,f55,f56,f57,f58"
    }

    /// 腾讯分时 JSON：`data[fullCode].data.data[]`，每行 `HHmm 价格 累计量 累计额`。
    static func parseTencentMinute(_ data: Data, fullCode: String) -> [MinutePoint]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dict = json["data"] as? [String: Any],
              let stockData = dict[fullCode] as? [String: Any],
              let minuteDict = stockData["data"] as? [String: Any],
              let lines = minuteDict["data"] as? [String] else { return nil }
        var points: [MinutePoint] = []
        points.reserveCapacity(lines.count)
        for line in lines {
            let parts = line.components(separatedBy: " ")
            guard parts.count >= 2, let price = Double(parts[1]), price > 0 else { continue }
            let t = parts[0]
            let display = t.count >= 4
                ? "\(t.prefix(2)):\(t.dropFirst(2))"
                : t
            let vol = parts.count > 2 ? (Double(parts[2]) ?? 0) : 0
            let amount = parts.count > 3 ? (Double(parts[3]) ?? 0) : 0
            points.append(MinutePoint(time: display, price: price, volume: vol, amount: amount))
        }
        return points
    }

    /// 东财趋势 JSON：`data.trends[]`，每行
    /// `yyyy-MM-dd HH:mm,open,close,high,low,volume,amount,avgPrice`。
    static func parseEastmoneyMinute(_ data: Data) -> [MinutePoint]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dict = json["data"] as? [String: Any],
              let trends = dict["trends"] as? [String] else { return nil }
        var points: [MinutePoint] = []
        points.reserveCapacity(trends.count)
        var cumulativeVolume = 0.0
        var cumulativeAmount = 0.0
        for line in trends {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 6,
                  let stamp = fields[0].split(separator: " ").last, stamp.count >= 5,
                  let price = Double(fields[2]), price > 0 else { continue }
            cumulativeVolume += Double(fields[5]) ?? 0
            cumulativeAmount += fields.count > 6 ? (Double(fields[6]) ?? 0) : 0
            points.append(MinutePoint(time: String(stamp.prefix(5)),
                                      price: price, volume: cumulativeVolume,
                                      amount: cumulativeAmount))
        }
        return points
    }

    /// 分时两条链路都失败时给界面的**真实原因**（不再只写“网络受限/停牌”）。
    public static func minuteFailureSummary() -> String {
        func reason(_ endpoint: String) -> String? {
            DataSources.lastFetchFailureReason(matching: endpoint)
        }
        var tencent: [String] = []
        if let r = reason(DataSourceEndpoints.tencentMinute) {
            tencent.append("主 \(shortReason(r))")
        }
        if let r = reason(DataSourceEndpoints.tencentMinuteAlt) {
            tencent.append("备 \(shortReason(r))")
        }
        let t = tencent.isEmpty ? "无数据" : tencent.joined(separator: "；")
        let e = reason(DataSourceEndpoints.eastmoneyMinute).map(shortReason) ?? "无数据"
        return "腾讯 \(t)；东财 \(e)"
    }

    private static func shortReason(_ s: String) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 56 ? String(oneLine.prefix(56)) + "…" : oneLine
    }

    /// 数据源自检用的同步分时探测（**不改动**轮询链路，只读）。
    public struct MinuteProbe: Sendable {
        public let tencentOK: Bool
        public let tencentDetail: String
        public let eastmoneyOK: Bool
        public let eastmoneyDetail: String
    }

    public static func probeMinute(fullCode: String = "sh600519") -> MinuteProbe {
        var tencentOK = false
        var tencentNotes: [String] = []
        for host in [DataSourceEndpoints.tencentMinute, DataSourceEndpoints.tencentMinuteAlt] {
            let label = host.contains("proxy.finance") ? "镜像" : "备用"
            if let text = DataSources.httpGet("\(host)?code=\(fullCode)",
                                              timeout: 8, retries: 0),
               let pts = parseTencentMinute(Data(text.utf8), fullCode: fullCode), !pts.isEmpty {
                tencentOK = true
                tencentNotes.append("\(label)✓ \(pts.count)点")
                break
            }
            let reason = DataSources.lastFetchFailureReason(matching: host)
                ?? "返回空/解析失败"
            tencentNotes.append("\(label)✗ \(shortReason(reason))")
        }

        var eastmoneyOK = false
        var eastmoneyDetail: String
        if let url = eastmoneyMinuteURL(fullCode: fullCode) {
            defer { DataSources.throttleAfterNetwork() }
            if let text = DataSources.httpGet(url, timeout: 8,
                                              referer: DataSourceEndpoints.eastmoneyReferer,
                                              retries: 0),
               let pts = parseEastmoneyMinute(Data(text.utf8)), !pts.isEmpty {
                eastmoneyOK = true
                eastmoneyDetail = "\(pts.count)点"
            } else {
                eastmoneyDetail = shortReason(
                    DataSources.lastFetchFailureReason(matching: DataSourceEndpoints.eastmoneyMinute)
                        ?? "返回空/解析失败")
            }
        } else {
            eastmoneyDetail = "该代码不支持"
        }

        return MinuteProbe(tencentOK: tencentOK,
                           tencentDetail: tencentNotes.joined(separator: "；"),
                           eastmoneyOK: eastmoneyOK,
                           eastmoneyDetail: eastmoneyDetail)
    }

}
