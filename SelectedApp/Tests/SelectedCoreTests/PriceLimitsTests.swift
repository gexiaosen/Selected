import XCTest
@testable import SelectedCore

/// 涨跌停 / 异动判定。
///
/// 这个文件的核心是**板块分档**与**指数哨兵值**两条 —— 它们都是"写错了不报错、
/// 只是结论反了"的地方。表里的比例全部来自真实请求实测。
final class PriceLimitsTests: XCTestCase {

    // MARK: - 板块分档（表驱动，比例取自实测）

    /// 「涨停价 ÷ 昨收」的实测值：主板 1.100 / 创业板·科创板 1.200 / 北交所 1.300 / ST 1.100。
    ///
    /// 本用例**故意用"某个比例"而不是"某只票"**：判据必须只依赖腾讯给的价格，
    /// 一旦有人把"跌幅 > 9.5%"或"ST 是 ±5%"这类档位表写进代码，这里就会红。
    func testLimitUpAcrossBoardsUsesTheGivenPricesOnly() {
        let cases: [(name: String, preClose: Double, upRatio: Double, downRatio: Double)] = [
            ("沪主板", 1252.57, 1.100, 0.900),
            ("深主板", 11.73, 1.100, 0.900),
            ("创业板", 297.10, 1.200, 0.800),
            ("科创板", 223.59, 1.200, 0.800),
            ("北交所", 3.03, 1.300, 0.700),      // ⚠ 常识里没有这一档
            ("ST（实测已是 ±10%）", 18.78, 1.100, 0.900),
        ]
        for c in cases {
            let up = PyMath.round(c.preClose * c.upRatio, 2)
            let dn = PyMath.round(c.preClose * c.downRatio, 2)
            let atUp = PriceLimits.verdict(price: up, open: up, high: up, low: up - 0.5,
                                           changePct: 10, amountWan: 1000,
                                           limitUp: up, limitDown: dn, volMult5d: nil)
            XCTAssertTrue(atUp.anomalies.contains(.limitUp), "\(c.name)：应判涨停")
            XCTAssertEqual(atUp.limitUp, up, "\(c.name)：有效涨停价应原样带出")

            let atDn = PriceLimits.verdict(price: dn, open: dn, high: dn + 0.5, low: dn,
                                           changePct: -10, amountWan: 1000,
                                           limitUp: up, limitDown: dn, volMult5d: nil)
            XCTAssertTrue(atDn.anomalies.contains(.limitDown), "\(c.name)：应判跌停")
        }
    }

    /// 不在板上的普通涨跌 → 一条都不命中
    func testOrdinaryMoveHitsNothing() {
        let v = PriceLimits.verdict(price: 10.5, open: 10.1, high: 10.6, low: 10.0,
                                    changePct: 3.2, amountWan: 5000,
                                    limitUp: 10.78, limitDown: 8.82, volMult5d: 1.5)
        XCTAssertTrue(v.isEmpty, "普通上涨不该命中：\(v.summary)")
        XCTAssertEqual(v.limitUp, 10.78, "没命中也要带出有效涨跌停价（卡上要显示）")
    }

    // MARK: - 指数哨兵值（最容易埋进代码的坑）

    /// 腾讯对**指数**返回 `limitUp = limitDown = -1`。
    /// 若不先判 `> 0`，`price >= -1` 恒真 → **每一条指数都会被判成"涨停"**。
    func testIndexSentinelMinusOneMustNotBeTreatedAsLimit() {
        let idx = PriceLimits.verdict(price: 3949.91, open: 3960, high: 3975, low: 3940,
                                      changePct: 0.12, amountWan: 500_000,
                                      limitUp: -1, limitDown: -1, volMult5d: nil)
        XCTAssertFalse(idx.anomalies.contains(.limitUp), "指数不能被判成涨停（哨兵值 -1）")
        XCTAssertFalse(idx.anomalies.contains(.limitDown))
        XCTAssertFalse(idx.anomalies.contains(.oneWordBoard))
        XCTAssertNil(idx.limitUp, "哨兵值要折成 nil，而不是把 -1 显示给用户")
        XCTAssertNil(idx.limitDown)
    }

