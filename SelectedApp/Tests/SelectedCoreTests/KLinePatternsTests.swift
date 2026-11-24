import XCTest
@testable import SelectedCore

/// `KLinePatterns` 的契约测试。
///
/// 这是本模块**唯一**的自动化覆盖 —— 详情页的形态卡不在任何测试子集里，`swift build`
/// 只做类型检查。所以"12 个形态各是什么判据、趋势语境怎么定名、谁跟谁必须互斥"这类
/// **真会静默出错**的部分，全部钉在本文件。
///
/// 测试**只用人工构造的 K 线**：形态判据是纯算术，人工数据的期望值可以手算，
/// 比"跑一遍看看像不像"可靠得多。
///
/// 每个形态用例都断言 `shapes` 的**完整集合**，不是"包含"。因为这里的核心风险不是
/// "漏报"，而是**同一个 K 线组合被报成三个形态** —— 只断言包含就看不见这种重复。
final class KLinePatternsTests: XCTestCase {

    // MARK: - 构造工具

    private func k(_ o: Double, _ h: Double, _ l: Double, _ c: Double) -> KLineBar {
        KLineBar(day: "2026-01-05", open: o, high: h, low: l, close: c, volume: 1000)
    }

    /// 实体为 0 的横盘 bar（全幅 0.4）—— 只用来摆趋势，本身不出任何形态
    private func flatBar(_ v: Double) -> KLineBar { k(v, v + 0.2, v - 0.2, v) }

    /// 5 根单调下跌（收盘 30→22）→ 趋势 = down
    private var downBase: [KLineBar] { [30.0, 28, 26, 24, 22].map(flatBar) }
    /// 5 根单调上涨（收盘 10→18）→ 趋势 = up
    private var upBase: [KLineBar] { [10.0, 12, 14, 16, 18].map(flatBar) }
    /// 5 根横盘（收盘恒 15）→ 趋势 = flat
    private var flatBase: [KLineBar] { [15.0, 15, 15, 15, 15].map(flatBar) }

    /// 跑一次识别，返回形状集合（**顺序无关，重复即错**）
    private func shapes(_ bars: [KLineBar],
                        _ config: PatternConfig = PatternConfig()) -> [String] {
        guard let r = KLinePatterns.detect(bars, config: config) else { return [] }
        let s = r.shapes
        XCTAssertEqual(s.count, Set(s).count, "同一形状被报了多次：\(s)")
        return s
    }

    // MARK: - 退化输入

    func testTooFewBarsReturnsNil() {
        // 空数组字面量推断不出元素类型（`[Any]` 不满足 `OHLCBar`）→ 要显式标注
        XCTAssertNil(KLinePatterns.detect([KLineBar]()))
        XCTAssertNil(KLinePatterns.detect([flatBar(10)]))
        // 3 根够算"三根形态"的形状，但**不够判趋势语境**（要至少 1 根前置）→ 一律 nil
        XCTAssertNil(KLinePatterns.detect([flatBar(10), flatBar(11), flatBar(12)]))
        XCTAssertNotNil(KLinePatterns.detect(downBase))
    }

    /// 一字板（全幅 0）：不应被当成"窄幅整理"，也不应命中任何形态
    func testLimitUpFlatBarProducesNoPattern() {
        let bars = flatBase + [k(10, 10, 10, 10)]
        XCTAssertEqual(shapes(bars), [])
    }

    /// 两种输入类型（引擎的 `KLineBar` / 详情页的 `KLineItem`）必须给出**完全相同**的结果
    func testBothInputTypesAgree() {
        let engineBars = downBase + [k(22, 22.1, 19.9, 20.0), k(19.8, 22.5, 19.6, 22.3)]
        let chartItems = engineBars.map {
            KLineItem(date: $0.day, open: $0.open, high: $0.high,
                      low: $0.low, close: $0.close, volume: $0.volume)
        }
        let a = KLinePatterns.detect(engineBars)
        let b = KLinePatterns.detect(chartItems)
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertEqual(a?.shapes, b?.shapes)
        XCTAssertEqual(a?.trend, b?.trend)
        XCTAssertEqual(a?.hits.map(\.note), b?.hits.map(\.note))
    }

    // MARK: - 趋势语境：同一形状，两个名字

