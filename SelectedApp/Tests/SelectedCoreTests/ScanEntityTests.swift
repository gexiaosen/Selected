import XCTest
@testable import SelectedCore

/// 扫描结果实体 vs **真实引擎输出**
///
/// 这个文件是证明"实体与生产者一致"的手段。它拿
/// `engine/tests/fixtures/2026-09-14/expected_scan_result{,_wide}.json` —— 真实产出
/// 的黄金结果 —— 做两件事：
///
/// 1. **键覆盖**：实体声明的键必须**恰好**覆盖引擎真实输出的键
///    （少声明 → 消费方拿不到；多声明 → 拼错了键名。两个方向都红）
/// 2. **无损往返**：`JSON → 实体 → JSON` 之后，逐键逐值**完全相等**
///    （含数字形态：`110` 与 `110.0` 必须各自保持）
///
/// 验证工具（`canonical` / `roundTrip`）在 `EntityTestSupport` —— 它走**生产同款编码器**
/// `PyJSON.encode`（`ScanStore.persist` 写的就是它，`SQLiteReader` 读回来再 `JSONSerialization` 解析）。
/// 不能用 `JSONDecoder`：它会把 `110` 与 `110.0` 都归一化（`NSNumber.isEqual` 按值比较），
/// 正好把 int/float 形态漂移盖掉。
final class ScanEntityTests: XCTestCase {

    // MARK: - 夹具定位

    private static let fixtureDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // Tests/SelectedCoreTests
        .deletingLastPathComponent()      // Tests
        .deletingLastPathComponent()      // SelectedApp
        .deletingLastPathComponent()      // 仓库根
        .appendingPathComponent("engine/tests/fixtures/2026-09-14")

