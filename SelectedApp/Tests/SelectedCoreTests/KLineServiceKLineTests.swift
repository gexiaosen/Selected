import XCTest
@testable import SelectedCore

/// 腾讯日/周/月线解析：第 9 字段是**万元**成交额，必须 ×10000 换成元。
final class KLineServiceKLineTests: XCTestCase {

    func testParseTencentKLinesReadsAmountInWanYuan() throws {
        // 真实 newfqkline 行（600519 2026-10-29 / 前一行缺额字段）
        let lines: [[Any]] = [
            ["2026-10-29", "1349.99", "1354.00", "1356.00", "1330.01",
             "42992.00", [String: Any](), "0.34", "579798.03", ""],
            ["2026-10-30", "1363.00", "1361.69", "1363.00", "1352.98", "5409"],
        ]
        let items = KLineService.parseTencentKLines(lines)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].volume, 42992)
        XCTAssertEqual(items[0].amount, 5_797_980_300, accuracy: 0.5, "万元 → 元")
        XCTAssertEqual(items[1].amount, 0, "缺第 9 字段 → 成交额回落 0")
    }

    func testParseTencentKLinesSkipsBadRows() {
        let lines: [[Any]] = [
            ["2026-10-30", "0", "0", "0", "0", "1"],
            ["bad"],
        ]
        XCTAssertTrue(KLineService.parseTencentKLines(lines).isEmpty)
    }
}