    /// 锤头 / 上吊线：形状完全相同，只有前序趋势不同
    func testHammerVsHangingManDependsOnTrend() {
        // 长下影 + 小实体（实体 0.3 / 全幅 1.35 = 22%，下影 1.0 = 3.3× 实体）
        let shape = k(10.0, 10.35, 9.0, 10.3)

        let down = KLinePatterns.detect(downBase + [shape])
        XCTAssertEqual(down?.shapes, ["hammer"])
        XCTAssertEqual(down?.hits.first?.name, "锤头")
        XCTAssertEqual(down?.hits.first?.direction, .bullish)
        XCTAssertEqual(down?.trend, .down)

        let up = KLinePatterns.detect(upBase + [shape])
        XCTAssertEqual(up?.shapes, ["hammer"])
        XCTAssertEqual(up?.hits.first?.name, "上吊线")
        XCTAssertEqual(up?.hits.first?.direction, .bearish)
        XCTAssertEqual(up?.trend, .up)
    }

    /// 趋势走平时**不出**语境形态 —— 硬按一个方向命名等于编造信号
    func testContextShapeIsSilentWhenTrendIsFlat() {
        let shape = k(10.0, 10.35, 9.0, 10.3)
        XCTAssertEqual(shapes(flatBase + [shape]), [])
    }

    func testInvertedHammerVsShootingStar() {
        let shape = k(10.0, 11.0, 9.65, 9.7)

        let down = KLinePatterns.detect(downBase + [shape])
        XCTAssertEqual(down?.shapes, ["inverted_hammer"])
        XCTAssertEqual(down?.hits.first?.name, "倒锤头")
        XCTAssertEqual(down?.hits.first?.direction, .bullish)

        let up = KLinePatterns.detect(upBase + [shape])
        XCTAssertEqual(up?.shapes, ["inverted_hammer"])
        XCTAssertEqual(up?.hits.first?.name, "射击之星")
        XCTAssertEqual(up?.hits.first?.direction, .bearish)
    }

    // MARK: - 三根形态

    func testMorningStar() {
        let bars = downBase + [
            k(22.0, 22.1, 19.9, 20.0),   // 大阴（实体 2.0 / 全幅 2.2 = 91%）
            k(19.5, 19.7, 19.3, 19.4),   // 小实体（10%），收盘更低
            k(19.6, 21.25, 19.4, 21.2),  // 阳线收回前阴实体上半（中点 21.0）
        ]
        let r = KLinePatterns.detect(bars)
        XCTAssertEqual(r?.shapes, ["star"])
        XCTAssertEqual(r?.hits.first?.name, "早晨之星")
        XCTAssertEqual(r?.hits.first?.direction, .bullish)
        XCTAssertEqual(r?.hits.first?.bars, 3)
    }

    func testEveningStar() {
        let bars = upBase + [
            k(18.0, 20.1, 17.9, 20.0),   // 大阳
            k(20.5, 20.75, 20.4, 20.6),  // 小实体（29%），收盘更高
            k(20.3, 20.5, 18.5, 18.6),   // 阴线跌回前阳实体下半（中点 19.0）
        ]
        let r = KLinePatterns.detect(bars)
        XCTAssertEqual(r?.shapes, ["star"])
        XCTAssertEqual(r?.hits.first?.name, "黄昏之星")
        XCTAssertEqual(r?.hits.first?.direction, .bearish)
    }

    /// 早晨之星的分支判据：第三根必须**收回前一根阴线实体的上半**
    func testMorningStarRequiresRecoveryAbovePriorMid() {
        // 第三根只收到 20.9（中点 21.0 之下）→ 不算早晨之星
        let bars = downBase + [
            k(22.0, 22.1, 19.9, 20.0),
            k(19.5, 19.7, 19.3, 19.4),
            k(19.6, 21.0, 19.5, 20.9),
        ]
        XCTAssertFalse(shapes(bars).contains("star"))
    }

    func testThreeWhiteSoldiers() {
        let bars = downBase + [
            k(21.0, 22.1, 20.9, 22.0),
            k(21.5, 23.1, 21.4, 23.0),
            k(22.5, 24.1, 22.4, 24.0),
        ]
        let r = KLinePatterns.detect(bars)
        XCTAssertEqual(r?.shapes, ["three_soldiers"])
        XCTAssertEqual(r?.hits.first?.name, "三个白兵")
        XCTAssertEqual(r?.hits.first?.direction, .bullish)
    }

    /// 三个白兵要求"每根都开在前一根实体内" —— 大幅跳空高开就不算了
    func testThreeWhiteSoldiersRejectsGappingOpen() {
        let bars = downBase + [
            k(21.0, 22.1, 20.9, 22.0),
            k(22.5, 23.1, 22.4, 23.0),   // 开在 22.5 > 前一根收盘 22.0（跳空）
            k(23.5, 24.1, 23.4, 24.0),
        ]
        XCTAssertFalse(shapes(bars).contains("three_soldiers"))
    }

