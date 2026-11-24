import XCTest
@testable import SelectedCore

/// 「数据源新鲜度徽章」的行为契约。
///
/// 这枚徽章的判据**全部来自日志文本**（`data_source_logs` 的
/// `source` / `event` / `ts`），而日志的事件词表是散落在 `DataSources` 各调用点里的、
/// 没有 schema 约束的字符串。写错一个事件名不会编译报错、也不会让任何检查变红 ——
/// 只会让徽章**安静地常年显示绿色**（把"从未成功过"读成"刚刚成功"）。
/// 故这里把每条判据钉死。
final class DataFreshnessTests: XCTestCase {

    private func row(_ ts: String, _ source: String, _ event: String) -> [String: Any] {
        ["ts": ts, "source": source, "event": event]
    }

    // MARK: - ① 分级（纯函数）

    func testFreshWhenSyncedWithLatest() {
        XCTAssertEqual(DataFreshness.classify(asOf: "2026-09-18", latest: "2026-09-18",
                                              previous: "2026-09-17"), .fresh)
    }

    /// 长假期间源仍被刷新（asOf 晚于参照日）→ 新鲜，不是过期
    func testFreshWhenAheadOfLatest() {
        XCTAssertEqual(DataFreshness.classify(asOf: "2026-10-05", latest: "2026-09-30",
                                              previous: "2026-09-29"), .fresh)
    }

    func testLaggingWhenExactlyOneObservedDayBehind() {
        XCTAssertEqual(DataFreshness.classify(asOf: "2026-09-17", latest: "2026-09-18",
                                              previous: "2026-09-17"), .lagging)
    }

    func testExpiredWhenOlderThanPrevious() {
        XCTAssertEqual(DataFreshness.classify(asOf: "2026-09-10", latest: "2026-09-18",
                                              previous: "2026-09-17"), .expired)
    }

    /// 只观察到一个交易日时没有"前一个"可比 —— 落后就只能是过期（不能猜成 lagging）
    func testExpiredWhenNoPreviousReference() {
        XCTAssertEqual(DataFreshness.classify(asOf: "2026-09-10", latest: "2026-09-18",
                                              previous: nil), .expired)
    }

    /// 无成功记录 ≠ 异常：如实报 unknown，由聚合层决定不告警
    func testUnknownWithoutSuccessRecord() {
        XCTAssertEqual(DataFreshness.classify(asOf: nil, latest: "2026-09-18",
                                              previous: "2026-09-17"), .unknown)
    }

    /// 应用还没观察过任何交易日 → 没有参照系，不猜成过期
    func testUnknownWithoutReference() {
        XCTAssertEqual(DataFreshness.classify(asOf: "2026-09-18", latest: nil, previous: nil), .unknown)
    }

    // MARK: - ② 参照系

    func testObservedDaysFiltersAndSorts() {
        let meta: [String: Int] = ["2026-09-18": 63, "2026-09-17": 3, "bad": 1, "2026-09-16": 63]
        XCTAssertEqual(DataFreshness.observedDays(meta), ["2026-09-16", "2026-09-17", "2026-09-18"])
    }

    func testReferenceNeedsTwoDaysForPrevious() {
        let one = DataFreshness.reference(["2026-09-18"])
        XCTAssertEqual(one.latest, "2026-09-18")
        XCTAssertNil(one.previous, "只有一个观察日时不得凭空造出'前一个交易日'")

        let two = DataFreshness.reference(["2026-09-16", "2026-09-17", "2026-09-18"])
        XCTAssertEqual(two.latest, "2026-09-18")
        XCTAssertEqual(two.previous, "2026-09-17")

        let none = DataFreshness.reference([])
        XCTAssertNil(none.latest)
        XCTAssertNil(none.previous)
    }

    // MARK: - ③ 从日志派生