    /// `effectiveLimit` 的三条分支
    func testEffectiveLimitFiltersSentinelAndInvalid() {
        XCTAssertNil(PriceLimits.effectiveLimit(nil))
        XCTAssertNil(PriceLimits.effectiveLimit(-1))
        XCTAssertNil(PriceLimits.effectiveLimit(0))
        XCTAssertEqual(PriceLimits.effectiveLimit(0.01), 0.01, "正数原样返回（北交所低价股可能只有几分）")
        XCTAssertEqual(PriceLimits.effectiveLimit(1393.68), 1393.68)
    }

    /// 港股没有涨跌停（解析时已留空）→ 只能命中"放量下跌"
    func testHKMovingWithoutLimitsNeverHitsLimitAnomalies() {
        let hk = PriceLimits.verdict(price: 419, open: 428, high: 430.4, low: 419,
                                     changePct: -1.64, amountWan: 1_218_078,
                                     limitUp: nil, limitDown: nil, volMult5d: 1.85)
        XCTAssertTrue(hk.isEmpty, "港股没有涨跌停，不该命中：\(hk.summary)")
    }

    // MARK: - 一字板

    /// 开 = 收 = 高 = 低，**且**停在板上 → 一字板
    func testOneWordBoardRequiresFlatPricesAndALimit() {
        let v = PriceLimits.verdict(price: 11.03, open: 11.03, high: 11.03, low: 11.03,
                                    changePct: 10.0, amountWan: 300,
                                    limitUp: 11.03, limitDown: 9.03, volMult5d: nil)
        XCTAssertTrue(v.anomalies.contains(.oneWordBoard))
        XCTAssertTrue(v.anomalies.contains(.limitUp), "一字板同时也在涨停（两条都报）")
    }

    /// **四个价相等但不在板上** → 不是一字板（这是"全天停牌"或数据异常的形状）
    func testFlatPricesWithoutLimitIsNotOneWordBoard() {
        let v = PriceLimits.verdict(price: 10.0, open: 10.0, high: 10.0, low: 10.0,
                                    changePct: 0, amountWan: 0,
                                    limitUp: 11.0, limitDown: 9.0, volMult5d: nil)
        XCTAssertFalse(v.anomalies.contains(.oneWordBoard), "停牌不该被说成一字板")
        XCTAssertTrue(v.isEmpty)
    }

    /// 开=高=低 但**收**不在板上（涨停被砸开）→ 不是一字板
    func testOpenHighLowFlatButCloseOffLimitIsNotOneWordBoard() {
        let v = PriceLimits.verdict(price: 10.50, open: 11.00, high: 11.00, low: 11.00,
                                    changePct: 9.7, amountWan: 300_000,
                                    limitUp: 11.00, limitDown: 9.00, volMult5d: 2.0)
        XCTAssertFalse(v.anomalies.contains(.oneWordBoard), "开=高=低 但收盘不在板上，不是一字板")
    }

    /// 价格无效（停牌 / 数据源异常）→ 不做涨跌停判定
    func testZeroPriceSkipsLimitJudgement() {
        let v = PriceLimits.verdict(price: 0, open: 0, high: 0, low: 0,
                                    changePct: 0, amountWan: 0,
                                    limitUp: 11.0, limitDown: 9.0, volMult5d: nil)
        XCTAssertTrue(v.isEmpty)
    }

    // MARK: - 放量大跌（三条件齐备才判）

    func testHeavyVolumeDownRequiresAllThreeConditions() {
        func judge(pct: Double, amount: Double, vm: Double?) -> [PriceLimits.Anomaly] {
            PriceLimits.verdict(price: 9.0, open: 9.9, high: 9.95, low: 8.95,
                                changePct: pct, amountWan: amount,
                                limitUp: 11.0, limitDown: 9.0, volMult5d: vm).anomalies
        }
        XCTAssertTrue(judge(pct: -9.6, amount: 30000, vm: 4.5).contains(.heavyVolumeDown), "三条件齐备 → 命中")
        XCTAssertFalse(judge(pct: -9.0, amount: 30000, vm: 4.5).contains(.heavyVolumeDown), "跌幅不够")
        XCTAssertFalse(judge(pct: -9.6, amount: 19999, vm: 4.5).contains(.heavyVolumeDown), "成交额不够")
        XCTAssertFalse(judge(pct: -9.6, amount: 30000, vm: 3.9).contains(.heavyVolumeDown), "量能倍数不够")
        // 量能倍数**缺失** → 不判（而不是当成 0，也不是当成满足）
        XCTAssertFalse(judge(pct: -9.6, amount: 30000, vm: nil).contains(.heavyVolumeDown),
                       "算不出量能倍数时不该报'放量'")
    }