    // MARK: - 两日形态

    func testPiercingLine() {
        let bars = downBase + [
            k(22.0, 22.1, 19.9, 20.0),   // 阴线（实体中点 21.0）
            k(19.5, 21.5, 19.3, 21.3),   // 低开阳线，收进上半但未吞没
        ]
        let r = KLinePatterns.detect(bars)
        XCTAssertEqual(r?.shapes, ["piercing"])
        XCTAssertEqual(r?.hits.first?.name, "曙光初现")
        XCTAssertEqual(r?.hits.first?.direction, .bullish)
        XCTAssertEqual(r?.hits.first?.bars, 2)
    }

    func testDarkCloudCover() {
        let bars = upBase + [
            k(18.0, 20.1, 17.9, 20.0),   // 阳线（实体中点 19.0）
            k(20.5, 20.7, 18.5, 18.7),   // 高开阴线，跌破下半但未吞没
        ]
        let r = KLinePatterns.detect(bars)
        XCTAssertEqual(r?.shapes, ["piercing"])
        XCTAssertEqual(r?.hits.first?.name, "乌云盖顶")
        XCTAssertEqual(r?.hits.first?.direction, .bearish)
    }

    /// 曙光初现与**阳包阴**的分界就在"有没有吞没"：收盘越过前一根开盘 → 归吞没，不归曙光
    func testPiercingStopsWhereEngulfingBegins() {
        let bars = downBase + [
            k(22.0, 22.1, 19.9, 20.0),
            k(19.5, 22.5, 19.4, 22.3),   // 收盘 22.3 > 前阴开盘 22.0 → 吞没
        ]
        XCTAssertEqual(shapes(bars), ["engulfing"])
    }

    func testBullishEngulfing() {
        let bars = downBase + [
            k(22.0, 22.1, 19.9, 20.0),
            k(19.8, 22.5, 19.6, 22.3),
        ]
        let r = KLinePatterns.detect(bars)
        XCTAssertEqual(r?.shapes, ["engulfing"])
        XCTAssertEqual(r?.hits.first?.name, "穿头破脚（阳包阴）")
        XCTAssertEqual(r?.hits.first?.direction, .bullish)
        XCTAssertEqual(r?.bias, 1)
    }

    func testBearishEngulfing() {
        let bars = upBase + [
            k(18.0, 20.1, 17.9, 20.0),
            k(20.2, 20.5, 17.5, 17.8),
        ]
        let r = KLinePatterns.detect(bars)
        XCTAssertEqual(r?.shapes, ["engulfing"])
        XCTAssertEqual(r?.hits.first?.name, "穿头破脚（阴包阳）")
        XCTAssertEqual(r?.hits.first?.direction, .bearish)
        XCTAssertEqual(r?.bias, -1)
    }

    func testHaramiIsNeutral() {
        let bars = downBase + [
            k(22.0, 22.1, 18.9, 19.0),   // 大阴（实体 3.0）
            k(20.5, 20.8, 20.0, 20.2),   // 小实体完全孕于其中
        ]
        let r = KLinePatterns.detect(bars)
        XCTAssertEqual(r?.shapes, ["harami"])
        XCTAssertEqual(r?.hits.first?.direction, .neutral)
        XCTAssertEqual(r?.bias, 0)
    }

    // MARK: - 单根形态族

    func testDojiFamilyIsPartitioned() {
        // 普通十字星：两侧都有影
        let doji = downBase + [k(10.0, 10.3, 9.7, 10.02)]
        XCTAssertEqual(shapes(doji), ["doji"])
        XCTAssertEqual(KLinePatterns.detect(doji)?.hits.first?.direction, .neutral)

        // 蜻蜓十字：上影≈0 + 长下影
        let dragonfly = downBase + [k(10.0, 10.02, 9.4, 10.01)]
        XCTAssertEqual(shapes(dragonfly), ["dragonfly"])
        XCTAssertEqual(KLinePatterns.detect(dragonfly)?.hits.first?.name, "蜻蜓十字")
        XCTAssertEqual(KLinePatterns.detect(dragonfly)?.hits.first?.direction, .bullish)

        // 墓碑十字：下影≈0 + 长上影
        let gravestone = upBase + [k(10.0, 10.6, 9.98, 9.99)]
        XCTAssertEqual(shapes(gravestone), ["dragonfly"])
        XCTAssertEqual(KLinePatterns.detect(gravestone)?.hits.first?.name, "墓碑十字")
        XCTAssertEqual(KLinePatterns.detect(gravestone)?.hits.first?.direction, .bearish)
    }