    func testTencentFullScanIsHeartbeat() {
        let items = DataFreshness.derive(
            rows: [row("2026-09-18T14:30:00", "tencent", "full_scan")],
            latest: "2026-09-18", previous: "2026-09-17")
        let t = items.first { $0.key == "tencent" }
        XCTAssertEqual(t?.asOf, "2026-09-18")
        XCTAssertEqual(t?.level, .fresh)
    }

    /// **本组最关键的一条**：列表刷新的成功事件记在 `sina` 名下，
    /// `fund_list` 这个 source 只在降级时出现 —— 把降级当成功，徽章就会常年假绿。
    func testListRefreshSuccessIsOnSinaNotOnOwnSource() {
        let items = DataFreshness.derive(
            rows: [
                row("2026-09-18T09:05:00", "sina", "fund_list_refreshed"),
                row("2026-09-18T09:05:01", "fund_list", "fallback_cache"),
            ],
            latest: "2026-09-18", previous: "2026-09-17")
        let f = items.first { $0.key == "fund_list" }
        XCTAssertEqual(f?.asOf, "2026-09-18", "成功心跳在 sina|fund_list_refreshed 上")
        XCTAssertEqual(f?.level, .fresh)
        // 最近一条相关日志是**降级**，必须如实带出来供排查
        XCTAssertEqual(f?.lastEvent, "fallback_cache")
    }

    /// 只有降级、没有成功 → unknown（不是 fresh）
    func testDegradedOnlyMeansUnknownNotFresh() {
        let items = DataFreshness.derive(
            rows: [row("2026-09-18T09:05:01", "hk_list", "fallback_cache")],
            latest: "2026-09-18", previous: "2026-09-17")
        let h = items.first { $0.key == "hk_list" }
        XCTAssertNil(h?.asOf, "降级日志不得被当成成功记录")
        XCTAssertEqual(h?.level, .unknown)
        XCTAssertEqual(h?.lastEvent, "fallback_cache")
    }

    /// `sina` 被三个列表源共享：别家的事件不得污染本源的"最近事件"
    func testSharedSinaEventsDoNotLeakAcrossSources() {
        let items = DataFreshness.derive(
            rows: [row("2026-09-18T09:05:00", "sina", "fund_list_refreshed")],
            latest: "2026-09-18", previous: "2026-09-17")
        let s = items.first { $0.key == "stock_list" }
        XCTAssertNil(s?.asOf, "fund_list 的成功不得算作 stock_list 的成功")
        XCTAssertNil(s?.lastEvent, "fund_list 的事件不得成为 stock_list 的'最近事件'")
    }

    /// "最近事件"取**最新**那条（不区分成败），而 `asOf` 取**最新的成功日**
    func testLastEventIsNewestWhileAsOfIsNewestSuccess() {
        let items = DataFreshness.derive(
            rows: [
                row("2026-09-18T09:05:00", "tencent", "full_scan"),
                row("2026-09-18T14:30:00", "tencent", "chunk_partial"),
            ],
            latest: "2026-09-18", previous: "2026-09-17")
        let t = items.first { $0.key == "tencent" }
        XCTAssertEqual(t?.asOf, "2026-09-18")
        XCTAssertEqual(t?.lastEvent, "chunk_partial", "最近事件应是时间最新的那条")
    }

    /// 多日多次成功 → 取最新成功日；落后一个观察日 → lagging
    func testAsOfTakesLatestSuccessAndClassifiesLagging() {
        let items = DataFreshness.derive(
            rows: [
                row("2026-09-10T09:05:00", "sina", "stock_list_refreshed"),
                row("2026-09-17T09:05:00", "sina", "stock_list_refreshed"),
                row("2026-09-10T09:05:01", "stock_list", "refreshed"),
            ],
            latest: "2026-09-18", previous: "2026-09-17")
        let s = items.first { $0.key == "stock_list" }
        XCTAssertEqual(s?.asOf, "2026-09-17")
        XCTAssertEqual(s?.level, .lagging)
    }

