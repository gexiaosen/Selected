import XCTest
@testable import SelectedCore

/// 自选提醒的纯逻辑契约（`docs/specs/README.md`）。
///
/// 这一组是**告警能不能响、会不会重复响**的地基 —— 判据全在 Core 里就是为了能被这里覆盖。
/// 视图侧只有"画铃铛"和"弹通知"，没有可自动化的判据。
///
/// 本组**不需要夹具**（全是纯函数），故没有 `EntityTestSupport` 的读取前置。
/// 夹具/输入必须落在**函数定义域内**：涉及百分比的用例一律给非零
///   `changePercent`，否则"没触发"既可能是判据对、也可能是输入压根进不了判据。
final class AlertRulesTests: XCTestCase {

    // MARK: - 工具

    private let day = "2026-09-23"
    private let stamp = "2026-09-23 10:30:00"

    /// 交易时段内的一个时刻（10:30 → 630）
    private func clock(minute: Int = 630, trading: Bool = true, day: String? = nil) -> AlertClock {
        AlertClock(day: day ?? self.day, minuteOfDay: minute,
                   isTradingDay: trading, stamp: stamp)
    }

    private func rule(_ kind: AlertKind, _ threshold: Double,
                      _ repeatMode: AlertRepeat = .daily,
                      firedAt: String = "", firedDay: String = "") -> AlertRule {
        AlertRule(kind: kind, threshold: threshold, repeatMode: repeatMode,
                  lastFiredAt: firedAt, lastFiredDay: firedDay)
    }

    /// 待评估标的。`changeAmt`（当日涨跌额，元）默认 `0`（平盘）。
    ///
    /// **涉及 `upAmount` / `downAmount` 的用例必须显式传它**：
    ///   默认 0 会让"不该触发"这类**反向断言**因为"输入压根进不了判据"而**假绿**，
    ///   正向用例也必须传，否则证明不了"是判据在起作用"而不是别的分支放行。
    private func subject(_ rules: [AlertRule], price: Double, changePct: Double,
                         changeAmt: Double = 0,
                         window: AlertWindow = .anytime, code: String = "600276",
                         name: String = "恒瑞医药") -> AlertSubject {
        AlertSubject(code: code, name: name, price: price,
                     changeAmount: changeAmt, changePercent: changePct,
                     rules: rules, window: window)
    }

    // MARK: - ① 输入解析：空 ≠ 错

    func testParseEmptyIsEmptyNotError() {
        for text in ["", "   ", "\n", ",", ",,,", " , , "] {
            XCTAssertEqual(AlertInput.parse(text, kind: .upPrice), .empty,
                           "空输入应表示「删除该条」，不是错误：\"\(text)\"")
        }
    }

    func testParseSingleAndMultiValue() {
        XCTAssertEqual(AlertInput.parse("5", kind: .upPct), .ok([5]))
        XCTAssertEqual(AlertInput.parse("1.00,3.00,5.00", kind: .upPct), .ok([1, 3, 5]))
    }

    /// 去重 + **升序**：顺序稳定才能与库里的行序、通知的先后一致
    func testParseDedupesAndSorts() {
        XCTAssertEqual(AlertInput.parse("7,1,3,1,7", kind: .upPct), .ok([1, 3, 7]))
    }

    /// 全角逗号 / 顿号一并当分隔符（中文输入法下的常态，要宽容收）
    func testParseAcceptsFullWidthComma() {
        XCTAssertEqual(AlertInput.parse("5，7", kind: .upPct), .ok([5, 7]))
        XCTAssertEqual(AlertInput.parse("5、7", kind: .upPct), .ok([5, 7]))
        XCTAssertEqual(AlertInput.parse("5，7,9", kind: .upPct), .ok([5, 7, 9]))
    }

    func testParseSkipsBlankSegments() {
        XCTAssertEqual(AlertInput.parse("5,,7", kind: .upPct), .ok([5, 7]))
        XCTAssertEqual(AlertInput.parse(" 5 , 7 ", kind: .upPct), .ok([5, 7]))
    }

    /// 非法输入**显式失败**并把出错的那一段回显（不静默丢弃）
    func testParseRejectsNonNumericAndEchoesToken() {
        guard case let .invalid(msg) = AlertInput.parse("5,abc,7", kind: .upPct) else {
            return XCTFail("非数字应判 invalid")
        }
        XCTAssertTrue(msg.contains("abc"), "错误文案要回显出错的那一段，实际：\(msg)")
    }

