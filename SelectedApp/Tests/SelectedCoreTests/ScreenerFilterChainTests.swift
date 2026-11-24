import XCTest
@testable import SelectedCore

/// 选股主链的**过滤层**与三轮对比的**信号分类**。
///
/// ## 为什么专门补这个文件（2026-10-16 测试审查 B7）
/// 审查时实测过：`Screener.hardFilter` / `passesProfileRisk` / `screenEtf` /
/// `SignalClassifier.classifySignals` 在 `Tests/` 里**一条引用都没有**，
/// `Screener.scoreStock` 也只有唯一一条用例、且是在把所有阈值表清空的情况下跑的
/// （只验形态分 ±6）。也就是说 —— 指标库有 26 份黄金 CSV 逐点比对、
/// 实体层有键集/往返断言，但**"哪些票能进、进来了算哪一档信号"这一层完全没有自动化**。
/// 而这一层恰恰是直接决定下单名单的，写错不会被任何测试拦住。
///
/// ## 钉住的是哪些"容易搞错"
/// · **边界是闭还是开**：价格/ loosen 带 用 `<=` 双向闭区间；振幅是`>` 才剔；
///   涨跌幅是 `<=` 就剔 —— 差一个等号就是"这只票今天到底能不能进"的差别
/// · **一字板要两个条件同时成立**（开=收=高=低 **且** |涨跌幅| ≥ 阈值），
///   写成 `||` 会把普通高开低走的票整批误杀
/// · **非法参数不许把整轮打成 0 只**：`change_pct_loose` 长度不足时必须回落 `[1,6]` 并留痕
/// · **轮次不足 ⇒ 一切信号都必须是 `unverified`**（不能因为"两轮里都有它"就说"持续"）
/// · **预算截断过的票即使全轮命中也必须降级**（`budget_limited`），
///   否则"今天钱不够只买了一半"会被显示成"信号弱"
final class ScreenerFilterChainTests: XCTestCase {

    // MARK: - 夹具

    /// 一只"健康"的候选：现价 10.5 / 昨收 10.0 ⇒ 涨跌幅 +5.00%，振幅 5.00%
    private func quote(_ code: String, price: Double, preClose: Double,
                       open: Double? = nil, high: Double? = nil, low: Double? = nil,
                       name: String = "测试股") -> EngineQuote {
        var q = EngineQuote()
        q.code = code
        q.name = name
        q.price = price
        q.preClose = preClose
        q.open = open ?? preClose
        q.high = high ?? max(price, q.open)
        q.low = low ?? min(price, q.open)
        return q
    }

    /// 与出厂口径同形的硬过滤参数（区间刻意取整，方便手算边界）
    private func hardFilterParams(changePctLoose: [Any] = [1.0, 6.0]) -> [String: Any] {
        ["one_word_board_pct": 9.0,
         "price_min": 3.0, "price_max": 60.0,
         "amplitude_max": 8.0,
         "change_pct_min": 1.0,
         "change_pct_loose": changePctLoose]
    }

    // MARK: - ① 边界方向

    func testPriceAndPreCloseMustBePositive() {
        let out = Screener.hardFilter([
            "000001": quote("000001", price: 0, preClose: 10),
            "000002": quote("000002", price: 10, preClose: 0),
            "000003": quote("000003", price: -1, preClose: 10),
        ], hardFilterParams())
        XCTAssertTrue(out.isEmpty, "现价或昨收 ≤0 必须剔除（涨跌幅无从计算，不能放行）")
    }

    func testPriceRangeIsInclusiveBothEnds() {
        // price_min=3.0 / price_max=60.0：端点本身必须**保留**
        let ok = quote("600001", price: 10.5, preClose: 10)            // 区间内
        let loEdge = quote("600002", price: 3.05, preClose: 3.0)        // 恰在低位（涨 1.67%）
        let hiEdge = quote("600003", price: 60.0, preClose: 58.0)       // 恰在高位（涨 3.45%）
        let under = quote("600004", price: 2.9, preClose: 2.85)         // 低于 price_min
        let over = quote("600005", price: 60.01, preClose: 58.0)        // 高于 price_max
        let out = Screener.hardFilter(
            ["600001": ok, "600002": loEdge, "600003": hiEdge, "600004": under, "600005": over],
            hardFilterParams())
        XCTAssertEqual(Set(out.keys), ["600001", "600002", "600003"],
                       "价格区间是双向闭区间：端点保留、越界剔除")
    }

