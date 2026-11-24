import Foundation

/// 行情抓取层 —— K 线 / 事件日志 / 代码工具（`DataSources` 的 extension，契约见 `DataSources.swift` 文件头）。

extension DataSources {
    // MARK: - K 线

    /// 新浪 / 同花顺 JSONP → JSON 体：取首个 `(` 到末个 `)` 之间（贪婪匹配）
    static func jsonpBody(_ text: String) -> String? {
        guard let lp = text.firstIndex(of: "("),
              let rp = text.lastIndex(of: ")"),
              lp < rp else { return nil }
        return String(text[text.index(after: lp)..<rp])
    }

    /// 解析新浪 K 线 JSONP → [{day,open,high,low,close,volume}]（**全有或全无**：
    /// 任一行缺键/非数值即整体返回 []）
    private static func parseSinaKline(_ text: String) -> [[String: Any]] {
        guard let inner = jsonpBody(text) else { return [] }
        guard let rows = (try? JSONSerialization.jsonObject(with: Data(inner.utf8))) as? [[String: Any]] else {
            return []
        }
        var out: [[String: Any]] = []
        for d in rows {
            guard let day = d["day"] as? String,
                  let open = jsonNum(d["open"]), let high = jsonNum(d["high"]),
                  let low = jsonNum(d["low"]), let close = jsonNum(d["close"]),
                  let volume = jsonNum(d["volume"]) else { return [] }
            out.append(["day": day, "open": open, "high": high,
                        "low": low, "close": close, "volume": volume])
        }
        return out
    }

    /// 日K线（新浪）。返回按时间升序。
    ///
    /// ⚠ 重要口径：新浪 scale=240 盘中**不含当日 bar**，末根 = 前一交易日。调用方若需要
    /// 「末根 = 今日」，必须自行合成当日 bar。fixture 模式返回抓取时刻的原始快照，同样不含当日 bar。
    public static func fetchDailyKline(_ code: String, datalen: Int = 65) -> [KLineBar] {
        // ⚠ 代码形状闸门（2026-10-16 审查 B4）：`code` 会被拼进新浪 URL 的
        //   **JSONP 变量名**（`var%20_\(code)_\(datalen)/`）与 `symbol=` 参数里。
        //   非 ASCII 数字（全角 `６０００００`）会让 `URL(string:)` 返回 nil ⇒ 静默空；
        //   含 `&`/`,`/`=` 则直接改变请求语义。不合格 ⇒ 按"这只票没数据"处理并留痕。
        guard DataSourceEndpoints.isQuoteCode(code) else {
            NSLog("[ERROR] 日K取数被拒（代码形状非法）：%@", String(code.prefix(24)))
            return []
        }
        // ⚠ `datalen` 同样进 URL：夹到 [1, 500]，防越界值拼出无意义请求
        let span = max(1, min(datalen, 500))

        // 回放模式：缓存里**截止回放日的最近 datalen 根**，天然**不含未来 bar**（无前视偏差）。
        // ⚠ 缓存没有该票 → 返回空，**绝不回落网络**：回落等于"拿今天的 K 线冒充历史"，
        //   而且不报错。空会让下游按"这只票没数据"处理。
        if let day = HistoryReplayMode.activeDay {
            return HistoryBarStore.bars(code: code, upTo: day, limit: span).map(\.klineBar)
        }
        if let barsFx = fixture("daily_kline/\(code).json") as? [[String: Any]] {
            return pyTail(barsFx, span).map(klineBar)
        }
        // 同一交易日内日K恒定（新浪盘中不含当日 bar）→ 三轮扫描 / 自选判定 / 复盘共享
        let cacheKey = "daily|\(code)|\(span)|\(dayFormatter.string(from: Date()))"
        if let hit: [KLineBar] = cacheGet(cacheKey, ttl: nil) { return hit }
        defer { throttleAfterNetwork() }        // 真的走了网络才限速
        let sym = symbolPrefix(code)
        let url = DataSourceEndpoints.sinaKLine + "var%20_\(code)_\(span)/"
            + "CN_MarketDataService.getKLineData?symbol=\(sym)&scale=240&ma=no&datalen=\(span)"
        if let text = httpGet(url, referer: DataSourceEndpoints.sinaFinanceReferer) {
            let bars = parseSinaKline(text)
            if !bars.isEmpty {
                let out = pyTail(bars, span).map(klineBar)
                cachePut(cacheKey, out)
                return out
            }
            logDataSource("sina", "kline_empty", code)
        }
        return []
    }