    /// `Double("inf")` / `Double("nan")` **解析成功** —— 而 NaN 参与比较恒为 false。
    /// 放进去就是一条"永不触发"的规则，界面上却显示得好好的。
    func testParseRejectsNonFiniteValues() {
        for text in ["inf", "-inf", "nan", "Infinity", "NaN"] {
            guard case .invalid = AlertInput.parse(text, kind: .upPct) else {
                return XCTFail("非有限值应判 invalid：\(text)")
            }
        }
    }

    func testParseRangeForPriceKind() {
        XCTAssertEqual(AlertInput.parse("0", kind: .upPrice), .invalid("「0」超出范围（价格需大于 0）"))
        XCTAssertEqual(AlertInput.parse("-5", kind: .downPrice),
                       .invalid("「-5」超出范围（价格需大于 0）"))
        XCTAssertEqual(AlertInput.parse("5.2", kind: .upPrice), .ok([5.2]))
    }

    func testParseRangeForPercentKind() {
        XCTAssertEqual(AlertInput.parse("0", kind: .upPct), .invalid("「0」超出范围（百分比需在 0 与 100 之间）"))
        XCTAssertEqual(AlertInput.parse("101", kind: .downPct),
                       .invalid("「101」超出范围（百分比需在 0 与 100 之间）"))
        XCTAssertEqual(AlertInput.parse("100", kind: .upPct), .ok([100]))
        XCTAssertEqual(AlertInput.parse("0.01", kind: .upPct), .ok([0.01]))
    }

    /// 超上限**报错**，不静默截断 —— 静默截断会让用户以为"填进去了"
    func testParseRejectsTooManyValues() {
        let eleven = (1...11).map { String($0) }.joined(separator: ",")
        guard case let .invalid(msg) = AlertInput.parse(eleven, kind: .upPct) else {
            return XCTFail("超过 \(AlertInput.maxThresholds) 个应判 invalid")
        }
        XCTAssertTrue(msg.contains("11"), "错误文案要带上实际个数，实际：\(msg)")

        let ten = (1...10).map { String($0) }.joined(separator: ",")
        XCTAssertEqual(AlertInput.parse(ten, kind: .upPct), .ok((1...10).map(Double.init)))
    }

    /// 上限判定要在**去重之后**：`5,5,5,...`（11 个 5）去重后只有 1 个，不该报错
    func testParseCountsAfterDedupe() {
        let repeated = Array(repeating: "5", count: 11).joined(separator: ",")
        XCTAssertEqual(AlertInput.parse(repeated, kind: .upPct), .ok([5]))
    }

    /// 回显与解析互逆（弹窗初值走 `format`，确认时走 `parse`）
    func testFormatRoundTrip() {
        XCTAssertEqual(AlertInput.format([7, 5]), "5.00,7.00")
        XCTAssertEqual(AlertInput.format([]), "")
        let values = [1, 3.5, 9]
        XCTAssertEqual(AlertInput.parse(AlertInput.format(values), kind: .upPct), .ok(values))
    }

    // MARK: - ①b 涨跌额族的解析

    /// 涨跌额与价格同口径：`> 0`；**0 与负数都非法**（"涨 0 元"没有意义，且
    /// `changeAmount <= -0` 会让跌幅规则在平盘时恒真）
    func testParseAmountFamilyUsesPositiveRange() {
        XCTAssertEqual(AlertInput.parse("1.00", kind: .upAmount), .ok([1.0]))
        XCTAssertEqual(AlertInput.parse("0.50,1.00", kind: .upAmount), .ok([0.5, 1.0]))
        XCTAssertEqual(AlertInput.parse("1.00", kind: .downAmount), .ok([1.0]))
        // 0 与负数 → 显式失败（不是"静默当成 0"）
        XCTAssertEqual(AlertInput.parse("0", kind: .upAmount),
                       .invalid("「0」超出范围（涨跌额需大于 0）"))
        XCTAssertEqual(AlertInput.parse("-1", kind: .upAmount),
                       .invalid("「-1」超出范围（涨跌额需大于 0）"))
        // 价格族的文案**不受影响**（改 parse 时别把两个分支合并了）
        XCTAssertEqual(AlertInput.parse("0", kind: .upPrice),
                       .invalid("「0」超出范围（价格需大于 0）"))
        // 全角逗号与顿号同样宽容（三个族别共用一条规范化路径）
        XCTAssertEqual(AlertInput.parse("0.5，1.0", kind: .upAmount), .ok([0.5, 1.0]))
        XCTAssertEqual(AlertInput.parse("0.5、1.0", kind: .downAmount), .ok([0.5, 1.0]))
    }