    func testMarubozu() {
        let bull = downBase + [k(10.0, 10.81, 9.99, 10.8)]
        XCTAssertEqual(shapes(bull), ["marubozu"])
        XCTAssertEqual(KLinePatterns.detect(bull)?.hits.first?.name, "光头光脚阳线")
        XCTAssertEqual(KLinePatterns.detect(bull)?.hits.first?.direction, .bullish)

        let bear = upBase + [k(10.8, 10.81, 9.99, 10.0)]
        XCTAssertEqual(shapes(bear), ["marubozu"])
        XCTAssertEqual(KLinePatterns.detect(bear)?.hits.first?.name, "光头光脚阴线")
        XCTAssertEqual(KLinePatterns.detect(bear)?.hits.first?.direction, .bearish)
    }

    func testSpinningTop() {
        let bars = downBase + [k(10.0, 10.7, 9.5, 10.2)]
        let r = KLinePatterns.detect(bars)
        XCTAssertEqual(r?.shapes, ["spinning_top"])
        XCTAssertEqual(r?.hits.first?.direction, .neutral)
    }

    func testNarrowRangeUsesPriorAverage() {
        // 前置全幅恒 0.4；当日全幅 0.15 = 均值的 37.5%
        let bars = flatBase + [k(10.0, 10.075, 9.925, 10.06)]
        let r = KLinePatterns.detect(bars)
        XCTAssertEqual(r?.shapes, ["narrow_range"])
        XCTAssertEqual(r?.hits.first?.name, "窄幅整理")
        XCTAssertEqual(r?.hits.first?.direction, .neutral)
    }

    /// 当日全幅与前 5 日均值持平 → 不算窄幅
    func testNormalRangeIsNotNarrow() {
        let bars = flatBase + [k(10.0, 10.2, 9.8, 10.1)]
        XCTAssertFalse(shapes(bars).contains("narrow_range"))
    }

    // MARK: - 尾部未形成 bar

    /// 开盘前的"当日占位 bar"（high/low 全 0）必须被剔除 —— 否则 12 个形态全落在一条假 K 线上
    func testDropUnformedTailRemovesPreOpenBar() {
        let placeholder = k(0, 0, 0, 0)
        let bars = downBase + [k(10.0, 10.35, 9.0, 10.3), placeholder]

        // 不剔除 → 当前根是那条全零 bar，一个形态都不出（而且不报错）
        XCTAssertEqual(shapes(bars), [])
        // 剔除后 → 正确地落在真实的那根长下影上
        let cleaned = KLinePatterns.dropUnformedTail(bars)
        XCTAssertEqual(cleaned.count, bars.count - 1)
        XCTAssertEqual(shapes(cleaned), ["hammer"])
    }

    /// 只剔**尾部**：中间的停牌零值 bar 是历史事实，剔掉会让两日形态跨停牌拼接
    func testDropUnformedTailKeepsInteriorZeroBars() {
        let bars = downBase + [k(0, 0, 0, 0), k(10.0, 10.35, 9.0, 10.3)]
        XCTAssertEqual(KLinePatterns.dropUnformedTail(bars).count, bars.count)
    }

    /// `high < low` 这种脏数据同样按"未形成"处理
    func testDropUnformedTailRemovesInvertedRange() {
        let bars = downBase + [k(10, 9.0, 10.0, 9.5)]
        XCTAssertEqual(KLinePatterns.dropUnformedTail(bars).count, bars.count - 1)
    }

    /// 全是垃圾 → 剔完为空（调用方据此走空态，而不是拿空数组去 detect）
    func testDropUnformedTailCanEmptyEverything() {
        let bars = [k(0, 0, 0, 0), k(0, 0, 0, 0)]
        XCTAssertTrue(KLinePatterns.dropUnformedTail(bars).isEmpty)
    }

    // MARK: - 覆盖性护栏