    /// ⚠ 全部用**二进制可精确表示**的价格（1/8、1/4 这类）：
    ///   第一版这里写的是 `10.9 - 10.1` 想凑"振幅正好 8.0"，实测得到
    ///   `8.000000000000007` ⇒ 被 `amp > ampMax` 判成超限。
    ///   这既是测试写法的问题，也是**这条边界本身对浮点敏感**的事实
    ///   （`amplitude_max` 取整数值时，落在端点上的票进还是出，取决于价位的二进制表示）。
    func testAmplitudeUsesStrictGreaterThan() {
        // 昨收 4：(5-4)/4×100 = 25.0 **精确**；(5.125-4)/4×100 = 28.125 精确
        let edge = quote("000010", price: 4.125, preClose: 4, high: 5, low: 4)      // 振幅 25.0
        let over = quote("000011", price: 4.125, preClose: 4, high: 5.125, low: 4)  // 振幅 28.125
        var hf = hardFilterParams()
        hf["amplitude_max"] = 25.0
        let out = Screener.hardFilter(["000010": edge, "000011": over], hf)
        XCTAssertEqual(Set(out.keys), ["000010"], "振幅等于上限保留、超过才剔")
    }

    func testChangePctBandKeepsInsideAndRejectsOutside() {
        // 昨收 8 ⇒ 涨幅精确可算：8.125→1.5625 · 8.25→3.125 · 8.5→6.25 · 8.0625→0.78125
        let insideLow = quote("000020", price: 8.125, preClose: 8)    // +1.5625（带内、且 > min）
        let insideMid = quote("000021", price: 8.25, preClose: 8)     // +3.125
        let above = quote("000022", price: 8.5, preClose: 8)          // +6.25 > 带上限 6
        let below = quote("000023", price: 8.0625, preClose: 8)       // +0.78125 < min 1.0
        let out = Screener.hardFilter(
            ["000020": insideLow, "000021": insideMid, "000022": above, "000023": below],
            hardFilterParams())
        XCTAssertEqual(Set(out.keys), ["000020", "000021"],
                       "带内保留；高于上限、低于 change_pct_min 都剔除")
    }

    func testChangePctMustBeStrictlyAboveMin() {
        // 判据是 `chg <= chgMin → 剔`：等于阈值也算"不大于"。
        // 昨收 8、现价 8.0625 ⇒ +0.78125（二进制精确，不受浮点抖动影响）
        let under = quote("000030", price: 8.0625, preClose: 8)
        let hf = ["one_word_board_pct": 9.0, "price_min": 3.0, "price_max": 60.0,
                  "amplitude_max": 8.0, "change_pct_min": 1.0,
                  "change_pct_loose": [0.5, 6.0]] as [String: Any]
        XCTAssertTrue(Screener.hardFilter(["000030": under], hf).isEmpty,
                      "涨跌幅必须**严格大于** change_pct_min（这里是有意收紧的口径）")
    }

    // MARK: - ② 一字板

    func testOneWordBoardNeedsBothConditions() {
        // 开=收=高=低 且 涨跌幅 ≥9 ⇒ 剔
        let stuck = quote("000040", price: 10.9, preClose: 10.0,
                          open: 10.9, high: 10.9, low: 10.9)   // +9.00% 一字
        // 四个价相等但涨幅只有 5% ⇒ **不是一字板**，必须留下
        let softStuck = quote("000041", price: 10.5, preClose: 10.0,
                              open: 10.5, high: 10.5, low: 10.5)  // +5.00%
        let out = Screener.hardFilter(["000040": stuck, "000041": softStuck],
                                      hardFilterParams())
        XCTAssertEqual(Set(out.keys), ["000041"],
                       "一字板要两条件同时成立；把 || 写进来会误杀普通平开平走的票")
    }

    func testOneWordThresholdIsParameterized() {
        // 开=高=低=收 的"一字"形态，涨幅 +3.125（昨收 8、现价 8.25，二进制精确）
        // ⇒ 阈值 2.0 时该剔、阈值 20.0 时该留 —— 证明阈值真的读参数，不是写死 9
        let stuck = quote("000042", price: 8.25, preClose: 8,
                          open: 8.25, high: 8.25, low: 8.25)
        var tight = hardFilterParams()
        tight["one_word_board_pct"] = 2.0
        XCTAssertTrue(Screener.hardFilter(["000042": stuck], tight).isEmpty,
                      "阈值 2.0 ⇒ +3.125 的一字板应被剔")
        var loose = hardFilterParams()
        loose["one_word_board_pct"] = 20.0
        XCTAssertEqual(Screener.hardFilter(["000042": stuck], loose).count, 1,
                       "阈值抬到 20 ⇒ 同一只票不该再被一字板规则剔掉")
    }

