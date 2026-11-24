import Foundation

/// 参数调优。
///
/// 基于**历史实盘标的**做参数重放评估（不重扫全市场，本地毫秒级）：
///   1. 标的池：各评估日 `scan_rounds` 入档的 picks（含全部轮次，去重后取有真实表现标签者）
///   2. 每个标的用**存储的深度指标**（`deep_info_json`）按候选参数重算 score / 档位
///   3. 标签：该选股日 `stock_outcomes`（含三档、统一政策）→ 缺失时回落 `reviews.stocks_json`
///   4. 指标：一档胜率 ×0.6 + 平均窗口收益 ×0.3 + 一档覆盖率 ×0.1（cap 可配）
///   5. 搜索：粗网格随机扰动 → Top 5 → 爬山精调（逐维 ±step 收敛）
///
/// 结果**不直接应用**：输出候选 diff，由 UI 决定「保存为新版本」或放弃。
///
/// 三处必须逐字对齐的地方（**口径已定，别改**，无自动拦截）：
///   · 随机流：`PyRandom`（MT19937 + CPython 取数口径，同 seed 同序列）
///   · 排序：Python `list.sort` / `sorted` 是**稳定排序**，Swift `sorted` 不稳定
///     → 所有排序都带「原下标」兜底，否则并列时 Top 候选会漂
///   · 数值：`PyMath.round`（银行家舍入）与 `PyMath.sum`（Neumaier 补偿求和）
///
/// ⚠ 存储值类型异常的处理：`vol_mult_5d` / `gain_ratio` / `shadow_body_ratio`
///   为「显式 null」时丢弃样本并计入 `score_errors`，其余非数值一律按 0.0
///   （`ScanRunner` 恒写数值，唯一可空的是 `cum_5d`）。
public enum PhaseTune {

    // MARK: - 评估口径

    public struct Metric: Sendable {
        public let key: String
        public let label: String
        public let field: String
    }

    /// 评估口径（顺序即 `by_metric` 的输出顺序）
    public static let metrics: [Metric] = [
        Metric(key: "l3", label: "纪律口径(窗口内首次触及目标价)", field: "disc_profit"),
        Metric(key: "l1", label: "跳空口径(次日开盘为正)", field: "open_pct"),
        Metric(key: "window", label: "窗口最高价口径(不可实现,仅诊断)", field: "window_profit"),
        Metric(key: "close", label: "收盘持有口径", field: "close_profit"),
        Metric(key: "ceiling", label: "策略上限口径(事后视角,仅诊断)", field: "high_profit"),
    ]
    public static let defaultMetric = "l3"

    public enum TuneError: LocalizedError {
        case paramsUnavailable

        public var errorDescription: String? {
            "激活参数不可读（数据库与随包文件都读不到），调优未执行"
        }
    }

    // MARK: - 标的池

    /// 池内一条样本。
    /// `deepDict` 保留**原始存储字典**：转 `DeepInfo` 可能失败，
    /// 那一步必须发生在 `evaluate` 内，否则 `valid_size` 的口径会错。
    public struct PoolItem {
        public let date: String
        public let code: String
        public let name: String
        public let quote: EngineQuote
        public let deepDict: [String: Any]
        public let formScore: Int
        public let envStored: [String: Any]
        public let actual: [String: Any]
    }

    /// 可调维度：仅「评分/档位」类（筛选类维度只在全市场阶段生效，池内重放无影响）
    public static var tuningDims: [String] {
        ParamSchema.shared.allItems
            .filter { $0.tunable && $0.key.hasPrefix("scoring.") }
            .map(\.key)
    }

    private static var itemByKey: [String: ParamSchema.Item] {
        var out: [String: ParamSchema.Item] = [:]
        for it in ParamSchema.shared.allItems { out[it.key] = it }
        return out
    }

    /// 调优基线 = 全局激活参数（与日扫描同一基线；个股覆盖已删除）
    public static func paramsFor() -> [String: Any]? {
        ParamStore.shared.activeParams()
    }

    /// 调优池「只用 live 样本」的 SQL 片段（`includeReplay == false` 时生效）。
    ///
    /// ⚠ **列不存在时必须不筛**：`PhaseStore.query` 把 SQL 错误**静默吞成 `[]`**，
    /// 于是 `no such column: scan_mode` 会表现为"池是空的"，报错文案像"你还没跑过扫描"。
    /// 而"列不存在"恰好**等价于"库里不可能有回放样本"**（回放标记写入也需要这一列），
    /// 所以不筛就是正确行为。
    static func liveOnlyClause(_ includeReplay: Bool) -> String {
        liveOnlyClause(includeReplay: includeReplay, hasColumn: reviewsHasScanMode())
    }

    /// 纯决策版（**可单测**）：列是否存在由调用方给，不碰库。
    ///
    /// 三条分支都要有断言钉住，尤其是第三条 —— "列不存在就不筛"是那个静默失效的解法。
    static func liveOnlyClause(includeReplay: Bool, hasColumn: Bool) -> String {
        guard !includeReplay, hasColumn else { return "" }
        return " AND scan_mode='live'"
    }

    /// `reviews` 是否已有 `scan_mode` 列（Swift-only 迁移是否跑过）。
    ///
    /// ⚠ **有意不缓存**：`PRAGMA table_info` 是微秒级，而调优不是热路径；
    /// 缓存会引入可变静态状态（Swift 6 不允许裸可变全局），还得额外处理"换库后失效"。
    static func reviewsHasScanMode() -> Bool {
        PhaseStore.shared.query("PRAGMA table_info(reviews)")
            .contains { ($0["name"] as? String) == "scan_mode" }
    }