    /// `definitions` 里的 12 个形状**必须每个都能被真实 K 线命中**
    ///
    /// 这是本模块的覆盖性护栏：往 `definitions` 加一项而不加实现，这条立刻红
    /// （与参数中心 specs 的覆盖性护栏同一手法）。
    func testEveryDefinedShapeIsReachable() {
        let cases: [String: [KLineBar]] = [
            "hammer": downBase + [k(10.0, 10.35, 9.0, 10.3)],
            "inverted_hammer": downBase + [k(10.0, 11.0, 9.65, 9.7)],
            "star": downBase + [k(22.0, 22.1, 19.9, 20.0), k(19.5, 19.7, 19.3, 19.4),
                                k(19.6, 21.25, 19.4, 21.2)],
            "piercing": downBase + [k(22.0, 22.1, 19.9, 20.0), k(19.5, 21.5, 19.3, 21.3)],
            "engulfing": downBase + [k(22.0, 22.1, 19.9, 20.0), k(19.8, 22.5, 19.6, 22.3)],
            "harami": downBase + [k(22.0, 22.1, 18.9, 19.0), k(20.5, 20.8, 20.0, 20.2)],
            "three_soldiers": downBase + [k(21.0, 22.1, 20.9, 22.0), k(21.5, 23.1, 21.4, 23.0),
                                          k(22.5, 24.1, 22.4, 24.0)],
            "doji": downBase + [k(10.0, 10.3, 9.7, 10.02)],
            "dragonfly": downBase + [k(10.0, 10.02, 9.4, 10.01)],
            "marubozu": downBase + [k(10.0, 10.81, 9.99, 10.8)],
            "spinning_top": downBase + [k(10.0, 10.7, 9.5, 10.2)],
            "narrow_range": flatBase + [k(10.0, 10.075, 9.925, 10.06)],
        ]
        let declared = KLinePatterns.definitions.map(\.shape)
        XCTAssertEqual(declared.count, 12, "清单项数变了，同步更新覆盖性断言")
        XCTAssertEqual(Set(declared), Set(cases.keys), "definitions 与用例集合必须一一对应")

        for shape in declared {
            let bars = cases[shape]!
            XCTAssertTrue(shapes(bars).contains(shape),
                          "形状 \(shape) 无法被命中 —— definitions 里有它但实现里没有")
        }
    }

    /// 语境形态之外的 8 个形状在**任何趋势下**都应能出（不依赖语境）
    func testContextFreeShapesIgnoreTrend() {
        for shape in KLinePatterns.contextFreeShapes {
            XCTAssertTrue(KLinePatterns.definitions.map(\.shape).contains(shape),
                          "\(shape) 不在 definitions 里")
        }
        // 语境形态**不在** contextFree 里
        for shape in ["hammer", "inverted_hammer", "star", "piercing"] {
            XCTAssertFalse(KLinePatterns.contextFreeShapes.contains(shape),
                           "\(shape) 是语境形态，不该进 contextFreeShapes")
        }
    }

    // MARK: - 反证：把阈值/守卫弄坏，必须能看出问题

    /// 反证一：放宽 `dojiBodyRatio` 会把「锤头」**改名**成「蜻蜓十字」——
    /// 说明"实体比值守卫"真的在决定归哪一类，不是摆设。
    func testRelaxingDojiGuardRenamesHammerToDragonfly() {
        let bars = downBase + [k(10.0, 10.35, 9.0, 10.3)]
        XCTAssertEqual(shapes(bars), ["hammer"])

        var relaxed = PatternConfig()
        relaxed.dojiBodyRatio = 0.25          // 实体 22% 现在也算"十字星族"
        let after = KLinePatterns.detect(bars, config: relaxed)
        XCTAssertEqual(after?.shapes, ["dragonfly"], "守卫失效后应改判为蜻蜓十字")
    }

    /// 反证二：`dojiBodyRatio` 是**四个判据共用的边界**（锤头 / 倒锤头 / 纺锤的"实体不小"守卫
    /// + 十字星族的"实体很小"入口）→ 放宽它**不会**让两个形态同时命中，而是把
    /// **纺锤直接改名成十字星**。
    ///
    /// 结论：**同一个阈值既是入口又是守卫，所以调它只会"改名"不会"重复"**。
    func testRelaxingDojiGuardRenamesSpinningTopToDoji() {
        let bars = downBase + [k(10.0, 10.7, 9.5, 10.2)]
        XCTAssertEqual(shapes(bars), ["spinning_top"])

        var relaxed = PatternConfig()
        relaxed.dojiBodyRatio = 0.2           // 实体 16.7% 现在也算"十字星族"
        let after = KLinePatterns.detect(bars, config: relaxed)
        XCTAssertEqual(after?.shapes, ["doji"], "放宽后应改判为十字星，而不是两个都出")
        XCTAssertEqual(after?.hits.first?.direction, .neutral)
    }