    /// 上限与 inf/nan 的排除对涨跌额族同样生效（不然是一条**永不触发**的规则）
    func testParseAmountFamilyRejectsNonFiniteAndTooMany() {
        XCTAssertEqual(AlertInput.parse("inf", kind: .upAmount),
                       .invalid("「inf」不是有效数字"))
        XCTAssertEqual(AlertInput.parse("nan", kind: .upAmount),
                       .invalid("「nan」不是有效数字"))
        let eleven = (1...11).map { String($0) }.joined(separator: ",")
        guard case .invalid = AlertInput.parse(eleven, kind: .upAmount) else {
            return XCTFail("涨跌额族同样受 \(AlertInput.maxThresholds) 个上限约束")
        }
    }

    // MARK: - ①c 族别（`AlertFamily`）—— 加类型时这几条会替我们发现漏改

    /// 每个 kind 都有族别，且**六个 kind 的族别与预期逐一对上**
    /// （不是"六个都属于某个族"那种恒真断言）
    func testFamilyMappingIsExhaustiveAndCorrect() {
        XCTAssertEqual(AlertKind.allCases.count, 6, "新增类型时请同步本测试与文档")
        let expected: [AlertKind: AlertFamily] = [
            .upPrice: .price, .downPrice: .price,
            .upAmount: .amount, .downAmount: .amount,
            .upPct: .percent, .downPct: .percent,
        ]
        for kind in AlertKind.allCases {
            XCTAssertEqual(kind.family, expected[kind], "\(kind.rawValue) 的族别不对")
        }
        // 三个族别都真的被用到了（否则某个族别是死代码）
        XCTAssertEqual(Set(AlertKind.allCases.map(\.family)).count, AlertFamily.allCases.count)
    }

    /// **加第三族不许改变既有输出**。
    /// `unitSuffix` 是"统一加后缀"最容易改坏的一处 —— 价格类必须**留空**。
    func testUnitSuffixKeepsExistingKindsByteIdentical() {
        XCTAssertEqual(AlertKind.upPrice.unitSuffix, "")
        XCTAssertEqual(AlertKind.downPrice.unitSuffix, "")
        XCTAssertEqual(AlertKind.upAmount.unitSuffix, " 元")
        XCTAssertEqual(AlertKind.downAmount.unitSuffix, " 元")
        XCTAssertEqual(AlertKind.upPct.unitSuffix, "%")
        XCTAssertEqual(AlertKind.downPct.unitSuffix, "%")

        // 拼出来的字符串与改动前**逐字相同**（设置页一览走的就是这个拼法）
        func summary(_ kind: AlertKind, _ v: Double) -> String {
            String(format: "%.2f", v) + kind.unitSuffix
        }
        XCTAssertEqual(summary(.upPrice, 5.2), "5.20")
        XCTAssertEqual(summary(.downPrice, 4.8), "4.80")
        XCTAssertEqual(summary(.upPct, 5), "5.00%")
        XCTAssertEqual(summary(.downPct, 3), "3.00%")
        // 新增的才有单位
        XCTAssertEqual(summary(.upAmount, 1), "1.00 元")
        XCTAssertEqual(summary(.downAmount, 0.5), "0.50 元")
    }

    /// 默认重复方式：价格类「单次」（到一个点位就完了）；
    /// 涨跌额与涨跌幅「每日重复」（当日累计量的水平线，日内会反复穿越）
    func testDefaultRepeatPerFamily() {
        XCTAssertEqual(AlertKind.upPrice.defaultRepeat, .once)
        XCTAssertEqual(AlertKind.downPrice.defaultRepeat, .once)
        XCTAssertEqual(AlertKind.upAmount.defaultRepeat, .daily)
        XCTAssertEqual(AlertKind.downAmount.defaultRepeat, .daily)
        XCTAssertEqual(AlertKind.upPct.defaultRepeat, .daily)
        XCTAssertEqual(AlertKind.downPct.defaultRepeat, .daily)
    }

    /// 通知标题在**族别之间**必须两两不同 —— 用户可能同时设「涨 1 元」与「涨 5%」，
    /// 标题一样就分不出是哪条在响。
    ///
    /// **同族内的涨/跌共用标题是既有设计**（`upPrice` / `downPrice` 都是「到价提醒」）：
    ///   方向由**正文**表达（"涨到 5.20" vs "跌到 4.80"），且 `identifier` 不同
    ///   （通知不会互相替换）。**这里刻意不改它** —— 加第三族不该顺手改既有输出。
    ///   所以本测试**不能**写成"六个标题两两不同" —— 断言比设计更严会误红。
    func testNotifyTitlesDistinctAcrossFamilies() {
        var byFamily: [AlertFamily: Set<String>] = [:]
        for kind in AlertKind.allCases {
            XCTAssertFalse(kind.notifyTitle.isEmpty, "\(kind.rawValue) 的通知标题不许为空")
            byFamily[kind.family, default: []].insert(kind.notifyTitle)
        }
        let families = AlertFamily.allCases
        for i in 0..<families.count {
            for j in (i + 1)..<families.count {
                let a = byFamily[families[i]] ?? []
                let b = byFamily[families[j]] ?? []
                XCTAssertTrue(a.isDisjoint(with: b),
                              "\(families[i].rawValue) 与 \(families[j].rawValue) 的通知标题撞了：\(a) / \(b)")
            }
        }
        // 逐族钉死（改这几行 = 在动通知栏文案，想清楚再改）
        XCTAssertEqual(byFamily[.price], ["到价提醒"])
        XCTAssertEqual(byFamily[.amount], ["涨额提醒", "跌额提醒"])
        XCTAssertEqual(byFamily[.percent], ["涨幅提醒", "跌幅提醒"])
    }

