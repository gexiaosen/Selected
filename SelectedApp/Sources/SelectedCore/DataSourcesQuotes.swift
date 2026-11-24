import Foundation

/// 行情抓取层 —— 腾讯实时行情 / 回放重建（`DataSources` 的 extension，契约见 `DataSources.swift` 文件头）。

extension DataSources {
    // MARK: - 腾讯实时行情

    /// 解析腾讯行情响应 → {code: quote}。
    ///
    /// 口径：
    ///   · 按 `;` 分行；行内必须含 `=`；`split('="')` 后取第 2 段，`rstrip('"')`，再按 `~` 拆字段
    ///   · 字段数 < 52 跳过；price<=0 跳过（停牌/无成交）
    ///   · 字段下标固定（见下方内联注释）
    ///   · change_pct/volume_ratio/turnover/amplitude/pe 走 PyMath.round(_,2)，其余保持原始 double
    ///   · 数值空串 → 0.0；非空但非数值 → **整行跳过**
    ///   · name 走 cleanName
    /// 独立成 static 是为了可离线测试解析口径（不依赖网络/fixture）。
    public static func parseTencentQuote(_ text: String) -> [String: [String: Any]] {
        var results: [String: [String: Any]] = [:]
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ";")
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || !line.contains("=") { continue }
            let parts = line.components(separatedBy: "=\"")
            if parts.count < 2 { continue }
            var body = parts[1]
            while body.hasSuffix("\"") { body.removeLast() }     // 去尾部引号
            let fields = body.components(separatedBy: "~")
            if fields.count < 52 { continue }

