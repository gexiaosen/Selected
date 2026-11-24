import XCTest
@testable import SelectedCore

/// `ParamThresholdTableOps` 的契约测试 —— 参数中心形状 A 行编辑器的**全部逻辑**都在这里。
///
/// 视图本身（`ParamThresholdTableEditor`）只负责画，进不了自动化覆盖；
/// 所以"改阈值时键名怎么变、冲突怎么处理、新增档位落在哪"这类**真会出错**的部分，
/// 全部钉在本文件。
final class ParamThresholdTableOpsTests: XCTestCase {

    private let consecUp: [String: Any] = ["le1": 15, "le2": 10, "le3": 5, "gt3": 0]

    // MARK: - rows：排序与容错

    /// 按阈值从小到大 —— 与键名在字典里的顺序无关（用户读起来应该从松到紧）
    func testRowsSortedByThreshold() {
        // 故意打乱插入顺序
        let table: [String: Any] = ["gt3": 0, "le3": 5, "le1": 15, "le2": 10]
        let rows = ParamThresholdTableOps.rows(table)
        XCTAssertEqual(rows.map(\.threshold), [1, 2, 3, 3])
        XCTAssertEqual(rows.map(\.key), ["le1", "le2", "le3", "gt3"])
    }

    func testRowsParsesOpAndScore() {
        let rows = ParamThresholdTableOps.rows(["le_neg5": 5, "gt_neg5": 0])
        XCTAssertEqual(rows.map(\.op), ["<=", ">"])
        XCTAssertEqual(rows.map(\.threshold), [-5, -5])
        XCTAssertEqual(rows.map(\.score), [5, 0])
    }

    /// 解析不了的行**跳过**（由 `ParamTableSpecs.problem` 在保存前报错，这里不猜）
    func testRowsSkipsUnparsableEntries() {
        let table: [String: Any] = ["le1": 15, "乱七八糟": 3, "gt3": "abc", "gt5": true]
        let rows = ParamThresholdTableOps.rows(table)
        XCTAssertEqual(rows.map(\.key), ["le1"], "非法的键名 / 非数值 / 布尔都应被跳过")
    }

    func testRowsOnEmptyTable() {
        XCTAssertTrue(ParamThresholdTableOps.rows([:]).isEmpty)
    }

    // MARK: - replacingKey：改比较符 / 改阈值

    func testReplacingKeyChangesThreshold() {
        // 把「≤1」改成「≤2」—— 但 le2 已存在 → 冲突，必须拒绝
        XCTAssertNil(ParamThresholdTableOps.replacingKey(consecUp, from: "le1", to: "le2"),
                     "le2 已存在，换过去会吞掉一个档位")

        // le3 → le4 没有冲突
        let out = ParamThresholdTableOps.replacingKey(consecUp, from: "le3", to: "le4")
        XCTAssertEqual(out?["le4"] as? Int, 5, "分值应跟着搬过去")
        XCTAssertNil(out?["le3"], "旧键应被移除")
        XCTAssertEqual((out ?? [:]).count, consecUp.count, "档位数不应变化")
    }

    func testReplacingKeyChangesOp() {
        let out = ParamThresholdTableOps.replacingKey(["le1": 15], from: "le1", to: "lt1")
        XCTAssertEqual(out?["lt1"] as? Int, 15)
        XCTAssertNil(out?["le1"])
    }

    func testReplacingKeyRejectsInvalidNewKey() {
        XCTAssertNil(ParamThresholdTableOps.replacingKey(consecUp, from: "le1", to: "连续上涨"),
                     "非法键名必须拒绝（否则引擎解析不了、静默跳过该档）")
        XCTAssertNil(ParamThresholdTableOps.replacingKey(consecUp, from: "le1", to: ""))
    }

    func testReplacingKeySameKeyIsNoOp() {
        XCTAssertEqual(ParamThresholdTableOps.replacingKey(consecUp, from: "le1", to: "le1")?.count,
                       consecUp.count)
    }

    func testReplacingKeyOnMissingOldKeyReturnsNil() {
        XCTAssertNil(ParamThresholdTableOps.replacingKey(consecUp, from: "le9", to: "le10"))
    }

    // MARK: - addingRow：新增档位

    /// 默认落在现有档位**之外**（`>` 取比最大阈值更大的一档），不与现有键冲突
    func testAddingRowLandsOutsideExistingRange() throws {
        let result = try XCTUnwrap(ParamThresholdTableOps.addingRow(consecUp))
        XCTAssertEqual(result.key, "gt4", "最大阈值是 3，新增的 > 档应落在 4")
        XCTAssertEqual(result.table["gt4"] as? Int, 0, "新档默认 0 分")
        XCTAssertEqual(result.table.count, consecUp.count + 1)
        // 原有档位一个都不能丢
        for (k, v) in consecUp {
            XCTAssertEqual(result.table[k] as? Int, v as? Int, "\(k) 被改动了")
        }
    }

    /// 连续新增不会互相覆盖
    func testAddingRowIsRepeatable() throws {
        var t = consecUp
        var keys: [String] = []
        for _ in 0..<5 {
            let r = try XCTUnwrap(ParamThresholdTableOps.addingRow(t))
            keys.append(r.key); t = r.table
        }
        XCTAssertEqual(keys, ["gt4", "gt5", "gt6", "gt7", "gt8"])
        XCTAssertEqual(t.count, consecUp.count + 5)
    }

    func testAddingRowOnEmptyTable() throws {
        let result = try XCTUnwrap(ParamThresholdTableOps.addingRow([:]))
        XCTAssertEqual(result.key, "gt1")
    }

    // MARK: - 与形状校验协同（编辑结果必须仍是合法表）

    /// `rows` / `replacingKey` / `addingRow` 的结果都必须仍通过 `ParamTableSpecs.problem`。
    /// 两条纯逻辑如果不一致，用户会在"编辑器允许、保存被拒"之间反复撞墙。
    func testEditedTablesStillPassShapeCheck() throws {
        let key = "scoring.bonus.consec_up"
        XCTAssertNil(ParamTableSpecs.problem(key, value: consecUp), "起点就不合法")

        let replaced = try XCTUnwrap(ParamThresholdTableOps.replacingKey(consecUp, from: "le3", to: "le4"))
        XCTAssertNil(ParamTableSpecs.problem(key, value: replaced))

        let added = try XCTUnwrap(ParamThresholdTableOps.addingRow(consecUp))
        XCTAssertNil(ParamTableSpecs.problem(key, value: added.table))

        let removed = { () -> [String: Any] in
            var v = consecUp; v.removeValue(forKey: "le3"); return v
        }()
        XCTAssertNil(ParamTableSpecs.problem(key, value: removed),
                     "删掉**非必填**档位后仍应合法（必填性由 validate 的 REQUIRED_JSON_KEYS 管）")
    }

    /// 负阈值档位改阈值也要能拼回合法键名（`_neg` 形态）
    func testReplacingKeyOnNegativeThreshold() throws {
        let table: [String: Any] = ["le_neg5": 5, "gt_neg5": 0]
        let out = try XCTUnwrap(ParamThresholdTableOps.replacingKey(table, from: "le_neg5", to: "le_neg8"))
        XCTAssertEqual(out["le_neg8"] as? Int, 5)
        XCTAssertNil(ParamTableSpecs.problem("scoring.bonus.dist_high", value: out))
    }
}
