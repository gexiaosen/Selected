import Foundation

/// 信号类型 —— rawValue = **线上值**（`signal_type` 的落库键，英文）。
///
/// rawValue 等于线上值 ⇒ `.rawValue` 就是序列化、`init?(rawValue:)` 就是解析器，
/// 不存在"代码值 ↔ 线上值"的映射可以漂移。中文只出现在**展示名**
/// （`displayName`，落 `signal_type_name`）。
///
/// ⚠ 分支一律走枚举、由编译器穷尽检查（不用裸字符串比较）——
///   新增档位时每个 switch 都会报错，而不是静默落进灰/兜底。
public enum SignalType: String, Sendable, CaseIterable {
    case strongest, consensus, pulse, unverified

    /// 展示名（`signal_type_name` 落此值）
    public var displayName: String {
        switch self {
        case .strongest: return "最强信号"
        case .consensus: return "持续信号"
        case .pulse: return "脉冲信号"
        case .unverified: return "未验证（轮次不足）"
        }
    }

    /// **强度序**：最强 → 持续 → 脉冲 → 未验证（越小越强）。
    ///
    /// ⚠ 为什么要有它而不是直接用 `allCases` 的下标：`allCases` 的顺序是**声明顺序**，
    ///   它今天是巧合对了；把"排序口径"写成显式的 rank，改枚举顺序时不会静默改行为。
    /// ⚠ `unverified`（轮次不足）排**最后**：它不是"弱信号"，是**没结论** ——
    ///   混在脉冲里会让"重点股票"列表里冒出一批没验证的。
    public var rank: Int {
        switch self {
        case .strongest: return 0
        case .consensus: return 1
        case .pulse: return 2
        case .unverified: return 3
        }
    }

    /// 「已确认持续」的两种类型
    public static let verified: Set<SignalType> = [.strongest, .consensus]

    /// 该值是否「已确认持续」
    public var isVerified: Bool { Self.verified.contains(self) }

    /// 从 JSON/字典落库值解析（缺失 / 非字符串 / 空串 / 未识别 → nil）。
    /// 空串**不折成任何一个 case**：各调用点原本就有各自的空串语义
    /// （多数落 "非持续"、`PhasePredict` 计为"不计入任何一组"），
    /// 折成 case 会静默改口径，所以一律让调用点显式处理 nil。
    public init?(json: Any?) {
        guard let s = json as? String, let v = SignalType(rawValue: s) else { return nil }
        self = v
    }
}

/// Selected 引擎 — 三轮对比与信号分类（交并集）。
///
/// **轮次不足保护**：可用轮次少于应有轮次时一律判「未验证」，绝不输出
/// strongest/consensus —— 少一轮就无法证明"持续"。
///
/// **预算截断保护**：被耗时预算跳过、**未曾评分**的标的，在该轮"缺席"不等于
/// "没入选"；把它当完整轮次参与交集，等于用"引擎没来得及看"否定持续性
/// （方向相反的误杀）→ 一律 unverified 并显式告警。
public enum SignalClassifier {

    /// 判定「持续」所必需的轮次（14:00/14:30/14:50）
    /// 该有几轮 —— 唯一来源是 ``RoundPlan/slots``，这里只留一个兼容别名
    /// （`CompareStore` / 报表与测试都按这个名字读）。
    public static let expectedSlots = RoundPlan.slots


    // MARK: - 输入辅助

    /// 从 rounds 字典里取某一轮的 pick 列表
    private static func picks(_ round: [String: Any], _ key: String) -> [[String: Any]] {
        (round[key] as? [[String: Any]]) ?? []
    }

    private static func codeOf(_ p: [String: Any]) -> String { (p["code"] as? String) ?? "" }

    private static func setOfCodes(_ ps: [[String: Any]]) -> Set<String> {
        Set(ps.map(codeOf))
    }

    /// 集合交集
    private static func intersect(_ sets: [Set<String>]) -> Set<String> {
        guard var acc = sets.first else { return [] }
        for s in sets.dropFirst() { acc.formIntersection(s) }
        return acc
    }

