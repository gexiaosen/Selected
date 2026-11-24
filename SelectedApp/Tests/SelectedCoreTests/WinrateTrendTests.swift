import XCTest
@testable import SelectedCore

/// 四层胜率走势的**按周聚合**。
///
/// ## 背景与口径
/// 历史页「四层胜率走势」要覆盖长窗口才判断得了"策略是不是在变差"；
/// 但逐日折线会在几百个点上糊成一条带 ⇒ 超过 120 天**按自然周聚合**。
///
/// **周均值是"简单平均"**：`reviews.four_layer_json` **只存胜率、不存样本数**
///   ⇒ 加权所需的权重拿不到。这意味着"某天只有 3 只票"与"某天有 300 只票"权重相同 ✗ ——
///   所以界面上必须写明"按周聚合"（`ReviewView.trendSubtitle` 负责）。
///
/// 本文件钉的是**纯函数**行为；"范围切换后真的重拉了数据"属视图/Store 侧，不在单测范围。
final class WinrateTrendTests: XCTestCase {

    /// 造一行：`date` + 四个口径（缺的口径传 nil，模拟"那天那层没值"）
    private func row(_ date: String, window: Double?, close: Double?,
                     snapshot: Double? = nil, ceiling: Double? = nil) -> WinrateTrendRow {
        // 必须是 `[String: Any]`，**不能是 `[String: JSONValue]`**：
        //   `JSONValue.init(_ any: Any?)` 会把传进来的东西**原样当 raw 存** ——
        //   内层再包一层 `JSONValue` 的话，`json.str("date")` 取到的就是 `JSONValue` 而不是
        //   `String` ⇒ 全部读成默认值。
        var d: [String: Any] = ["date": date]
        func put(_ k: String, _ v: Double?) { d[k] = v ?? NSNull() }
        put("window", window); put("close", close)
        put("snapshot", snapshot); put("ceiling", ceiling)
        return WinrateTrendRow(JSONValue(d))
    }

    /// `XCTAssertEqual(_:_:accuracy:)` 的重载**不收 `Double?`** ⇒ 统一在这里折一下
    /// （没值时给 `.nan`，比较必然失败 —— 比"编译不过"更早暴露问题）
    private func wr(_ r: WinrateTrendRow, _ layer: String) -> Double {
        r.winrate(for: layer) ?? .nan
    }

    // MARK: - 基本行为

    func testEmptyStaysEmpty() {
        XCTAssertTrue(WinrateTrend.weekly([]).isEmpty)
    }

    /// 2026-09-07 / 09-14 都是**周一**（2026-09-24 是周四，往前推）
    func testSameWeekCollapsesToOnePointWithSimpleMean() {
        let rows = [
            row("2026-09-07", window: 60, close: 50),   // 周一
            row("2026-09-08", window: 70, close: 40),   // 周二
            row("2026-09-09", window: 80, close: 30),   // 周三
        ]
        let out = WinrateTrend.weekly(rows)
        XCTAssertEqual(out.count, 1, "同一自然周应折成 1 个点")
        XCTAssertEqual(out[0].date, "2026-09-07", "取该周**第一个有样本的日子**当行 id")
        XCTAssertEqual(wr(out[0], "window"), 70, accuracy: 1e-9)   // (60+70+80)/3
        XCTAssertEqual(wr(out[0], "close"), 40, accuracy: 1e-9)    // (50+40+30)/3
    }

    func testDifferentWeeksStaySeparateAndAscending() {
        let rows = [
            row("2026-09-14", window: 50, close: 50),   // 次周周一
            row("2026-09-07", window: 70, close: 30),   // 本周周一（故意乱序输入）
        ]
        let out = WinrateTrend.weekly(rows)
        XCTAssertEqual(out.map(\.date), ["2026-09-07", "2026-09-14"], "输出必须按日期升序")
    }

    /// 跨周的那一天（周五 → 下周一）不该被并到一起
    func testFridayAndNextMondayAreDifferentWeeks() {
        let rows = [
            row("2026-09-11", window: 10, close: 10),   // 周五
            row("2026-09-14", window: 90, close: 90),   // 次周周一
        ]
        let out = WinrateTrend.weekly(rows)
        XCTAssertEqual(out.count, 2)
        guard out.count == 2 else { return }   // ⚠ 数量不对时直接返回：下面按序号取值会崩
        XCTAssertEqual(wr(out[0], "window"), 10, accuracy: 1e-9)
        XCTAssertEqual(wr(out[1], "window"), 90, accuracy: 1e-9)
    }

    // MARK: - 缺值（缺值不折成 0）

    /// 某口径在一周里只有部分日子有值 ⇒ **只对有值的求平均**（缺的那天不参与、也不算 0）
    func testMissingLayerValuesAreExcludedNotZeroed() {
        let rows = [
            row("2026-09-07", window: 60, close: 50),
            row("2026-09-08", window: 80, close: nil),   // 周二 close 没值
        ]
        let out = WinrateTrend.weekly(rows)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(wr(out[0], "close"), 50, accuracy: 1e-9,
                       "只有一天有值 ⇒ 周均值 = 那天的值（**不是** (50+0)/2 = 25）")
        XCTAssertEqual(out[0].winrate(for: "snapshot"), nil,
                       "整周都没值的口径 ⇒ nil（图上跳过，不画成 0）")
    }

    // MARK: - 边界

    /// 日期解析不出来时**按原日期单独成桶**（宁可多一个点，也不要把两天的数据合并错）
    func testUnparseableDateFallsBackToItsOwnBucket() {
        let rows = [
            row("坏日期", window: 10, close: 10),
            row("2026-09-07", window: 90, close: 90),
        ]
        let out = WinrateTrend.weekly(rows)
        XCTAssertEqual(out.count, 2, "坏日期不能被并进任何一周")
        XCTAssertEqual(out.map(\.date).sorted(), ["2026-09-07", "坏日期"].sorted())
    }

    /// 阈值常量本身：120（超过才聚合）—— 改它要同步改界面文案与文档
    func testWeeklyThresholdIs120() {
        XCTAssertEqual(WinrateTrend.weeklyThreshold, 120)
    }

    /// 聚合后的行**仍然是 `WinrateTrendRow`**（下游图表/表格不用改类型）
    func testAggregatedRowKeepsTheSameTypeAndLayerKeys() {
        // 输入要**四层都给**：只给两层的话另两层聚合后本来就该是 `nil`（见上一个用例），
        //   拿它断言"四层都在"是**测试写错**
        let out = WinrateTrend.weekly([row("2026-09-07", window: 60, close: 50,
                                           snapshot: 40, ceiling: 30)])
        XCTAssertEqual(out.count, 1)
        for key in WinrateTrend.layerKeys {
            XCTAssertNotNil(out[0].winrate(for: key), "四层都给了，聚合结果里就该都在（\(key)）")
        }
        XCTAssertEqual(wr(out[0], "snapshot"), 40, accuracy: 1e-9)
        XCTAssertEqual(wr(out[0], "ceiling"), 30, accuracy: 1e-9)
    }
}