    /// 输入框占位符按族别给 —— 涨跌额不能沿用价格的「如 5.20」（口径会误导）
    func testPlaceholderPerFamily() {
        XCTAssertEqual(AlertKind.upPrice.placeholder, "如 5.20")
        XCTAssertEqual(AlertKind.downPrice.placeholder, "如 5.20")
        XCTAssertEqual(AlertKind.upAmount.placeholder, "如 0.50,1.00")
        XCTAssertEqual(AlertKind.downAmount.placeholder, "如 0.50,1.00")
        XCTAssertEqual(AlertKind.upPct.placeholder, "如 1.00,3.00,5.00")
    }

    // MARK: - ② 判据方向与闭区间

    /// 闭区间：**恰好等于**阈值算触发（"涨到 5.00" 含 5.00）
    func testPriceKindsUseClosedInterval() {
        XCTAssertTrue(AlertEval.triggered(.upPrice, threshold: 5.2, price: 5.2, changeAmount: 0, changePct: 0))
        XCTAssertFalse(AlertEval.triggered(.upPrice, threshold: 5.2, price: 5.19, changeAmount: 0, changePct: 0))
        XCTAssertTrue(AlertEval.triggered(.downPrice, threshold: 4.8, price: 4.8, changeAmount: 0, changePct: 0))
        XCTAssertFalse(AlertEval.triggered(.downPrice, threshold: 4.8, price: 4.81, changeAmount: 0, changePct: 0))
    }

    /// 跌幅阈值在**界面与库里都存正数**，比较时才取负 ——
    /// 存负数会让"输入校验范围"与"实际比较值"分叉
    func testDownPctThresholdIsStoredPositive() {
        XCTAssertTrue(AlertEval.triggered(.downPct, threshold: 3, price: 10, changeAmount: 0, changePct: -3))
        XCTAssertFalse(AlertEval.triggered(.downPct, threshold: 3, price: 10, changeAmount: 0, changePct: -2.99))
        // 反向：涨幅不该触发跌幅规则
        XCTAssertFalse(AlertEval.triggered(.downPct, threshold: 3, price: 10, changeAmount: 0, changePct: 5))
        XCTAssertTrue(AlertEval.triggered(.upPct, threshold: 3, price: 10, changeAmount: 0, changePct: 3))
        XCTAssertFalse(AlertEval.triggered(.upPct, threshold: 3, price: 10, changeAmount: 0, changePct: -5))
    }

    /// 涨跌额族的闭区间与方向。
    /// `changeAmt` 必须**显式给**（默认 0 会让"不该触发"这类反向断言因为输入进不了判据而假绿）
    func testAmountKindsUseClosedIntervalAndDirection() {
        // 恰好等于阈值算触发（闭区间）
        XCTAssertTrue(AlertEval.triggered(.upAmount, threshold: 1, price: 10, changeAmount: 1, changePct: 0))
        XCTAssertFalse(AlertEval.triggered(.upAmount, threshold: 1, price: 10, changeAmount: 0.99, changePct: 0))
        XCTAssertTrue(AlertEval.triggered(.downAmount, threshold: 1, price: 10, changeAmount: -1, changePct: 0))
        XCTAssertFalse(AlertEval.triggered(.downAmount, threshold: 1, price: 10, changeAmount: -0.99, changePct: 0))
        // 方向不许互串
        XCTAssertFalse(AlertEval.triggered(.upAmount, threshold: 1, price: 10, changeAmount: -3, changePct: 0))
        XCTAssertFalse(AlertEval.triggered(.downAmount, threshold: 1, price: 10, changeAmount: 3, changePct: 0))
        // 平盘（0）两边都不触发 —— 这是"没涨没跌却报涨了 0 元"的保证
        XCTAssertFalse(AlertEval.triggered(.upAmount, threshold: 1, price: 10, changeAmount: 0, changePct: 0))
        XCTAssertFalse(AlertEval.triggered(.downAmount, threshold: 1, price: 10, changeAmount: 0, changePct: 0))
        // **负零**（ETF 平盘时接口给的就是 `-0.00`，见设计 §13.2 实测）也不许触发
        XCTAssertFalse(AlertEval.triggered(.upAmount, threshold: 1, price: 10, changeAmount: -0.0, changePct: 0))
        XCTAssertFalse(AlertEval.triggered(.downAmount, threshold: 1, price: 10, changeAmount: -0.0, changePct: 0))
    }