    /// 集合并集
    private static func unionAll(_ sets: [Set<String>]) -> Set<String> {
        var acc = Set<String>()
        for s in sets { acc.formUnion(s) }
        return acc
    }

    /// 数值格式化：**保持浮点表示**（110.0 → "110.0"）。
    ///
    /// ⚠ 整数值**不能**省小数点：score 来自 picks.score REAL 列，运行时是 float，
    /// 建议文案就是"末轮110.0分"而不是"末轮110分"。
    /// Swift 的 `String(Double)` 与 Python 的 `str(float)` 同为最短往返表示，可直接对应。
    public static func fmtNum(_ v: Double) -> String {
        String(v)
    }

    /// nil / Optional.none → NSNull()。
    ///
    /// ⚠ 必须显式转换：`dict[key] = nn(nil)` 在 Swift 里会**移除该键**，
    /// 而语义要求缺失时**保留键、值为 null**。直接写 `as Any` 会让 JSON 里少一个键，
    /// 且 Optional 未展开时 JSONSerialization 会直接抛错。
    public static func nn(_ v: Any?) -> Any {
        guard let v = v else { return NSNull() }
        let m = Mirror(reflecting: v)
        if m.displayStyle == .optional {
            guard let child = m.children.first else { return NSNull() }
            return nn(child.value)
        }
        return v
    }

    // MARK: - 信号分类

    /// 返回 (order, info)：order 是插入顺序（Swift 字典无序，而报告里的列表
    /// 顺序依赖它 —— 例如 always_tier1 / tier1_matrix 的行序必须确定）
    public static func classifySignals(_ rounds: [Int: [String: Any]])
        -> (order: [String], info: [String: [String: Any]]) {
        var order: [String] = []
        var info: [String: [String: Any]] = [:]
        if rounds.isEmpty { return (order, info) }

        let slots = rounds.keys.sorted()
        let verified = slots.count >= expectedSlots.count

        var slotTier1: [Int: Set<String>] = [:]
        var slotAll: [Int: Set<String>] = [:]
        var budgetSkipped: [Int: Set<String>] = [:]
        for s in slots {
            let r = rounds[s] ?? [:]
            let t1 = picks(r, "tier1"), t2 = picks(r, "tier2")
            slotTier1[s] = setOfCodes(t1)
            slotAll[s] = setOfCodes(t1 + t2)
            budgetSkipped[s] = Set((r["budget_skipped_codes"] as? [String]) ?? [])
        }

        var budgetAffected = Set<String>()
        for s in slots { budgetAffected.formUnion(budgetSkipped[s] ?? []) }

        let consensusT1 = intersect(slots.compactMap { slotTier1[$0] })
        let consensusAll = intersect(slots.compactMap { slotAll[$0] })

        // 名称与评分轨迹（插入顺序：slots → tier1 + tier2）
        for s in slots {
            let r = rounds[s] ?? [:]
            let t1 = picks(r, "tier1"), t2 = picks(r, "tier2")
            for p in t1 + t2 {
                let c = codeOf(p)
                if info[c] == nil {
                    info[c] = ["name": (p["name"] as? String) ?? "",
                               "scores": [Int: Double](), "tiers": [Int: Int]()]
                    order.append(c)
                }
                var scores = (info[c]?["scores"] as? [Int: Double]) ?? [:]
                scores[s] = numOf(p["score"])
                info[c]?["scores"] = scores
                var tiers = (info[c]?["tiers"] as? [Int: Int]) ?? [:]
                // 同 slot 内 tier2 出现会覆盖 tier1 的记录
                tiers[s] = t1.contains(where: { codeOf($0) == c }) ? 1 : 2
                info[c]?["tiers"] = tiers
            }
        }

        for c in order {
            let sig: SignalType
            if !verified {
                sig = .unverified
            } else if budgetAffected.contains(c) {
                sig = .unverified
            } else if consensusT1.contains(c) {
                sig = .strongest
            } else if consensusAll.contains(c) {
                sig = .consensus
            } else {
                sig = .pulse
            }
            let scores = (info[c]?["scores"] as? [Int: Double]) ?? [:]
            info[c]?["signal_type"] = sig.rawValue
            info[c]?["signal_type_name"] = sig.displayName
            info[c]?["signal_verified"] = verified && !budgetAffected.contains(c)
            info[c]?["budget_limited"] = budgetAffected.contains(c)
            info[c]?["slots_available"] = slots
            info[c]?["slots_expected"] = expectedSlots
            info[c]?["trend"] = trendLabel(scores, slots)
        }
        return (order, info)
    }

