import XCTest
@testable import SelectedCore

/// 数据集注册表的运行时账本：成功/失败都要记，`nil` 一律算失败。
final class DataSourceRegistryTests: XCTestCase {

    private func counter(_ id: DataSetID) -> DataSourceRegistry.Health {
        DataSourceRegistry.health().first { $0.id == id }!
    }

    func testTimedCountsSuccessAndFailure() {
        let before = counter(.lhb)
        _ = DataSourceRegistry.timed(.lhb) { 1 }
        let afterSuccess = counter(.lhb)
        XCTAssertEqual(afterSuccess.requests, before.requests + 1)
        XCTAssertEqual(afterSuccess.failures, before.failures)
        XCTAssertNotNil(afterSuccess.lastSuccessAt)

        _ = DataSourceRegistry.timed(.lhb) { nil as Int? }
        let afterFailure = counter(.lhb)
        XCTAssertEqual(afterFailure.requests, afterSuccess.requests + 1)
        XCTAssertEqual(afterFailure.failures, afterSuccess.failures + 1)
    }

    func testSingleSourceDataSetsAreDeclaredNotHidden() {
        // 单源不是"没做"，是**明确选择**（字段口径独有）。这里把已知单点钉住：
        // 新增第二个源时这条会提示你同步更新注册表。
        XCTAssertTrue(DataSourceRegistry.singleSourceDataSets.contains(.lhb))
        XCTAssertTrue(DataSourceRegistry.singleSourceDataSets.contains(.limitUpPool))
        XCTAssertFalse(DataSourceRegistry.singleSourceDataSets.contains(.quotes))
        XCTAssertFalse(DataSourceRegistry.singleSourceDataSets.contains(.kline))
        XCTAssertFalse(DataSourceRegistry.singleSourceDataSets.contains(.minute))
    }

    /// 2026-11-02 新接的四条必须在册，且**各自的失败策略不许被顺手改宽**。
    ///
    /// `.fundFlow` 必须仍是 `singleSource`：东财那条已经实现并单独在册
    /// （`.eastmoneyFundFlow`），两家"主力净流入"同日反号 ⇒ 合并成一个池 = 同一列混两种定义。
    /// 谁把 `.fundFlow` 改成 `.pool`，这条会直接红。
    func testNewDataSetsAreRegisteredWithHonestPolicy() throws {
        let depth = try XCTUnwrap(DataSourceRegistry.entry(.depth))
        XCTAssertEqual(depth.policy, .singleSource, "五档只有腾讯给得出（东财 ulist/新浪简版都没有）")
        XCTAssertEqual(DataSourceRegistry.entry(.ticks)?.policy, .singleSource)
        XCTAssertEqual(DataSourceRegistry.entry(.tradeCalendar)?.policy, .inferenceFallback,
                       "官方日历取不到时退回「行情报价日期」这条间接判据，不是同口径的第二家")
        XCTAssertEqual(DataSourceRegistry.entry(.eastmoneyFundFlow)?.policy, .singleSource)
        XCTAssertEqual(DataSourceRegistry.entry(.fundFlow)?.policy, .singleSource,
                       "新浪与东财的资金流不可互换 ⇒ 合并成池即错")
        XCTAssertTrue(DataSourceRegistry.entry(.kline)!.providers.contains { $0.contains("同花顺") },
                      "K 线兜底加了同花顺，账本上必须看得见")
    }
}