    /// 边界值：恰好等于阈值 → 命中（`<=` / `>=` 的方向不能写反）
    func testHeavyVolumeDownThresholdBoundariesAreInclusive() {
        let v = PriceLimits.verdict(price: 9.0, open: 9.9, high: 9.9, low: 9.0,
                                    changePct: PriceLimits.heavyVolumeDownPct,
                                    amountWan: PriceLimits.heavyVolumeMinAmountWan,
                                    limitUp: 11.0, limitDown: 9.0,
                                    volMult5d: PriceLimits.heavyVolumeMinMult)
        XCTAssertTrue(v.anomalies.contains(.heavyVolumeDown), "恰好等于阈值应命中")
        XCTAssertTrue(v.anomalies.contains(.limitDown), "同时也在跌停上")
    }

    // MARK: - 排序与文案

    /// 跌停排最前（severity 降序）—— 卡直接按序渲染，不必再排
    func testAnomaliesAreSortedBySeverityDescending() {
        let v = PriceLimits.verdict(price: 9.0, open: 9.0, high: 9.0, low: 9.0,
                                    changePct: -10, amountWan: 30000,
                                    limitUp: 11.0, limitDown: 9.0, volMult5d: 4.5)
        XCTAssertEqual(v.anomalies, [.limitDown, .oneWordBoard, .heavyVolumeDown],
                       "跌停 > 一字板 > 放量下跌（涨停最低，因为它不是风险）")
        XCTAssertEqual(v.summary, "跌停 · 一字板 · 放量下跌")
    }

    /// 标签与 severity：互不相同、非空；风险侧只有跌停与放量下跌
    func testAnomalyLabelsAndSeverityAreDistinct() {
        let all = PriceLimits.Anomaly.allCases
        XCTAssertEqual(Set(all.map(\.label)).count, all.count, "标签有重复")
        XCTAssertEqual(Set(all.map(\.severity)).count, all.count, "severity 有重复（排序会不稳定）")
        XCTAssertFalse(all.contains { $0.label.isEmpty })
        XCTAssertEqual(all.filter(\.isRisk), [.limitDown, .heavyVolumeDown])
    }

    func testEmptyVerdictHasEmptySummary() {
        let v = PriceLimits.verdict(price: 10, open: 10, high: 10.5, low: 9.5,
                                    changePct: 1, amountWan: 1000,
                                    limitUp: 11, limitDown: 9, volMult5d: 1)
        XCTAssertTrue(v.isEmpty)
        XCTAssertEqual(v.summary, "")
    }

    // MARK: - 量能倍数（必须复用引擎公式）

    /// 5 个交易日的夹具（含/不含今日两种形态都用它）
    private let kDays = ["2026-09-15", "2026-09-16", "2026-09-17", "2026-09-18", "2026-09-21"]
    private let kVols = [100.0, 100, 100, 100, 100]
    private let today = "2026-09-22"

    /// 复用 `EngineIndicators.volMult5d`：自己写一遍会得到第二个口径，
    /// 而量能倍数在引擎里是参与加分的量（`scoring.bonus.vol_mult_*`）。
    func testVolumeMultipleMatchesTheEngineFormula() {
        // 新浪形态：日K**不含**今日 → 今日量接在末尾。前 5 日各 100，今日 400 → 4.0
        let sina = PriceLimits.volumeMultiple(klineDays: kDays, klineVolumes: kVols,
                                             today: today, todayVolume: 400)
        XCTAssertEqual(sina, 4.0)
        XCTAssertEqual(sina, EngineIndicators.volMult5d(kVols + [400.0], 5),
                       "必须与引擎公式逐位一致")
        XCTAssertEqual(PriceLimits.volumeMultiple(klineDays: kDays, klineVolumes: kVols,
                                                 today: today, todayVolume: 100), 1.0)
    }

