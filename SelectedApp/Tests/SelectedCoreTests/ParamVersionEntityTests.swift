import XCTest
@testable import SelectedCore

/// 参数版本库行实体 vs **真实读取结果**
///
/// 夹具 `engine/tests/fixtures/param_version_outputs/versions.json` 是**真实捕获**：
/// 临时驱动（链接 `SelectedCore`）对测试库跑 `ParamStore.shared.listVersions()` 的输出。
///
/// 重点在 `deletable` —— `run_all.sh` 的 `param_source` 护栏钉死"只能有一份实现"。
final class ParamVersionEntityTests: XCTestCase {

    private func load() throws -> [JSONValue] {
        try EntityTestSupport.fixture("engine/tests/fixtures/param_version_outputs/versions.json").array
    }

    func testCoversExactlyAndRoundTrips() throws {
        let rows = try load()
        XCTAssertFalse(rows.isEmpty, "测试库里应有出厂参数版本")
        for (i, r) in rows.enumerated() {
            try EntityTestSupport.check(ParamVersionRow.self, r, "versions[\(i)]")
        }
    }

    func testTypedValues() throws {
        let rows = try load().map(ParamVersionRow.init)
        // 出厂版本排在前面（`ORDER BY is_builtin DESC`）
        XCTAssertTrue(rows.first?.isBuiltin ?? false, "第一行应是出厂版本")
        XCTAssertTrue(rows.contains { $0.isBuiltin }, "应有出厂版本")
        XCTAssertTrue(rows.contains { $0.name == "默认" })

        let def = try XCTUnwrap(rows.first { $0.name == "默认" })
        XCTAssertTrue(def.isBuiltin)
        XCTAssertFalse(def.deletable, "出厂且受保护的版本不可删")
        XCTAssertFalse(def.isActive, "本库的激活版本不是「默认」")
        XCTAssertFalse(def.note.isEmpty, "出厂版本带说明")
        XCTAssertTrue(def.hasCreatedAt)
        XCTAssertGreaterThan(def.createdAt, 1_700_000_000, "Unix 时间戳量级检查")

        // 激活版本恰好一个（且不可删）
        let actives = rows.filter { $0.isActive }
        XCTAssertLessThanOrEqual(actives.count, 1, "激活版本最多一个")
        for a in actives {
            XCTAssertFalse(a.deletable, "**当前激活的版本不可删**（deletable 的裁决条件之一）")
        }
        // 至少有一个可删的（本库有 backtest* 系列）
        XCTAssertTrue(rows.contains { $0.deletable }, "应存在可删版本")
    }

    /// `deletable` 的三条裁决：非保护版本 **且** 非当前激活
    /// （这里用构造数据把语义钉死，免得以后有人简化成"非出厂即可删"）
    func testDeletableIsNotMerelyNotBuiltin() {
        let builtinButDeletable = ParamVersionRow(JSONValue([
            "name": "backtest", "is_builtin": true, "is_active": false, "deletable": true,
        ]))
        XCTAssertTrue(builtinButDeletable.isBuiltin)
        XCTAssertTrue(builtinButDeletable.deletable, "出厂但不在保护名单里 → 可删")

        let active = ParamVersionRow(JSONValue([
            "name": "my-ver", "is_builtin": false, "is_active": true, "deletable": false,
        ]))
        XCTAssertTrue(active.isActive)
        XCTAssertFalse(active.deletable, "激活中的版本不可删（即便非出厂）")
    }

    func testMissingKeysFallBackWithoutCrash() throws {
        let empty = ParamVersionRow(JSONValue([:]))
        XCTAssertEqual(empty.name, "")
        XCTAssertEqual(empty.nameDash, "-")
        XCTAssertEqual(empty.noteDash, "-")
        XCTAssertFalse(empty.isBuiltin)
        XCTAssertFalse(empty.isActive)
        XCTAssertFalse(empty.deletable, "缺省不可删（保守）")
        XCTAssertFalse(empty.hasCreatedAt)
        try EntityTestSupport.assertLossless(empty, JSONValue([:]), "version-empty")
    }
}
