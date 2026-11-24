import XCTest
@testable import SelectedCore

/// `ScheduleStateCodec` —— 调度状态的持久化编解码。
///
/// **为什么值得单独一个测试文件**：这条链路容易出"写进去了但没读回来"的静默 bug ——
/// 例如 `lastFailureAt` 进了 `saveRetryState` 的字典、`loadRetryState` 却没读回来，
/// 后果是 App 一重启 `nextRetryTask` 的 `if let` 恒失败、**当天已失败的任务永不重试**，
/// 而 UI 仍显示"等待重试"。
///
/// 原则：**"写进去了"和"读回来了"是两件事**。下面用"逐字段往返相等"把这件事钉死：
/// 少读一个字段就会红。
final class ScheduleStateCodecTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_789_000_000)   // 固定时刻，避免用 Date() 引入不确定性
    private let t1 = Date(timeIntervalSince1970: 1_789_003_600)

    // MARK: - 往返

    func testRoundTripPreservesEveryField() throws {
        let originals: [String: TaskRuntimeState] = [
            "predict": TaskRuntimeState(status: .done, attempts: 1, changedAt: t0),
            "verify": TaskRuntimeState(status: .failed, attempts: 2,
                                       lastFailureAt: t1, message: "全量行情不足", changedAt: t1),
            "round1": TaskRuntimeState(status: .missed, attempts: 3, lastFailureAt: t0,
                                       message: "超出补跑窗口未执行", changedAt: t1),
            "round2": TaskRuntimeState(),      // 全 nil 的 pending
        ]
        let json = try XCTUnwrap(ScheduleStateCodec.toJSON(originals))
        let back = try XCTUnwrap(ScheduleStateCodec.fromJSON(json))
        XCTAssertEqual(back, originals, "逐字段往返必须相等 —— 少读一个字段就是那个历史 bug")
    }

    /// 精确到秒（时间戳是 Double，不该有精度损失）
    func testRoundTripKeepsTimestampsExact() throws {
        let st = TaskRuntimeState(status: .failed, attempts: 1,
                                  lastFailureAt: t1, message: "x", changedAt: t0)
        let back = try XCTUnwrap(ScheduleStateCodec.fromJSON(
            try XCTUnwrap(ScheduleStateCodec.toJSON(["a": st]))))
        XCTAssertEqual(back["a"]?.lastFailureAt, t1)
        XCTAssertEqual(back["a"]?.changedAt, t0)
    }

    /// 这条是回归锁：**失败时刻必须能读回来**
    func testLastFailureAtSurvivesRoundTrip() throws {
        let st = TaskRuntimeState(status: .failed, attempts: 1, lastFailureAt: t1)
        let back = try XCTUnwrap(ScheduleStateCodec.fromJSON(
            try XCTUnwrap(ScheduleStateCodec.toJSON(["round1": st]))))
        let restored = try XCTUnwrap(back["round1"])
        XCTAssertNotNil(restored.lastFailureAt,
                        "失败时刻丢失 → 重启后重试间隔算不出来，已失败任务将永不重试")
        XCTAssertEqual(restored.lastFailureAt, t1)
    }

    func testEmptyTableRoundTrip() throws {
        let back = ScheduleStateCodec.fromJSON(try XCTUnwrap(ScheduleStateCodec.toJSON([:])))
        XCTAssertEqual(back, [:])
    }

    // MARK: - 脏数据

    func testNoArchiveReturnsNilDistinctFromEmptyTable() {
        XCTAssertNil(ScheduleStateCodec.fromJSON(nil), "没有存档 → nil（触发旧键迁移）")
        XCTAssertEqual(ScheduleStateCodec.fromJSON("{}"), [:], "空存档 → 空表（不迁移）")
        XCTAssertNil(ScheduleStateCodec.fromJSON("not json"))
        XCTAssertNil(ScheduleStateCodec.fromJSON("[1,2,3]"))
    }

    /// 单条解不出来只丢那一条，不整体失败 —— 脏数据不该让整个状态表读不回来
    func testCorruptEntryIsDroppedNotFatal() throws {
        let payload: [String: Any] = [
            "good": ["status": "done", "attempts": 1],
            "badStatus": ["status": "wat", "attempts": 1],
            "notADict": "oops",
            "missingStatus": ["attempts": 2],
        ]
        let back = ScheduleStateCodec.decodeAll(payload)
        XCTAssertEqual(Set(back.keys), ["good"])
        XCTAssertEqual(back["good"]?.status, .done)
    }

    func testAttemptsDefaultsToZeroWhenAbsent() {
        XCTAssertEqual(ScheduleStateCodec.decode(["status": "pending"])?.attempts, 0)
    }

    func testAllStatusesSurviveRoundTrip() throws {
        for st in ScheduleStatus.allCases {
            let back = try XCTUnwrap(ScheduleStateCodec.fromJSON(
                try XCTUnwrap(ScheduleStateCodec.toJSON(["k": TaskRuntimeState(status: st)]))))
            XCTAssertEqual(back["k"]?.status, st, "\(st.rawValue) 未能往返")
        }
    }

    // MARK: - 旧版本迁移

    func testLegacyMigrationMarksCompletedTasksDone() {
        let out = ScheduleStateCodec.migrateLegacy(completed: ["predict", "verify"],
                                                   retryCounts: [:], failureMessages: [:],
                                                   lastFailureAt: [:], now: t0)
        XCTAssertEqual(out["predict"]?.status, .done)
        XCTAssertEqual(out["verify"]?.status, .done)
        XCTAssertEqual(out["predict"]?.changedAt, t0)
    }

    func testLegacyMigrationKeepsFailureDetails() {
        let out = ScheduleStateCodec.migrateLegacy(
            completed: ["predict"],
            retryCounts: ["round1": 2],
            failureMessages: ["round1": "落库失败"],
            lastFailureAt: ["round1": t1.timeIntervalSince1970],
            now: t0)
        XCTAssertEqual(out["round1"]?.status, .failed)
        XCTAssertEqual(out["round1"]?.attempts, 2)
        XCTAssertEqual(out["round1"]?.message, "落库失败")
        XCTAssertEqual(out["round1"]?.lastFailureAt, t1)
    }

    /// 已完成的任务不被失败记录覆盖（迁移顺序不能反）
    func testLegacyMigrationPrefersCompletedOverRetryRecord() {
        let out = ScheduleStateCodec.migrateLegacy(completed: ["round1"],
                                                   retryCounts: ["round1": 3],
                                                   failureMessages: ["round1": "旧失败"],
                                                   lastFailureAt: [:], now: t0)
        XCTAssertEqual(out["round1"]?.status, .done, "已重试成功后完成的任务不该被旧失败记录拉回失败态")
    }

    func testLegacyMigrationOnEmptyInput() {
        XCTAssertTrue(ScheduleStateCodec.migrateLegacy(completed: [], retryCounts: [:],
                                                       failureMessages: [:],
                                                       lastFailureAt: [:]).isEmpty)
    }

    /// 迁移结果必须能被新格式继续往返（否则升级当天之后就丢状态）
    func testMigratedStateIsRoundTrippable() throws {
        let migrated = ScheduleStateCodec.migrateLegacy(
            completed: ["predict"], retryCounts: ["round1": 2],
            failureMessages: ["round1": "落库失败"],
            lastFailureAt: ["round1": t1.timeIntervalSince1970], now: t0)
        let back = try XCTUnwrap(ScheduleStateCodec.fromJSON(
            try XCTUnwrap(ScheduleStateCodec.toJSON(migrated))))
        XCTAssertEqual(back, migrated)
    }
}
