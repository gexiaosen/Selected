import XCTest
@testable import SelectedCore

/// `BoardStrength` 的公式行为（板块页的"强度"指标）。
///
/// 这里**不钉具体分数**（权重是可解释的经验值，改权重不该让测试变红），
///   只钉**序关系与边界**——那才是"强度"这个指标的意义所在：
///   涨幅更高 / 上涨占比更高 / 资金更多 / 有涨停 ⇒ 强度不能更低。
final class BoardStrengthTests: XCTestCase {

    private func point(_ code: String, _ name: String, change: Double,
                       up: Int, down: Int, flat: Int = 0, net: Double) -> BoardHeatPoint {
        BoardHeatPoint(date: "2026-10-13", boardCode: code, boardName: name, index: 1000,
                       changePct: change, amount: 1e9, turnoverRate: 1.0, totalCap: 1e11,
                       mainNet: net, upCount: up, downCount: down, flatCount: flat,
                       leaderName: "龙头\(name)", leaderCode: "600000", leaderMarket: 1)
    }

    private func record(_ name: String, industry: String, boards: Int) -> LimitUpRecord {
        LimitUpRecord(date: "2026-10-13", code: "6000\(boards)\(name.count)", name: name,
                      price: 10, changePct: 10, amount: 1e8, turnoverRate: 5,
                      floatCap: 1e9, totalCap: 2e9, boards: boards, statDays: 1, statBoards: boards,
                      firstSeal: "09:35:00", lastSeal: "09:35:00", brokenCount: 0,
                      sealFund: 1e7, industry: industry)
    }

    func testStrongerBoardsScoreHigher() {
        let rows = [
            point("BK1", "强", change: 6, up: 20, down: 0, net: 3e8),
            point("BK2", "中", change: 1, up: 10, down: 5, net: 1e7),
            point("BK3", "弱", change: -5, up: 0, down: 20, net: -2e8),
        ]
        let s = BoardStrength.compute(rows: rows, limitUpByIndustry: [:])
        XCTAssertGreaterThan(s["BK1"]!.score, s["BK2"]!.score)
        XCTAssertGreaterThan(s["BK2"]!.score, s["BK3"]!.score)
        XCTAssertGreaterThanOrEqual(s["BK1"]!.score, 0)
        XCTAssertLessThanOrEqual(s["BK1"]!.score, 100)
    }

    func testLimitUpBonusRaisesScore() {
        let rows = [
            point("BK1", "有涨停", change: 3, up: 10, down: 0, net: 1e8),
            point("BK2", "无涨停", change: 3, up: 10, down: 0, net: 1e8),
        ]
        let withLimit = BoardStrength.compute(
            rows: rows,
            limitUpByIndustry: ["有涨停": [record("A", industry: "有涨停", boards: 2),
                                          record("B", industry: "有涨停", boards: 1)]])
        let without = BoardStrength.compute(rows: rows, limitUpByIndustry: [:])
        XCTAssertGreaterThan(withLimit["BK1"]!.score, without["BK1"]!.score,
                             "同一板块有涨停时强度必须更高（第四因子）")
        XCTAssertEqual(withLimit["BK1"]!.limitUpCount, 2)
        XCTAssertEqual(without["BK2"]!.limitUpCount, 0)
    }

    func testTiesGetSameScore() {
        let rows = [
            point("BK1", "甲", change: 2, up: 5, down: 5, net: 0),
            point("BK2", "乙", change: 2, up: 5, down: 5, net: 0),
        ]
        let s = BoardStrength.compute(rows: rows, limitUpByIndustry: [:])
        XCTAssertEqual(s["BK1"]!.score, s["BK2"]!.score, accuracy: 1e-9,
                       "完全并列的两块必须同分（分位用「严格小于」口径）")
    }

    func testEmptyInputIsEmpty() {
        XCTAssertTrue(BoardStrength.compute(rows: [], limitUpByIndustry: [:]).isEmpty)
    }

    func testZeroBreadthDoesNotDivideByZero() {
        // 源没给家数（全 0）时 upRatio 折 0，不能崩、也不能给 NaN
        let rows = [point("BK1", "无家数", change: 1, up: 0, down: 0, net: 1e7)]
        let s = BoardStrength.compute(rows: rows, limitUpByIndustry: [:])
        XCTAssertEqual(s["BK1"]!.upRatio, 0)
        XCTAssertFalse(s["BK1"]!.score.isNaN)
    }
}