    /// 趋势标签（评分递增/递减/波动/新增/消失/部分出现）
    public static func trendLabel(_ scores: [Int: Double], _ slots: [Int]) -> String {
        let appeared = scores.keys.sorted()
        if appeared.count == slots.count {
            let seq = slots.compactMap { scores[$0] }
            var inc = true, dec = true
            for i in 0..<(seq.count - 1) {
                if seq[i] > seq[i + 1] { inc = false }
                if seq[i] < seq[i + 1] { dec = false }
            }
            // ⚠ 必须先判"全程无变化"（2026-10-16 审查 B5-15）：
            //   `inc`/`dec` 只在**严格**大/小时才被清零，三轮评分完全相等时两者都还成立，
            //   于是原先第一个分支把"75/75/75"报成「评分递增」——
            //   而"递增"是三轮对比里表示"走强"的词，把它贴在一条水平线上，
            //   用户据此判断"这只票一轮比一轮强"就完全是反的。
            if inc && dec { return "评分持平" }
            if inc { return "评分递增" }
            if dec { return "评分递减" }
            return "波动"
        }

        if appeared.count == 1 {
            return appeared[0] == (slots.max() ?? 0) ? "新增(尾盘才入档)" : "消失(后续被淘汰)"
        }
        return "部分轮次出现"
    }

    private static func numOf(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return 0
    }

    /// 实现收敛到 `Num.intOrNil`（与 `CompareStore.intOf` / `ParamStore.intOf` 同一语义）。
    private static func intOf(_ v: Any?) -> Int? { Num.intOrNil(v) }

    // MARK: - 三轮汇总对比