    /// 取数版：[(date, item)]。
    ///
    /// ⚠ `poolDays`：只取**最近 N 个交易日** —— `evaluate` 会对池内每个标的重新打分，
    /// 总计算量 ≈ trials × 池大小，**随使用年限线性增长**；加窗口后耗时封顶。
    ///
    /// 取"最近 N 个"但仍按**升序**返回：子查询 DESC 取窗口、外层 ASC 还原原有时序 ——
    /// 池顺序会决定 `per_stock` 的顺序，必须稳定。
    ///
    /// - Parameter includeReplay: 是否纳入**历史回放样本**。
    ///   **默认 `false`（只用 live）**：回放样本是**收盘价口径**，live 是**尾盘盘中口径**，
    ///   混在一起得到的"最优参数"是两种口径的平均，而界面上看不出池里混了什么。
    ///   取值来自工厂参数 `iterate.include_replay`。
    public static func buildPool(poolDays: Int = 120,
                                 includeReplay: Bool = false) -> [PoolItem] {
        var pool: [PoolItem] = []
        let dates = PhaseStore.shared.query(
            "SELECT sel_date FROM ("
            + "  SELECT DISTINCT sel_date FROM reviews"
            + "  WHERE is_empty_day=0 AND length(stocks_json)>10" + liveOnlyClause(includeReplay)
            + "  ORDER BY sel_date DESC LIMIT ?"
            + ") ORDER BY sel_date ASC", [max(1, poolDays)])
        for dRow in dates {
            let date = (dRow["sel_date"] as? String) ?? ""
            let rounds = PhaseStore.shared.query(
                "SELECT id, market_env_json FROM scan_rounds WHERE date=? ORDER BY slot", [date])
            if rounds.isEmpty { continue }
            var envStored = jsonDict(rounds[0]["market_env_json"])
            if envStored["sh_change_pct"] == nil { envStored["sh_change_pct"] = 0 }
            if envStored["ratio"] == nil { envStored["ratio"] = 999 }
            if envStored["sh_consecutive_decline"] == nil { envStored["sh_consecutive_decline"] = false }

            let actualMap = actualMapFor(date)
            if actualMap.isEmpty { continue }

            for r in rounds {
                guard let rid = r["id"] as? Int else { continue }
                let picks = PhaseStore.shared.query(
                    "SELECT code, name, volume_ratio, turnover, change_pct, deep_info_json,"
                    + " score_details_json FROM picks WHERE round_id=?", [rid])
                for p in picks {
                    let pcode = (p["code"] as? String) ?? ""
                    guard let actual = actualMap[pcode] else { continue }
                    var quote = EngineQuote()
                    quote.code = pcode
                    quote.name = (p["name"] as? String) ?? ""
                    quote.volumeRatio = numOrNil(p["volume_ratio"]) ?? 0
                    quote.turnover = numOrNil(p["turnover"]) ?? 0
                    quote.changePct = numOrNil(p["change_pct"]) ?? 0
                    pool.append(PoolItem(
                        date: date, code: pcode, name: quote.name, quote: quote,
                        deepDict: jsonDict(p["deep_info_json"]),
                        formScore: inferFormScore(jsonList(p["score_details_json"])),
                        envStored: envStored, actual: actual))
                }
            }
        }

        // 同一标的同一天只保留一次。
        // ⚠ 保留**最后一轮**的特征/行情，而不是第一轮（2026-10-16 审查 B5-11）：
        //   标签侧的入场价来自 `PhaseStore.scoredPicks` —— 那里明写
        //   "后面的 slot 覆盖前面的 ⇒ 留下最晚一轮"（`sel_price` = 14:50 那轮的价）。
        //   原先本函数去重却是 `取先出现的那轮` ⇒ **用 14:00 的特征向量，去评 14:50 入场的收益**，
        //   调优器因此在优化一个"当天并不存在的组合"（尾盘量比、深度信息、形态分都是盘中演进的）。
        //   现在两侧对齐到同一轮：**顺序仍按首次出现**（保持既有排序与 tie-break 不变），
        //   只把随轮次变化的负载（行情/深度信息/形态分/环境）换成最晚一轮的。
        var seen = Set<String>()
        var dedup: [PoolItem] = []
        var indexByCode: [String: Int] = [:]
        for it in pool {
            let key = it.date + "\u{1}" + it.code
            guard !seen.contains(key) else {
                if let i = indexByCode[key] {
                    let keep = dedup[i]
                    // 整体替换（`PoolItem` 全是 `let`，不改公开 API 的可变性）：
                    // 位置与 `actual` 沿用首次出现的，轮次相关负载换成最晚一轮的
                    dedup[i] = PoolItem(date: keep.date, code: keep.code, name: it.name,
                                        quote: it.quote, deepDict: it.deepDict,
                                        formScore: it.formScore, envStored: it.envStored,
                                        actual: keep.actual)
                }
                continue
            }

            seen.insert(key)
            indexByCode[key] = dedup.count
            dedup.append(it)
        }
        return dedup

    }

    /// 标签取数：优先 `stock_outcomes`（含三档，统一政策），缺失回落 `reviews.stocks_json`。
    ///
    /// ⚠ 这条优先级是「解幸存者偏差」的核心：只从 reviews 取标签时，被当前参数判为三档的
    /// 标的永远进不了评估，调优器只能"在已选中的标的里重新排序"，发现不了「筛错了」。
    public static func actualMapFor(_ selDate: String) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        let rows = PhaseStore.shared.query(
            "SELECT code, open_pct, disc_profit, disc_win, disc_hit, window_profit, close_profit,"
            + " high_profit, target_pct, window_start, window_end"
            + " FROM stock_outcomes WHERE sel_date=? AND skipped=0", [selDate])
        for r in rows {
            let code = (r["code"] as? String) ?? ""
            out[code] = [
                "open_pct": r["open_pct"] ?? NSNull(),
                "disc_profit": r["disc_profit"] ?? NSNull(),
                "disc_win": r["disc_win"] ?? NSNull(),
                "disc_hit": r["disc_hit"] ?? NSNull(),
                "window_profit": r["window_profit"] ?? NSNull(),
                "close_profit": r["close_profit"] ?? NSNull(),
                "high_profit": r["high_profit"] ?? NSNull(),
                // 政策三列：标签是**按当时政策**打的，带上它才能发现"历史行用的是旧纪律政策"
                "target_pct": r["target_pct"] ?? NSNull(),
                "window_start": r["window_start"] ?? NSNull(),
                "window_end": r["window_end"] ?? NSNull(),
                "label_source": "outcomes",
            ]
        }
        if !out.isEmpty { return out }