    /// 涨跌额与涨跌幅是**同一事实的两种刻度**（设计 §13.1③），但判据必须**各读各的输入**：
    /// 只给 `changePct` 而 `changeAmount = 0` 时，涨幅规则该响、涨额规则**不该**响
    func testAmountAndPctReadSeparateInputs() {
        XCTAssertTrue(AlertEval.triggered(.upPct, threshold: 5, price: 10, changeAmount: 0, changePct: 5.2))
        XCTAssertFalse(AlertEval.triggered(.upAmount, threshold: 1, price: 10, changeAmount: 0, changePct: 5.2))
        XCTAssertTrue(AlertEval.triggered(.upAmount, threshold: 1, price: 10, changeAmount: 1.05, changePct: 0))
        XCTAssertFalse(AlertEval.triggered(.upPct, threshold: 5, price: 10, changeAmount: 1.05, changePct: 0))
    }

    /// 端到端：涨跌额规则经 `AlertEval.evaluate` **真的能触发** ——
    /// 证明 `AlertSubject.changeAmount` 这条线接通了，而不是只在 `triggered` 里对
    func testEvaluateFiresAmountRule() {
        let hit = subject([rule(.upAmount, 1)], price: 21.50, changePct: 5.13, changeAmt: 1.05)
        let out = AlertEval.evaluate([hit], at: clock())
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.kind, .upAmount)
        XCTAssertEqual(out.first?.changeAmount, 1.05, "触发记录必须把涨跌额原样带出来")
        XCTAssertEqual(out.first?.body, "恒瑞医药 涨额达 1.00 元（现涨 1.05 元）")

        // 反向：没到阈值就不响（同一条 subject 只改阈值 → 证明是判据在起作用）
        let miss = subject([rule(.upAmount, 2)], price: 21.50, changePct: 5.13, changeAmt: 1.05)
        XCTAssertTrue(AlertEval.evaluate([miss], at: clock()).isEmpty)

