import XCTest
@testable import SelectedCore

/// 量能 / 连续性判据。
///
/// 这个文件的重点是**口径**：
/// · 「前 N 日均量」**不含末根**（末根就是今日）
/// · 「连阳」按 `收 > 开`，与 `consec_up`（按**涨幅**）**不是一回事**
/// · 均量为 0（长期停牌）不能被当成"极度缩量"
final class KLineSignalsTests: XCTestCase {

    // MARK: - 夹具

    /// 一根 bar。`body` 决定阳/阴（close > open 为阳）；默认量 100
    private func bar(_ close: Double, open: Double, volume: Double = 100,
                     day: String = "") -> KLineBar {
        KLineBar(day: day, open: open, high: max(open, close), low: min(open, close),
                 close: close, volume: volume)
    }

    /// 5 根"前序"（量各 100、收平）—— 用于把"前 5 日均量"钉在 100。
    ///
    /// 这 5 根是**十字**（`close == open`）→ 它们**不计入**连阳/连阴（见
    /// `consecutiveBodyStreak` 的口径）。造连续类夹具时要另起 `yangRun` / `yinRun`。
    private func flatPriors(_ n: Int = 5) -> [KLineBar] {
        (0..<n).map { bar(10, open: 10, volume: 100, day: "d\($0)") }
    }

    /// n 根**干净的**阳线（收 > 开，且逐根收盘走高）
    private func yangRun(_ n: Int) -> [KLineBar] {
        (0..<n).map { bar(10 + Double($0 + 1) * 0.1, open: 10, day: "y\($0)") }
    }

    /// n 根**干净的**阴线（收 < 开，且逐根收盘走低）
    private func yinRun(_ n: Int) -> [KLineBar] {
        (0..<n).map { bar(10 - Double($0 + 1) * 0.1, open: 10, day: "n\($0)") }
    }

    // MARK: - 天量

    func testHeavyVolumeHitsAtThreshold() {
        // 前 5 日各 100 → 均量 100；今日 300 → 3.00 倍，恰好等于阈值
        let bars = flatPriors() + [bar(10, open: 10, volume: 300)]
        let hits = KLineSignals.detect(bars)
        XCTAssertTrue(hits.contains { $0.kind == .heavyVolume }, "3.00 倍应命中（`>=` 不是 `>`）")
        XCTAssertEqual(hits.first { $0.kind == .heavyVolume }?.direction, .neutral,
                       "天量的方向是**中性**（天量上涨与天量下跌是两回事），方向写在 note 里")
        XCTAssertTrue(hits.first { $0.kind == .heavyVolume }?.note.contains("3.00") ?? false,
                      "note 要带量能倍数：\(hits.first { $0.kind == .heavyVolume }?.note ?? "")")
    }

    func testHeavyVolumeMissesJustBelowThreshold() {
        let bars = flatPriors() + [bar(10, open: 10, volume: 299)]   // 2.99 倍
        XCTAssertFalse(KLineSignals.detect(bars).contains { $0.kind == .heavyVolume })
    }

    /// 判据必须是"今日 ÷ **前 5 日**均量"，**不能把今日算进均量里**。
    ///
    /// 若把末根也算进均量（6 根一起平均），均量 = (500+300)/6 = 133.3、倍数 = 2.25 → 不命中。
    /// 所以这条断言同时验证了"分母不含今日"。
    func testVolumeBaseExcludesToday() {
        let bars = flatPriors() + [bar(10, open: 10, volume: 300)]
        XCTAssertEqual(EngineIndicators.volMult5d(bars.map(\.volume), 5), 3.0, accuracy: 1e-9,
                       "前 5 日均量必须是 100（不含今日）")
        XCTAssertTrue(KLineSignals.detect(bars).contains { $0.kind == .heavyVolume })
    }

    // MARK: - 连涨放量（两个条件缺一不可）