    /// 三轮汇总对比 + 操作建议（不含入库；写库由调用方负责）
    public static func compare(_ rounds: [Int: [String: Any]], date: String) -> [String: Any] {
        let slots = rounds.keys.sorted()
        var report: [String: Any] = [
            "date": date,
            // generated_at 键不可缺（compare_reports.json 的读取方按键取值）；
            // 取值用 ChinaTime 而非本机时间：项目"日期唯一出口"是北京时间。
            "generated_at": ChinaTime.stamp(),
            "available_slots": slots,
            "market_env_table": [[String: Any]](),
            "funnel_table": [[String: Any]](),
            "tier1_matrix": [[String: Any]](),
            "tier2_matrix": [[String: Any]](),
            "tier_changes": [[String: Any]](),
            "excluded_table": [[String: Any]](),
            "etf_matrix": [[String: Any]](),
            "signals": [String: Any](),
            "stability": [String: Any](),
            "suggestions": [[String: Any]](),
            "warnings": [String](),
        ]
        if rounds.isEmpty {
            report["status"] = "no_data"
            return report
        }

        // 1. 大盘环境对比
        var envTable: [[String: Any]] = []
        for s in slots {
            let r = rounds[s] ?? [:]
            let me = (r["market_env"] as? [String: Any]) ?? [:]
            var row: [String: Any] = ["slot": s, "label": nn(r["slot_label"])]
            for k in ["sh_price", "sh_change_pct", "up_count", "down_count", "flat_count",
                      "sh_ok", "ratio_ok", "sh_3d_trend", "sh_consecutive_decline"] {
                row[k] = nn(me[k])
            }
            envTable.append(row)
        }
        report["market_env_table"] = envTable

        // 2. 漏斗对比
        var funnel: [[String: Any]] = []
        for s in slots {
            var row: [String: Any] = ["slot": s]
            for (k, v) in ((rounds[s]?["stats"] as? [String: Any]) ?? [:]) { row[k] = v }
            funnel.append(row)
        }
        report["funnel_table"] = funnel

        // 3. 信号分类
        let (order, info) = classifySignals(rounds)
        var signalsJSON: [String: Any] = [:]
        for c in order { signalsJSON[c] = jsonSafe(info[c] ?? [:]) }
        report["signals"] = signalsJSON

        var warnings: [String] = []
        let budgetSlots = slots.filter { (rounds[$0]?["budget_limited"] as? Bool) ?? false }
        if !budgetSlots.isEmpty {
            let affected = order.filter { (info[$0]?["budget_limited"] as? Bool) ?? false }
                .map { (info[$0]?["name"] as? String) ?? "" }
            report["budget_limited_slots"] = budgetSlots
            let slotText = budgetSlots.map(String.init).joined(separator: "、")
            var text = "第 \(slotText) 轮触发耗时预算，有候选未完成评分；"
                + "受影响的 \(affected.count) 只已判为「未验证」（不可据此确认持续性）"
            if !affected.isEmpty {
                text += "：" + affected.prefix(8).joined(separator: "、")
            }
            warnings.append(text)
        }

        var tier1Matrix: [[String: Any]] = []
        var tier2Matrix: [[String: Any]] = []
        for c in order {
            guard let meta = info[c] else { continue }
            let scores = (meta["scores"] as? [Int: Double]) ?? [:]
            let tiers = (meta["tiers"] as? [Int: Int]) ?? [:]
            var row: [String: Any] = [
                "code": c, "name": nn(meta["name"]),
                "signal_type": nn(meta["signal_type"]),
                "signal_type_name": nn(meta["signal_type_name"]),
                "trend": nn(meta["trend"]),
            ]
            var scoreOut: [String: Any] = [:]
            var tierOut: [String: Any] = [:]
            for s in slots {
                scoreOut[String(s)] = nn(scores[s])
                tierOut[String(s)] = nn(tiers[s])
            }
            row["scores"] = scoreOut
            row["tiers"] = tierOut
            var prices: [String: Any] = [:], changes: [String: Any] = [:]
            for s in slots {
                let r = rounds[s] ?? [:]
                for p in picks(r, "tier1") + picks(r, "tier2") where codeOf(p) == c {
                    prices[String(s)] = nn(p["price"])
                    changes[String(s)] = nn(p["change_pct"])
                }
            }
            row["prices"] = prices
            row["changes"] = changes
            if tiers.values.contains(1) { tier1Matrix.append(row) } else { tier2Matrix.append(row) }
        }
        report["tier1_matrix"] = tier1Matrix
        report["tier2_matrix"] = tier2Matrix

        // 4. 档位升降
        var changes: [[String: Any]] = []
        for c in order {
            guard let meta = info[c] else { continue }
            let tiers = (meta["tiers"] as? [Int: Int]) ?? [:]
            let seq = slots.compactMap { tiers[$0] }
            if seq.count >= 2 && seq[0] != seq[seq.count - 1] {
                let direction = seq[seq.count - 1] < seq[0] ? "升级" : "降级"
                let from = seq[0] == 1 ? "一档" : "二档"
                let to = seq[seq.count - 1] == 1 ? "一档" : "二档"
                changes.append(["code": c, "name": nn(meta["name"]),
                                "change": "\(from) → \(to) (\(direction))"])
            }
        }
        report["tier_changes"] = changes

        // 5. 深度排除
        var seenOrder: [String] = []
        var seen: [String: [String: Any]] = [:]
        for s in slots {
            for e in ((rounds[s]?["excluded_deep_trend"] as? [[String: Any]]) ?? []) {
                let c = (e["code"] as? String) ?? ""
                if seen[c] == nil {
                    seen[c] = ["code": c, "name": (e["name"] as? String) ?? "",
                               "reasons": [String: String](), "slots": [Int]()]
                    seenOrder.append(c)
                }
                var reasons = (seen[c]?["reasons"] as? [String: String]) ?? [:]
                reasons[String(s)] = (e["reason"] as? String) ?? ""
                seen[c]?["reasons"] = reasons
                var sl = (seen[c]?["slots"] as? [Int]) ?? []
                sl.append(s)
                seen[c]?["slots"] = sl
            }
        }
        report["excluded_table"] = seenOrder.map { seen[$0] ?? [:] }

        // 6. ETF 对比
        var etfOrder: [String] = []
        var etfSeen: [String: [String: Any]] = [:]
        for s in slots {
            for e in ((rounds[s]?["etf_recommendations"] as? [[String: Any]]) ?? []) {
                let c = (e["code"] as? String) ?? ""
                if etfSeen[c] == nil {
                    etfSeen[c] = ["code": c, "name": (e["name"] as? String) ?? "",
                                  "changes": [String: Any]()]
                    etfOrder.append(c)
                }
                var ch = (etfSeen[c]?["changes"] as? [String: Any]) ?? [:]
                ch[String(s)] = nn(e["change_pct"])
                etfSeen[c]?["changes"] = ch
            }
        }
        report["etf_matrix"] = etfOrder.map { etfSeen[$0] ?? [:] }

        // 7. 稳定性分析与操作建议
        let finalSlot = slots.max() ?? 0
        let final = rounds[finalSlot] ?? [:]
        let verified = slots.count >= expectedSlots.count
        let alwaysT1 = order.filter { SignalType(json: info[$0]?["signal_type"]) == .strongest }
        let consensusList = order.filter { SignalType(json: info[$0]?["signal_type"])?.isVerified == true }
        let pulseList = order.filter { SignalType(json: info[$0]?["signal_type"]) == .pulse }
        let unverifiedList = order.filter { SignalType(json: info[$0]?["signal_type"]) == .unverified }
        let finalNew = order.filter {
            guard let m = info[$0], let sc = m["scores"] as? [Int: Double] else { return false }
            return (sc.keys.max() ?? 0) == finalSlot && sc.count == 1
        }
        let declining = order.filter { (info[$0]?["trend"] as? String) == "评分递减" }
        // 缺哪几轮只算一次（原先 415 与 422 各写一份 filter，两份会漂）
        let missingSlots = RoundPlan.missing(slots)

        report["stability"] = [
            "persistence_verified": verified,
            "slots_available": slots,
            "slots_expected": expectedSlots,
            "missing_slots": missingSlots,
            "always_tier1": alwaysT1, "consensus": consensusList,
            "pulse_only": pulseList, "unverified": unverifiedList,
            "final_new": finalNew, "declining": declining,
        ] as [String: Any]

        if !verified {
            let missing = missingSlots
                .map { RoundPlan.label(of: $0) == "" ? "slot\($0)" : RoundPlan.label(of: $0) }
                .joined(separator: "、")

            // 强调记号用「」（源头统一）。⚠ 历史落库的 `compare_reports` 仍含 Markdown `**`
            //   形态 → 展示层 `TextMarkup.toCJK` 归一化**不许删**。
            warnings.append("⚠ 本轮仅有 \(slots.count)/\(expectedSlots.count) 轮数据（缺 \(missing)），"
                + "「无法判定三轮持续性」：所有标的标记为「未验证」，"
                + "不得按持续信号对待（补跑窗口 25 分钟，超时该轮永久缺失）")
        }

        let shOkAll = slots.allSatisfy {
            ((rounds[$0]?["market_env"] as? [String: Any])?["sh_ok"] as? Bool) ?? true }
        if !shOkAll {
            warnings.append("大盘偏弱环境：验证数据显示脉冲信号胜率仅30%，仅操作持续信号标的，脉冲信号标注高风险不建议操作")
        }

        // 建议
        var suggestions: [[String: Any]] = []
        let finalT1 = picks(final, "tier1"), finalT2 = picks(final, "tier2")
        let finalEtfs = (final["etf_recommendations"] as? [[String: Any]]) ?? []
        func nameOf(_ c: String) -> String { (info[c]?["name"] as? String) ?? "" }
        func scoreAt(_ c: String, _ s: Int) -> Double {
            ((info[c]?["scores"] as? [Int: Double])?[s]) ?? 0
        }

        if finalT1.isEmpty && finalT2.isEmpty {
            suggestions.append(["type": "empty",
                "text": "末轮个股全部被淘汰，建议空仓观望。今日不进场，如已持仓严格执行止损纪律。"])
            if !finalEtfs.isEmpty {
                let names = finalEtfs.prefix(3).map {
                    "\(($0["code"] as? String) ?? "") \(($0["name"] as? String) ?? "")"
                        + "(\(fmtNum(numOf($0["change_pct"])))%)"
                }
                suggestions.append(["type": "etf_hedge",
                    "text": "避险ETF参考：\(names.joined(separator: ", "))（不宜重仓追高）"])
            }
        } else if !verified {
            // 轮次不足时**禁止**输出"高置信标的"建议 —— 那需要三轮一致才能成立
            let cand = !alwaysT1.isEmpty ? alwaysT1
                : (!consensusList.isEmpty ? consensusList : finalT1.map(codeOf))
            let names = cand.prefix(6).map { "\($0) \(nameOf($0))" }
            suggestions.append(["type": "unverified_warning",
                "text": "轮次不足，持续性未经确认：当前入档 \(finalT1.count + finalT2.count) 只"
                    // 强调记号用「」（理由见本文件 warnings 处注释）
                    + "（\(names.joined(separator: "、"))）。请「不要」按「持续信号」对待，"
                    + "按脉冲处理：轻仓、见好就收；若轮次缺失是休眠所致，可手动补跑后再看"])
        } else {
            if !alwaysT1.isEmpty {
                let names = alwaysT1.map {
                    "\($0) \(nameOf($0))(末轮\(fmtNum(scoreAt($0, finalSlot)))分)" }
                suggestions.append(["type": "high_confidence",
                    "text": "高置信标的（三轮均一档，\(alwaysT1.count)只）："
                        + "\(names.joined(separator: ", "))，可优先考虑尾盘建仓"])
            }
            if !finalNew.isEmpty {
                let names = finalNew.map {
                    "\($0) \(nameOf($0))(\(fmtNum(scoreAt($0, finalSlot)))分)" }
                suggestions.append(["type": "late_enhance",
                    "text": "尾盘强化标的（末轮才入一档）：\(names.joined(separator: ", "))，"
                        + "可能是午后资金流入，需次日开盘确认"])
            }
            if !declining.isEmpty {
                let names = declining.map { "\($0) \(nameOf($0))" }
                suggestions.append(["type": "weakening",
                    "text": "信号减弱标的（评分递减）：\(names.joined(separator: ", "))，"
                        + "盘中条件恶化，谨慎追入"])
            }
            if alwaysT1.isEmpty && finalNew.isEmpty && !finalT1.isEmpty {
                suggestions.append(["type": "weak_signal",
                    "text": "无三轮稳定标的，尾盘仍有入选但信号不够强，轻仓试探为主，严格止损"])
            }
        }
        report["suggestions"] = suggestions

        // 大盘逐轮走弱
        let shChanges = slots.map {
            numOf((rounds[$0]?["market_env"] as? [String: Any])?["sh_change_pct"])
        }
        if shChanges.count >= 2 {
            var nonIncreasing = true
            var hasStrictDrop = false
            for i in 0..<(shChanges.count - 1) {
                if shChanges[i] < shChanges[i + 1] {
                    nonIncreasing = false
                    break
                }
                if shChanges[i] > shChanges[i + 1] {
                    hasStrictDrop = true
                }
            }
            if nonIncreasing && hasStrictDrop {
                let seq = shChanges.map { "\(fmtNum($0))%" }.joined(separator: " → ")
                warnings.append("大盘逐轮走弱（\(seq)），整体偏弱，控制仓位")
            }
        }

        report["warnings"] = warnings
        report["status"] = "ok"
        return report
    }

    /// 把内部结构（含 Int 键字典）转成可 JSON 序列化的形式
    private static func jsonSafe(_ m: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in m {
            if let scores = v as? [Int: Double] {
                var d: [String: Any] = [:]
                for (s, val) in scores { d[String(s)] = val }
                out[k] = d
            } else if let tiers = v as? [Int: Int] {
                var d: [String: Any] = [:]
                for (s, val) in tiers { d[String(s)] = val }
                out[k] = d
            } else {
                out[k] = v
            }
        }
        return out
    }
}
