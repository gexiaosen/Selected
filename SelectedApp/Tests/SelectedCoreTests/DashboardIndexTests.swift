import XCTest
@testable import SelectedCore

/// 看板指数选择/补位规则（产品口径：恒 4 个、已选优先、不足按目录补位、最多 4 个）。
final class DashboardIndexTests: XCTestCase {

    func testDefaultDisplayedIsFirstFour() {
        let shown = DashboardIndexSelection.displayed(IndexCatalog.defaultSelected)
        XCTAssertEqual(shown.map(\.symbol),
                       ["sh000001", "sz399001", "sh000688", "sh000510"])
        XCTAssertEqual(shown.count, IndexCatalog.visibleCount)
    }

    func testFewerSelectedAreFilledInCatalogOrder() {
        let shown = DashboardIndexSelection.displayed(["sh000510", "sh000001"])
        XCTAssertEqual(shown.map(\.symbol),
                       ["sh000510", "sh000001", "sz399001", "sh000688"],
                       "已选顺序保留，其余按目录顺序补位")
    }

    func testSelectedOrderIsDisplayOrder() {
        let shown = DashboardIndexSelection.displayed(["sh000688", "sh000001", "sh000510", "sz399001"])
        XCTAssertEqual(shown.map(\.symbol),
                       ["sh000688", "sh000001", "sh000510", "sz399001"])
    }

    func testNormalizeDropsUnknownAndDuplicatesAndCapsAtFour() {
        let normalized = DashboardIndexSelection.normalize([
            "sh000001", "sh000001", "NOPE", "sz399001",
            "sh000688", "sh000510", "sh000300",
        ])
        XCTAssertEqual(normalized,
                       ["sh000001", "sz399001", "sh000688", "sh000510"])
    }

    func testToggleRejectsFifthAndLastRemoval() {
        let full = IndexCatalog.defaultSelected
        let fifth = DashboardIndexSelection.toggle("sh000300", in: full)
        XCTAssertEqual(fifth.selection, full)
        XCTAssertNotNil(fifth.error)

        let one = ["sh000001"]
        let removeLast = DashboardIndexSelection.toggle("sh000001", in: one)
        XCTAssertEqual(removeLast.selection, one)
        XCTAssertNotNil(removeLast.error)

        let add = DashboardIndexSelection.toggle("sh000300", in: ["sh000001", "sz399001"])
        XCTAssertNil(add.error)
        XCTAssertEqual(add.selection, ["sh000001", "sz399001", "sh000300"])
    }

    func testMoveWithinSelection() {
        let moved = DashboardIndexSelection.move("sh000510", offset: -1,
                                                 in: ["sh000001", "sz399001", "sh000510"])
        XCTAssertEqual(moved, ["sh000001", "sh000510", "sz399001"])
        XCTAssertEqual(DashboardIndexSelection.move("sh000001", offset: -1,
                                                    in: ["sh000001", "sz399001"]),
                       ["sh000001", "sz399001"], "越界不动")

        let dragForward = DashboardIndexSelection.move("sh000510", to: "sh000001",
                                                       in: ["sh000001", "sz399001", "sh000688", "sh000510"])
        XCTAssertEqual(dragForward, ["sh000510", "sh000001", "sz399001", "sh000688"])

        let dragBack = DashboardIndexSelection.move("sh000001", to: "sh000688",
                                                    in: ["sh000001", "sz399001", "sh000688", "sh000510"])
        XCTAssertEqual(dragBack, ["sz399001", "sh000688", "sh000001", "sh000510"])
    }

    func testAutoFilledOnlyReturnsMissingSlots() {
        let auto = DashboardIndexSelection.autoFilled(["sh000001", "sz399001"])
        XCTAssertEqual(auto.map(\.symbol), ["sh000688", "sh000510"])
        XCTAssertTrue(DashboardIndexSelection.autoFilled(IndexCatalog.defaultSelected).isEmpty)
    }

    /// 指数批量解析必须保留**完整 symbol**：`sh000001` / `sz000001` 的数字部分相同，
    /// 用纯数字做键会互相覆盖（自选 `parseBatch` 仍保持纯数字键，不能被这次改动带偏）。
    func testIndexBatchKeepsFullSymbolKeys() {
        func line(market: String, name: String, code: String, price: String,
                  prev: String, pct: String) -> String {
            var f = Array(repeating: "0", count: 50)
            f[0] = "1"
            f[1] = name
            f[2] = code
            f[3] = price
            f[4] = prev
            f[5] = prev
            f[31] = "0"
            f[32] = pct
            f[33] = price
            f[34] = price
            f[37] = "100"
            f[45] = "1000"
            return "v_\(market)\(code)=\"" + f.joined(separator: "~") + "\";"
        }
        let text = line(market: "sh", name: "上证指数", code: "000001",
                        price: "3735.16", prev: "3735.37", pct: "-0.01") + "\n"
            + line(market: "sz", name: "平安银行", code: "000001",
                   price: "11.20", prev: "11.00", pct: "1.82")

        let full = StockQuotes.parseBatchFullKeys(text)
        XCTAssertEqual(Set(full.keys), ["sh000001", "sz000001"])
        XCTAssertEqual(full["sh000001"]?.market, "sh")
        XCTAssertEqual(full["sz000001"]?.market, "sz")

        let digits = StockQuotes.parseBatch(text)
        XCTAssertEqual(digits.count, 1, "纯数字键口径下同码会合并（自选列表的既有行为）")
    }
}