    /// 反证三：把趋势回看窗口改成 1 根，"锤头 vs 上吊线"的判定会随语境翻转 ——
    /// 说明 `trendLookback` 真的参与定名。
    func testTrendLookbackChangesContextName() {
        // 前置 5 根下跌 + 1 根大反弹（22 → 30），当日长下影小实体
        let bars = downBase + [k(22.0, 30.2, 21.9, 30.0), k(30.0, 30.35, 29.0, 30.3)]

        var look5 = PatternConfig(); look5.trendLookback = 5
        var look1 = PatternConfig(); look1.trendLookback = 1

        // 回看 5 根：均线被前面的下跌拖低 → 收盘 30 > 均线 → 上涨语境 → 上吊线
        XCTAssertEqual(KLinePatterns.detect(bars, config: look5)?.trend, .up)
        XCTAssertEqual(KLinePatterns.detect(bars, config: look5)?.hits.first?.name, "上吊线")

        // 回看 1 根：只看上一根收盘 30.0 vs 当日前置…… 均线 = 30.0 → 走平 → 不出语境形态
        let r1 = KLinePatterns.detect(bars, config: look1)
        XCTAssertEqual(r1?.trend, .flat)
        XCTAssertEqual(r1?.shapes, [])
    }
}

// MARK: - 打分（`scoring.patterns`）

/// `PatternScoreConfig` 的契约测试。
///
/// 这里钉的是**两件事**，都很容易静默出错：
///   ① **出厂默认必须关闭** —— 形态方向尚未标定，开着就是凭直觉给分
///   ② **读取处回落值必须与工厂默认值逐字一致** —— 否则"参数没配"与"配了默认值"
///      会给出不同结果（参数系统那条「工厂参数 + 读取处回落默认值」的硬要求）
final class PatternScoreConfigTests: XCTestCase {

    private func cfg(_ d: [String: Any]) -> PatternScoreConfig {
        PatternScoreConfig.from(["scoring": ["patterns": d]])
    }

    // MARK: - 默认值

    /// 出厂默认关闭（这条红了说明有人把形态打分默认打开了 —— 那是标定后才能做的事）
    func testDefaultIsDisabled() {
        XCTAssertFalse(PatternScoreConfig().enabled, "形态打分必须出厂默认关闭")
        XCTAssertFalse(PatternScoreConfig.from(nil).enabled)
        XCTAssertFalse(PatternScoreConfig.from([:]).enabled)
        XCTAssertFalse(PatternScoreConfig.from(["scoring": [:]]).enabled)
        XCTAssertFalse(cfg([:]).enabled)
    }

    func testDefaults() {
        let c = PatternScoreConfig()
        XCTAssertEqual(c.bullishScore, 6)
        XCTAssertEqual(c.bearishScore, -6)
        XCTAssertEqual(c.neutralScore, 0, "中性形态默认不给分（方向本身不是信号）")
        XCTAssertEqual(c.cap, 12)
    }

    // MARK: - 读取与回落

    func testReadsAllKeys() {
        let c = cfg(["enabled": true, "bullish_score": 9, "bearish_score": -9,
                     "neutral_score": 2, "cap": 30])
        XCTAssertTrue(c.enabled)
        XCTAssertEqual(c.bullishScore, 9)
        XCTAssertEqual(c.bearishScore, -9)
        XCTAssertEqual(c.neutralScore, 2)
        XCTAssertEqual(c.cap, 30)
    }

    /// 逐键回落：只配了 `enabled`，其余必须仍是默认值（而不是归零）
    func testPartialParamsFallBackPerKey() {
        let c = cfg(["enabled": true])
        XCTAssertTrue(c.enabled)
        XCTAssertEqual(c.bullishScore, 6)
        XCTAssertEqual(c.bearishScore, -6)
        XCTAssertEqual(c.neutralScore, 0)
        XCTAssertEqual(c.cap, 12)
    }

    /// 识别阈值同样逐键回落，且与 `PatternConfig()` 的默认值一致
    func testConfigFromParamsMatchesPlainDefaults() {
        XCTAssertEqual(KLinePatterns.config(from: nil), PatternConfig())
        XCTAssertEqual(KLinePatterns.config(from: [:]), PatternConfig())
        XCTAssertEqual(KLinePatterns.config(from: ["scoring": [:]]), PatternConfig())
        let c = KLinePatterns.config(from: ["scoring": ["patterns": ["shadow_ratio": 3.0]]])
        var want = PatternConfig(); want.shadowRatio = 3.0
        XCTAssertEqual(c, want)
    }

    // MARK: - 计分

    private func hit(_ shape: String, _ name: String, _ d: PatternDirection) -> PatternHit {
        PatternHit(shape: shape, name: name, direction: d, note: "测试", bars: 1)
    }