    // MARK: - ③ 非法参数不许打成 0 只

    func testMalformedLooseBandFallsBackInsteadOfRejectingEverything() {
        // `change_pct_loose` 只剩一个元素 ⇒ 必须回落 [1.0, 6.0] 并继续按回落值筛，
        // 而不是"条件恒假"把整轮打成 0 只（那是审查记录里最危险的静默失效形态）
        let good = quote("000050", price: 10.5, preClose: 10.0)   // +5.00%，回落带内
        let tooHigh = quote("000051", price: 11.0, preClose: 10.0)  // +10%，回落带外
        let out = Screener.hardFilter(
            ["000050": good, "000051": tooHigh],
            hardFilterParams(changePctLoose: [3.0]))
        XCTAssertEqual(Set(out.keys), ["000050"],
                       "非法长度要回落兜底带：兜底带内的仍入选、带外的照旧剔")
    }

    // MARK: - ④ 输出字段是算出来的、不是原样带的

    func testOutputCarriesRecomputedChangeAndAmplitude() {
        // 昨收 9.99、现价 10.5 ⇒ +5.1051…%，必须写成保留两位的 5.11
        let q = quote("000060", price: 10.5, preClose: 9.99, high: 10.6, low: 10.0)
        let out = Screener.hardFilter(["000060": q], hardFilterParams())
        guard let r = out["000060"] else { return XCTFail("应通过硬过滤") }
        XCTAssertEqual(r.changePct, 5.11, accuracy: 0.005, "涨跌幅由现价/昨收重算并保留两位")
        XCTAssertEqual(r.amplitude, PyMath.round((10.6 - 10.0) / 9.99 * 100, 2),
                       accuracy: 0.005, "振幅同样重算保留两位")
    }

    // MARK: - ⑤ 三轮对比的信号分类

    private func pick(_ code: String, name: String, score: Double) -> [String: Any] {
        ["code": code, "name": name, "score": score]
    }

    /// 造一轮：`tier1` / `tier2` 两组代码
    private func round(tier1: [[String: Any]], tier2: [[String: Any]] = [],
                       budgetSkipped: [String] = []) -> [String: Any] {
        var r: [String: Any] = ["tier1": tier1, "tier2": tier2]
        if !budgetSkipped.isEmpty { r["budget_skipped_codes"] = budgetSkipped }
        return r
    }

    func testEmptyRoundsProduceNothing() {
        let (order, info) = SignalClassifier.classifySignals([:])
        XCTAssertTrue(order.isEmpty)
        XCTAssertTrue(info.isEmpty)
    }

    func testAllThreeRoundsTier1IsStrongest() {
        let a = pick("600001", name: "甲", score: 80)
        let rounds: [Int: [String: Any]] = [
            1: round(tier1: [a]), 2: round(tier1: [a]), 3: round(tier1: [a]),
        ]
        let (_, info) = SignalClassifier.classifySignals(rounds)
        XCTAssertEqual(info["600001"]?["signal_type"] as? String, SignalType.strongest.rawValue,
                       "三轮 tier1 都在 ⇒ 最强信号")
        XCTAssertEqual(info["600001"]?["signal_verified"] as? Bool, true)
    }

    func testTier2AcrossAllRoundsIsConsensusNotStrongest() {
        // 只在 tier1∪tier2 的交集里（这里全在 tier2）⇒ 持续信号，不是最强信号
        let b = pick("600002", name: "乙", score: 70)
        let rounds: [Int: [String: Any]] = [
            1: round(tier1: [], tier2: [b]),
            2: round(tier1: [], tier2: [b]),
            3: round(tier1: [], tier2: [b]),
        ]
        let (_, info) = SignalClassifier.classifySignals(rounds)
        XCTAssertEqual(info["600002"]?["signal_type"] as? String, SignalType.consensus.rawValue,
                       "tier1 交集为空但全集交集非空 ⇒ 持续信号")
    }

    func testSingleRoundAppearanceIsPulse() {
        let c = pick("600003", name: "丙", score: 66)
        let rounds: [Int: [String: Any]] = [
            1: round(tier1: [c]), 2: round(tier1: []), 3: round(tier1: []),
        ]
        let (_, info) = SignalClassifier.classifySignals(rounds)
        XCTAssertEqual(info["600003"]?["signal_type"] as? String, SignalType.pulse.rawValue,
                       "只在一轮出现 ⇒ 脉冲信号")
    }