            func field(_ i: Int) -> String { i < fields.count ? fields[i] : "" }
            /// 空串 → 0.0；非空但非数值 → nil（调用方据此跳过整行）
            func num(_ i: Int) -> Double? {
                let v = field(i)
                if v.isEmpty { return 0.0 }
                return Double(v)
            }
            // 字段下标：price=3 pre_close=4 open=5 high=33 low=34
            // change_pct=32 volume=36 amount=37 turnover=38 pe=39 amplitude=43 volume_ratio=49
            // avg_price=51 quote_time=30 name=1 code=2
            guard let price = num(3), price > 0,
                  let preClose = num(4),
                  let open = num(5), let high = num(33), let low = num(34),
                  let chg = num(32), let vratio = num(49), let turnover = num(38),
                  let amplitude = num(43), let amount = num(37), let avg = num(51),
                  let pe = num(39), let volume = num(36) else { continue }
            let code = field(2)
            let quote: [String: Any] = [
                "code": code, "name": cleanName(field(1)),
                "price": price, "pre_close": preClose,
                "open": open, "high": high, "low": low,
                "change_pct": PyMath.round(chg, 2),
                "volume_ratio": PyMath.round(vratio, 2),
                "turnover": PyMath.round(turnover, 2),
                "amplitude": PyMath.round(amplitude, 2),
                "amount": amount, "avg_price": avg, "pe": PyMath.round(pe, 2),
                "volume": volume,
                // 报价时间戳 YYYYMMDDHHMMSS：把当日累计量折算到全日口径，且让离线重放可复现
                "quote_time": field(30),
            ]
            results[code] = quote
        }
        return results
    }

    /// 单批腾讯行情。失败→重试；仍失败→对半拆片（最多 2 层，防止单批失败放大影响面）。
    ///
    /// `deadline`：整轮预算。超预算后**不再拆分重试** ——
    /// 拆分的每一步都是一次完整的「3 次重试 × 15s」，不拦的话单批最坏约 322s。
    private static func fetchTencentChunk(_ codes: [String], depth: Int = 0,
                                          deadline: Date? = nil) -> [String: [String: Any]] {
        if codes.isEmpty { return [:] }
        if let dl = deadline, Date() >= dl {
            logDataSource("tencent", "chunk_budget_skip", "整轮预算耗尽，跳过 \(codes.count) 只")
            return [:]
        }
        let codesStr = codes.map { symbolPrefix($0) }.joined(separator: ",")
        let text = httpGet(DataSourceEndpoints.tencentQuotes + codesStr, gbk: true,
                           retries: tencentChunkRetries, deadline: deadline)
        let data = text.map { parseTencentQuote($0) } ?? [:]

        // 判定失败：HTTP 层拿不到 / 一条都没解析出来（停牌股会被 parse 跳过，故不能按比例判）
        if !data.isEmpty {
            if Double(data.count) < Double(codes.count) * 0.5 {
                logDataSource("tencent", "chunk_partial",
                              "请求\(codes.count)只仅返回\(data.count)只（含停牌，属正常偏低）")
            }
            return data
        }
        if depth < 2 && codes.count > 10,
           !(deadline.map { Date() >= $0 } ?? false) {
            logDataSource("tencent", "chunk_split",
                          "分片\(codes.count)只无返回，降级拆分重试（第\(depth + 1)层）")
            let mid = codes.count / 2
            var out = fetchTencentChunk(Array(codes[..<mid]), depth: depth + 1, deadline: deadline)
            out.merge(fetchTencentChunk(Array(codes[mid...]), depth: depth + 1, deadline: deadline)) { _, new in new }
            return out
        }
        logDataSource("tencent", "chunk_failed", "分片\(codes.count)只最终失败，放弃")
        return [:]
    }

    /// 腾讯批量行情（500 只/批，无批间休眠；单片失败自动重试并降级拆分）。
    ///
    /// fixture 模式：读 `quotes.json`，**只回请求的 code**，返回快照里的原始 dict（不加工/不取整）。
    /// - Parameter shouldStop: 取消检查闭包。本函数是同步的，没有 Task 上下文 ⇒
    ///   必须由调用方传入；缺省 `{ false }` = 不取消。
    public static func fetchTencentQuotes(_ codes: [String],
                                          shouldStop: () -> Bool = { false })
        -> [String: [String: Any]] {
        // 回放模式：由缓存重建这些票在**回放日**的行情
        if let day = HistoryReplayMode.activeDay {
            return replayQuotes(codes: codes, day: day)
        }
        if let fx = fixture("quotes.json") as? [String: Any] {
            var out: [String: [String: Any]] = [:]
            for c in codes {
                if let q = fx[c] as? [String: Any] { out[c] = q }
            }
            return out
        }
        var allData: [String: [String: Any]] = [:]
        // 整轮预算 + 连续失败熔断：见 quoteRoundBudgetSec 注释。
        // 没有这两道闸门时，数据源整体不可用会让单轮拖到 50+ 分钟，
        // 期间调度器一切任务与手动写操作全部被拒 —— 而且日志里只有零星 chunk_failed，
        // 看不出"整轮卡住"。超预算/熔断都**带着已有数据返回**（上层有覆盖率闸门兜底）。
        let roundStart = Date()
        let deadline = roundStart.addingTimeInterval(quoteRoundBudgetSec)
        var consecutiveFailures = 0
        var i = 0
        while i < codes.count {
            // ⚠ 取消检查放在预算检查**之后** —— 两者语义不同：预算是"这轮最多花 180s"，
            //   取消是"用户要它停下"。满市场 5000+ 只 / 每批 500 只 ≈ 10+ 批，每批检查一次
            //   ⇒ 这一行能把取消响应时间从"整轮 40~60 秒"压到"单批 1~2 秒"。
            if shouldStop() {
                logDataSource("tencent", "round_cancelled",
                              "取数被取消：已取 \(allData.count)/\(codes.count) 只，剩余批次放弃")
                break
            }
            if Date() >= deadline {
                logDataSource("tencent", "round_budget_exceeded",
                              "整轮预算 \(Int(quoteRoundBudgetSec))s 耗尽：已取 "
                              + "\(allData.count)/\(codes.count) 只，剩余批次放弃")
                break
            }
            let batch = Array(codes[i..<min(i + tencentBatchSize, codes.count)])
            let got = fetchTencentChunk(batch, deadline: deadline)
            if got.isEmpty {
                consecutiveFailures += 1
                if consecutiveFailures >= quoteRoundFailureLimit {
                    logDataSource("tencent", "round_aborted",
                                  "连续 \(consecutiveFailures) 批无返回，判定数据源不可用，"
                                  + "提前收工（已取 \(allData.count)/\(codes.count) 只）")
                    break
                }
            } else {
                consecutiveFailures = 0
            }
            allData.merge(got) { _, new in new }
            i += tencentBatchSize
        }
        return allData
    }

    /// 指数实时行情（fixture 原样返回；否则网络解析，指数代码无前缀故取唯一结果）。
    public static func fetchIndexQuote(symbol: String = "sh000001") -> [String: Any] {
        // 回放模式：由指数缓存重建**回放日**那根
        if let day = HistoryReplayMode.activeDay {
            return replayIndexQuote(symbol: symbol, day: day)
        }
        if let fx = fixture("index_quote.json") as? [String: Any] { return fx }
        guard let text = httpGet(DataSourceEndpoints.tencentQuotes + symbol, gbk: true) else { return [:] }
        let data = parseTencentQuote(text)
        if let q = data[symbol] { return q }
        if let q = data.values.first { return q }
        return [:]
    }

    /// 隔夜外盘（道琼斯/纳指）
    public static func fetchOverseas() -> [String: Any] {
        // 回放模式：外盘**无历史端点**（腾讯只给最新一跳）。
        // 返回空 → `market_env.us_market` 落到"数据获取失败"，与真实缺数据同形；
        // 若照常取网络，就会把**今天的**美股涨跌写进历史日的大盘环境（静默错值）。
        if HistoryReplayMode.isActive { return [:] }
        if let fx = fixture("overseas.json") as? [String: Any] { return fx }
        var out: [String: Any] = [:]
        for (sym, key) in [("usDJI", "dji_change_pct"), ("usIXIC", "ixic_change_pct")] {
            guard let text = httpGet(DataSourceEndpoints.tencentQuotes + sym, gbk: true) else { continue }
            let data = parseTencentQuote(text)
            guard !data.isEmpty else { continue }
            guard let q = data[sym] ?? data.values.first, let cp = q["change_pct"] else { continue }
            out[key] = cp
        }
        return out
    }

    // MARK: - 全量实时行情 + 覆盖率留痕

    /// 最近一次全量行情的覆盖率统计（锁保护的静态变量）。
    ///
    /// `nonisolated(unsafe)`：Swift 6 严格并发禁止非隔离的可变全局状态；
    /// 这里**自带 `statLock` 保护**（写：fetchAllQuotes，读：lastQuoteStat），故显式声明豁免。
    /// 不加这句在 `swift build`（严格并发）下会直接编译失败；Tools 脚本用裸 swiftc
    /// （Swift 5 模式）编不出这个问题，属于「只在 App 构建时暴露」的坑。
    private static let statLock = NSLock()
    private nonisolated(unsafe) static var quoteStat: [String: Any] = [:]

    /// 全量行情。返回 (quotes, "tencent")。当前唯一链路为腾讯批量 HTTP。
    ///
    /// 覆盖率留痕：整批失败只影响约 500 只，在总量 5000+ 时仍会通过 MIN_EXPECTED_QUOTES 闸门，
    /// 那约 500 只被静默当成「无行情」剔除 —— 结果偏了却无痕迹。这里把覆盖率记下供上层展示/告警。
    public static func fetchAllQuotes(_ stockList: [[String: Any]]? = nil,
                                     shouldStop: () -> Bool = { false })
        -> (quotes: [String: [String: Any]], source: String) {
        let list = stockList ?? fetchStockList()
        let codes = list.compactMap { $0["code"] as? String }
        let quotes = fetchTencentQuotes(codes, shouldStop: shouldStop)
        let req = codes.count, got = quotes.count
        let ratio: Double = req > 0 ? PyMath.round(Double(got) / Double(req), 4) : 0.0
        statLock.lock()
        quoteStat = ["requested": req, "returned": got, "ratio": ratio]
        statLock.unlock()
        logDataSource("tencent", "full_scan", "全量扫描 \(got)只（请求 \(req)，覆盖 \(pct1(ratio))）")
        if req > 0 && ratio < 0.95 {
            // 不拿它当硬闸门：停牌股天然被 parse 跳过，比例低于 100% 属正常；只提醒
            logDataSource("tencent", "low_coverage",
                          "覆盖率仅 \(pct1(ratio))（请求 \(req) / 返回 \(got)），可能有整批失败")
        }
        return (quotes, "tencent")
    }

    // MARK: - 回放模式：由历史缓存重建行情

    /// 回放模式下重建指定票在 `day` 的行情。
    ///
    /// 窗口往前留 `HistoryReplay.warmupCalendarDays` 个自然日：`quote` 需要「前收 + 前 5 日量」，
    /// 而交易日与自然日不是 1:1（有周末与长假）。
    ///
    /// ⚠ 缓存里查不到的票**直接不产出**（不填 0、不回落网络）——
    /// 返回空行情会让它在硬过滤阶段被剔除，这是对的；编造一个全 0 的行情
    /// 会让它带着"零成交零涨幅"的假面目参与后面的打分。
    static func replayQuotes(codes: [String], day: String) -> [String: [String: Any]] {
        guard !codes.isEmpty, !day.isEmpty else { return [:] }
        let beg = HistoryReplay.shiftCalendarDays(day, -HistoryReplay.warmupCalendarDays)
        let byCode = HistoryBarStore.barsByCode(from: beg, to: day)
        guard !byCode.isEmpty else { return [:] }
        let names = stockNames()
        var out: [String: [String: Any]] = [:]
        out.reserveCapacity(codes.count)
        for code in codes {
            guard let bars = byCode[code],
                  let q = HistoryReplay.quote(code: code, name: names[code] ?? "",
                                              day: day, bars: bars) else { continue }
            out[code] = q
        }
        return out
    }

    /// 回放模式下重建指数在 `day` 的行情
    static func replayIndexQuote(symbol: String, day: String) -> [String: Any] {
        guard !symbol.isEmpty, !day.isEmpty else { return [:] }
        let bars = HistoryBarStore.indexBars(symbol: symbol, upTo: day)
        return HistoryReplay.quote(code: symbol, name: "", day: day, bars: bars) ?? [:]
    }

    /// 代码 → 名称（取当前证券主列表）。
    ///
    /// ⚠ 回放用的是**当前**清单，不是历史清单（历史清单不可得）→ 早年回放的候选池偏小，
    /// 且退市票缺失（幸存者偏差方向是"高估策略收益"）。
    static func stockNames() -> [String: String] {
        var out: [String: String] = [:]
        for s in fetchStockList() {
            guard let c = s["code"] as? String, let n = s["name"] as? String, !c.isEmpty else {
                continue
            }
            out[c] = cleanName(n)
        }
        return out
    }

    /// 最近一次全量行情覆盖率统计 {requested, returned, ratio}，无则空 dict
    public static func lastQuoteStat() -> [String: Any] {
        statLock.lock(); defer { statLock.unlock() }
        return quoteStat
    }

}
