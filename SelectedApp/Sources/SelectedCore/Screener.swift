import Foundation

/// Selected 引擎 — 选股核心纯函数。
///
/// 覆盖（**不含** run_scan / _persist_round / get_latest_round 这些编排与落库逻辑）：
///   · 评分表键名解析 / 查值（让「改表生效」）
///   · 第3层硬性过滤、第6层画像+避雷（纯函数）
///   · 评分（附录 + 源码逐项对齐）
///   · ETF 筛选、第4层大盘环境、轮次归属
///
/// 之所以单列纯函数：反事实重放与整轮扫描必须共用**同一份**筛选/评分逻辑，
/// 否则「如果当初放宽量比会怎样」的答案会因为两份实现的细微差异而失真。
///
/// ⚠ 字符串口径（score_details / penalty_details 要与 Python f-string 逐字符一致）：
///   · 来自 deep_info 的数字都是**已 round 过的 double** → 用 `pyStr`（≡ Python str(float)，
///     `1.75→"1.75"`、`2.0→"2.0"`、`-0.0→"-0.0"`）
///   · 来自**参数**的数字必须用 `PyJSON.numStr`：JSON 里的 3 与 3.0 在 Python 分别是
///     int/float，f-string 输出 "3" / "3.0" 不同
public enum Screener {

    // MARK: - Python 语义的小工具

    /// ≡ Python `str(x)`（x 为 float）：最短往返表示，整数值保留 ".0"
    private static func pyStr(_ v: Double) -> String { String(describing: v) }