    /// 腾讯形态：日K**已含**今日（实测末根就是今天）→ **不能再接一次**
    ///
    /// 判错的后果：分子分母都挪一位 → 量能倍数整体错位一个交易日，
    /// **不报错**，只是"放量"被算成"缩量"。
    ///
    /// 判别式断言：两种形态在**数据自洽时本来就该同值**（同一份序列），
    /// 所以不能拿它们互相比较 —— 要**喂一个明显不同的 `todayVolume`**，
    /// 看它到底有没有被用上。腾讯形态下它必须**被忽略**。
    func testVolumeMultipleDoesNotDoubleCountWhenKlineAlreadyHasToday() {
        let tencentDays = kDays + [today]          // 末根 = 今天
        let tencentVols = kVols + [400.0]          // 今日量 400 已在末根里
        XCTAssertEqual(PriceLimits.volumeMultiple(klineDays: tencentDays,
                                                 klineVolumes: tencentVols,
                                                 today: today, todayVolume: 400), 4.0)

        // 喂一个荒谬的 todayVolume：若实现"再接到末尾"，结果会变成
        // 999999 / mean([100,100,100,100,400]) ≈ 1111 —— 与 4.0 天差地别。
        XCTAssertEqual(PriceLimits.volumeMultiple(klineDays: tencentDays,
                                                 klineVolumes: tencentVols,
                                                 today: today, todayVolume: 999_999), 4.0,
                       "末根已是今日 → todayVolume 必须被忽略（用了就是重复计数）")

        // 反证：新浪形态（末根不是今天）**必须**用上 todayVolume
        XCTAssertEqual(PriceLimits.volumeMultiple(klineDays: kDays, klineVolumes: kVols,
                                                 today: today, todayVolume: 400), 4.0)
        XCTAssertEqual(PriceLimits.volumeMultiple(klineDays: kDays, klineVolumes: kVols,
                                                 today: today, todayVolume: 200), 2.0,
                       "新浪形态必须真的把今日量算进去（否则这条断言没有牙齿）")
    }

    /// 样本不足 / 今日量为 0 / 日期与量长度不齐 → `nil`
    func testVolumeMultipleReturnsNilWhenNotComputable() {
        XCTAssertNil(PriceLimits.volumeMultiple(klineDays: Array(kDays.prefix(4)),
                                                klineVolumes: Array(kVols.prefix(4)),
                                                today: today, todayVolume: 400),
                     "只有 4 根 → 算不出 5 日均量")
        XCTAssertNil(PriceLimits.volumeMultiple(klineDays: kDays, klineVolumes: kVols,
                                                today: today, todayVolume: 0),
                     "今日量为 0（停牌）→ nil")
        XCTAssertNil(PriceLimits.volumeMultiple(klineDays: [], klineVolumes: [],
                                                today: today, todayVolume: 400))
        XCTAssertNil(PriceLimits.volumeMultiple(klineDays: kDays, klineVolumes: [],
                                                today: today, todayVolume: 400),
                     "日期与量长度不齐 → 不能按位取值")
        XCTAssertNil(PriceLimits.volumeMultiple(klineDays: kDays, klineVolumes: kVols,
                                                today: "", todayVolume: 400),
                     "today 为空 → 无法判断含不含当日 → nil（不猜）")
    }

    /// 前 5 日全为 0（长期停牌）→ 除零，返回 nil 而不是 inf
    func testVolumeMultipleHandlesZeroBase() {
        XCTAssertNil(PriceLimits.volumeMultiple(klineDays: kDays, klineVolumes: [0, 0, 0, 0, 0],
                                                today: today, todayVolume: 400),
                     "均量为 0 时不能产出 inf")
    }

    /// 非交易日（周末）：末根是上周五、今日量为 0 → nil（而不是把 0 当量算出一个假倍数）
    func testVolumeMultipleOnNonTradingDayIsNil() {
        XCTAssertNil(PriceLimits.volumeMultiple(klineDays: kDays, klineVolumes: kVols,
                                                today: "2026-09-26", todayVolume: 0),
                     "周末打开详情页：今日量 0 → 不产出一个假的量能倍数")
    }