    /// 上证指数日K（大盘连跌检测）。
    /// ⚠ fixture 模式**原样返回快照全部 bar（忽略 datalen）**。
    public static func fetchIndexDailyKline(symbol: String = "sh000001", datalen: Int = 5) -> [KLineBar] {
        // 回放模式：与 fixture 模式**同规则** —— 忽略 datalen，返回截止回放日的全部。
        //
        // ⚠ `TradingCalendar` 靠它拿长历史：只给短截历史时，历史日的 `nextTradingDay`
        //   会走"静默回落下一个工作日"那条分支（`TradingCalendar.swift:53-62`）
        //   → 把**错误日**的收益写进 `stock_outcomes` → 污染调优标签。
        //   同时**必须含回放日之后的交易日**：复盘要推 T+1、多观察窗要推 T+3/T+5。
        if let day = HistoryReplayMode.activeDay {
            return HistoryBarStore.indexBars(symbol: symbol, upTo: day).map(\.klineBar)
        }
        if let barsFx = fixture("index_daily_kline.json") as? [[String: Any]] {
            return barsFx.map(klineBar)
        }
        // 同一交易日内恒定 → 三轮扫描（每轮一次）+ 预判 + 复盘共享
        let cacheKey = "idx|\(symbol)|\(datalen)|\(dayFormatter.string(from: Date()))"
        if let hit: [KLineBar] = cacheGet(cacheKey, ttl: nil) { return hit }
        defer { throttleAfterNetwork() }
        let url = DataSourceEndpoints.sinaKLine + "var%20_idx_\(datalen)/"
            + "CN_MarketDataService.getKLineData?symbol=\(symbol)&scale=240&ma=no&datalen=\(datalen)"
        if let text = httpGet(url, referer: DataSourceEndpoints.sinaFinanceReferer) {
            let bars = parseSinaKline(text)
            if !bars.isEmpty {
                let out = bars.map(klineBar)
                cachePut(cacheKey, out)
                return out
            }
        }
        return []
    }