        // 跌额同理（方向正确）
        let downHit = subject([rule(.downAmount, 0.5)], price: 19.40, changePct: -3.10, changeAmt: -0.62)
        let downOut = AlertEval.evaluate([downHit], at: clock())
        XCTAssertEqual(downOut.first?.kind, .downAmount)
        XCTAssertEqual(downOut.first?.body, "恒瑞医药 跌额达 0.50 元（现跌 0.62 元）")
    }

    // MARK: - ③ 去重：单次 / 每日重复

    func testOnceDisarmsAfterFiring() {
        let fresh = rule(.upPct, 3, .once)
        XCTAssertTrue(fresh.isArmed(day: day))
        let used = rule(.upPct, 3, .once, firedAt: stamp, firedDay: day)
        XCTAssertFalse(used.isArmed(day: day), "单次触发后应永久哑火")

        let s = subject([used], price: 10, changePct: 5)
        XCTAssertTrue(AlertEval.evaluate([s], at: clock()).isEmpty)
    }

    func testDailyFiresOncePerDayAndRearmsNextDay() {
        let firedToday = rule(.upPct, 3, .daily, firedAt: stamp, firedDay: day)
        XCTAssertFalse(firedToday.isArmed(day: day))
        XCTAssertTrue(firedToday.isArmed(day: "2026-09-24"), "次日应重新武装")

        let s = subject([firedToday], price: 10, changePct: 5)
        XCTAssertTrue(AlertEval.evaluate([s], at: clock()).isEmpty, "同一天不该重复响")
        XCTAssertEqual(AlertEval.evaluate([s], at: clock(day: "2026-09-24")).count, 1)
    }

    /// 阶梯阈值：各自独立去重 —— 5% 响过之后 7% 还能响（这正是多值逗号输入的意义）
    func testSteppedThresholdsFireIndependently() {
        let rules = [rule(.upPct, 5, .daily, firedAt: stamp, firedDay: day),
                     rule(.upPct, 7, .daily)]
        let s = subject(rules, price: 10, changePct: 7.5)
        let fires = AlertEval.evaluate([s], at: clock())
        XCTAssertEqual(fires.count, 1)
        XCTAssertEqual(fires.first?.threshold, 7)
    }

    // MARK: - ④ 时间窗与交易日

    func testWindowMinuteRanges() {
        // 随时提醒 = 09:30–11:30 / 13:00–15:00（**含午休跳过**，与既有交易时段口径同一套）
        XCTAssertTrue(AlertWindow.anytime.contains(minuteOfDay: 570))
        XCTAssertTrue(AlertWindow.anytime.contains(minuteOfDay: 690))
        XCTAssertFalse(AlertWindow.anytime.contains(minuteOfDay: 691), "午休不算交易时段")
        XCTAssertTrue(AlertWindow.anytime.contains(minuteOfDay: 780))
        XCTAssertTrue(AlertWindow.anytime.contains(minuteOfDay: 900))
        XCTAssertFalse(AlertWindow.anytime.contains(minuteOfDay: 901))
        XCTAssertFalse(AlertWindow.anytime.contains(minuteOfDay: 569))

        XCTAssertTrue(AlertWindow.open.contains(minuteOfDay: 570))
        XCTAssertTrue(AlertWindow.open.contains(minuteOfDay: 600))
        XCTAssertFalse(AlertWindow.open.contains(minuteOfDay: 601))

        XCTAssertFalse(AlertWindow.tail.contains(minuteOfDay: 869))
        XCTAssertTrue(AlertWindow.tail.contains(minuteOfDay: 870))
        XCTAssertTrue(AlertWindow.tail.contains(minuteOfDay: 900))
    }

    /// 非交易日一律不评估 —— 缺了它「每日重复」会在周末拿周五收盘价再弹一次
    func testNonTradingDayNeverFires() {
        let s = subject([rule(.upPct, 3)], price: 10, changePct: 5)
        XCTAssertTrue(AlertEval.evaluate([s], at: clock(trading: false)).isEmpty)
    }

    /// 日期缺失（调用方没给日期）→ 一律不响。两种失效方向里"不响"比"每 5 秒响一次"安全
    func testEmptyDayNeverFires() {
        let s = subject([rule(.upPct, 3)], price: 10, changePct: 5)
        XCTAssertTrue(AlertEval.evaluate([s], at: clock(day: "")).isEmpty)
    }

    func testOutsideWindowNoFire() {
        let s = subject([rule(.upPct, 3)], price: 10, changePct: 5, window: .tail)
        XCTAssertTrue(AlertEval.evaluate([s], at: clock(minute: 630)).isEmpty, "10:30 不在尾盘窗")
        XCTAssertEqual(AlertEval.evaluate([s], at: clock(minute: 880)).count, 1)
    }

    // MARK: - ⑤ 无行情

    /// 取不到行情（price == 0）时必须跳过：否则 `down_price` 的 `price <= threshold`
    /// **恒真**，一次行情抖动就能把所有"跌破"规则全部触发。
    func testZeroPriceNeverFires() {
        let s = subject([rule(.downPrice, 10)], price: 0, changePct: 0)
        XCTAssertTrue(AlertEval.evaluate([s], at: clock()).isEmpty)

        let nan = subject([rule(.downPrice, 10)], price: .nan, changePct: .nan)
        XCTAssertTrue(AlertEval.evaluate([nan], at: clock()).isEmpty)
    }

    // MARK: - ⑥ 判别性：没有规则就没有提醒

    /// 价格已经跌穿任何价位，但只要**用户没配规则**，就不产生任何提醒。
    ///
    /// 这条是「提醒只来自手动规则」的判别性用例：证明本模块的触发**只看 `rules`**，
    /// 不会去读引擎的 `watch_judgments.target_price` / `stop_loss_price` ——
    /// 否则用户会收到一条自己没设过的提醒，而界面上完全看不出来源。
    func testNoRulesMeansNoAlertsRegardlessOfPrice() {
        let noRules = subject([], price: 1.0, changePct: -19.9)
        XCTAssertTrue(AlertEval.evaluate([noRules], at: clock()).isEmpty)

        // 对照：同一价格 + 一条规则 → 会响（说明"没响"是规则为空，不是别的原因）
        let withRule = subject([rule(.downPrice, 10)], price: 1.0, changePct: -19.9)
        XCTAssertEqual(AlertEval.evaluate([withRule], at: clock()).count, 1)
    }

    // MARK: - ⑦ 合并：触发状态的继承（**本模块最容易静默出错的一处**）

    /// 三者全同 → 继承（否则每次保存都会重新武装）
    func testMergeCarriesOverUnchangedRule() {
        let existing = [rule(.upPct, 5, .daily, firedAt: stamp, firedDay: day)]
        let drafts = [AlertDraft(kind: .upPct, threshold: 5, repeatMode: .daily)]
        let merged = AlertMerge.carryOver(existing: existing, drafts: drafts)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].lastFiredAt, stamp)
        XCTAssertEqual(merged[0].lastFiredDay, day)
        XCTAssertFalse(merged[0].isArmed(day: day), "同一天保存过规则后不该能再响")
    }

    /// 改了阈值 → 重新武装（是期望行为：改了阈值就该按新阈值重新算）
    func testMergeResetsWhenThresholdChanged() {
        let existing = [rule(.upPct, 5, .daily, firedAt: stamp, firedDay: day)]
        let drafts = [AlertDraft(kind: .upPct, threshold: 6, repeatMode: .daily)]
        let merged = AlertMerge.carryOver(existing: existing, drafts: drafts)
        XCTAssertEqual(merged[0].lastFiredAt, "")
        XCTAssertEqual(merged[0].lastFiredDay, "")
        XCTAssertTrue(merged[0].isArmed(day: day))
    }

    /// 改了重复方式 → 重新武装（单次改每日重复，用户显然是想让它再响）
    func testMergeResetsWhenRepeatModeChanged() {
        let existing = [rule(.upPct, 5, .once, firedAt: stamp, firedDay: day)]
        let drafts = [AlertDraft(kind: .upPct, threshold: 5, repeatMode: .daily)]
        let merged = AlertMerge.carryOver(existing: existing, drafts: drafts)
        XCTAssertEqual(merged[0].lastFiredAt, "")
        XCTAssertTrue(merged[0].isArmed(day: day))
    }

    /// 改了类型 → 重新武装（同为 5 但含义从"涨幅"变成"跌幅"）
    func testMergeResetsWhenKindChanged() {
        let existing = [rule(.upPct, 5, .daily, firedAt: stamp, firedDay: day)]
        let drafts = [AlertDraft(kind: .downPct, threshold: 5, repeatMode: .daily)]
        let merged = AlertMerge.carryOver(existing: existing, drafts: drafts)
        XCTAssertEqual(merged[0].lastFiredAt, "")
    }

    func testMergeNewRuleStartsUnfired() {
        let merged = AlertMerge.carryOver(existing: [], drafts: [
            AlertDraft(kind: .upPrice, threshold: 5.2, repeatMode: .once),
        ])
        XCTAssertEqual(merged[0].lastFiredAt, "")
        XCTAssertEqual(merged[0].lastFiredDay, "")
    }

    /// 增删混合：留下的那条继承、新增那条从零开始
    func testMergeMixedAddRemove() {
        let existing = [rule(.upPct, 5, .daily, firedAt: stamp, firedDay: day),
                        rule(.downPct, 3, .daily, firedAt: stamp, firedDay: day)]
        let drafts = [AlertDraft(kind: .upPct, threshold: 5, repeatMode: .daily),
                      AlertDraft(kind: .upPrice, threshold: 4.8, repeatMode: .once)]
        let merged = AlertMerge.carryOver(existing: existing, drafts: drafts)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].lastFiredDay, day, "未变的那条要继承")
        XCTAssertEqual(merged[1].lastFiredAt, "", "新增的那条从零开始")
    }

    /// 阈值键必须**稳定**：`5` 与 `5.0` 是同一个阈值，不能因为写法不同就丢触发状态
    func testThresholdKeyIsStableAcrossDoubleRepresentations() {
        XCTAssertEqual(alertThresholdKey(5), alertThresholdKey(5.0))
        XCTAssertEqual(alertThresholdKey(5), "5.0000")
        XCTAssertEqual(alertThresholdKey(5.25), "5.2500")
    }

    // MARK: - ⑧ 通知文案与标识

    func testFiringBodyTexts() {
        let up = AlertFiring(code: "600276", name: "恒瑞医药", kind: .upPrice, threshold: 5.2,
                             price: 5.24, changeAmount: 0, changePercent: 0.7, repeatMode: .once,
                             firedAt: stamp, day: day)
        XCTAssertEqual(up.body, "恒瑞医药 涨到 5.20（现价 5.24）")

        let down = AlertFiring(code: "600276", name: "恒瑞医药", kind: .downPrice, threshold: 4.8,
                               price: 4.76, changeAmount: 0, changePercent: -1.2, repeatMode: .once,
                               firedAt: stamp, day: day)
        XCTAssertEqual(down.body, "恒瑞医药 跌到 4.80（现价 4.76）")

        let upPct = AlertFiring(code: "600276", name: "恒瑞医药", kind: .upPct, threshold: 5,
                                price: 10, changeAmount: 0, changePercent: 5.24, repeatMode: .daily,
                                firedAt: stamp, day: day)
        XCTAssertEqual(upPct.body, "恒瑞医药 涨幅达 5.00%（现涨 5.24%）")

        // 跌幅类取绝对值：`现跌 -3.12%` 读起来是双重否定
        let downPct = AlertFiring(code: "600276", name: "恒瑞医药", kind: .downPct, threshold: 3,
                                  price: 10, changeAmount: 0, changePercent: -3.12, repeatMode: .daily,
                                  firedAt: stamp, day: day)
        XCTAssertEqual(downPct.body, "恒瑞医药 跌幅达 3.00%（现跌 3.12%）")

        // 涨跌额族：阈值与现值都带「元」，方向由措辞表达
        let upAmt = AlertFiring(code: "002623", name: "亚玛顿", kind: .upAmount, threshold: 1,
                                price: 21.50, changeAmount: 1.05, changePercent: 5.13,
                                repeatMode: .daily, firedAt: stamp, day: day)
        XCTAssertEqual(upAmt.body, "亚玛顿 涨额达 1.00 元（现涨 1.05 元）")

        // 跌额取绝对值：`现跌 -0.62 元` 读起来是双重否定
        let downAmt = AlertFiring(code: "002623", name: "亚玛顿", kind: .downAmount, threshold: 0.5,
                                  price: 19.40, changeAmount: -0.62, changePercent: -3.10,
                                  repeatMode: .daily, firedAt: stamp, day: day)
        XCTAssertEqual(downAmt.body, "亚玛顿 跌额达 0.50 元（现跌 0.62 元）")
    }

    /// 涨额与涨幅**必须各有自己的 identifier / dedupKey** ——
    /// 否则同一只票的两个族别会互相顶掉（`Notifier` 对同一 identifier 是**替换**不是堆叠）
    func testAmountAndPctHaveDistinctIdentifiers() {
        let amt = AlertFiring(code: "600276", name: "x", kind: .upAmount, threshold: 1,
                              price: 10, changeAmount: 1.05, changePercent: 5,
                              repeatMode: .daily, firedAt: stamp, day: day)
        let pct = AlertFiring(code: "600276", name: "x", kind: .upPct, threshold: 5,
                              price: 10, changeAmount: 1.05, changePercent: 5,
                              repeatMode: .daily, firedAt: stamp, day: day)
        XCTAssertNotEqual(amt.identifier, pct.identifier)
        XCTAssertNotEqual(amt.dedupKey, pct.dedupKey)
        XCTAssertNotEqual(amt.title, pct.title)
        XCTAssertEqual(amt.identifier, "selected.alert.600276.up_amount.1.0000")
    }

    /// 名称缺失时回落代码（与 `WatchItemRow.displayName` 同口径）
    func testFiringBodyFallsBackToCode() {
        let f = AlertFiring(code: "600276", name: "", kind: .upPct, threshold: 5,
                            price: 10, changeAmount: 0, changePercent: 5.24, repeatMode: .daily,
                            firedAt: stamp, day: day)
        XCTAssertTrue(f.body.hasPrefix("600276 "), "实际：\(f.body)")
    }

    /// 会话内去重键：`daily` 带日期（次日能再响），`once` 不带（跨日也不该再响）
    func testDedupKeyIncludesDayOnlyForDaily() {
        let daily = AlertFiring(code: "600276", name: "x", kind: .upPct, threshold: 5,
                                price: 10, changeAmount: 0, changePercent: 5, repeatMode: .daily,
                                firedAt: stamp, day: day)
        let once = AlertFiring(code: "600276", name: "x", kind: .upPct, threshold: 5,
                               price: 10, changeAmount: 0, changePercent: 5, repeatMode: .once,
                               firedAt: stamp, day: day)
        XCTAssertTrue(daily.dedupKey.contains(day))
        XCTAssertFalse(once.dedupKey.contains(day))
        XCTAssertNotEqual(daily.dedupKey, once.dedupKey)
    }

    /// 通知 identifier 按规则稳定（`Notifier` 靠它把重复通知**替换**而不是堆叠）
    func testIdentifierIsStablePerRule() {
        let a = AlertFiring(code: "600276", name: "x", kind: .upPct, threshold: 5,
                            price: 10, changeAmount: 0, changePercent: 5, repeatMode: .daily,
                            firedAt: stamp, day: day)
        let b = AlertFiring(code: "600276", name: "y", kind: .upPct, threshold: 5,
                            price: 11, changeAmount: 0, changePercent: 9, repeatMode: .once,
                            firedAt: "2026-09-24 10:00:00", day: "2026-09-24")
        XCTAssertEqual(a.identifier, b.identifier, "同一条规则的通知标识必须稳定")
        XCTAssertEqual(a.identifier, "selected.alert.600276.up_pct.5.0000")
    }
}
