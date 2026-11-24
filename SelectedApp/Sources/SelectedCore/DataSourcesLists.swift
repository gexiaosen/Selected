import Foundation

/// 行情抓取层 —— 证券/基金/港股列表（`DataSources` 的 extension，契约见 `DataSources.swift` 文件头）。

extension DataSources {
    // MARK: - 证券主列表（HTTP 主源 → 当日/过期缓存（securities 表）→ 随包基线）

    /// 随包基线（engine/params/stock_list_baseline.json）
    private static func stockListBaselinePath() -> String {
        ParamSchema.resourceCandidates("engine/params/stock_list_baseline.json")
            .first { FileManager.default.fileExists(atPath: $0) } ?? ""
    }

    /// 随包证券列表基线（归一化后，纯本地读、不触网）——
    /// 供 UI 在 `securities` 表为空时兜底（见 Store.loadStockList）：
    /// 升级后首次取数前 / 全新安装未取数时，表是空的，而"按代码加自选"依赖
    /// code→name 解析（拿不到名字即拒绝）。与 fetchStockList 的最末层兜底同源。
    public static func baselineStockList() -> [[String: Any]] {
        let (_, baseList) = loadJSONList(stockListBaselinePath())
        return normalizeList(baseList)
    }

    /// 读 {date,count,list} 结构 → (date, list)。失败返回 (nil, [])
    private static func loadJSONList(_ path: String) -> (date: String?, list: [[String: Any]]) {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, [])
        }
        let lst = (obj["list"] as? [[String: Any]]) ?? []
        if !lst.isEmpty {
            return (obj["date"] as? String, lst)
        }
        return (nil, [])
    }

    /// 统一成 [{code,name,market}]：code 补零 zfill(6)、去重、仅保留 A 股前缀、名称清洗，
    /// market = 6 开头 ? 1 : 0，最终按 code 字典序排序。
    private static func normalizeList(_ items: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var seen = Set<String>()
        for x in items {
            let code = zfill6(pyStr(x["code"]))
            if code.isEmpty || seen.contains(code) || !isAStock(code) { continue }
            seen.insert(code)
            out.append(["code": code,
                        "name": cleanName(pyStr(x["name"])),
                        "market": marketOf(code)])
        }
        out.sort { ($0["code"] as? String ?? "") < ($1["code"] as? String ?? "") }
        return out
    }

    /// 分页响应体 → 行数组。⚠ **把"异常"与"末页"在类型上分开**。
    ///
    /// 为什么必须分开：若"解析失败"和"已到末页"都写成裸 `break` ——
    ///   第 5 页解析失败时循环正常退出、`collected` 是**半截**，而调用方见
    ///   `!httpList.isEmpty` 就整表替换写缓存 ⇒ **A 股候选池静默缩小**，
    ///   唯一表现是"今天选出的票变少"，没有任何报错。
    ///
    /// 返回语义（**这就是"分开"本身**，不靠注释）：
    ///   - `nil` = **这一页异常**（无响应 / 不是 JSON 数组 / 解析失败）→ 调用方**整轮作废**
    ///   - `[]`  = **正常但没有更多数据**（末页）→ 调用方正常收尾
    private static func decodeListPage(_ text: String?) -> [[String: Any]]? {
        let stripped = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard stripped.hasPrefix("["), let body = stripped.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]]
        else { return nil }
        return rows
    }

    /// [主源] 新浪 Market_Center 分页拉全市场 A 股列表（num>100 被服务端强制回落为 100，必须分页）
    ///
    /// ⚠ `SELECTED_STOCK_LIST_HTTP=off` 为**测试注入**（测试脚本模拟"主源不可用"以覆盖
    ///   过期缓存/基线兜底路径）；未设置时零行为变化。
    private static func fetchStockListHTTP() -> [[String: Any]] {
        if ProcessInfo.processInfo.environment["SELECTED_STOCK_LIST_HTTP"] == "off" { return [] }
        var collected: [[String: Any]] = []
        var page = 1
        while page <= sinaListMaxPages {
            let url = DataSourceEndpoints.sinaList
                + "Market_Center.getHQNodeData?page=\(page)&num=\(sinaListPageSize)"
                + "&sort=symbol&asc=1&node=hs_a&symbol=&_s_r_a=page"
            let text = httpGet(url, referer: "https://finance.sina.com.cn", retries: 1)
            // ⚠ 异常页 → **整轮作废**：半截列表不写缓存（否则"A 股候选池静默缩小"）。
            //   返回 `[]` 让调用方走**过期缓存 / 随包基线**兜底。
            guard let rows = decodeListPage(text) else {
                logDataSource("sina", page == 1 ? "stock_list_error" : "stock_list_incomplete",
                              "第 \(page) 页异常 → 整轮作废（不写缓存）；响应 \((text ?? "").count) 字节")
                return []
            }
            if rows.isEmpty { break }   // 空页 = 已到末页（**正常**结束，与上面的异常不是一回事）
            // code/name 缺失的行按空串处理，随后被 isAStock 过滤掉（仅影响异常响应）。
            for r in rows {
                collected.append(["code": r["code"] ?? "", "name": r["name"] ?? ""])
            }
            page += 1
            if sinaListDelay > 0 { Thread.sleep(forTimeInterval: sinaListDelay) }
        }
        let result = normalizeList(collected)
        if !result.isEmpty {
            logDataSource("sina", "stock_list_refreshed",
                          "\(page - 1)页 原始\(collected.count)条 A股\(result.count)只")
        }
        return result
    }

    /// 全量 A 股代码表 [{code, name, market}]。四层兜底：
    ///   1) 当日缓存（securities 表，免网络）
    ///   2) HTTP 主源（新浪分页）→ 与随包基线并集（保证不丢股票）→ 写缓存
    ///   3) 过期缓存（securities 表）
    ///   4) 随包基线
    /// 全失败时返回 [] 并记日志（调用方按空列表处理，不把"列表拿不到"升级成崩溃）。
    ///
    /// 缓存写入必经 `cleanName`，名称不会再被 NUL 污染。
    public static func fetchStockList(refresh: Bool = false) -> [[String: Any]] {
        let today = dayFormatter.string(from: Date())

        if let fx = fixture("stock_list.json") as? [[String: Any]] {
            return normalizeList(fx)
        }

        if !refresh {
            let (cdate, clist) = SecuritiesCache.shared.load()
            if cdate == today && clist.count > 4000 {
                return normalizeList(clist)
            }
        }

        // ---- 主源 ----
        let httpList = fetchStockListHTTP()
        let (_, baseList) = loadJSONList(stockListBaselinePath())

        if !httpList.isEmpty {
            // 并集：以 HTTP 为主，基线补足（新增股由 HTTP 提供，次新/CDR 由基线提供）
            let merged = normalizeList(httpList + baseList)
            do {
                try SecuritiesCache.shared.replace(date: today, list: merged)
            } catch {
                logDataSource("stock_list", "cache_write_error", "\(error)")
            }
            logDataSource("stock_list", "refreshed",
                          "HTTP主源\(httpList.count)只 ∪ 基线\(baseList.count)只 → \(merged.count)只")
            return merged
        }

        // ---- 兜底 1：过期缓存（securities 表）----
        let (cacheDate, cacheList) = SecuritiesCache.shared.load()
        if !cacheList.isEmpty {
            logDataSource("stock_list", "fallback_cache",
                          "HTTP主源失败，回退过期缓存（日期 \(cacheDate ?? "?"), \(cacheList.count)只）")
            return cacheList
        }

        // ---- 兜底 2：随包基线 ----
        if !baseList.isEmpty {
            logDataSource("stock_list", "fallback_baseline",
                          "HTTP主源与缓存均不可用，回退随包基线（\(baseList.count)只）")
            return normalizeList(baseList)
        }

        logDataSource("stock_list", "fatal",
                      "证券主列表获取失败：HTTP 主源、本地缓存、随包基线均不可用（Swift 侧返回空列表）")
        return []
    }

    // MARK: - 场内基金列表（自选页「搜索添加」按名称模糊匹配）
    //
    // 与 A 股列表（securities）**完全隔离**：基金不进扫描池，只服务于自选页搜索。
    // 缓存 7 天（成分变动慢，每次搜索都抓 10s 不值得）；过期或为空时抓新浪三个节点。

    /// 归一化基金项 [{code,name,market,kind}]：代码补零、去重、清洗名称、按代码排序
    ///
    /// ⚠ market 不能用 A 股的 `marketOf`（"6 开头才算沪"）：基金是 **5 开头沪市 / 1 开头深市**，
    ///   用 A 股规则会把 510300 这类沪市 ETF 判成深市。优先取新浪返回的 `symbol` 前缀
    ///   （数据源权威），缺失时按基金代码规则兜底。
    private static func normalizeFunds(_ items: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var seen = Set<String>()
        for x in items {
            let code = zfill6(pyStr(x["code"]))
            guard !code.isEmpty, !seen.contains(code) else { continue }
            seen.insert(code)
            let sym = pyStr(x["symbol"]).lowercased()
            let market = sym.hasPrefix("sh") ? 1 : (sym.hasPrefix("sz") ? 0 : (code.hasPrefix("5") ? 1 : 0))
            out.append(["code": code,
                        "name": cleanName(pyStr(x["name"])),
                        "market": market,
                        "kind": pyStr(x["kind"])])
        }
        out.sort { ($0["code"] as? String ?? "") < ($1["code"] as? String ?? "") }
        return out
    }

    /// [主源] 新浪 Market_Center 三节点分页拉场内基金列表（ETF / LOF / 封闭式）
    private static func fetchFundListHTTP() -> [[String: Any]] {
        if ProcessInfo.processInfo.environment["SELECTED_STOCK_LIST_HTTP"] == "off" { return [] }
        var collected: [[String: Any]] = []
        for (node, kind) in fundNodes {
            var page = 1
            while page <= fundMaxPages {
                let url = DataSourceEndpoints.sinaList
                    + "Market_Center.getHQNodeData?page=\(page)&num=\(sinaListPageSize)"
                    + "&sort=symbol&asc=1&node=\(node)&symbol=&_s_r_a=page"
                let text = httpGet(url, referer: "https://finance.sina.com.cn", retries: 1)
                // ⚠ 异常页 → **整轮作废**：任一节点翻页失败都不当"该节点到末页"，
                //   否则基金池静默缺一段，却照样写缓存。
                guard let rows = decodeListPage(text) else {
                    logDataSource("sina", page == 1 ? "fund_list_error" : "fund_list_incomplete",
                                  "\(node) 第 \(page) 页异常 → 整轮作废（不写缓存）；响应 \((text ?? "").count) 字节")
                    return []
                }
                if rows.isEmpty { break }   // 空页 = 该节点已到末页（正常）
                for r in rows {
                    collected.append(["code": r["code"] ?? "", "name": r["name"] ?? "",
                                      "kind": kind, "symbol": r["symbol"] ?? ""])
                }
                page += 1
            }
        }
        let result = normalizeFunds(collected)
        if !result.isEmpty {
            logDataSource("sina", "fund_list_refreshed", "原始\(collected.count)条 → 场内基金\(result.count)只")
        }
        return result
    }

    /// 场内基金列表 [{code, name, market, kind}]。缓存优先，过期/为空则抓主源：
    ///   1) 缓存日期在 `fundCacheTTLDays` 天内 → 直接用（免网络）
    ///   2) HTTP 主源 → 写缓存
    ///   3) 主源失败 → 回退过期缓存（有总比没有好）；都无 → 空列表
    ///
    /// **同步阻塞**（最多约 10s）：调用方必须放后台线程（Store 走 Task.detached）。
    public static func fetchFundList(refresh: Bool = false) -> [[String: Any]] {
        let (cacheDate, cached) = FundCache.shared.load()
        if !refresh, !cached.isEmpty, let d = cacheDate, daysSince(d) < fundCacheTTLDays {
            return cached
        }

        let httpList = fetchFundListHTTP()
        if !httpList.isEmpty {
            do {
                try FundCache.shared.replace(date: dayFormatter.string(from: Date()), list: httpList)
            } catch {
                logDataSource("fund_list", "cache_write_error", "\(error)")
            }
            return httpList
        }

        if !cached.isEmpty {
            logDataSource("fund_list", "fallback_cache",
                          "主源失败，回退过期基金缓存（日期 \(cacheDate ?? "?"), \(cached.count)只）")
            return cached
        }
        logDataSource("fund_list", "fatal", "场内基金列表获取失败：主源与缓存均不可用")
        return []
    }

    /// `yyyy-MM-dd` 距今天数（解析失败视为很久以前 → 触发刷新）
    private static func daysSince(_ dateStr: String) -> Int {
        guard let d = dayFormatter.date(from: dateStr) else { return Int.max }
        let cal = Calendar(identifier: .gregorian)
        return cal.dateComponents([.day], from: d, to: Date()).day ?? Int.max
    }

    /// 基金缓存是否仍在有效期内（供 Store 判断要不要后台刷新；nil/解析失败 → 视为不新鲜）
    public static func isFundCacheFresh(_ dateStr: String?) -> Bool {
        guard let dateStr else { return false }
        return daysSince(dateStr) < fundCacheTTLDays
    }

    // MARK: - 港股列表（自选页「搜索添加」按名称模糊匹配港股）
    //
    // 与 A 股扫描池、场内基金池**完全隔离**：港股只服务自选页搜索/加自选
    // （行情走腾讯 hk 前缀，见 StockQuotes），不进扫描池也不进基金池。
    // 新浪港股节点单页硬上限 60 条（num 传更大也被服务端压回 60），
    // 全市场 ~2600 只 ≈ 44 页 ≈ 10s（与基金池同量级，页间无需节流）。缓存 7 天。

    private static let hkListPageSize = 60
    private static let hkListMaxPages = 60
    /// 港股列表缓存有效期（天）：与另两个池同口径（成分变动缓慢）
    public static let hkCacheTTLDays = 7

    /// 归一化港股项 [{code,name}]：代码补足 5 位、去重、清洗名称、按代码排序
    private static func normalizeHkList(_ items: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var seen = Set<String>()
        for x in items {
            let raw = pyStr(x["code"])
            guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }
            // 港股代码 5 位（00001 / 00700）；接口偶发返回短码 → 前补零
            let code = raw.count >= 5 ? raw : String(repeating: "0", count: 5 - raw.count) + raw
            guard !seen.contains(code) else { continue }
            seen.insert(code)
            out.append(["code": code, "name": cleanName(pyStr(x["name"]))])
        }
        out.sort { ($0["code"] as? String ?? "") < ($1["code"] as? String ?? "") }
        return out
    }

    /// [主源] 新浪 Market_Center 港股节点（qbgg_hk，全部港股）分页拉列表
    private static func fetchHkListHTTP() -> [[String: Any]] {
        if ProcessInfo.processInfo.environment["SELECTED_STOCK_LIST_HTTP"] == "off" { return [] }
        var collected: [[String: Any]] = []
        var page = 1
        while page <= hkListMaxPages {
            let url = DataSourceEndpoints.sinaList
                + "Market_Center.getHKStockData?page=\(page)&num=\(hkListPageSize)"
                + "&sort=symbol&asc=1&node=qbgg_hk&symbol=&_s_r_a=page"
            let text = httpGet(url, referer: "https://finance.sina.com.cn", retries: 1)
            // ⚠ 异常页 → **整轮作废**。这里最危险：下面"不满一页 = 已到末页"
            //   也用 `break`，两者**长得一模一样** —— "第 5 页解析失败"与"第 5 页就是末页"
            //   必须靠 `decodeListPage` 的类型区分，否则半截港股列表会被当完整列表写进缓存。
            guard let rows = decodeListPage(text) else {
                logDataSource("sina", page == 1 ? "hk_list_error" : "hk_list_incomplete",
                              "第 \(page) 页异常 → 整轮作废（不写缓存）；响应 \((text ?? "").count) 字节")
                return []
            }
            if rows.isEmpty { break }   // 空页 = 已到末页（正常）
            for r in rows {
                collected.append(["code": r["symbol"] ?? r["code"] ?? "", "name": r["name"] ?? ""])
            }
            // 不满一页 = 已到末页（接口不返回 total，只能按页大小判定）—— 正常结束
            if rows.count < hkListPageSize { break }
            page += 1
        }
        let result = normalizeHkList(collected)
        if !result.isEmpty {
            logDataSource("sina", "hk_list_refreshed",
                          "\(page)页 原始\(collected.count)条 → 港股\(result.count)只")
        }
        return result
    }

    /// 港股列表 [{code, name}]。三层与基金池同构：
    ///   1) 缓存日期在 `hkCacheTTLDays` 天内 → 直接用（免网络）
    ///   2) HTTP 主源 → 写缓存
    ///   3) 主源失败 → 回退过期缓存；都无 → 空列表
    ///
    /// **同步阻塞**（最多约 10s）：调用方必须放后台线程（Store 走 Task.detached）。
    public static func fetchHkList(refresh: Bool = false) -> [[String: Any]] {
        let (cacheDate, cached) = HkCache.shared.load()
        if !refresh, !cached.isEmpty, let d = cacheDate, daysSince(d) < hkCacheTTLDays {
            return cached
        }

        let httpList = fetchHkListHTTP()
        if !httpList.isEmpty {
            do {
                try HkCache.shared.replace(date: dayFormatter.string(from: Date()), list: httpList)
            } catch {
                logDataSource("hk_list", "cache_write_error", "\(error)")
            }
            return httpList
        }

        if !cached.isEmpty {
            logDataSource("hk_list", "fallback_cache",
                          "主源失败，回退过期港股缓存（日期 \(cacheDate ?? "?"), \(cached.count)只）")
            return cached
        }
        logDataSource("hk_list", "fatal", "港股列表获取失败：主源与缓存均不可用")
        return []
    }

    /// 港股缓存是否仍在有效期内（供 Store 判断要不要后台刷新；nil/解析失败 → 视为不新鲜）
    public static func isHkCacheFresh(_ dateStr: String?) -> Bool {
        guard let dateStr else { return false }
        return daysSince(dateStr) < hkCacheTTLDays
    }

}