    func testSurgeUpRequiresBothConsecutiveGainsAndVolume() {
        // 连涨 3 天（收 10→11→12→13）+ 今日量 250（2.5 倍）
        let up = flatPriors() + [bar(11, open: 10.5, volume: 100),
                                 bar(12, open: 11.5, volume: 100),
                                 bar(13, open: 12.5, volume: 250)]
        let hits = KLineSignals.detect(up)
        XCTAssertTrue(hits.contains { $0.kind == .volumeSurgeUp }, "连涨 3 天 + 2.5 倍 → 命中")

        // 只放量、没连涨（前一根收 13，今日收 12.9 → 跌）→ 不命中
        let noUp = flatPriors() + [bar(13, open: 12.5, volume: 100),
                                   bar(12.9, open: 13.2, volume: 250)]
        XCTAssertFalse(KLineSignals.detect(noUp).contains { $0.kind == .volumeSurgeUp },
                       "没连涨就不该报'连涨放量'")

        // 只连涨、量不够（1.5 倍 < 2.0）→ 不命中
        let noVol = flatPriors() + [bar(11, open: 10.5, volume: 100),
                                    bar(12, open: 11.5, volume: 100),
                                    bar(13, open: 12.5, volume: 150)]
        XCTAssertFalse(KLineSignals.detect(noVol).contains { $0.kind == .volumeSurgeUp },
                       "量不够就不该报'连涨放量'")
    }

    // MARK: - 下跌无量

    func testQuietDeclineRequiresADecline() {
        // 跌 + 缩量到 0.5 倍 → 命中
        let down = flatPriors() + [bar(9.5, open: 10, volume: 50)]
        XCTAssertTrue(KLineSignals.detect(down).contains { $0.kind == .quietDecline })

        // **涨** + 缩量 → 不是"下跌无量"（方向写反了就不是同一个判据）
        let up = flatPriors() + [bar(10.5, open: 10, volume: 50)]
        XCTAssertFalse(KLineSignals.detect(up).contains { $0.kind == .quietDecline },
                       "缩量上涨不是'下跌无量'")
    }

    /// 均量为 0（长期停牌）时 `volMult5d` 返回 0，而 `0 ≤ 0.7` 会让"算不出来"
    /// 被当成"极度缩量" → 停牌票被报成"下跌无量"。`vm > 0` 这个前置不能省。
    func testZeroVolumeBaseDoesNotBecomeQuietDecline() {
        let bars = (0..<5).map { bar(10, open: 10, volume: 0, day: "d\($0)") }
            + [bar(9.5, open: 10, volume: 0)]
        let hits = KLineSignals.detect(bars)
        XCTAssertFalse(hits.contains { $0.kind == .quietDecline },
                       "均量为 0（停牌）不能报成'下跌无量'：\(hits.map(\.name))")
        XCTAssertFalse(hits.contains { $0.kind == .heavyVolume })
        XCTAssertFalse(hits.contains { $0.kind == .volumeSurgeUp })
    }

    // MARK: - 连续阳线 / 阴线

    func testConsecutiveYangAndYinAtThreshold() {
        // 4 连阳（默认下限 4）
        XCTAssertTrue(KLineSignals.detect(flatPriors() + yangRun(4))
            .contains { $0.kind == .consecutiveYang }, "4 连阳应命中")

        // 3 连阳 → 不命中（默认下限是 4）
        XCTAssertFalse(KLineSignals.detect(flatPriors() + yangRun(3))
            .contains { $0.kind == .consecutiveYang }, "3 连阳不该命中（默认下限 4）")

        // 4 连阴
        XCTAssertTrue(KLineSignals.detect(flatPriors() + yinRun(4))
            .contains { $0.kind == .consecutiveYin }, "4 连阴应命中")
        XCTAssertFalse(KLineSignals.detect(flatPriors() + yinRun(3))
            .contains { $0.kind == .consecutiveYin }, "3 连阴不该命中")
    }