    /// 从 [String: Any]（JSONSerialization 产物）取数；bool 不算数
    private static func numPy(_ v: Any?) -> Double? {
        guard let v = v else { return nil }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.doubleValue
        }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    /// ≡ Python `int(x)`：向零截断
    private static func intPy(_ v: Any?) -> Int? {
        guard let v = v else { return nil }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            // 复用 Num.intOrNil：它按 objCType 区分整/浮并做越界守卫
            // （原先的 `n.intValue` 是 **Int32**，大整数静默回绕）。
            return Num.intOrNil(n)
        }
        if let i = v as? Int { return i }
        // ⚠ 守卫走 `Num.intSafe`：只查 `isFinite` 不够 —— `Int(1e30)` 有限但越界，
        //   是**不可 catch 的 trap**（2026-10-16 审查 B2）。非有限/越界一律折 nil（= 不存在）。
        if let d = v as? Double { return Num.intSafe(d) }
        return nil
    }

    private static func boolPy(_ v: Any?) -> Bool? {
        guard let v = v else { return nil }
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }

    private static func intOf(_ v: Any) -> Int {
        // 统一走 Num：`n.intValue` 是 Int32（大整数回绕），`Int(1e30)` 是 trap。
        Num.intOrNil(v) ?? 0
    }

    /// `intOf` 的浮点版（加项可能是 float —— 见 `ScoreAcc` 说明）
    private static func numOf(_ v: Any) -> Double {
        if let n = v as? NSNumber {
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? 1 : 0) : n.doubleValue
        }
        if let i = v as? Int { return Double(i) }
        if let d = v as? Double { return d }
        return 0
    }

    // ============================================================
    // 评分表查值（让「改表生效」）
    // ============================================================

    private static let numRegex = try! NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)")
    /// 前缀顺序必须与 Python `_OP_MAP` 的 dict 顺序一致：le/lt/ge/gt
    private static let opMap: [(String, String)] = [("le", "<="), ("lt", "<"), ("ge", ">="), ("gt", ">")]

    /// 从评分表键名解析 (比较符, 阈值)。支持 le8 / lt2 / gt15 / le_neg5 / gt_neg5。
    ///
    /// 评分表把**阈值编码在键名里**（如 cum_5d 的 le8/le12/le15/gt15），
    /// 按键名解析后，表里任何项都真正生效（写死阈值会导致"界面能改、引擎不读"）。
    public static func keyThreshold(_ key: String) -> (op: String, threshold: Double)? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        for (prefix, op) in opMap where k.hasPrefix(prefix) {
            let rest = String(k.dropFirst(prefix.count))
            let neg = rest.hasPrefix("_neg")
            let ns = rest as NSString
            guard let m = numRegex.firstMatch(in: rest, range: NSRange(location: 0, length: ns.length))
            else { return nil }
            let s = ns.substring(with: m.range(at: 1))
            guard let v = Double(s) else { return nil }
            return (op, neg ? -v : v)
        }
        return nil
    }

    /// `keyThreshold` 的**逆**：把 (比较符, 阈值) 拼回键名。
    ///
    /// 参数中心的结构化编辑器用（用户改阈值 → 键名跟着变）。
    /// 放在紧邻位置是**有意的**：编解码必须同源，分开写迟早漂移。
    ///
    /// 规则（与 `keyThreshold` 严格互逆）：
    /// - `("<=", 1)` → `le1`；`(">", 15)` → `gt15`；`("<", 2)` → `lt2`；`(">=", 1)` → `ge1`
    /// - 负阈值插 `_neg`：`("<=", -5)` → `le_neg5`
    /// - **整数值不写小数点**（`le1` 而不是 `le1.0`）—— 与出厂表的写法一致
    ///
    /// ⚠ 拼出的键名必须能被 `keyThreshold` 解析回来（`ParamTableSpecsTests` 有往返断言）。
    public static func thresholdKey(op: String, threshold: Double) -> String? {
        guard threshold.isFinite else { return nil }
        let prefix: String
        switch op {
        case "<=": prefix = "le"
        case "<":  prefix = "lt"
        case ">=": prefix = "ge"
        case ">":  prefix = "gt"
        default:   return nil
        }
        let v = abs(threshold)
        let num = v == v.rounded() ? String(Int(v)) : String(v)
        return prefix + (threshold < 0 ? "_neg" : "") + num
    }

    /// 内部原始命中：分数保留原值（Any），以便 score_details 用 numStr 还原 int/float 形态
    private static func lookupTableHitRaw(_ table: [String: Any], _ value: Double?)
        -> (score: Any, key: String)? {
        guard let value = value else { return nil }
        var leBest: (thr: Double, score: Any, key: String)?
        var gtBest: (thr: Double, score: Any, key: String)?
        // 键序必须**确定**：直接吃 Swift Dictionary 的迭代序，而 Hasher 每进程随机播种 →
        // 同一份参数、同一份数据，**重启后可能算出不同的分数**，违反"同快照同结果"的核心不变量。
        // 仅当同一分支出现相同阈值（如用户手改参数造出 `le10` 与 `lt10`）时才会分叉。
        // 按字典序遍历既确定、也最接近"稳定"语义（Python dict 是恒定插入序）。
        for k in table.keys.sorted() {
            guard let raw = table[k] else { continue }
            guard let parsed = keyThreshold(k) else { continue }
            // bool 类型的 score 要排除（Python isinstance(score, bool) 跳过）
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { continue }
            let op = parsed.op, thr = parsed.threshold
            let hit: Bool
            switch op {
            case "<=": hit = value <= thr
            case "<":  hit = value < thr
            case ">=": hit = value >= thr
            default:   hit = value > thr
            }
            if !hit { continue }
            if op == "<=" || op == "<" {
                // le/lt 分支取阈值**最小**者（更严格）
                if leBest == nil || thr < leBest!.thr { leBest = (thr, n, k) }
            } else {
                // gt/ge 分支取阈值**最大**者（更严格）
                if gtBest == nil || thr > gtBest!.thr { gtBest = (thr, n, k) }
            }
        }
        let pick: (thr: Double, score: Any, key: String)?
        if let le = leBest, let gt = gtBest {
            pick = le.thr >= gt.thr ? le : gt      // 两类同时命中取阈值较大者
        } else if let le = leBest {
            pick = le
        } else {
            pick = gtBest
        }
        guard let p = pick else { return nil }
        return (p.score, p.key)
    }

    /// 在「阈值→分数」表里查 value，返回 (分数, 命中的键名 或 None)。
    ///
    /// 返回键名是为了让 score_details 能说清「哪一条生效」，便于人工对账。
    public static func lookupTableHit(_ table: [String: Any], _ value: Double?, _ def: Int = 0) -> (Int, String?) {
        guard let h = lookupTableHitRaw(table, value) else { return (def, nil) }
        return (intOf(h.score), h.key)
    }

    /// `lookupTableHit` 的取分包装
    public static func lookupTable(_ table: [String: Any], _ value: Double?, _ def: Int = 0) -> Int {
        lookupTableHit(table, value, def).0
    }

    /// 内部便捷：返回原始分数与键名（无命中时 (0, nil)）
    private static func hit(_ table: [String: Any], _ value: Double?) -> (score: Any, key: String?) {
        guard let h = lookupTableHitRaw(table, value) else { return (0, nil) }
        return (h.score, h.key)
    }

    // ============================================================
    // 硬性过滤（第3层）
    // ============================================================

    /// 返回 {code: quote}（含计算字段 change_pct/amplitude）
    public static func hardFilter(_ allQuotes: [String: EngineQuote], _ hf: [String: Any]) -> [String: EngineQuote] {
        let oneWord = numPy(hf["one_word_board_pct"]) ?? 0
        let priceMin = numPy(hf["price_min"]) ?? 0
        let priceMax = numPy(hf["price_max"]) ?? 0
        let ampMax = numPy(hf["amplitude_max"]) ?? 0
        let chgMin = numPy(hf["change_pct_min"]) ?? 0
        var out: [String: EngineQuote] = [:]
        for (code, q) in allQuotes {
            let price = q.price, last = q.preClose
            if price <= 0 || last <= 0 { continue }
            let chg = (price - last) / last * 100
            let amp = (q.high - q.low) / last * 100
            // 一字板：开=收=高=低 且 |涨跌幅|≥9
            if q.open == price && q.high == q.low && abs(chg) >= oneWord { continue }
            if !(priceMin <= price && price <= priceMax) { continue }
            if amp > ampMax { continue }
            if chg <= chgMin { continue }
            var band: [Any] = (hf["change_pct_loose"] as? [Any]) ?? []
            if band.count < 2 {
                // 参数被改成非法长度时不让整轮崩掉（按 ValueError 挂掉选股不可取）
                DataSources.logDataSource("params", "invalid_change_pct_loose",
                    "\(PyJSON.encode(band)) 长度<2，本轮按 [1.0, 6.0] 兜底（请在参数中心修正）")
                band = [1.0, 6.0]
            }
            let lo = numPy(band[0]) ?? 0, hi = numPy(band[1]) ?? 0
            if !(lo <= chg && chg <= hi) { continue }
            var q2 = q
            q2.changePct = PyMath.round(chg, 2)
            q2.amplitude = PyMath.round(amp, 2)
            out[code] = q2
        }
        return out
    }

    // ============================================================
    // 第6层：稳健画像 + 强制避雷（纯函数）
    // ============================================================

    /// 画像区间**扫描前**自检（2026-10-16 审查 B5-7）。
    ///
    /// ⚠ 为什么单独提出来：`passesProfileRisk` 里三处区间读都写成
    ///   `guard arr.count >= 2, let lo = numPy(arr[0]), … else { return false }` ——
    ///   配置坏掉（区间缺失/只有一个元素/元素不是数）时它**拒绝每一只票**，
    ///   而 `ScanRunner` 仍按 `status="ok"` 落库、`after_profile_filter = 0`，
    ///   接着 `Signals.compare` 输出「末轮个股全部被淘汰，建议空仓观望」——
    ///   一个参数错误被翻译成了**交易结论**，界面与库里都看不出区别。
    ///   （同文件 `hardFilter` 的 `change_pct_loose` 是"记日志 + 回落兜底带"，
    ///   画像这三项此前漏了同等处理。）
    /// 返回非 nil = 有区间非法，调用方必须**显式失败**而不是继续跑。
    public static func profileRangeProblem(_ pf: [String: Any]) -> String? {
        func bad(_ key: String) -> String? {
            guard pf.keys.contains(key) else { return nil }        // 键不存在 = 该项不筛
            let arr = (pf[key] as? [Any]) ?? []
            if arr.count < 2 { return "\(key) 需要 [下限, 上限] 两个元素，实际 \(arr.count) 个：\(PyJSON.encode(arr))" }
            guard let lo = numPy(arr[0]), let hi = numPy(arr[1]) else {
                return "\(key) 端点不是数：\(PyJSON.encode(arr))"
            }
            guard lo.isFinite, hi.isFinite else { return "\(key) 端点非有限值：\(PyJSON.encode(arr))" }
            if lo > hi { return "\(key) 下限大于上限（[\(lo), \(hi)]），任何标的都不可能通过" }
            return nil
        }
        for k in ["change_pct", "volume_ratio", "turnover"] {
            if let p = bad(k) { return p }
        }
        return nil
    }

    /// 抽出来的理由：反事实重放必须用**同一份**筛选逻辑，
    /// 否则「如果当初放宽量比会怎样」的答案会因为两份实现的细微差异而失真。
    ///
    /// check_turnover / check_avg_price：历史日K**无法回溯**换手率与均价
    /// （需要流通股本），重放时置 False 跳过这两项并显式说明 —— 不让近似值冒充真值。
    ///
    /// ⚠ 画像区间的**合法性自检**不在这个函数里，见 ``profileRangeProblem(_:)``：
    ///   这里对坏配置只能"拒绝该标的"，必须有人在扫描前先拦住，否则整轮 0 只。
    public static func passesProfileRisk(code: String, q: EngineQuote, pf: [String: Any], rf: [String: Any],
                                  stPattern: NSRegularExpression, bsePrefix: String,
                                  checkTurnover: Bool = true, checkAvgPrice: Bool = true) -> Bool {

        let name = q.name
        if stPattern.firstMatch(in: name, range: NSRange(name.startIndex..<name.endIndex, in: name)) != nil {
            return false
        }
        if code.hasPrefix(bsePrefix) { return false }

        let cpr = (pf["change_pct"] as? [Any]) ?? []
        guard cpr.count >= 2, let c0 = numPy(cpr[0]), let c1 = numPy(cpr[1]) else { return false }
        if !(c0 <= q.changePct && q.changePct <= c1) { return false }

        let vrr = (pf["volume_ratio"] as? [Any]) ?? []
        guard vrr.count >= 2, let v0 = numPy(vrr[0]), let v1 = numPy(vrr[1]) else { return false }
        if !(v0 <= q.volumeRatio && q.volumeRatio <= v1) { return false }

        if checkTurnover {
            let tr = (pf["turnover"] as? [Any]) ?? []
            guard tr.count >= 2, let t0 = numPy(tr[0]), let t1 = numPy(tr[1]) else { return false }
            if !(t0 <= q.turnover && q.turnover <= t1) { return false }
        }
        if q.amplitude > (numPy(pf["amplitude_max"]) ?? 0) { return false }
        if checkAvgPrice && (boolPy(pf["price_ge_avg"]) ?? false)
            && q.avgPrice > 0 && q.price < q.avgPrice { return false }

        // 强制避雷
        if q.volumeRatio > (numPy(rf["volume_ratio_hard_max"]) ?? 0) { return false }
        if checkTurnover && q.turnover > (numPy(rf["turnover_hard_max"]) ?? 0) { return false }
        return true
    }

    // ============================================================
    // ETF 筛选（F8）
    // ============================================================

    /// 入参 quotes 由调用方传入（`Screener` 不自己取数，保持纯函数）。
    ///
    /// ⚠ 入参是**有序**的 (code, quote) 序列而不是字典：排序是**稳定**的，
    /// change_pct 并列时按「行情插入序」决定先后（由 etf.codes 的请求序决定）。
    /// 用无序字典 + Swift 不稳定的 `sorted` 会让 ETF 推荐在并列时换序 ——
    /// 同一份行情落库两次结果不同，不可复现。
    public static func screenEtf(params: [String: Any],
                          quotes: [(code: String, quote: EngineQuote)]) -> [[String: Any]] {
        let etfCfg = (params["etf"] as? [String: Any]) ?? [:]
        let chgMin = numPy(etfCfg["change_pct_min"]) ?? 0
        let vrMin = numPy(etfCfg["volume_ratio_min"]) ?? 0
        let topN = intPy(etfCfg["top_n"]) ?? 0
        let picked = quotes.enumerated()
            .filter { $0.element.quote.price > 0 && $0.element.quote.changePct >= chgMin
                      && $0.element.quote.volumeRatio >= vrMin }
            .sorted { a, b in
                if a.element.quote.changePct != b.element.quote.changePct {
                    return a.element.quote.changePct > b.element.quote.changePct
                }
                return a.offset < b.offset            // 稳定：并列保持插入序
            }
        return picked.prefix(max(0, topN)).map { item in
            let q = item.element.quote
            return ["code": q.code, "name": q.name, "price": q.price,
                    "change_pct": q.changePct, "volume_ratio": q.volumeRatio,
                    "turnover": q.turnover, "amount": q.amount]
        }
    }

    // ============================================================
    // 评分（附录 + 源码逐项对齐）
    // ============================================================

    /// 返回 (score, score_details, penalty_details)；meta 出参写 score_raw / ma_qualified / tier_lock_applied
    ///
    /// 为什么需要 meta：`score` 仍作为档位判定依据（保证选股结果不变），
    /// 但只存这一个数会让"原始分 78 被锁进三档"和"原始分 33 本来就在三档"在库里长得一样，
    /// 三档因此不再表示质量。把原始分与资格标记一并留存，纯信息补全、零行为变化。
    ///
    /// `intraday` 是尾盘分时特征，由调用方算好后传入；本函数只读不算（"不要自己去算分时"）。
    public static func scoreStock(quote: EngineQuote, deep: DeepInfo, intraday: [String: Any]?,
                           patterns: PatternResult? = nil,
                           formScore: Int, marketEnv: [String: Any], params: [String: Any],
                           meta: inout [String: Any]) -> (score: Any, details: [String], penalties: [String]) {
        let sc = (params["scoring"] as? [String: Any]) ?? [:]
        let bonus = (sc["bonus"] as? [String: Any]) ?? [:]
        let pen = (sc["penalty"] as? [String: Any]) ?? [:]
        var score = ScoreAcc()
        var scoreDetails: [String] = []
        var penaltyDetails: [String] = []

        // 1. 均线多头（+20） / 偏离度扣分（非多头时）
        if deep.maPass {
            score.add(bonus["ma_bullish"])
            scoreDetails.append("均线多头 +\(PyJSON.numStr(bonus["ma_bullish"] ?? 0))")
        } else {
            scoreDetails.append("均线不达标 +0")
            let dev = deep.maDeviation
            let (dp, dk) = hit((pen["ma_deviation"] as? [String: Any]) ?? [:], dev)
            score.add(dp)
            if numOf(dp) != 0 {
                penaltyDetails.append("MA偏离\(pyStr(dev))% 命中\(dk ?? "") 扣\(PyJSON.numStr(dp))")
            } else {
                penaltyDetails.append("MA偏离\(pyStr(dev))% 命中\(dk ?? "lt2") 不扣分(即将修复)")
            }
        }

        // 2. 5日均量倍数
        let vm = deep.volMult5d
        let vHigh = (bonus["vol_mult_high"] as? [Any]) ?? []
        let vMid = (bonus["vol_mult_mid"] as? [Any]) ?? []
        if let h0 = numPy(vHigh.first), vm >= h0 {
            score.add(vHigh.count > 1 ? vHigh[1] : nil)
            scoreDetails.append("量能\(pyStr(vm)) +\(PyJSON.numStr(vHigh.count > 1 ? vHigh[1] : 0))")
        } else if let m0 = numPy(vMid.first), vm >= m0 {
            score.add(vMid.count > 1 ? vMid[1] : nil)
            scoreDetails.append("量能\(pyStr(vm)) +\(PyJSON.numStr(vMid.count > 1 ? vMid[1] : 0))")
        } else {
            scoreDetails.append("量能\(pyStr(vm)) +0")
        }
        let vShrink = (pen["vol_shrink"] as? [String: Any]) ?? [:]
        if vm < (numPy(vShrink["threshold"]) ?? 0) {
            score.add(vShrink["score"])
            penaltyDetails.append("5日均量倍数\(pyStr(vm))<\(PyJSON.numStr(vShrink["threshold"] ?? 0))"
                                  + " 量能萎缩 扣\(PyJSON.numStr(vShrink["score"] ?? 0))")
        }

        // 3. 连涨天数（加分表 le1/le2/le3/gt3 —— 全部真实生效）
        let cu = deep.consecUp
        let (bc, bk) = hit((bonus["consec_up"] as? [String: Any]) ?? [:], Double(cu))
        score.add(bc)
        scoreDetails.append("连涨\(cu)天 +\(PyJSON.numStr(bc))" + (bk == nil ? "(无匹配档,按0)" : ""))

        // 4. 5日累计涨幅（加分表 le8/le12/le15/gt15）
        //    cum_5d 为 None = K线不足（次新股/长期停牌）→ 该项**不参与评分**
        //    （0.0 会命中 le8 白拿 +15，绝不能折 0）
        if let c5 = deep.cum5d {
            let (bc5, bk5) = hit((bonus["cum_5d"] as? [String: Any]) ?? [:], c5)
            score.add(bc5)
            scoreDetails.append("5日累计\(pyStr(c5))% +\(PyJSON.numStr(bc5))" + (bk5 == nil ? "(无匹配档,按0)" : ""))
        } else {
            scoreDetails.append("5日累计数据不足 +0(不参与)")
        }

        // 4b. 5日累计过低扣分
        if let c5 = deep.cum5d, let low = pen["cum_5d_low"] as? [String: Any] {
            if c5 < (numPy(low["threshold"]) ?? 0) {
                score.add(low["score"])
                penaltyDetails.append("5日累计\(pyStr(c5))%<\(PyJSON.numStr(low["threshold"] ?? 0))%"
                                      + " 动能不足 扣\(PyJSON.numStr(low["score"] ?? 0))")
            }
        }

        // 5. 位置（加分表 le15/le25/gt25 与 le_neg5/gt_neg5）
        let dfl = deep.distFromLow
        let (bl, blk) = hit((bonus["dist_low"] as? [String: Any]) ?? [:], dfl)
        score.add(bl)
        scoreDetails.append("距低点\(pyStr(dfl))% +\(PyJSON.numStr(bl))" + (blk == nil ? "(无匹配档,按0)" : ""))

        let dfh = deep.distFromHigh
        let (bh, bhk) = hit((bonus["dist_high"] as? [String: Any]) ?? [:], dfh)
        score.add(bh)
        scoreDetails.append("距高点\(pyStr(dfh))% +\(PyJSON.numStr(bh))" + (bhk == nil ? "(无匹配档,按0)" : ""))

        // 6. K线形态
        if formScore == 3 {
            score.add(bonus["form_full"])
            scoreDetails.append("形态满分 +\(PyJSON.numStr(bonus["form_full"] ?? 0))")
        } else if formScore == 2 {
            score.add(bonus["form_pass"])
            scoreDetails.append("形态及格 +\(PyJSON.numStr(bonus["form_pass"] ?? 0))")
        }

        // 6b. K 线形态组合
        //
        // ⚠ **出厂默认关闭**（`scoring.patterns.enabled`）——
        //   形态维度的方向尚未标定，开着就是凭直觉给分。关闭时这一段**一行都不执行**，
        //   `score` / `score_details` / `penalty_details` 复现旧行为（黄金夹具因此不受影响）。
        //
        // ⚠ 与上面第 6 项（`formScore`）是**两个独立维度**，刻意不合并：
        //   · 第 6 项 = 当日 K 线形状是否**合格**（上影线 / 收盘位置 / 实体比）→ 过滤闸门
        //   · 本项   = 当日 K 线**构成哪个已知形态**（锤头 / 早晨之星 / 穿头破脚 …）→ 组合判据
        //   合并会改第 6 项口径 → 黄金夹具全红。
        let patCfg = PatternScoreConfig.from(params)
        if patCfg.enabled, let p = patterns {
            let (delta, names) = patCfg.score(p)
            if delta != 0 {
                score.add(delta)
                let label = "K线形态 " + names.joined(separator: "/")
                if delta > 0 {
                    scoreDetails.append("\(label) +\(delta)")
                } else {
                    penaltyDetails.append("\(label) \(delta)")
                }
            }
        }

        // 7. 大盘环境
        let shOk = boolPy(marketEnv["sh_ok"]) ?? false
        let ratioOk = boolPy(marketEnv["ratio_ok"]) ?? false
        if shOk && ratioOk {
            score.add(bonus["market_ok_ok"])
            scoreDetails.append("大盘OK +\(PyJSON.numStr(bonus["market_ok_ok"] ?? 0))")
        } else if shOk {
            score.add(bonus["market_ok_only"])
            scoreDetails.append("大盘一般 +\(PyJSON.numStr(bonus["market_ok_only"] ?? 0))")
        }

        // 8. MA20上翘（额外）
        if deep.ma20SlopeUp {
            score.add(bonus["ma20_slope_up"])
            scoreDetails.append("MA20上翘 +\(PyJSON.numStr(bonus["ma20_slope_up"] ?? 0))")
        }

        // 9. 尾盘分时结构（目标「次日高开」的最直接证据，原引擎扫描阶段完全没用 5 分钟线）
        let ic = intraday ?? [:]
        let icCfg = (sc["intraday"] as? [String: Any]) ?? [:]
        if !ic.isEmpty && (boolPy(icCfg["enabled"]) ?? true) {
            if let tvr = numPy(ic["tail_vol_ratio"]),
               tvr >= (numPy(icCfg["tail_vol_ratio_min"]) ?? 1.5) {
                let add = intPy(icCfg["tail_vol_ratio_score"]) ?? 12
                // 加分为 0 的维度只保留特征、不写明细（避免出现"尾盘放量1.8倍 +0"这种噪声）；
                // 标定结论本来就是"尾盘放量方向相反，默认不加分"
                if add != 0 {
                    score.add(add)
                    scoreDetails.append("尾盘放量\(pyStr(tvr))倍 +\(add)")
                }
            }
            if let tg = numPy(ic["tail_gain_pct"]),
               tg >= (numPy(icCfg["tail_gain_min"]) ?? 0.3) {
                let add = intPy(icCfg["tail_gain_score"]) ?? 8
                score.add(add)
                scoreDetails.append("尾盘拉升\(pyStr(tg))% +\(add)")
            }
            if let cp = numPy(ic["close_position"]),
               cp >= (numPy(icCfg["close_position_min"]) ?? 0.9) {
                let add = intPy(icCfg["close_position_score"]) ?? 8
                score.add(add)
                scoreDetails.append("收盘强度\(pyStr(cp)) +\(add)")
            }
            // 尾盘创日内新高（标定结论：创新高组平均跳空 -0.048% vs 未创新高 -0.46%）
            let nhighScore = intPy(icCfg["tail_new_high_score"]) ?? 0
            if (boolPy(ic["tail_new_high"]) ?? false) && nhighScore != 0 {
                score.add(nhighScore)
                scoreDetails.append("尾盘创日内新高 +\(nhighScore)")
            }
            if let ha = numPy(ic["high_age_ratio"]),
               ha >= (numPy(icCfg["high_age_max"]) ?? 0.75) {
                let penScore = intPy(icCfg["stale_high_penalty"]) ?? -8
                if penScore != 0 {
                    score.add(penScore)
                    penaltyDetails.append("高点陈旧(高点\((ic["day_high_time"] as? String) ?? "")"
                                          + " 陈旧度\(pyStr(ha))) 扣\(penScore)")
                }
            }
        }

        // === 扣分项 ===
        // 前日涨幅（扣分表 gt7/gt5 —— 阈值编码在键名里，改表即生效）
        let p1 = deep.prev1d
        let (pp, pk) = hit((pen["prev_1d"] as? [String: Any]) ?? [:], p1)
        if numOf(pp) != 0 {
            score.add(pp)
            let keyBase = pk ?? "gt"
            let keyPart = String(keyBase.dropFirst(min(2, keyBase.count)))
            penaltyDetails.append("前日涨\(pyStr(p1))%>\(keyPart)% 扣\(PyJSON.numStr(pp))(昨天已大涨)")
        }

        // 放量滞涨 / 放量长上影（文本里的阈值一律取自参数，避免改了参数但提示还写死旧值）
        let vr = quote.volumeRatio
        if let stCfg = pen["stagnation"] as? [String: Any] {
            let vrMin = numPy(stCfg["vol_ratio_min"]) ?? 0
            if vr >= vrMin && deep.gainRatio < (numPy(stCfg["gain_ratio"]) ?? 0) {
                score.add(stCfg["score"])
                penaltyDetails.append("放量滞涨(量比\(pyStr(vr))≥\(PyJSON.numStr(stCfg["vol_ratio_min"] ?? 0))"
                                      + " 保留度\(pyStr(deep.gainRatio))<\(PyJSON.numStr(stCfg["gain_ratio"] ?? 0)))"
                                      + " 扣\(PyJSON.numStr(stCfg["score"] ?? 0))")
            }
        }
        if let lsCfg = pen["long_shadow"] as? [String: Any] {
            let vrMin = numPy(lsCfg["vol_ratio_min"]) ?? 0
            if vr >= vrMin && deep.shadowBodyRatio > (numPy(lsCfg["shadow_body"]) ?? 0) {
                score.add(lsCfg["score"])
                penaltyDetails.append("放量长上影(量比\(pyStr(vr))≥\(PyJSON.numStr(lsCfg["vol_ratio_min"] ?? 0))"
                                      + " 影/体=\(pyStr(deep.shadowBodyRatio))>\(PyJSON.numStr(lsCfg["shadow_body"] ?? 0)))"
                                      + " 扣\(PyJSON.numStr(lsCfg["score"] ?? 0))")
            }
        }

        // 均线不达标降档锁定（判定口径保持不变；额外留存原始分与资格，见 meta 说明）
        let lock = (sc["tier_lock"] as? [String: Any]) ?? [:]
        let scoreRaw = score
        var locked = false
        let lockMax = numOf(lock["max_score"] ?? NSNull())
        if (boolPy(lock["enabled"]) ?? false) && !deep.maPass && score.doubleValue > lockMax {
            locked = true
            // ⚠ 文案里的两个数都用 `PyJSON.numStr` 取**原值**（保住 int/float 两态）：
            //   Python 的 f"{score}" 对 int 是 "68"、对 float 是 "68.3" —— 与明细文案逐字对齐
            penaltyDetails.append("均线未多头排列 原分\(PyJSON.numStr(scoreRaw.value))→锁定"
                                  + "\(PyJSON.numStr(lock["max_score"] ?? 0))分"
                                  + (lockMax >= 50 ? "(二档上限)" : "(三档(排除))"))
            score.set(lock["max_score"])
        }

        // 「指标钝化保护」：补两个**纯诊断**字段，判定零变化。
        // 复用上面的 `locked`，不重算、不读新数据。
        let trendState = classifyTrendState(deep, price: quote.price)
        meta["trend_state"] = trendState
        meta["lock_confidence"] = classifyLockConfidence(trendState: trendState, locked: locked)

        meta["score_raw"] = scoreRaw.value
        meta["ma_qualified"] = deep.maPass
        meta["tier_lock_applied"] = locked
        return (score.value, scoreDetails, penaltyDetails)
    }

    // MARK: - 趋势状态 / 锁档信心

    /// 趋势状态（5 态）—— **纯诊断字段，不参与任何判定**。
    ///
    /// 为什么需要（「指标钝化保护」）：`tier_lock` 是**二值**的 —— 只要
    /// `ma_pass` 为假就把分数压到 `lock.max_score`，于是「差一点不达标（上升途中的
    /// 回踩）」与「明确走坏的空头」在库里长得一模一样，无法复核是哪一种。
    ///
    /// ⚠ 与 `score_raw`/`ma_qualified` **同一原则**：
    /// **只增加信息、不改变判定** —— `score` 与档位划分完全不受本函数影响。
    ///
    /// 判据只用 `DeepInfo` 已有字段（不新增 K 线请求、不引入新指标）：
    /// · `INSUFFICIENT`   —— `cum_5d == nil`（K 线不足 6 根，均线/趋势都不可靠）
    /// · `BULL_ALIGNED`   —— ma_pass 且 MA20 上翘（完整多头排列）
    /// · `BULL_WEAKENING` —— ma_pass 但 MA20 走平/下弯（多头在走弱）
    /// · `MA_PULLBACK`    —— 未多头，但 MA20 上翘且现价仍在 MA20 之上（上升途中回踩）
    /// · `BEAR_TREND`     —— 其余（明确走坏）
    public static func classifyTrendState(_ deep: DeepInfo, price: Double) -> String {
        // `cum_5d == nil` 是引擎里唯一显式判空的指标（K 线不足 6 根）→ 数据不足的可靠标记
        if deep.cum5d == nil { return "INSUFFICIENT" }
        if deep.maPass {
            return deep.ma20SlopeUp ? "BULL_ALIGNED" : "BULL_WEAKENING"
        }
        if deep.ma20SlopeUp, let m20 = deep.ma20, price >= m20 {
            return "MA_PULLBACK"
        }
        return "BEAR_TREND"
    }

    /// 锁档信心 —— 只在**真的被锁**时才有意义：回答「这次锁是钝化误伤，还是趋势确实走坏」。
    ///
    /// · `high`         —— `BEAR_TREND`：明确走坏，锁得对
    /// · `likely_blunt` —— `MA_PULLBACK`：**疑似钝化误伤**（上升途中回踩被一刀切）
    /// · `unknown`      —— `INSUFFICIENT`：数据不足，不猜
    /// · `none`         —— 未被锁（该字段不适用）
    ///
    /// ⚠ 本函数只产标签，**不改变 `max_score`、不影响档位** —— 要改判定必须另提。
    public static func classifyLockConfidence(trendState: String, locked: Bool) -> String {
        guard locked else { return "none" }
        switch trendState {
        case "MA_PULLBACK": return "likely_blunt"
        case "BEAR_TREND": return "high"
        default: return "unknown"
        }
    }

    /// 评分累加器（≡ Python 的动态数值语义）
    ///
    /// Python 的 `score` 是 **int**（全部加项为 int）或 **float**（任一加项为 float）。
    /// 这不是单纯的数值差异：明细文案 `f"{score}"` 是 "68" 还是 "68.0"、落库 JSON 是 68 还是
    /// 68.0，都由它决定。调优候选会把 `scoring.bonus.vol_mult_high[1]` 扰动成小数
    /// （`_mutate` 的 num_pair 分支走 `round(...,2)`），此刻分数就变成 float。
    ///
    /// 故这里按 Python 规则保留两态：加项是浮点 JSON 数（NSNumber objCType 'd'/'f'）→ 结果浮点。
    public struct ScoreAcc {
        private(set) var doubleValue: Double = 0
        private(set) var isFloat = false

        public mutating func add(_ v: Any?) {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return }
            let t = String(cString: n.objCType)
            if t == "d" || t == "f" { isFloat = true }
            doubleValue += n.doubleValue
        }

        /// 覆写（tier_lock 锁分）：类型同样按加项判定
        public mutating func set(_ v: Any?) {
            doubleValue = 0
            isFloat = false
            add(v)
        }

        /// Python 侧的真实类型：无浮点加项且值为整数 → Int
        public var value: Any {
            (!isFloat && doubleValue == doubleValue.rounded()) ? Int(doubleValue) : doubleValue
        }
    }

    // ============================================================
    // 大盘环境（STAGE 0 + STAGE 1 汇总）
    // ============================================================

    public static func buildMarketEnv(params: [String: Any], allQuotes: [String: EngineQuote]?) -> [String: Any] {
        var env: [String: Any] = [:]
        let idx = DataSources.fetchIndexQuote()
        let shPrice = numPy(idx["price"]) ?? 0
        let shPreClose = numPy(idx["pre_close"]) ?? 0
        let shHigh = numPy(idx["high"]) ?? 0
        let shLow = numPy(idx["low"]) ?? 0
        let shChangePct = numPy(idx["change_pct"]) ?? 0
        env["sh_price"] = shPrice
        env["sh_change_pct"] = shChangePct
        env["sh_amplitude"] = shPreClose > 0
            ? PyMath.round((shHigh - shLow) / shPreClose * 100, 2) : 0.0

        // 涨跌家数（来自全量扫描）
        //
        // 判据**严格按涨跌额符号**（`MarketBreadth` 的类型文档里有依据：
        // 百分比死区会把 `12.20 → 12.21`（+0.08%）这类明明在涨的票算成平盘）。
        // ⚠ 这 4 个键的口径是**有意定死的**，改动会连带 `ratio`（评分输入）——见 `MarketBreadth`。
        let breadth = MarketBreadth.counts(allQuotes ?? [:])
        let up = breadth.up, down = breadth.down, flat = breadth.flat
        env["up_count"] = up
        env["down_count"] = down
        env["flat_count"] = flat
        // 除零分支是 **int 999，不是 999.0** —— 落库 JSON 形态要保住（999 写成 999.0 差一个 ".0"）。
        // 比较用数值本身（形态无关），落库用固定形态。
        let ratioValue = MarketBreadth.ratio(breadth)
        if down > 0 {
            env["ratio"] = PyMath.round(ratioValue, 2)
        } else {
            env["ratio"] = 999          // int：Python `round(999, 2)` 仍是 int
        }

        let excl = (params["exclusion"] as? [String: Any]) ?? [:]
        // ⚠ 无样本时 `ratio_ok` 必须是 false（2026-10-16 审查 B5-15）：
        //   `down == 0` 的除零分支给的是 `999`（落库形态已钉死，不能改），
        //   于是"**全市场一只都没取到价**"（开盘前快照 / 源退化成一堆 0）会算出
        //   史上最大的看涨比值 ⇒ `ratio_ok = true` ⇒ 每只候选都拿市场加分。
        //   `ratio` 的存储值保持不变（改它会连带 `MarketBreadth` 的既有口径），
        //   只把"没有样本"与"样本显示极度强势"在**判定**上分开。
        let breadthSampled = (up + down + flat) > 0
        env["ratio_ok"] = breadthSampled && ratioValue >= (numPy(excl["market_ratio_threshold"]) ?? 0)
        if !breadthSampled {
            DataSources.logDataSource("market", "breadth_empty",
                                      "涨跌家数全为 0（样本 \(up + down + flat)）⇒ ratio_ok 记 false，"
                                      + "不给市场加分：涨跌宽度无从测量，不能当成极度强势")
        }


        // 连跌检测（近 N 日上证日K；N = 参数 exclusion.market_decline_lookback）
        let lbRaw = intPy(excl["market_decline_lookback"])
        let lookback = (lbRaw == nil || lbRaw == 0) ? 3 : lbRaw!     // ≡ Python `.get(k,3) or 3`
        let kline = DataSources.fetchIndexDailyKline(symbol: "sh000001",
                                                     datalen: PredictRules.indexKlineDatalen)
        let pr = (params["predict_rules"] as? [String: Any]) ?? [:]
        let rdRaw = intPy(pr["red_decline_days"])
        let declineDays = (rdRaw == nil || rdRaw == 0) ? 2 : rdRaw!  // 红灯阈值与预判页同源
        let m = EngineIndicators.marketConsecutiveDecline(
            kline, todayChangePct: shChangePct, lookback: lookback,
            today: DataSources.runDate(), declineDays: declineDays)
        for (k, v) in m.json { env[k] = v }        // ≡ Python env.update(m)

        env["sh_ok"] = shChangePct > (numPy(excl["market_change_threshold"]) ?? 0)
            && !(boolPy(env["sh_consecutive_decline"]) ?? false)

        // 市场状态机：**纯附加** —— 多写 `regime` / `ma_period_used` 两个键，
        // 不改上面任何一个判定（`light` 在预判侧、这里连算都不算）。
        // 放在扫描侧是为了让 `scan_rounds.market_env_json` 带上它 ——
        // 自选判定 / 调优 / 看板都从这份库里读（门槛浮动要用）。
        let regime = PredictRules.classifyRegime(
            kline: kline, today: DataSources.runDate(),
            consecutiveDecline: m.shConsecutiveDecline, declineCount: m.sh3dDeclineCount,
            rules: pr)
        for (k, v) in regime.json { env[k] = v }
        return env
    }

    // ============================================================
    // 轮次归属
    // ============================================================

    /// 轮次归属：相邻两轮的边界由调度时间决定（`RoundPlan.count - 1` 个）。
    ///
    /// - Parameter bounds: 边界（**当日分钟数**，升序 `轮数-1` 个）。`nil` / 个数不对 → 默认边界。
    ///
    /// ⚠ **边界走显式参数，不走环境变量**：环境变量是**进程级可变状态** ——
    ///   从不清理、后台线程写、并发路径（历史回放 + 实时扫描同时跑）会**读到对方的边界**
    ///   （而边界决定"这轮算第几轮"，进而影响三轮持续信号）。
    ///   由调用方一路显式传：`runRound(boundaries:)` → `runScan(boundaries:)` → 这里。
    public static func resolveSlot(now: Date? = nil, bounds: [Int]? = nil) -> (slot: Int, label: String) {
        let now = now ?? Date()
        // ⚠ 用 `ChinaTime` 而不是 `Calendar.current`：后者跟随**系统时区** ——
        //   机器不在 Asia/Shanghai 时轮次归属会算错，落库的 `slot` 与实际时段错位
        //   （而它决定"这轮算第几轮"，进而影响三轮持续信号）。
        let t = ChinaTime.minutesOfDay(now)
        // 个数与默认值都派生自 `RoundPlan`（原先这里是第四处手写 `14:15/14:40`）。
        let b = (bounds?.count == RoundPlan.count - 1) ? bounds! : RoundPlan.defaultBounds
        // 槽位号与标签一律出自 `RoundPlan`（审查 B8-1）：加一轮时最容易漏 ——
        // 漏了会得到一个**没有标签的槽位**（落库 `slot_label` 空串）而不报任何错。
        for (i, edge) in b.enumerated() where t < edge {
            return RoundPlan.resolved(atOrdinal: i) ?? (i + 1, "")
        }
        return RoundPlan.resolved(atOrdinal: b.count) ?? (b.count + 1, "")
    }

    /// `"14:15,14:40"` → `[855, 880]`（当日分钟数）；格式不对 / 个数不是 `轮数-1` → `nil`（调用方回落默认）。
    ///
    /// ⚠ 从 `resolveSlot` 里**抽出来的纯函数**：解析混在取数分支里就不可单测；
    ///   现在它只做字符串 → 分钟数，可被 `swift test` 覆盖。
    public static func parseBounds(_ s: String?) -> [Int]? {
        let env = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !env.isEmpty else { return nil }
        let parts = env.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count == RoundPlan.count - 1 else { return nil }
        var parsed: [Int] = []
        for p in parts {
            let hm = p.split(separator: ":")
            guard hm.count >= 2, let h = Int(hm[0]), let mm = Int(hm[1]) else { return nil }
            parsed.append(h * 60 + mm)
        }
        return parsed
    }
}