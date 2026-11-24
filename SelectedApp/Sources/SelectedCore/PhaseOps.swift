import Foundation

/// 运维类命令：`selftest`（数据源自检）。
///
/// ⚠ 「源系统导入」（`migrate` / `previewMigrate`）已于 2026-10-27 整条删除：
///   本 App 没有对应的导出功能，它读的是早期版本在同一台机器上写的目录，那条路径早已不再产生；
///   备份恢复走 `scripts/backup_data.sh` 的文件复制，不经过这里。
///
/// ⚠ 自检的失败判定：DataSources 内部已兜住网络异常并返回空值，
///   本实现按"空值 = 失败"判定。
public enum PhaseOps {

    // MARK: - 数据源自检

    /// 自检报告。`refresh` 对应 CLI 的 `--refresh`（App 侧不传，恒为 false）
    public static func selftest(refresh: Bool = false) -> [String: Any] {
        var probes: [(cap: String, source: String, ok: Bool, detail: String)] = []

        // 1. 证券列表（新浪 HTTP 主源 + 随包基线）
        let t0 = Date().timeIntervalSince1970
        do {
            let list = DataSources.fetchStockList(refresh: refresh)
            let n = list.count
            probes.append(("证券列表", "新浪", n > 4000,
                           "\(n)只 (\(String(format: "%.1f", Date().timeIntervalSince1970 - t0))s)"))
        }
        let baseline = baselineList()
        probes.append(("证券列表", "随包基线", baseline.count > 4000,
                       "\(baseline.count)只（离线兜底）"))

        // 2. 实时行情（腾讯批量 HTTP）
        let quotes = DataSources.fetchTencentQuotes(["600000", "000001"])
        let item = quotes["600000"] ?? quotes["000001"]
        let itemName = (item?["name"] as? String) ?? ""
        let vr = item?["volume_ratio"]
        let fieldsOK = !itemName.isEmpty && !(vr == nil || vr is NSNull)
        let detail2: String
        if let it = item {
            detail2 = "样本: \(it["name"] as? String ?? "None") 量比=\(pyStr(it["volume_ratio"]))"
        } else {
            detail2 = "样本: 无 量比=-"
        }
        probes.append(("实时行情", "腾讯", fieldsOK, detail2))

        // 3. 日K线（新浪）
        let kline = DataSources.fetchDailyKline("600000", datalen: 10)
        probes.append(("日K线", "新浪", kline.count >= 5, "取到\(kline.count)根"))

        // 4. 指数行情（腾讯）
        let idx = DataSources.fetchIndexQuote()
        probes.append(("指数行情", "腾讯", truthy(idx["price"]),
                       "\(pyStr(idx["price"])) \(pyStr(idx["change_pct"]))%"))

        // 5. 5分钟K线（新浪）
        let bars = DataSources.fetch5minBars("600000")
        probes.append(("5分钟K线", "新浪", bars.count > 0, "\(bars.count)根"))

        // 6. 分时（腾讯镜像 / 备用 host + 东财 1 分钟兜底）
        //    ⚠ 这条**必须**探：详情页分时走的是独立端点，行情/K线全绿时它也可能单独被 WAF 拦
        //    （2026-10-21 实测 `web.ifzq.gtimg.cn` 返回 HTTP 501）。
        let minute = KLineService.probeMinute()
        probes.append(("分时", "腾讯", minute.tencentOK, minute.tencentDetail))
        probes.append(("分时", "东财", minute.eastmoneyOK, minute.eastmoneyDetail))

        // ---- 按能力聚合 ----
        let primary: [String: String] = ["证券列表": "新浪", "实时行情": "腾讯", "日K线": "新浪",
                                         "指数行情": "腾讯", "分时": "腾讯", "5分钟K线": "新浪"]
        let order = ["证券列表", "实时行情", "日K线", "指数行情", "分时", "5分钟K线"]
        var checks: [[String: Any]] = []
        for cap in order {
            let chans = probes.filter { $0.cap == cap }
            let okN = chans.filter { $0.ok }.count
            let prim = primary[cap] ?? ""
            let primOK = chans.contains { $0.source == prim && $0.ok }
            let anyOK = okN > 0
            let status = primOK ? "green" : (anyOK ? "yellow" : "red")
            let detail = chans.map { "\($0.source)\($0.ok ? "✓" : "✗") \($0.detail)" }
                .joined(separator: "；")
            checks.append(["item": cap, "ok": anyOK, "status": status,
                           "ok_count": okN, "total": chans.count, "detail": detail])
        }

        // ---- 源级统计 ----
        var sources: [String: (ok: Int, total: Int)] = [:]
        for p in probes {
            var s = sources[p.source] ?? (0, 0)
            s.total += 1
            if p.ok { s.ok += 1 }
            sources[p.source] = s
        }
        // 按源名排序输出（键就是上面刚放进去的，直接遍历字典即可）
        let sourceList: [[String: Any]] = sources.sorted { $0.key < $1.key }.map { name, v in
            let status = v.ok == v.total ? "green" : (v.ok > 0 ? "yellow" : "red")
            return ["source": name, "ok": v.ok, "total": v.total, "status": status]
        }

        let coreOK = checks.allSatisfy { truthy($0["ok"]) }
        return ["selftest": coreOK ? "PASS" : "FAIL",
                "link": "全 HTTP 链路（腾讯行情/分时 + 东财分时兜底 + 新浪列表/K线）",
                "checks": checks, "sources": sourceList,
                "db_path": PhaseStore.shared.dataDirPath + "/selected.sqlite3"]
    }

    /// 随包基线（engine/params/stock_list_baseline.json）→ `{date,count,list}` 的 list
    private static func baselineList() -> [[String: Any]] {
        for path in ParamSchema.resourceCandidates("engine/params/stock_list_baseline.json") {
            guard let data = FileManager.default.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lst = obj["list"] as? [[String: Any]], !lst.isEmpty else { continue }
            return lst
        }
        return []
    }

    // MARK: - 自检取数工具

    /// Python 真值（0/""/None 为假；数字 1 为真）
    private static func truthy(_ v: Any?) -> Bool {
        guard let v = v else { return false }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            return n.doubleValue != 0
        }
        if let s = v as? String { return !s.isEmpty }
        return false
    }

    /// `str(v)` 等价（detail 文案里嵌原始值；None 打印 "None"）
    private static func pyStr(_ v: Any?) -> String {
        guard let v = v, !(v is NSNull) else { return "None" }
        return PyJSON.numStr(v)
    }
}