    /// 十字（收 == 开）**同时打断**两条连续 —— 它既不是阳线也不是阴线。
    /// 用严格不等号（`>` / `<`）而不是 `>=` / `<=` 就是为了这个。
    func testDojiBreaksBothStreaks() {
        // 末根是十字 → 两条都不成立
        let endsWithDoji = [bar(10, open: 9), bar(11, open: 10), bar(12, open: 11),
                            bar(13, open: 12), bar(14, open: 13), bar(14, open: 14)]
        let (yang, yin) = KLineSignals.consecutiveBodyStreak(endsWithDoji)
        XCTAssertEqual(yang, 0, "末根是十字 → 不算阳线")
        XCTAssertEqual(yin, 0)

        // 中间夹一根十字 → 连续在它那里断掉
        let broken = [bar(10, open: 9), bar(11, open: 10), bar(11, open: 11),
                      bar(12, open: 11), bar(13, open: 12)]
        XCTAssertEqual(KLineSignals.consecutiveBodyStreak(broken).yang, 2,
                       "倒数第三根是十字 → 只数到它后面那 2 根")
    }

    /// 口径差异：跳空高开但**收阴**的票计入**连涨**、不计入**连阳**。
    /// 这就是"连阳/连阴"与既有 `consec_up` 不是重复口径的证据。
    func testConsecutiveBodyDiffersFromConsecutiveUp() {
        // 三根：收 10 → 11（阳）→ 12（阴，开 12.5 收 12）
        let bars = [bar(10, open: 9), bar(11, open: 10), bar(12, open: 12.5)]
        let closes = bars.map(\.close)
        // 涨幅口径：11 > 10 ✓、12 > 11 ✓ → 连涨 2 天
        XCTAssertEqual(EngineIndicators.consecutiveUpDays(closes), 2, "按涨幅算是连涨 2 天")
        // 阳线口径：末根收 12 < 开 12.5 → 是阴线 → 连阳 0
        XCTAssertEqual(KLineSignals.consecutiveBodyStreak(bars).yang, 0,
                       "末根收阴 → 连阳 0（与'连涨 2 天'不同，这正是本模块的增量）")
        XCTAssertEqual(KLineSignals.consecutiveBodyStreak(bars).yin, 1)
    }

    // MARK: - 命名（清单里的传统名）

    func testTraditionalNamesFollowTheList() {
        XCTAssertEqual(KLineSignals.yangName(4), "四串阳")
        XCTAssertEqual(KLineSignals.yangName(8), "八仙过海")
        XCTAssertEqual(KLineSignals.yangName(9), "九阳神功")
        XCTAssertEqual(KLineSignals.yangName(5), "5连阳", "没有传统名的按 N连阳")
        XCTAssertEqual(KLineSignals.yangName(10), "10连阳")

        XCTAssertEqual(KLineSignals.yinName(7), "七仙女下凡")
        XCTAssertEqual(KLineSignals.yinName(6), "6连阴")
        XCTAssertEqual(KLineSignals.yinName(8), "8连阴")

        // 1/2 根的「一根大阳线 / 两根大阳线」不在这里：那两条还要求"实体够大"，
        //   而"大阳线 / 大阴线"已由 KLinePatterns 的 marubozu（光头光脚）覆盖。
        XCTAssertEqual(KLineSignals.yangName(1), "1连阳")
    }

    /// 命中的连续类要用传统名，且 note 里带**数字**（不能只给"九阳神功"让人去猜）
    func testConsecutiveHitCarriesTraditionalNameAndNumber() {
        guard let hit = KLineSignals.detect(flatPriors() + yangRun(9))
            .first(where: { $0.kind == .consecutiveYang })
        else { return XCTFail("9 连阳应命中") }
        XCTAssertEqual(hit.name, "九阳神功")
        XCTAssertTrue(hit.note.contains("9"), "note 要写清根数：\(hit.note)")

        // 8 连阳是「八仙过海」—— 顺带证明名字是按根数映射的，不是写死一个
        XCTAssertEqual(KLineSignals.detect(flatPriors() + yangRun(8))
            .first { $0.kind == .consecutiveYang }?.name, "八仙过海")
    }