    /// 5分钟K线（新浪）。返回 [{day, time, open, high, low, close, volume}] 升序。
    /// 只保留 `day` 长度≥16 且含空格的 bar，`time` 取前 5 字符（HH:MM）。
    public static func fetch5minBars(_ code: String) -> [MinuteBar] {
        // ⚠ 同 `fetchDailyKline`：`code` 进 JSONP 变量名与 `symbol=`，形状非法即拒绝（审查 B4）
        guard DataSourceEndpoints.isQuoteCode(code) else {
            NSLog("[ERROR] 5 分钟线取数被拒（代码形状非法）：%@", String(code.prefix(24)))
            return []
        }

        // 回放模式：分时**不可回溯**（新浪 5 分钟线只覆盖最近约 5 个交易日）→ 恒空。
        // 这不是"降级"，是**唯一正确的答案**：返回任何数据都会让尾盘分时结构
        // 用上"别的一天"的分时，而界面上看不出来。
        // 空 → `IntradayFeaturesCalc.compute` 返回 nil → `Screener` 的整个分时块
        // （含 `stale_high_penalty` 扣分）被跳过，这是**既有机制**，无需新代码。
        if HistoryReplayMode.isActive { return [] }
        if let barsFx = fixture("m5/\(code).json") as? [[String: Any]] {
            return barsFx.map { MinuteBar(json: $0) }
        }
        // 盘中在变 → 只做短 TTL 复用（一轮扫描 / 一次判定内够用；三轮之间也会过期重取）
        let cacheKey = "m5|\(code)"
        if let hit: [MinuteBar] = cacheGet(cacheKey, ttl: kline5minTTL) { return hit }
        defer { throttleAfterNetwork() }        // 注册在 httpGet 之前，覆盖其后的所有 return
        let sym = symbolPrefix(code)
        let url = DataSourceEndpoints.sinaKLine + "var%20_\(code)_m5/"
            + "CN_MarketDataService.getKLineData?symbol=\(sym)&scale=5&ma=no&datalen=240"
        guard let text = httpGet(url, referer: DataSourceEndpoints.sinaFinanceReferer) else { return [] }
        guard let inner = jsonpBody(text),
              let rows = (try? JSONSerialization.jsonObject(with: Data(inner.utf8))) as? [[String: Any]] else {
            return []
        }
        var bars: [MinuteBar] = []
        for d in rows {
            let dt = pyStr(d["day"])
            if dt.count < 16 || !dt.contains(" ") { continue }
            let parts = dt.components(separatedBy: " ")
            // 拆不出恰好两段 → 整体返回 []（全有或全无）
            if parts.count != 2 { return [] }
            guard let open = jsonNum(d["open"]), let high = jsonNum(d["high"]),
                  let low = jsonNum(d["low"]), let close = jsonNum(d["close"]) else { return [] }
            let volume = jsonNum(d["volume"]) ?? 0     // volume 缺失给 0
            var b = MinuteBar()
            b.day = parts[0]
            b.time = String(parts[1].prefix(5))
            b.open = open; b.high = high; b.low = low; b.close = close; b.volume = volume
            bars.append(b)
        }
        if !bars.isEmpty {
            logDataSource("sina", "5min", "\(code) \(bars.count)根")
            cachePut(cacheKey, bars)
        }
        return bars
    }

    // MARK: - 数据源事件日志（任何失败都静默）

    /// 写 data_source_logs(ts, source, event, detail)；detail 截断 500 字符。
    /// 写库失败绝不影响主流程（DB 未初始化/被锁都静默吞掉）。
    public static func logDataSource(_ source: String, _ kind: String, _ detail: String) {
        let ts = timestampFormatter.string(from: Date())
        let trimmed = String(detail.prefix(500))
        do {
            _ = try SQLiteWriter.shared.write { tx in
                try tx.execute(
                    "INSERT INTO data_source_logs(ts, source, event, detail) VALUES(?,?,?,?)",
                    [ts, source, kind, trimmed])
            }
        } catch {
            // ⚠ 不完全静默：本表是 UI 数据源新鲜度（DataFreshness）的输入，
            //   它挂了新鲜度页全空且看不到原因，必须留一线痕迹。
            //   写失败仍不阻断主流程。
            NSLog("[NOTICE] data_source_logs 写入失败（数据源日志丢失，不影响主流程）：%@",
                  String(describing: error))
        }
    }

    // MARK: - 引擎口径的代码/市场工具

    /// 引擎口径市场前缀：6 开头 → sh，否则 sz。
    /// ⚠ 与 StockQuotes.fullCode（多市场推断，含 bj）**不同**，勿混用。
    public static func symbolPrefix(_ code: String) -> String {
        (code.hasPrefix("6") ? "sh" : "sz") + code
    }

    /// 6 开头 → 沪市 1，否则深市 0
    public static func marketOf(_ code: String) -> Int { code.hasPrefix("6") ? 1 : 0 }

    /// A 股前缀：00 / 30 / 60 / 68
    public static func isAStock(_ code: String) -> Bool {
        code.hasPrefix("00") || code.hasPrefix("30")
            || code.hasPrefix("60") || code.hasPrefix("68")
    }

}