    /// 缺失 → **失败**（不是 `XCTSkip`）：`expected_scan_result*.json` 是**黄金夹具**，
    /// **不可重新生成**，且已**纳入版本管理** —— 缺失 = 仓库不完整。
    /// 跳过会把"全新 clone 上少跑一批"伪装成"全绿"。
    /// 见 `.gitignore` 里 `engine/tests/fixtures/` 那段说明。
    private func loadFixture(_ name: String) throws -> JSONValue {
        let url = Self.fixtureDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EntityTestSupport.FixtureMissing(
                path: "engine/tests/fixtures/2026-09-14/\(name)")
        }
        let data = try Data(contentsOf: url)
        return JSONValue(try JSONSerialization.jsonObject(with: data))
    }

    /// 规范形式 / 往返 —— **转发到 `EntityTestSupport`**，不在这里留第二份实现。
    private func canonical(_ v: JSONValue) throws -> String {
        try EntityTestSupport.canonical(v)
    }

    private func roundTrip(_ v: JSONValue) throws -> JSONValue {
        try EntityTestSupport.roundTrip(v)
    }

    // MARK: - 通用检查

    /// 键覆盖：真实键集必须落在 `declaredKeys` 内；`declaredKeys` 里的"多余键"只允许是条件键
    private func assertKeyCoverage<T: JSONEntity>(
        _ type: T.Type, _ json: JSONValue, _ path: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let actual = Set(json.dict.keys)
        let declared = T.declaredKeys
        let missing = actual.subtracting(declared)
        XCTAssertTrue(missing.isEmpty,
                      "\(path)：引擎输出了实体未声明的键 \(missing.sorted())（消费方拿不到这些字段）",
                      file: file, line: line)
        let phantom = declared.subtracting(actual).subtracting(T.conditionalKeys)
        XCTAssertTrue(phantom.isEmpty,
                      "\(path)：实体声明了引擎输出里不存在的键 \(phantom.sorted())（键名拼错？）",
                      file: file, line: line)
    }

    /// 无损往返
    ///
    /// 只比**规范化后的 JSON 文本**，不用 `entity == entity`：
    /// `JSONValue` 的 `Hashable` 是 `String(describing: raw)`（为性能刻意如此），
    /// 而 Swift 字典的 `description` **不保证键顺序** → 两个内容相同的实体可能判不等。
    /// 所以实体相等性只能用于"同一份 raw"的场景，**不能**当作内容比对。
    /// （这也是视图要用 `id: \.code` 这类稳定主键、而不是 `\.self` 的原因之一。）
    private func assertLossless<T: JSONEntity>(
        _ entity: T, _ original: JSONValue, _ path: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let back = try roundTrip(entity.json)
        XCTAssertEqual(try canonical(back), try canonical(original),
                       "\(path)：JSON → 实体 → JSON 之后内容变了（丢字段或改类型）",
                       file: file, line: line)
    }

    /// 递归遍历扫描结果树
    private func checkTree(_ result: ScanResult, _ label: String) throws {
        try assertLossless(result, result.json, "\(label).result")

        assertKeyCoverage(MarketEnv.self, result.marketEnv.json, "\(label).market_env")
        try assertLossless(result.marketEnv, result.marketEnv.json, "\(label).market_env")

        assertKeyCoverage(ScanStats.self, result.stats.json, "\(label).stats")
        try assertLossless(result.stats, result.stats.json, "\(label).stats")

        for (tierName, picks) in [("tier1", result.tier1), ("tier2", result.tier2),
                                  ("tier3", result.tier3)] {
            for (i, pick) in picks.enumerated() {
                let p = "\(label).\(tierName)[\(i)]"
                assertKeyCoverage(ScanPick.self, pick.json, p)
                try assertLossless(pick, pick.json, p)

                assertKeyCoverage(ScanDeepInfo.self, pick.deepInfo.json, "\(p).deep_info")
                try assertLossless(pick.deepInfo, pick.deepInfo.json, "\(p).deep_info")

                assertKeyCoverage(ScanIntraday.self, pick.deepInfo.intraday.json, "\(p).intraday")
                try assertLossless(pick.deepInfo.intraday, pick.deepInfo.intraday.json, "\(p).intraday")
            }
        }

        for (i, e) in result.excludedDeepTrend.enumerated() {
            assertKeyCoverage(ScanExcluded.self, e.json, "\(label).excluded[\(i)]")
            try assertLossless(e, e.json, "\(label).excluded[\(i)]")
        }
        for (i, e) in result.etfRecommendations.enumerated() {
            assertKeyCoverage(ScanEtfRec.self, e.json, "\(label).etf[\(i)]")
            try assertLossless(e, e.json, "\(label).etf[\(i)]")
        }
    }

    // MARK: - 两个黄金夹具

    func testNarrowFixtureCoversExactly() throws {
        try checkTree(ScanResult(try loadFixture("expected_scan_result.json")), "narrow")
    }

    func testWideFixtureCoversExactly() throws {
        try checkTree(ScanResult(try loadFixture("expected_scan_result_wide.json")), "wide")
    }

    // MARK: - 类型化取值（证明属性真的读到了值，而不是全都落回默认）

    func testTypedAccessorsReadRealValues() throws {
        let r = ScanResult(try loadFixture("expected_scan_result.json"))
        XCTAssertEqual(r.date, "2026-09-14")
        XCTAssertEqual(r.slot, 1)
        XCTAssertEqual(r.slotLabel, "14:00")
        XCTAssertEqual(r.status, "ok")
        XCTAssertTrue(r.isOK)
        XCTAssertTrue(r.tradingDay)
        XCTAssertEqual(r.tradingDayReason, "fixture")
        XCTAssertEqual(r.dataSource, "tencent")
        XCTAssertEqual(r.paramVersion, "backtest-1.3.0")
        XCTAssertFalse(r.budgetLimited)
        XCTAssertTrue(r.budgetSkippedCodes.isEmpty)

        XCTAssertEqual(r.stats.totalScanned, 5222)
        XCTAssertEqual(r.stats.tier1Count, r.tier1.count)
        XCTAssertEqual(r.stats.tier2Count, r.tier2.count)
        XCTAssertEqual(r.stats.finalCount, r.tier1.count + r.tier2.count + r.tier3.count)

        XCTAssertEqual(r.marketEnv.upCount, 2739)
        XCTAssertEqual(r.marketEnv.downCount, 2133)
        XCTAssertEqual(r.marketEnv.flatCount, 350)
        XCTAssertTrue(r.marketEnv.ratioOK)
        XCTAssertFalse(r.marketEnv.shOK)

        let pick = try XCTUnwrap(r.tier1.first)
        XCTAssertEqual(pick.code, "600719")
        XCTAssertEqual(pick.name, "大连热电")
        XCTAssertEqual(pick.score, 110)
        XCTAssertEqual(pick.scoreRaw, 110)
        XCTAssertFalse(pick.tierLockApplied)
        XCTAssertTrue(pick.marketWeak)
        XCTAssertFalse(pick.scoreDetails.isEmpty, "评分明细不该为空（若空说明键名读错了）")
        XCTAssertTrue(pick.penaltyDetails.isEmpty)

        let di = pick.deepInfo
        XCTAssertEqual(di.ma5, 7.7)
        XCTAssertTrue(di.maPass)
        XCTAssertNotNil(di.volMult5d, "vol_mult_5d 在本夹具里有值")
        XCTAssertNotNil(di.gainRatio)
        XCTAssertNotNil(di.cum5d)

        let idy = di.intraday
        XCTAssertEqual(idy.barsToday, 41)
        XCTAssertEqual(idy.lastBarTime, "14:25")
        XCTAssertEqual(idy.highBucket, "tail")
        XCTAssertTrue(idy.tailNewHigh)

        let etf = try XCTUnwrap(r.etfRecommendations.first)
        XCTAssertEqual(etf.code, "159992")
        XCTAssertEqual(etf.price, 0.828, accuracy: 1e-9)

        let ex = try XCTUnwrap(r.excludedDeepTrend.first)
        XCTAssertEqual(ex.code, "002859")
        XCTAssertFalse(ex.reason.isEmpty)
    }

    // MARK: - 可空字段：`null` 与 `0` 必须能区分

    /// 这三个字段可能显式为 null（值异常时抛错并计入 `score_errors`）。
    /// null 与 0 是两个不同结论 —— 实体层必须保留区别。
    func testNullableDeepInfoFieldsKeepNullDistinctFromZero() {
        let withNull = ScanDeepInfo(JSONValue([
            "vol_mult_5d": NSNull(), "gain_ratio": NSNull(), "shadow_body_ratio": NSNull(),
            "cum_5d": NSNull(),
        ]))
        XCTAssertNil(withNull.volMult5d)
        XCTAssertNil(withNull.gainRatio)
        XCTAssertNil(withNull.shadowBodyRatio)
        XCTAssertNil(withNull.cum5d)

        let withZero = ScanDeepInfo(JSONValue([
            "vol_mult_5d": 0, "gain_ratio": 0.0, "shadow_body_ratio": 0, "cum_5d": 0.0,
        ]))
        XCTAssertEqual(withZero.volMult5d, 0)
        XCTAssertEqual(withZero.gainRatio, 0)
        XCTAssertEqual(withZero.shadowBodyRatio, 0)
        XCTAssertEqual(withZero.cum5d, 0)

        // 键缺失（不是显式 null）也走 nil
        XCTAssertNil(ScanDeepInfo(JSONValue([:])).volMult5d)
    }

    // MARK: - 缺键 / 空对象的退化

    func testMissingKeysFallBackToDefaultsWithoutCrash() {
        let empty = ScanResult(JSONValue([:]))
        XCTAssertEqual(empty.date, "")
        XCTAssertEqual(empty.slot, 0)
        XCTAssertEqual(empty.status, "ok", "status 缺省是 ok（与 ScanStore.slimResult 的 `?? \"ok\"` 一致）")
        XCTAssertTrue(empty.tradingDay, "trading_day 缺省 true")
        XCTAssertTrue(empty.tier1.isEmpty)
        XCTAssertEqual(empty.stats.totalScanned, 0)
        XCTAssertEqual(empty.marketEnv.shChangePct, 0)
        XCTAssertTrue(empty.slimJSON.dict.isEmpty == false, "slimJSON 至少要产出那 13 个键")
    }

    /// 早退分支（非交易日 / 数据不足）返回的往往只有 status + 少量键
    func testEarlyReturnShapeIsTolerated() throws {
        let early = ScanResult(JSONValue(["status": "not_trading_day", "date": "2026-10-01"]))
        XCTAssertEqual(early.status, "not_trading_day")
        XCTAssertFalse(early.isOK)
        XCTAssertTrue(early.tier1.isEmpty)
        XCTAssertEqual(early.stats.tier1Count, 0)
        try assertLossless(early, early.json, "early-return")
    }

    // MARK: - 失败分支的两个独有键（黄金夹具里**没有**这两个分支）

    /// `data_error` / `persist_error` 只在失败分支出现，两个黄金夹具都是 `ok` 轮次。
    ///
    /// **黄金结果里不存在的分支，键覆盖 / 往返都碰不到它**。
    /// 这两个键由 `ScanRunner` 直接写入（`data_error` 在 `:85` / `:100`，
    /// `persist_error` 在 `:353`），故这里按其写入语句构造最小输入。
    /// **键名写错不会静默** —— `Store.finishRound` / `Scheduler.finish` 已改走
    /// `dataErrorDash` / `persistErrorDash`，拼错是编译错误。
    func testFailureBranchKeysAreTyped() {
        let insufficient = ScanResult(JSONValue([
            "status": "data_insufficient",
            "data_error": "全量行情仅 3 只，低于健全性阈值 100",
        ]))
        XCTAssertEqual(insufficient.status, "data_insufficient")
        XCTAssertFalse(insufficient.isOK)
        XCTAssertEqual(insufficient.dataErrorDash, "全量行情仅 3 只，低于健全性阈值 100")

        let persistFailed = ScanResult(JSONValue([
            "status": "persist_failed",
            "persist_error": "disk I/O error",
        ]))
        XCTAssertEqual(persistFailed.status, "persist_failed")
        XCTAssertEqual(persistFailed.persistErrorDash, "disk I/O error")

        // 键缺失 → "-"（与旧的 `stringOrDash` 逐字一致；`Store`/`Scheduler` 直接把它当文案）
        XCTAssertEqual(ScanResult(JSONValue(["status": "ok"])).dataErrorDash, "-")
        XCTAssertEqual(ScanResult(JSONValue(["status": "ok"])).persistErrorDash, "-")
    }

    /// 这两个键必须是**条件键** —— 正常轮次（黄金夹具）确实不产出它们
    func testFailureBranchKeysAreConditionalNotAlwaysPresent() throws {
        let ok = try loadFixture("expected_scan_result.json")
        XCTAssertFalse(ok.dict.keys.contains("data_error"), "正常轮次不产出 data_error")
        XCTAssertFalse(ok.dict.keys.contains("persist_error"), "正常轮次不产出 persist_error")
        XCTAssertTrue(ScanResult.conditionalKeys.contains("data_error"))
        XCTAssertTrue(ScanResult.conditionalKeys.contains("persist_error"))
    }

    // MARK: - slimJSON 逐键等价

    /// 实体版的 `slimJSON` 必须与 `ScanStore.slimResult` 产出**完全一样**的键值。
    func testSlimJSONMatchesLegacySlimResult() throws {
        let raw = try loadFixture("expected_scan_result.json")
        let slim = ScanResult(raw).slimJSON
        // 逐键与 `ScanStore.slimResult` 口径对照
        XCTAssertEqual(slim["date"].string, raw["date"].string)
        XCTAssertEqual(slim["slot"].int, raw["slot"].int)
        XCTAssertEqual(slim["slot_label"].string, raw["slot_label"].string)
        XCTAssertEqual(slim["screener_version"].string, raw["screener_version"].string)
        XCTAssertEqual(slim["param_version"].string, raw["param_version"].string)
        XCTAssertEqual(slim["status"].string, raw["status"].string)
        XCTAssertEqual(slim["data_source"].string, raw["data_source"].string)
        XCTAssertEqual(slim["budget_limited"].bool, raw["budget_limited"].bool)
        XCTAssertEqual(slim["budget_note"].string ?? "", raw["budget_note"].string ?? "")
        XCTAssertEqual(try canonical(slim["stats"]), try canonical(raw["stats"]))
        XCTAssertEqual(try canonical(slim["market_env"]), try canonical(raw["market_env"]))
        XCTAssertEqual(slim["budget_skipped_codes"].array.count,
                       raw["budget_skipped_codes"].array.count)
        // 明细不进 slim（走 picks 表）
        XCTAssertTrue(slim["tier1"].isNull)
    }
}