    // MARK: - 排序与常量

    func testSignalsAreSortedBySeverityDescending() {
        // 造一根"4 连阴 + 天量 + 缩量"…… 组合不出来，就用"连阴 + 天量"
        let bars = (0..<5).map { bar(10 - Double($0) * 0.1, open: 10, volume: 100) }
            + [bar(9, open: 10, volume: 400)]      // 末根：阴 + 天量
        let hits = KLineSignals.detect(bars)
        XCTAssertTrue(hits.contains { $0.kind == .heavyVolume })
        XCTAssertTrue(hits.contains { $0.kind == .consecutiveYin })
        XCTAssertEqual(hits.map(\.kind.severity), hits.map(\.kind.severity).sorted(by: >),
                       "必须按 severity 降序（连阴在天量之前）")
    }

    func testKindConstantsAreDistinct() {
        let all = KLineSignals.Kind.allCases
        XCTAssertEqual(Set(all.map(\.baseName)).count, all.count, "基础名有重复")
        XCTAssertEqual(Set(all.map(\.severity)).count, all.count, "severity 有重复（排序会不稳定）")
        XCTAssertFalse(all.contains { $0.baseName.isEmpty })
        // 方向：只有连涨放量与连续阳线看多、连续阴线看空；天量与下跌无量是中性
        XCTAssertEqual(all.filter { $0.direction == .bullish },
                       [.volumeSurgeUp, .consecutiveYang])
        XCTAssertEqual(all.filter { $0.direction == .bearish }, [.consecutiveYin])
        XCTAssertEqual(all.filter { $0.direction == .neutral }, [.heavyVolume, .quietDecline])
    }

    // MARK: - 边界

    /// 样本不足（< volAvgDays + 1）→ 一条都不出（而不是拿不足的均量硬算）
    func testInsufficientBarsProduceNothing() {
        // 空数组字面量推断不出元素类型 → 必须显式写类型
        // （`KLinePatterns` 用协议而不是重载，就是为了避免这类歧义）
        XCTAssertTrue(KLineSignals.detect([KLineBar]()).isEmpty)
        XCTAssertTrue(KLineSignals.detect(flatPriors(4)).isEmpty, "只有 4 根，算不出 5 日均量")
        XCTAssertTrue(KLineSignals.detect(flatPriors(5)).isEmpty, "只有 5 根：没有'今日'")
        // 6 根起才可能有结论。此例量平（1.0 倍）且末根是十字 → 确实无命中，但必须不崩
        XCTAssertTrue(KLineSignals.detect(flatPriors(5) + [bar(10, open: 10)]).isEmpty,
                      "量平 + 末根十字 → 无命中")
    }

    /// 阈值可调：把天量阈值降到 2.0 → 2.5 倍也命中
    func testConfigIsHonored() {
        let bars = flatPriors() + [bar(10, open: 10, volume: 250)]   // 2.5 倍
        XCTAssertFalse(KLineSignals.detect(bars).contains { $0.kind == .heavyVolume })
        var cfg = KLineSignals.SignalConfig()
        cfg.heavyVolumeMult = 2.0
        XCTAssertTrue(KLineSignals.detect(bars, config: cfg).contains { $0.kind == .heavyVolume })
    }

    /// `KLineBar` 与 `KLineItem` 走**同一条计算路径**（同一份序列 → 同样的结论）。
    /// 两者各自是 `VolumeBar` 的 conformer，若哪天只给其中一个加字段，这条会红。
    func testKLineBarAndKLineItemAgree() {
        let bars = flatPriors() + [bar(10, open: 10, volume: 300)]
        let items = bars.map { KLineItem(date: $0.day, open: $0.open, high: $0.high,
                                         low: $0.low, close: $0.close, volume: $0.volume) }
        XCTAssertEqual(KLineSignals.detect(bars).map(\.kind),
                       KLineSignals.detect(items).map(\.kind),
                       "引擎侧与详情页侧必须同结论")
    }
}