    private func result(_ hits: [PatternHit]) -> PatternResult {
        PatternResult(hits: hits, barsUsed: 5, trend: .down)
    }

    func testNeutralHitsDoNotScoreButBullishDo() {
        let c = cfg(["enabled": true])
        let r = result([hit("hammer", "锤头", .bullish), hit("doji", "十字星", .neutral)])
        let (delta, names) = c.score(r)
        XCTAssertEqual(delta, 6, "中性形态默认 0 分，不应拉低看多的分")
        XCTAssertEqual(names, ["锤头"], "0 分的形态不写明细（与 scoring.intraday 同一约定）")
    }

    func testBearishHitIsNegativeAndListedInPenalties() {
        let c = cfg(["enabled": true])
        let (delta, names) = c.score(result([hit("hammer", "上吊线", .bearish)]))
        XCTAssertEqual(delta, -6)
        XCTAssertEqual(names, ["上吊线"])
    }

    func testCapClampsBothDirections() {
        let c = cfg(["enabled": true, "cap": 10])
        let three = (0..<3).map { hit("hammer", "锤头\($0)", .bullish) }
        XCTAssertEqual(c.score(result(three)).delta, 10, "三个看多 × 6 = 18 应被 cap 截到 10")

        let bearish = (0..<3).map { hit("hammer", "上吊线\($0)", .bearish) }
        XCTAssertEqual(c.score(result(bearish)).delta, -10)
    }

    /// `cap = 0` 视为"不设上限"（与 `deep_budget_sec` 一类"0 = 不限"的既有约定一致）
    func testZeroCapMeansUnlimited() {
        let c = cfg(["enabled": true, "cap": 0])
        let five = (0..<5).map { hit("hammer", "锤头\($0)", .bullish) }
        XCTAssertEqual(c.score(result(five)).delta, 30)
    }

    func testNoHitsScoresZero() {
        let c = cfg(["enabled": true])
        let (delta, names) = c.score(result([]))
        XCTAssertEqual(delta, 0)
        XCTAssertTrue(names.isEmpty)
    }

    /// 看多与看空同时命中 → 相互抵消（形态学上确实会同时出现，如"长下影"配"阴包阳"）
    func testMixedDirectionsCancel() {
        let c = cfg(["enabled": true])
        let r = result([hit("hammer", "锤头", .bullish), hit("engulfing", "穿头破脚（阴包阳）", .bearish)])
        XCTAssertEqual(c.score(r).delta, 0)
    }

    // MARK: - 差分：开关真的接进打分了吗（不是死代码）

    /// 同一个输入跑两次，**只差 `patterns.enabled`** → 分数与明细的差必须**恰好**是形态那一项。
    ///
    /// 这条是"开关真的接进打分"的**直接证据**（没有它，`scoreStock` 里那段可能根本没被执行过）。
    /// 同时它也是"关闭时逐字复现旧行为"的证据：`off` 那一次不该出现任何 `K线形态` 明细。
    func testEnabledSwitchChangesScoreByExactlyThePatternTerm() {
        let hits = [hit("hammer", "锤头", .bullish)]
        let p = result(hits)

        var sc: [String: Any] = ["bonus": [String: Any](), "penalty": [String: Any](),
                                 "tier_lock": ["enabled": false]]
        sc["patterns"] = ["enabled": false]
        let off = runScore(params: ["scoring": sc], patterns: p)

        sc["patterns"] = ["enabled": true]
        let on = runScore(params: ["scoring": sc], patterns: p)

        XCTAssertEqual(on.score - off.score, 6, "开启后分数应恰好 +6（看多默认分）")
        XCTAssertFalse(off.details.contains { $0.hasPrefix("K线形态") },
                       "关闭时不该出现任何形态明细 —— 这就是「逐字复现旧行为」")
        XCTAssertEqual(on.details.filter { $0.hasPrefix("K线形态") }, ["K线形态 锤头 +6"])
        XCTAssertEqual(on.details.count, off.details.count + 1, "只应多出形态这一条")
        XCTAssertEqual(on.penalties, off.penalties, "看多不该产生扣分明细")
    }