    func testFewerThanThreeRoundsEverythingUnverified() {
        // ⚠ 这条是本函数的核心不变量：轮次不全时，**即使同一只票两轮都在 tier1**，
        //   也不许标成"最强/持续"—— 那会把"没跑完"说成"信号确认了"。
        let d = pick("600004", name: "丁", score: 90)
        let rounds: [Int: [String: Any]] = [1: round(tier1: [d]), 2: round(tier1: [d])]
        let (_, info) = SignalClassifier.classifySignals(rounds)
        XCTAssertEqual(info["600004"]?["signal_type"] as? String, SignalType.unverified.rawValue,
                       "轮次不足 ⇒ 一律未验证")
        XCTAssertEqual(info["600004"]?["signal_verified"] as? Bool, false)
        XCTAssertEqual(info["600004"]?["slots_expected"] as? [Int], SignalClassifier.expectedSlots,
                       "期望轮次要如实报出来，界面才能写「缺哪几轮」")
    }

    func testBudgetSkippedCodeIsDemotedAndFlagged() {
        // 三轮 tier1 全中，但被预算截断过 ⇒ 只能算未验证，并且要打 `budget_limited`
        // （否则"钱不够只买了一半"会被读成"信号弱"）
        let e = pick("600005", name: "戊", score: 88)
        let rounds: [Int: [String: Any]] = [
            1: round(tier1: [e]), 2: round(tier1: [e]),
            3: round(tier1: [e], budgetSkipped: ["600005"]),
        ]
        let (_, info) = SignalClassifier.classifySignals(rounds)
        XCTAssertEqual(info["600005"]?["signal_type"] as? String, SignalType.unverified.rawValue)
        XCTAssertEqual(info["600005"]?["budget_limited"] as? Bool, true,
                       "预算截断必须单独可见，不能和「信号弱」混成一类")
    }

    func testScoreTrajectoryIsRecordedPerSlot() {
        let f = pick("600006", name: "己", score: 0)
        let rounds: [Int: [String: Any]] = [
            1: round(tier1: [pick("600006", name: "己", score: 60)]),
            2: round(tier1: [pick("600006", name: "己", score: 75)]),
            3: round(tier1: [pick("600006", name: "己", score: 90)]),
        ]
        _ = f
        let (order, info) = SignalClassifier.classifySignals(rounds)
        XCTAssertEqual(order, ["600006"], "输出顺序按 slot 升序 + tier1 先于 tier2")
        let scores = (info["600006"]?["scores"] as? [Int: Double]) ?? [:]
        XCTAssertEqual(scores, [1: 60, 2: 75, 3: 90], "每轮评分都要留痕（趋势标签靠它）")
    }

    // MARK: - ⑥ 趋势标签（可判定的部分）

    func testTrendLabelForMissingSlots() {
        // 只在部分轮出现 ⇒ 不能算"递增/递减"
        let s = SignalClassifier.trendLabel([1: 60, 3: 90], [1, 2, 3])
        XCTAssertFalse(s.contains("递增") || s.contains("递减"),
                       "缺轮时不许给出方向性结论，实际：\(s)")
    }

    /// 三轮评分**完全相等**必须报"持平"（2026-10-16 审查 B5-15 修复）。
    /// 修复前 `inc`/`dec` 只在严格大/小时清零，全相等时两者都成立 ⇒ 落到第一个分支
    /// 报成「评分递增」—— 把一条水平线说成"一轮比一轮强"，方向完全相反。
    /// （上一轮留的占位用例已按注释要求删掉，换成这条正向断言。）
    func testFlatTrendIsLabelledFlat() {
        XCTAssertEqual(SignalClassifier.trendLabel([1: 70, 2: 70, 3: 70], [1, 2, 3]), "评分持平")
        XCTAssertEqual(SignalClassifier.trendLabel([1: 60, 2: 70, 3: 80], [1, 2, 3]), "评分递增")
        XCTAssertEqual(SignalClassifier.trendLabel([1: 80, 2: 70, 3: 60], [1, 2, 3]), "评分递减")
        XCTAssertEqual(SignalClassifier.trendLabel([1: 60, 2: 90, 3: 70], [1, 2, 3]), "波动")
    }
}