    /// 分时K线：`ownSources` 为空（降级事件与成功事件同挂共享的 `sina`，无法归属）→
    /// 只认自己的成功心跳，`5min_fallback` 不得成为它的"最近事件"
    func testSharedOnlySourcePicksUpJustItsSuccessEvent() {
        let items = DataFreshness.derive(
            rows: [
                row("2026-09-18T14:25:00", "sina", "5min"),
                row("2026-09-18T14:30:00", "sina", "5min_fallback"),
            ],
            latest: "2026-09-18", previous: "2026-09-17")
        let m = items.first { $0.key == "5min" }
        XCTAssertEqual(m?.asOf, "2026-09-18")
        XCTAssertEqual(m?.lastEvent, "5min", "共享 source 上无法归属的降级事件不应被认领")
        XCTAssertEqual(m?.level, .fresh)
    }

    /// 行序无关（`data_source_logs` 按 ts 倒序取，但判据不得依赖入参顺序）
    func testDeriveIsOrderIndependent() {
        let a = row("2026-09-17T09:05:00", "sina", "stock_list_refreshed")
        let b = row("2026-09-18T09:05:00", "sina", "stock_list_refreshed")
        let asc = DataFreshness.derive(rows: [a, b], latest: "2026-09-18", previous: "2026-09-17")
        let desc = DataFreshness.derive(rows: [b, a], latest: "2026-09-18", previous: "2026-09-17")
        XCTAssertEqual(asc.first { $0.key == "stock_list" }?.asOf,
                       desc.first { $0.key == "stock_list" }?.asOf)
    }

    func testDeriveCoversAllDeclaredSources() {
        let items = DataFreshness.derive(rows: [], latest: "2026-09-18", previous: "2026-09-17")
        XCTAssertEqual(items.map(\.key), DataFreshness.specs.map(\.key),
                       "每个声明的源都必须有产出（缺项会让徽章漏报某个源）")
        XCTAssertTrue(items.allSatisfy { $0.level == .unknown })
    }

    // MARK: - ④ 聚合（徽章只显示一枚）

    func testAggregateTakesWorstAmongKnown() {
        let fresh = SourceFreshness(key: "a", label: "A", asOf: "2026-09-18",
                                    lastEvent: nil, lastEventAt: nil, level: .fresh)
        let lagging = SourceFreshness(key: "b", label: "B", asOf: "2026-09-17",
                                      lastEvent: nil, lastEventAt: nil, level: .lagging)
        let expired = SourceFreshness(key: "c", label: "C", asOf: "2026-09-01",
                                      lastEvent: nil, lastEventAt: nil, level: .expired)

        XCTAssertEqual(DataFreshness.aggregate([fresh, fresh]), .fresh)
        XCTAssertEqual(DataFreshness.aggregate([fresh, lagging]), .lagging)
        XCTAssertEqual(DataFreshness.aggregate([lagging, expired]), .expired)
        XCTAssertEqual(DataFreshness.aggregate([expired, lagging, fresh]), .expired)
    }

    /// `unknown` 不参与告警 —— 否则"从没搜过港股"会让徽章常年飘红（狼来了）
    func testUnknownDoesNotDriveAggregate() {
        let fresh = SourceFreshness(key: "a", label: "A", asOf: "2026-09-18",
                                    lastEvent: nil, lastEventAt: nil, level: .fresh)
        let unknown = SourceFreshness(key: "b", label: "B", asOf: nil,
                                      lastEvent: nil, lastEventAt: nil, level: .unknown)
        XCTAssertEqual(DataFreshness.aggregate([fresh, unknown]), .fresh)
        XCTAssertEqual(DataFreshness.aggregate([unknown, unknown]), .unknown,
                       "全部无记录时如实回 unknown（徽章此时不显示）")
        XCTAssertEqual(DataFreshness.aggregate([]), .unknown)
    }
}