    /// 看空形态走**扣分明细**（与"前日大涨/放量滞涨"同一条通道）
    func testBearishPatternGoesToPenaltyDetails() {
        var sc: [String: Any] = ["bonus": [String: Any](), "penalty": [String: Any](),
                                 "tier_lock": ["enabled": false],
                                 "patterns": ["enabled": true]]
        let p = result([hit("hammer", "上吊线", .bearish)])
        let r = runScore(params: ["scoring": sc], patterns: p)
        XCTAssertEqual(r.score, -6)
        XCTAssertEqual(r.penalties.filter { $0.hasPrefix("K线形态") }, ["K线形态 上吊线 -6"])
        XCTAssertFalse(r.details.contains { $0.hasPrefix("K线形态") })
        sc["patterns"] = ["enabled": false]
        XCTAssertEqual(runScore(params: ["scoring": sc], patterns: p).score, 0)
    }

    /// `patterns = nil`（例如 K 线不足）时即便开关打开也不该崩、不该加分
    func testNilPatternsIsSafeWhenEnabled() {
        let r = runScore(params: ["scoring": ["bonus": [String: Any](), "penalty": [String: Any](),
                                              "tier_lock": ["enabled": false],
                                              "patterns": ["enabled": true]]],
                         patterns: nil)
        XCTAssertEqual(r.score, 0)
    }

    // MARK: - 打分辅助

    private struct ScoreOut { let score: Int; let details: [String]; let penalties: [String] }

    private func runScore(params: [String: Any], patterns: PatternResult?) -> ScoreOut {
        var q = EngineQuote()
        q.code = "600000"; q.name = "测试"; q.price = 10; q.preClose = 10; q.volumeRatio = 1
        let d = DeepInfo(ma5: 10, ma10: 10, ma20: 10, maPass: true, volMult5d: 1.0,
                         consecUp: 0, cum5d: 0, prev1d: 0, distFromLow: 5, distFromHigh: -5,
                         ma20SlopeUp: false, maDeviation: 0, gainRatio: 1, shadowBodyRatio: 0)
        var meta: [String: Any] = [:]
        let (score, details, penalties) = Screener.scoreStock(
            quote: q, deep: d, intraday: nil, patterns: patterns,
            formScore: 0, marketEnv: [:], params: params, meta: &meta)
        let n = (score as? Int) ?? Int((score as? Double) ?? 0)
        return ScoreOut(score: n, details: details, penalties: penalties)
    }

    // MARK: - 护栏：工厂默认值 ≡ 读取处回落值

    /// **工厂参数里的默认值必须与 Swift 的回落值逐字一致**。
    ///
    /// 这两处一旦漂移，症状是：用出厂版本时是一个行为、用新建版本时是另一个行为，
    /// 而且**两边各自都自洽**、没有任何报错。这条断言把两处钉在一起。
    func testFactoryDefaultMatchesSwiftFallback() throws {
        // 读不到 → **失败**（不是 `XCTSkip`）：该 JSON 随仓库提供且是随包资源
        try EntityTestSupport.requireParamSchema()
        let factory = ParamSchema.shared.factoryParams
        guard let pat = (factory["scoring"] as? [String: Any])?["patterns"] as? [String: Any] else {
            XCTFail("工厂参数里没有 scoring.patterns —— 新库/新版本将拿不到它")
            return
        }
        let c = PatternScoreConfig()
        XCTAssertEqual(pat["enabled"] as? Bool, c.enabled,
                       "工厂默认 enabled 与 Swift 回落值不一致")
        XCTAssertFalse(pat["enabled"] as? Bool ?? true,
                       "⚠ 工厂里的形态打分默认必须是关闭的（方向尚未标定）")
        XCTAssertEqual(pat["bullish_score"] as? Int, c.bullishScore)
        XCTAssertEqual(pat["bearish_score"] as? Int, c.bearishScore)
        XCTAssertEqual(pat["neutral_score"] as? Int, c.neutralScore)
        XCTAssertEqual(pat["cap"] as? Int, c.cap)
    }

    /// 形态打分**刻意不声明为 schema 项**（同 `iterate.tune_pool_days`）：
    /// 声明了会让所有存量参数版本立即非法（`validate` 对"键缺失"一律报错）。
    /// 若将来标定通过要暴露到参数中心，按 `regime_thresholds` 那条路走
    /// （升格 schema 项 + Swift-only 补种迁移），届时这条断言要一并改。
    func testPatternsAreNotASchemaItem() throws {
        try EntityTestSupport.requireParamSchema()
        let keys = ParamSchema.shared.allItems.map(\.key)
        XCTAssertFalse(keys.contains("scoring.patterns"),
                       "scoring.patterns 不该是 schema 项 —— 会成为新的存量版本杀手")
        XCTAssertFalse(keys.contains(where: { $0.hasPrefix("scoring.patterns.") }),
                       "scoring.patterns 的子键也不该是 schema 项")
    }
}