        let rv = PhaseStore.shared.query("SELECT stocks_json FROM reviews WHERE sel_date=?", [selDate])
        if let raw = rv.first?["stocks_json"] as? String, !raw.isEmpty {
            for item in jsonList(raw) {
                guard let s = item as? [String: Any], let code = s["code"] as? String, !code.isEmpty
                else { continue }
                // ⚠ 与上面 `stock_outcomes` 那条路径口径对齐：必须过滤 skipped ——
                // 否则红灯日（策略规定不进场 → 全部 skipped）的标的会被当成合法样本计入，
                // 等于**用"不该进场的日子"去优化参数**。
                // `buildPool` 的日期条件（is_empty_day=0 且 stocks_json 够长）也**不排除红灯日**，
                // 所以这道过滤是唯一防线。
                if PredictRules.truthy(s["skipped"]) { continue }
                out[code] = [
                    "open_pct": s["open_pct"] ?? NSNull(),
                    "disc_profit": s["disc_profit"] ?? NSNull(),
                    "disc_win": s["disc_win"] ?? NSNull(),
                    "disc_hit": s["disc_hit"] ?? NSNull(),
                    "window_profit": s["window_profit"] ?? NSNull(),
                    "close_profit": s["close_profit"] ?? NSNull(),
                    "high_profit": s["high_profit"] ?? NSNull(),
                    // reviews 的 stock 行用的键是 `disc_target_pct`（见 PhaseReview 里
                    // `row["disc_target_pct"] = discTargetPct`），这里归一化成 `target_pct`
                    "target_pct": s["disc_target_pct"] ?? s["target_pct"] ?? NSNull(),
                    "label_source": "reviews",
                ]
            }
        }
        return out
    }

    /// 从落库的 score_details 文案反推形态档
    public static func inferFormScore(_ details: [Any]) -> Int {
        for s in details {
            guard let text = s as? String else { continue }
            if text.contains("形态满分") { return 3 }
            if text.contains("形态及格") { return 2 }
        }
        return 0
    }

    /// 存储字典 → DeepInfo。返回 nil = 存储值类型异常（样本被丢弃并计数）。
    public static func deepInfo(_ d: [String: Any]) -> DeepInfo? {
        /// 键缺失 → 默认值；显式 null → nil（由调用点决定语义）
        func val(_ k: String, _ def: Double = 0.0) -> Double? {
            guard let v = d[k] else { return def }
            if v is NSNull { return nil }
            return numOrNil(v) ?? def
        }
        guard let vm = val("vol_mult_5d"), let gr = val("gain_ratio"),
              let sbr = val("shadow_body_ratio") else { return nil }
        // cum_5d 单独处理：键缺失 → 0.0（照常参与打分）；显式 null → 数据不足分支
        let c5: Double?
        if let v = d["cum_5d"] { c5 = (v is NSNull) ? nil : (numOrNil(v) ?? 0.0) } else { c5 = 0.0 }
        return DeepInfo(
            ma5: numOrNil(d["ma5"]), ma10: numOrNil(d["ma10"]), ma20: numOrNil(d["ma20"]),
            maPass: PredictRules.truthy(d["ma_pass"]),
            volMult5d: vm,
            consecUp: intOrNil(d["consec_up"]) ?? 0,
            cum5d: c5,
            prev1d: val("prev_1d") ?? 0,
            distFromLow: val("dist_from_low") ?? 0,
            distFromHigh: val("dist_from_high") ?? 0,
            ma20SlopeUp: PredictRules.truthy(d["ma20_slope_up"]),
            maDeviation: val("ma_deviation") ?? 0,
            gainRatio: gr,
            shadowBodyRatio: sbr)
    }

    /// 重建评分用的大盘环境。返回 nil = `sh_change_pct` 显式 null，无法重建。
    public static func rebuildEnv(_ stored: [String: Any], _ params: [String: Any]) -> [String: Any]? {
        var env = stored
        let ex = (params["exclusion"] as? [String: Any]) ?? [:]
        let ratioVal = numOrNil(env["ratio"]) ?? 0
        let ratio = ratioVal != 0 ? ratioVal : 999
        let shRaw: Any? = env["sh_change_pct"]
        if shRaw is NSNull { return nil }
        let sh = numOrNil(shRaw) ?? 0
        env["ratio_ok"] = ratio >= (numOrNil(ex["market_ratio_threshold"]) ?? 0)
        env["sh_ok"] = sh > (numOrNil(ex["market_change_threshold"]) ?? 0)
            && !PredictRules.truthy(env["sh_consecutive_decline"])
        return env
    }

    // MARK: - 评估

    /// `pool_size` = 成功评分的样本数、`valid_size` = 池大小。
    public static func evaluate(params: [String: Any], pool: [PoolItem], detail: Bool = false,
                         metric: String = PhaseTune.defaultMetric) -> [String: Any] {
        let m = metrics.contains { $0.key == metric } ? metric : defaultMetric
        let tiers = ((params["scoring"] as? [String: Any])?["tiers"] as? [String: Any]) ?? [:]
        let tier1Min = numOrNil(tiers["tier1_min"]) ?? 0
        let tier2Min = numOrNil(tiers["tier2_min"]) ?? 0

        var groups: [String: [PoolItem]] = ["1": [], "2": [], "3": []]
        var perStock: [[String: Any]] = []
        var errors = 0
        var scored = 0
        for it in pool {
            guard let env = rebuildEnv(it.envStored, params), let deep = deepInfo(it.deepDict) else {
                errors += 1
                continue
            }
            var meta: [String: Any] = [:]
            let (score, _, _) = Screener.scoreStock(
                quote: it.quote, deep: deep, intraday: it.deepDict["intraday"] as? [String: Any],
                formScore: it.formScore, marketEnv: env, params: params, meta: &meta)
            let scoreNum = numOrNil(score) ?? 0
            let tier = scoreNum >= tier1Min ? 1 : (scoreNum >= tier2Min ? 2 : 3)
            groups[String(tier)]?.append(it)
            scored += 1
            if detail {
                let p = profit(it, m)
                // round(score, 1)：int 保持 int、float 保持 float（见 Screener.ScoreAcc）
                let scoreOut: Any = (score is Int) ? score : PyMath.round(scoreNum, 1)
                perStock.append([
                    "code": it.code, "name": it.name, "date": it.date,
                    "score": scoreOut, "tier": tier,
                    "profit": p ?? NSNull(), "win": p == nil ? NSNull() : (p! > 0),
                ])
            }
        }

        func stats(_ items: [PoolItem], _ mm: String) -> [String: Any] {
            if items.isEmpty {
                return ["n": 0, "winrate": 0.0, "avg_profit": 0.0, "wins": 0, "labeled": 0,
                        "labeled_fallback": 0]
            }
            // 一次算出 (值, 是否回退)，避免对同一只票反复调用 profit()
            let src = items.map { profitSrc($0, mm) }
            let labeledSrc = src.filter { $0.value != nil }
            let profits = labeledSrc.map { $0.value! }
            let fellBack = labeledSrc.filter { $0.fellBack }.count
            let wins = profits.filter { $0 > 0 }.count
            return [
                "n": items.count, "labeled": labeledSrc.count,
                // 显式报告口径回退样本数（见 profitSrc 注释）
                "labeled_fallback": fellBack,
                "winrate": labeledSrc.isEmpty ? 0.0
                    : PyMath.round(Double(wins) / Double(labeledSrc.count) * 100, 1),
                "avg_profit": profits.isEmpty ? 0.0
                    : PyMath.round(PyMath.sum(profits) / Double(profits.count), 2),
                "wins": wins,
            ]
        }

        // ⚠ `groups` 的字面量初始化就含 `"1"/"2"/"3"` 三个键（见函数开头），且全程只 append、
        //   不删键 —— 所以下面的 `groups["1"]!` 是**构造不变量**，不是赌博。
        //   若哪天改成"按需建键"，这几处要一起改；**不要**改成 `?? []` 之类静默兜底 ——
        //   那会把"键没了"悄悄变成"这一档 0 只票"，报表数字错而不报错。
        let s1 = stats(groups["1"]!, m)
        let s2 = stats(groups["2"]!, m)
        let tier1N = groups["1"]!.count
        let coverage = scored == 0 ? 0.0
            : PyMath.round(Double(tier1N) / Double(scored) * 100, 1)

        // 综合分权重：winrate/coverage 取值 0~100，avg_profit 取值 0~cap
        // 0.6×100 : 0.3×cap : 0.1×100 → 代码里写 (3.0 × (10/cap)) 保持 60:30:10 等效。
        let capRaw = numOrNil(((params["iterate"] as? [String: Any])?["thresholds"]
            as? [String: Any])?["avg_profit_cap"])
        let cap = (capRaw == nil || capRaw == 0) ? 10.0 : capRaw!
        let profitScale = cap > 0 ? 3.0 * (10.0 / cap) : 0.0
        let avgP = numOrNil(s1["avg_profit"]) ?? 0
        let winrate1 = numOrNil(s1["winrate"]) ?? 0
        // ⚠ 胜率项按**样本量向 50% 中性收缩**（2026-10-16 审查 B5-12）：
        //   原先直接用 `winrate1 * 0.6`，而一档只有 2 只且恰好都赢 ⇒ 胜率 100%
        //   → 该候选拿 60 分，碾压"一档 30 只、胜率 55%"的 33 分。
        //   随机搜索会**系统性地选出"把一档缩到几只运气票"的参数**（覆盖面项只有 0.1 权重，
        //   补不回这 27 分差），而 `sample_gate` 过去只看**整个池**的样本数、
        //   从不看候选自己的一档样本数 —— 这就是它拦不住的原因。
        //   做法：Beta 先验（伪计数 = `SampleGate.defaultThreshold`，先验胜率 50%），
        //   样本到 30 只时约收敛一半、到几百只时几乎不缩；无样本仍是 0（不给"什么都不选"发分）。
        let labeled1 = Num.intOrNil(s1["labeled"]) ?? 0
        let wins1 = Num.intOrNil(s1["wins"]) ?? 0
        let priorN = Double(SampleGate.defaultThreshold)
        let winrateAdj = labeled1 == 0 ? 0.0
            : PyMath.round((Double(wins1) + priorN * 0.5) / (Double(labeled1) + priorN) * 100, 1)
        let total = PyMath.round(winrateAdj * 0.6 + min(avgP, cap) * profitScale + coverage * 0.1, 2)


        var byMetric: [String: Any] = [:]
        for mm in metrics {
            // 直接用 stats 的结果（口径完全一致），顺带拿到回退计数
            let st = stats(groups["1"]!, mm.key)
            byMetric[mm.key] = [
                "label": mm.label,
                "winrate": st["winrate"] ?? 0.0,
                "avg_profit": st["avg_profit"] ?? 0.0,
                "labeled": st["labeled"] ?? 0,
                // 其中由"口径缺失回退"贡献的样本数（>0 时该口径的 winrate/avg_profit 是混合口径）
                "fallback": st["labeled_fallback"] ?? 0,
                "tier1_n": tier1N,
            ]
        }

        var result: [String: Any] = [:]
        result["total"] = total
        // 原始胜率与收缩后胜率都报出来：调优报告里"这一档的分数为什么比胜率低"必须可解释，
        // 不能是一个看不见的内部修正
        result["winrate_shrink"] = ["raw": winrate1, "used": winrateAdj,
                                    "labeled": labeled1, "prior_n": Int(priorN)]
        result["metric"] = m

        // ⚠ `m` 在入口已规范化 ⇒ `first` 当前不可达；回落成键名，
        //   防新增入口忘规范化时强解包成不可 catch 的 trap。
        result["metric_label"] = metrics.first { $0.key == m }?.label ?? m
        result["tier1"] = s1
        result["tier2"] = s2
        result["coverage_pct"] = coverage
        result["pool_size"] = scored
        result["valid_size"] = pool.count
        result["score_errors"] = errors
        result["by_metric"] = byMetric
        // 主口径的回退暴露：total 与 by_metric[m] 在回退发生时是"目标口径 + 收盘持有口径"
        // 的混合统计，必须让调用方**看得见**这个分裂，否则会把收盘持有口径读成纪律口径。
        let mainFallback = numOrNil((byMetric[m] as? [String: Any])?["fallback"]) ?? 0
        let mainLabeled = numOrNil((byMetric[m] as? [String: Any])?["labeled"]) ?? 0
        result["metric_fallback"] = mainFallback
        if mainFallback > 0 {
            let label = metrics.first { $0.key == m }!.label
            result["caliber_note"] = "⚠ \(label) 口径的 \(Int(mainLabeled)) 个样本中有 "
                + "\(Int(mainFallback)) 个因目标口径缺失回退成了「收盘持有」口径"
                + "（通常是该交易日没有窗口 5 分钟线，分时数据只覆盖最近约 5 个交易日）。"
                + "total 与 by_metric.\(m) 是混合口径，不可按单一纪律口径解读。"
        }
        if detail { result["per_stock"] = perStock }
        return result
    }

    /// 取指定口径收益，并**显式报告是否发生了口径回退**。
    ///
    /// ⚠ 为什么必须能区分：目标口径缺失时会静默退回收盘持有口径。`disc_profit`（L3 纪律口径）
    ///   为 NULL 的条件是"该交易日没有窗口 5 分钟线"，而 `fetch5minBars`（datalen=240）
    ///   只覆盖**最近约 5 个交易日** —— 更早的样本几乎**全部**回退，
    ///   此时 `by_metric["l3"]` 的 `winrate / avg_profit` 实际是收盘持有口径，
    ///   却被当作"纪律口径"解读。
    public static func profitSrc(_ it: PoolItem, _ metric: String) -> (value: Double?, fellBack: Bool) {
        // ⚠ metrics 表被改坏、两层都落空时返回"无值"而不是崩 —— (nil, false) 是本函数的合法结果
        guard let field = (metrics.first { $0.key == metric }
                           ?? metrics.first { $0.key == defaultMetric })?.field else {
            return (nil, false)
        }
        if let own = numOrNil(it.actual[field]) { return (own, false) }
        if metric != "close", let fallback = numOrNil(it.actual["close_profit"]) {
            return (fallback, true)
        }
        return (nil, false)
    }

    /// 取指定口径收益；该口径缺失时退回收盘持有收益（close 口径不退）。
    /// 需要区分"是否回退"时用 `profitSrc`。
    public static func profit(_ it: PoolItem, _ metric: String) -> Double? {
        profitSrc(it, metric).value
    }

    /// 逐标的档位/评分变化 + 真实次日盈亏；汇总指标差异
    public static func backtestCompare(_ old: [String: Any], _ new: [String: Any],
                                perOld: [[String: Any]], perNew: [[String: Any]]) -> [String: Any] {
        var newBy: [String: [String: Any]] = [:]
        for p in perNew {
            newBy[key(p["date"], p["code"])] = p
        }
        var rows: [[String: Any]] = []
        for o in perOld {
            guard let n = newBy[key(o["date"], o["code"])] else { continue }
            let oldTier = intOrNil(o["tier"]) ?? 0
            let newTier = intOrNil(n["tier"]) ?? 0
            let tierDelta = newTier - oldTier
            let win = PredictRules.truthy(n["win"])
            let good = (win && tierDelta < 0) || (!win && tierDelta > 0)
            let bad = (win && tierDelta > 0) || (!win && tierDelta < 0)
            rows.append([
                "code": o["code"] ?? NSNull(), "name": o["name"] ?? NSNull(),
                "old_score": o["score"] ?? NSNull(), "new_score": n["score"] ?? NSNull(),
                "old_tier": oldTier, "new_tier": newTier,
                "profit": n["profit"] ?? NSNull(), "win": n["win"] ?? NSNull(),
                "change": good ? "good" : (bad ? "bad" : "same"),
            ])
        }
        // 按 (change!="good", change!="bad", -new_score) 排序，稳定（offset 兜底）
        let order = rows.enumerated().sorted { a, b in
            let c = compareKeys(sortKey(a.element), sortKey(b.element))
            if c != 0 { return c < 0 }
            return a.offset < b.offset
        }.map { $0.offset }
        let sortedRows = order.map { rows[$0] }

        func delta(_ a: Any?, _ b: Any?) -> Double {
            PyMath.round((numOrNil(b) ?? 0) - (numOrNil(a) ?? 0), 2)
        }
        let oldT1 = (old["tier1"] as? [String: Any]) ?? [:]
        let newT1 = (new["tier1"] as? [String: Any]) ?? [:]
        var summary: [String: Any] = [:]
        summary["old"] = ["total": old["total"] ?? 0, "tier1": oldT1, "coverage_pct": old["coverage_pct"] ?? 0]
        summary["new"] = ["total": new["total"] ?? 0, "tier1": newT1, "coverage_pct": new["coverage_pct"] ?? 0]
        summary["total_delta"] = delta(old["total"], new["total"])
        summary["winrate_delta"] = delta(oldT1["winrate"], newT1["winrate"])
        summary["avg_profit_delta"] = delta(oldT1["avg_profit"], newT1["avg_profit"])
        summary["good_changes"] = sortedRows.filter { ($0["change"] as? String) == "good" }.count
        summary["bad_changes"] = sortedRows.filter { ($0["change"] as? String) == "bad" }.count
        return ["rows": sortedRows, "summary": summary]
    }

    private static func sortKey(_ r: [String: Any]) -> [Double] {
        let change = (r["change"] as? String) ?? "same"
        return [change == "good" ? 0 : 1, change == "bad" ? 0 : 1,
                -(numOrNil(r["new_score"]) ?? 0)]
    }

    private static func compareKeys(_ a: [Double], _ b: [Double]) -> Int {
        for i in 0..<min(a.count, b.count) where a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
        if a.count == b.count { return 0 }
        return a.count < b.count ? -1 : 1
    }

    // MARK: - 搜索

    /// 只扰动随机 1~maxDims 个维度 —— 扰动**全部**维度会让单维的有效信号
    /// 被其余维度的噪声淹没；限制子集大小后，单轮改动可解释、命中率更高。
    public static func mutate(base: [String: Any], dims: [String], rng: PyRandom,
                       maxDims: Int = 3) -> [String: Any] {
        let items = itemByKey
        let known = dims.filter { items[$0] != nil }
        if known.isEmpty { return [:] }
        let k = min(known.count, rng.randint(1, max(1, min(maxDims, known.count))))
        let subset = rng.sample(known, k)

        var diff: [String: Any] = [:]
        for key in subset {
            guard let item = items[key] else { continue }
            guard let cur = ParamSchema.getValue(base, key), !(cur is NSNull) else { continue }
            switch item.type {
            case "int":
                guard let c = intOrNil(cur) else { continue }
                let step = max(intOrNil(item.raw["step"]) ?? 1, 1)
                let delta = step * rng.choice([-5, -2, -1, 1, 2, 5])
                diff[key] = clampInt(c + delta, item)
            case "float":
                guard let c = numOrNil(cur) else { continue }
                diff[key] = clampFloat(PyMath.round(c * rng.uniform(0.85, 1.15), 2), item)
            case "num_pair":
                guard let arr = cur as? [Any], arr.count >= 2,
                      let c0 = numOrNil(arr[0]), let c1 = numOrNil(arr[1]) else { continue }
                var lo = max(PyMath.round(c0 * rng.uniform(0.9, 1.1), 2), 0.1)
                var hi = max(PyMath.round(c1 * rng.uniform(0.9, 1.1), 2), lo)   // 保持下限 ≤ 上限
                if let mn = numOrNil(item.minValue) { lo = max(lo, mn); hi = max(hi, mn) }
                if let mx = numOrNil(item.maxValue) { lo = min(lo, mx); hi = min(hi, mx) }
                diff[key] = [lo, hi]
            default:
                continue
            }
        }
        return diff
    }

    /// int 夹取到 [min, max]
    public static func clampInt(_ v: Int, _ item: ParamSchema.Item) -> Int {
        let hi = intOrNil(item.maxValue) ?? 1_000_000_000
        let lo = intOrNil(item.minValue) ?? 0
        return max(min(v, hi), lo)
    }

    /// float 夹取：先 round(v, 4) 再夹到 [min, max]
    public static func clampFloat(_ v: Double, _ item: ParamSchema.Item) -> Double {
        let x = PyMath.round(v, 4)
        let hi = numOrNil(item.maxValue) ?? 1e18
        let lo = numOrNil(item.minValue) ?? 0.0
        return max(min(x, hi), lo)
    }

    /// 逐项比较基线/候选（**遍历全部 schema 项**，含那些池内无影响的维度）
    public static func diffMap(_ base: [String: Any], _ params: [String: Any]) -> [String: Any] {
        var d: [String: Any] = [:]
        for item in ParamSchema.shared.allItems {
            let b = ParamSchema.getValue(base, item.key)
            let v = ParamSchema.getValue(params, item.key)
            if !pyEqual(b, v) { d[item.key] = v ?? NSNull() }
        }
        return d
    }

    private static func diffSignature(_ diff: [String: Any]) -> String {
        let obj: [String: Any] = diff.mapValues { $0 is NSNull ? NSNull() : $0 }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - 调优主流程

    /// - Parameter includeReplayOverride: 是否把**历史回放样本**纳入池。
    ///   `nil`（默认）= 读工厂参数 `iterate.include_replay`（出厂 `false`）；
    ///   非 nil = 调用方的**显式选择**（设置页的开关，存 UserDefaults）。
    ///
    ///   ⚠ 两层结构（与 `phases` 同一模式）：工厂参数是**引擎侧默认值**（随包 JSON 带着走），
    ///   而"这次调优要不要算回放样本"是**用户当下的选择**，不该逼用户去另存一个参数版本才能改；
    ///   实际生效值由设置页存在 UserDefaults 里。
    public static func tune(dims requested: [String]? = nil, trials: Int = 200, hillRounds: Int = 3,
                     seed: Int? = nil,
                     metric: String = PhaseTune.defaultMetric,
                     includeReplayOverride: Bool? = nil) throws -> [String: Any] {
        let t0 = Date().timeIntervalSince1970
        let m = metrics.contains { $0.key == metric } ? metric : defaultMetric
        // ⚠ seed 为 0 时同样走时间种子（`seed or int(time.time())` 语义）
        let effectiveSeed = (seed != nil && seed != 0) ? seed! : Int(Date().timeIntervalSince1970)
        let rng = PyRandom(seed: effectiveSeed)
        var dims = (requested ?? tuningDims).filter { tuningDims.contains($0) }
        if dims.isEmpty { dims = tuningDims }

        guard let base = paramsFor() else { throw TuneError.paramsUnavailable }
        // 调优池窗口：只取最近 N 个交易日，让耗时封顶。
        let iterateCfg = (base["iterate"] as? [String: Any]) ?? [:]
        let poolDays = PredictRules.int(iterateCfg["tune_pool_days"]) ?? 120
        // 是否纳入历史回放样本：工厂参数是**默认**，调用方可显式覆盖。
        // 默认 false = 只用 live —— 回放是收盘价口径，混池会让"最优参数"变成两种口径的平均。
        let includeReplay = includeReplayOverride
            ?? (PredictRules.bool(iterateCfg["include_replay"]) ?? false)
        let pool = buildPool(poolDays: poolDays, includeReplay: includeReplay)
        if pool.isEmpty {
            return ["status": "no_data", "error": "历史评估池为空：需有含真实复盘标的的选股日"]
        }

        let baseMetrics = evaluate(params: base, pool: pool, detail: true, metric: m)
        var best = base
        var bestScore = numOrNil(baseMetrics["total"]) ?? 0
        var grid: [(total: Double, metrics: [String: Any], cand: [String: Any])] = []

        for _ in 0..<trials {
            let cand = ParamSchema.shared.applyDiff(base: base, diff: mutate(base: base, dims: dims, rng: rng))
            let mm = evaluate(params: cand, pool: pool, metric: m)
            let total = numOrNil(mm["total"]) ?? 0
            if total > bestScore { best = cand; bestScore = total }
            grid.append((total, mm, cand))
        }
        // 按 -total 排序，稳定（offset 兜底）
        let gridOrder = grid.enumerated().sorted { a, b in
            if a.element.total != b.element.total { return a.element.total > b.element.total }
            return a.offset < b.offset
        }.map { $0.offset }

        // 爬山精调：每维尝试多档步长（step、3×step、5×step），能一步跨过档位边界
        for _ in 0..<hillRounds {
            var improved = false
            for key in dims {
                guard let item = itemByKey[key], item.type == "int" || item.type == "float" else { continue }
                guard let curRaw = ParamSchema.getValue(best, key), !(curRaw is NSNull) else { continue }
                let cur = numOrNil(curRaw) ?? 0
                let step: Double = (numOrNil(item.raw["step"]) ?? 0) != 0
                    ? numOrNil(item.raw["step"])! : (item.type == "int" ? 1 : 0.05)
                for delta in [step, -step, 3 * step, -3 * step, 5 * step, -5 * step] {
                    let newVal: Any = item.type == "int"
                        ? clampInt((intOrNil(curRaw) ?? 0) + Int(delta), item)
                        : clampFloat(cur + delta, item)
                    let trial = ParamSchema.shared.applyDiff(base: best, diff: [key: newVal])
                    let mm = evaluate(params: trial, pool: pool, metric: m)
                    let total = numOrNil(mm["total"]) ?? 0
                    if total > bestScore {
                        best = trial; bestScore = total; improved = true
                        break
                    }
                }
            }
            if !improved { break }
        }

        // 最终候选（爬山收敛结果）单独带逐标的明细，供回测对比
        let bestMetrics = evaluate(params: best, pool: pool, detail: true, metric: m)
        let final = [["metrics": bestMetrics, "diff": diffMap(base, best)]]
        var raw: [[String: Any]] = gridOrder.prefix(5).map {
            ["metrics": grid[$0].metrics, "diff": diffMap(base, grid[$0].cand)]
        }
        raw += final
        // 去重（同 diff 只保留一个，保持先出现者）
        var seen = Set<String>()
        var uniq: [[String: Any]] = []
        for c in raw {
            let sig = diffSignature((c["diff"] as? [String: Any]) ?? [:])
            if seen.contains(sig) { continue }
            seen.insert(sig)
            uniq.append(c)
        }
        // 按 total 降序，稳定 → 并列保持原序
        let topOrder = uniq.enumerated().sorted { a, b in
            let ta = numOrNil((a.element["metrics"] as? [String: Any])?["total"]) ?? 0
            let tb = numOrNil((b.element["metrics"] as? [String: Any])?["total"]) ?? 0
            if ta != tb { return ta > tb }
            return a.offset < b.offset
        }.map { $0.offset }

        let basePer = (baseMetrics["per_stock"] as? [[String: Any]]) ?? []
        var candidatesOut: [[String: Any]] = []
        for idx in topOrder.prefix(5) {
            let c = uniq[idx]
            let diff = (c["diff"] as? [String: Any]) ?? [:]
            let candParams = ParamSchema.shared.applyDiff(base: base, diff: diff)
            let candMetrics = evaluate(params: candParams, pool: pool, detail: true, metric: m)
            var candOut: [String: Any] = ["metrics": candMetrics, "diff": diff]
            if !diff.isEmpty {
                candOut["backtest"] = backtestCompare(
                    baseMetrics, candMetrics, perOld: basePer,
                    perNew: (candMetrics["per_stock"] as? [[String: Any]]) ?? [])
            }
            candidatesOut.append(candOut)
        }

        var sources: [String: Int] = [:]
        for it in pool {
            let s = (it.actual["label_source"] as? String) ?? "unknown"
            sources[s] = (sources[s] ?? 0) + 1
        }

        // 样本量透明度：让调用方看得见"这次调优是在多少天 / 多少样本上做的" ——
        // 样本量直接决定结论可信度，只报 pool_size（标的总数）看不出跨了多少天。
        let poolDateSet = Set(pool.map(\.date).filter { !$0.isEmpty }).sorted()
        let poolWindow = poolDateSet.isEmpty ? ""
            : "\(poolDateSet.first!) ~ \(poolDateSet.last!)"

        // 政策一致性：`stock_outcomes` 的标签是**按当时政策**打的（target_pct 落库）。
        // 用户改过 `iterate.thresholds.discipline_target_pct` 之后，历史行仍是旧政策，
        // 而调优会把两套政策混算 —— 必须报出来。
        // 同时给出 `policy_labeled`：reviews 回退路径的行没有政策字段，
        // 若只报 mismatch，那种库会永远显示 0（"看起来没问题"），同样是盲区。
        let curTargetPct = PredictRules.num(
            ((base["iterate"] as? [String: Any])?["thresholds"]
                as? [String: Any])?["discipline_target_pct"]).flatMap { $0 == 0 ? nil : $0 } ?? 1.5
        var policyLabeled = 0, policyMismatch = 0
        for it in pool {
            guard let t = numOrNil(it.actual["target_pct"]) else { continue }
            policyLabeled += 1
            if PyMath.round(t, 4) != PyMath.round(curTargetPct, 4) { policyMismatch += 1 }
        }

        var out: [String: Any] = [:]
        out["status"] = "ok"
        out["scope"] = "global"
        out["metric"] = m
        out["metric_label"] = metrics.first { $0.key == m }!.label
        out["label_sources"] = sources
        // 强调记号用「」：这段文案由 UI 逐字渲染（Text 不解析 Markdown），`**` 会原样显示
        out["scope_note"] = "评估覆盖：当日「全部已评分标的」（含三档，标签来自 stock_outcomes 的统一政策，"
            + "已消除原先只覆盖 tier1/tier2 的幸存者偏差）。"
            + "「仍未覆盖」：在全市场阶段就被硬过滤/画像/形态淘汰、因而从未评分的标的 —— "
            + "该层需用行情快照做全链路重放才能评估。"
        out["elapsed_s"] = PyMath.round(Date().timeIntervalSince1970 - t0, 1)
        out["pool_size"] = pool.count
        out["pool_days"] = poolDays
        out["pool_dates"] = poolDateSet.count
        out["pool_window"] = poolWindow
        // 这次调优用的是哪个口径的样本池。必须在结果里报出来 —— 否则用户看到
        // "池突然变大了"无从解释（回放样本是**收盘价口径**，与 live 的尾盘盘中口径不可混）。
        out["include_replay"] = includeReplay
        out["dims"] = dims
        // 加分项同源相关性诊断（见 `CorrelationDiagnostic`）：
        // 在池上算特征秩相关，提示"这几项其实在重复计数"。
        // 只诊断、不阻断、不改权重（附加式改动）。
        let corrSamples = correlationSamples(pool)
        out["correlation"] = CorrelationDiagnostic.json(
            pairs: CorrelationDiagnostic.diagnose(samples: corrSamples),
            samples: corrSamples.count,
            threshold: CorrelationDiagnostic.defaultThreshold)
        // 反事实覆盖诊断：被淘汰样本的行情/深度特征从未落库 → 无法并入评估池；
        // 把缺口做成**可测的数**。判据取自 `excluded_stocks` 的实际列名（不是写死的 0），
        // 补上列后自动变真实计数。
        let exclColumns = Set(PhaseStore.shared.query("PRAGMA table_info(excluded_stocks)")
            .compactMap { $0["name"] as? String })
        let missingCols = CounterfactualCoverage.missingColumns(from: exclColumns)
        // 窗口口径与 `buildPool` 的日期子查询**逐字一致**（同一份 LIMIT），否则数字对不上。
        // ⚠ 那句「只用 live」的过滤也必须一起带上 —— 漏了它就会出现
        //   "池里有 40 个交易日、诊断说窗口里有 60 个"，而两个数看着都正常。
        let windowDates = "SELECT sel_date FROM ("
            + "  SELECT DISTINCT sel_date FROM reviews"
            + "  WHERE is_empty_day=0 AND length(stocks_json)>10" + liveOnlyClause(includeReplay)
            + "  ORDER BY sel_date DESC LIMIT ?"
            + ")"
        // ⚠ 过滤器用枚举而不是字符串参数：防"可以传任意 SQL 片段"的形状
        //   让 SQL 文本从调用点漏进函数体。
        enum ExcludedFilter { case all, rescoreable }
        func countExcluded(_ f: ExcludedFilter) -> Int {
            let extra = (f == .rescoreable) ? " AND deep_info_json IS NOT NULL" : ""
            let rows = PhaseStore.shared.query(
                "SELECT COUNT(*) AS n FROM excluded_stocks WHERE date IN (\(windowDates))" + extra,
                [max(1, poolDays)])
            return (rows.first?["n"] as? Int) ?? 0
        }
        // 只有真具备特征列时才去数「可重新评分」的条数（否则那些列不存在，SQL 会报错）
        let exclRescoreable = missingCols.isEmpty
            ? countExcluded(.rescoreable) : 0
        out["counterfactual"] = CounterfactualCoverage.json(
            excludedInWindow: countExcluded(.all), excludedRescoreable: exclRescoreable,
            poolSize: pool.count, missingColumns: missingCols)
        // 参数时代诊断：池里每条样本按自己的 `sel_date` 反查**当天生效的参数版本**
        // （`effective_from`）—— 窗口跨多个版本时，结论是"混合参数时代"的
        // （与 `policy_mismatch` 同类偏差：用 A 时代入档的样本去优化 B 时代的参数）。
        // ⚠ **不做"按当日版本分别评估"**：那会让不同样本跑在不同基线下，指标彼此不可比，
        //   比"混合"更难解释。先如实报出来，要不要分时代调由用户决定。
        var eras: [String: Int] = [:]
        for it in pool {
            let v = ParamStore.shared.versionEffectiveOn(date: it.date) ?? "(未记录)"
            eras[v] = (eras[v] ?? 0) + 1
        }
        out["param_eras"] = eras
        if eras.count > 1 {
            // ⚠ 强调记号用「」：展示方（TunePanelView）用 `Text(String)` 逐字渲染，
            //   `**` 会原样显示。
            out["param_era_warning"] = "⚠ 评估池跨了 \(eras.count) 个参数版本（"
                + eras.keys.sorted().joined(separator: " / ")
                + "）：样本是在各自时代的参数下入档的，结论是「混合参数时代」的，"
                + "请勿与单一版本的结论直接对比。"
        }
        out["baseline"] = ["metrics": baseMetrics]
        out["candidates"] = candidatesOut
        // 样本门槛：结构化判据，UI 据此不出结论（只靠下面那句 `warning` 文案不够）。
        out["sample_gate"] = SampleGate.json(samples: pool.count)
        if pool.count < SampleGate.defaultThreshold {
            // ⚠ 阈值改走 `SampleGate.defaultThreshold`，以免同一个数字写两处
            out["warning"] = "样本仅 \(pool.count) 只，结果不具统计意义（建议≥30只）"
        }
        // 口径回退告警提升到顶层：基线里已有 caliber_note，但 UI 只读顶层字段 ——
        // 不提升就等于"记了但没人看得到"。
        if let note = baseMetrics["caliber_note"] as? String, !note.isEmpty {
            out["caliber_warning"] = note
        }
        out["policy_labeled"] = policyLabeled
        out["policy_mismatch"] = policyMismatch
        if policyMismatch > 0 {
            // 强调记号用「」（逐字渲染，`**` 会原样显示）
            out["policy_warning"] = "⚠ 带政策标签的 \(policyLabeled) 个样本中，有 "
                + "\(policyMismatch) 个是用「旧纪律政策」打的（当前目标价 +"
                + "\(PyJSON.numStr(curTargetPct))%）。这些行的 L3 标签按旧政策生成，"
                + "调优结果是「混合政策」的，请勿与单一政策结论直接对比。"
        }
        return out
    }

    // MARK: - 随机流探针（证明「同 seed 同序列」）

    /// ⚠ 调用顺序是调优可复现性的地基 —— 随机流一致了，"同 seed 同候选"才有意义。
    /// 无自动拦截，这条纪律靠本注释与 `PyRandomTests` 守住。
    public static func rngProbe(seeds: [Int]) -> [String: Any] {
        let dims = (0..<21).map { "d\($0)" }
        var out: [String: Any] = [:]
        for s in seeds {
            let r = PyRandom(seed: s)
            var rand: [Double] = []
            for _ in 0..<6 { rand.append(r.random()) }
            var randint: [Int] = []
            for _ in 0..<6 { randint.append(r.randint(1, 3)) }
            var sample: [String] = []
            for _ in 0..<3 { sample.append(r.sample(dims, 3).joined(separator: ",")) }
            var choice: [Int] = []
            for _ in 0..<6 { choice.append(r.choice([-5, -2, -1, 1, 2, 5])) }
            var uniform: [Double] = []
            for _ in 0..<3 { uniform.append(r.uniform(0.85, 1.15)) }
            out[String(s)] = ["rand": rand, "randint": randint, "sample": sample,
                              "choice": choice, "uniform": uniform]
        }
        return out
    }

    // MARK: - 取值与比较工具

    public static func key(_ a: Any?, _ b: Any?) -> String {
        "\((a as? String) ?? "")\u{1}\((b as? String) ?? "")"
    }

    /// 把调优池摊成「特征键 → 值」的样本表（供 `CorrelationDiagnostic` 用）。
    ///
    /// ⚠ **缺值不补 0**：`cum_5d` 在 K 线不足时是 null、`gain_ratio` / `shadow_body_ratio`
    /// 也可能显式为 null —— 补 0 会把"没有数据"变成"特征值为 0"，直接污染相关系数。
    /// 故只在**真的取到值**时才写键；缺键的样本由 `diagnose` 按"成对完整观测"排除。
    private static func correlationSamples(_ pool: [PoolItem]) -> [[String: Double]] {
        pool.map { it in
            var s: [String: Double] = [:]
            for f in CorrelationDiagnostic.features {
                if f.key == "form_score" {
                    // 形态分是**池内独立字段**（不在 deep 里），由评分明细反推得到
                    s[f.key] = Double(it.formScore)
                } else if let v = numOrNil(it.deepDict[f.key]) {
                    s[f.key] = v
                }
            }
            return s
        }
    }

    public static func numOrNil(_ v: Any?) -> Double? {
        guard let v = v else { return nil }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? 1 : 0 }
            return n.doubleValue
        }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    public static func intOrNil(_ v: Any?) -> Int? {
        guard let v = v else { return nil }
        if v is NSNull { return nil }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? 1 : 0 }
            return n.intValue
        }
        if let i = v as? Int { return i }
        // ⚠ `isFinite` 守卫：`Int(inf)` / `Int(nan)` 是 Swift trap，不可 catch
        if let d = v as? Double { return d.isFinite ? Int(d) : nil }
        return nil
    }

    /// 语义相等比较（含 `True == 1` 与列表/字典的逐元素比较）
    public static func pyEqual(_ a: Any?, _ b: Any?) -> Bool {
        let x: Any = a ?? NSNull()
        let y: Any = b ?? NSNull()
        if x is NSNull || y is NSNull { return x is NSNull && y is NSNull }
        if let nx = numOrNil(x), let ny = numOrNil(y) { return nx == ny }
        if let sx = x as? String, let sy = y as? String { return sx == sy }
        if let ax = x as? [Any], let ay = y as? [Any] {
            if ax.count != ay.count { return false }
            return zip(ax, ay).allSatisfy { pyEqual($0, $1) }
        }
        if let dx = x as? [String: Any], let dy = y as? [String: Any] {
            if dx.count != dy.count { return false }
            return dx.keys.allSatisfy { dy[$0] != nil && pyEqual(dx[$0], dy[$0]) }
        }
        return false
    }

    public static func jsonDict(_ v: Any?) -> [String: Any] {
        guard let s = v as? String, !s.isEmpty, let data = s.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    public static func jsonList(_ v: Any?) -> [Any] {
        guard let s = v as? String, !s.isEmpty, let data = s.data(using: .utf8) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data) as? [Any]) ?? []
    }
}