    // MARK: - StockQuote 便捷入口

    /// `verdict(_:volMult5d:)` 要把行情的价/额/涨跌停**原样**接进来
    func testVerdictFromStockQuoteUsesQuoteFields() {
        let q = StockQuote(market: "sh", code: "600519", name: "贵州茅台",
                           currentPrice: 1393.68, previousClose: 1266.98,
                           openPrice: 1393.68, highPrice: 1393.68, lowPrice: 1393.68,
                           volume: 24891, turnover: 313585, change: 126.7,
                           changePercent: 10.0, turnoverRate: 0.2, peRatio: 19.3,
                           marketCap: 17500, circulationMarketCap: 17500,
                           amplitude: 0.77, volumeRatio: 1.14, pbRatio: 6.25,
                           limitUp: 1393.68, limitDown: 1140.28)
        let v = PriceLimits.verdict(q, volMult5d: nil)
        XCTAssertTrue(v.anomalies.contains(.limitUp))
        XCTAssertTrue(v.anomalies.contains(.oneWordBoard), "开=收=高=低 且在板上")
        XCTAssertEqual(v.limitUp, 1393.68)
        XCTAssertEqual(v.limitDown, 1140.28)
    }

    // MARK: - 实测夹具的一致性（把"侦察结论"钉进代码）

    /// 用自检夹具里那条**真实抓取**的行情原文复核：
    /// 茅台（主板）与颖泰生物（北交所）的涨跌停比例必须分别落在 ±10% 与 ±30%。
    ///
    /// 这条是实测结论的可执行快照 —— 若哪天有人按"统一 10%"或"ST 5%"改判据，它会红。
    func testRealFixtureConfirmsBoardSpecificLimits() {
        let raw = #"""
        v_sh600519="1~贵州茅台~600519~1257.12~1266.98~1262.99~24891~12061~12829~1257.12~8~1257.11~2~1257.08~1~1257.06~2~1257.05~2~1257.13~1~1257.24~2~1257.28~1~1258.00~16~1258.28~1~~20260918161436~-9.86~-0.78~1265.88~1256.10~1257.12/24891/3135849108~24891~313585~0.20~19.30~~1265.88~1256.10~0.77~15715.03~15715.03~6.25~1393.68~1140.28~1.14~-6~1259.84~17.65~19.09~~~0.08~313584.9108~527.9904~42~   A~GP-A";
        v_bj920819="62~颖泰生物~920819~3.02~3.03~3.05~56372~29940~26431~3.02~612~3.01~2069~3.00~1306~2.99~650~2.98~440~3.03~1745~3.04~830~3.05~481~3.06~1019~3.07~2148~~20260918153443~-0.01~-0.33~3.08~3.01~3.02/56372/17108707~56372~1710.87~0.47~-13.89~~3.08~3.01~2.31~36.59~37.02~0.78~3.93~2.13~0.70~-1146~3.03~323.86~-14.41~~~~1710.8707~0.0000~0~ ~GP~-21.96~-7.65~0.00~-5.60~-2.44~4.55~2.52~-6.50~1.00~13.11~1211625000~1225800000~-10.14~-24.50~1211625000~~~-32.74~0.33~~CNY~4~NBFND~0.00~0";
        """#
        let batch = StockQuotes.parseBatch(raw)
        guard let sh = batch["600519"], let bj = batch["920819"] else {
            return XCTFail("夹具解析失败：\(batch.keys.sorted())")
        }
        XCTAssertEqual(PyMath.round((sh.limitUp! / sh.previousClose) * 100, 1), 110.0,
                       "主板涨停幅度应是 10%")
        XCTAssertEqual(PyMath.round((bj.limitUp! / bj.previousClose) * 100, 1), 129.7,
                       "⚠ 北交所应是 30%（实测 3.93/3.03=129.7%）—— 不是 10%")
        XCTAssertEqual(PyMath.round((bj.limitDown! / bj.previousClose) * 100, 1), 70.3,
                       "⚠ 北交所跌停应是 -30%")
    }
}
