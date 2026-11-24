import XCTest
@testable import SelectedCore

/// `ParamTableSpecs` 与 `Screener.thresholdKey` 的契约测试。
///
/// 这一组测试是**参数中心结构化编辑器的地基护栏** —— 控件本身是 UI、进不了自动化覆盖，
/// 所以把"能自动化"的那部分（元数据完整性、编解码互逆、形状校验）全部钉在这里。
final class ParamTableSpecsTests: XCTestCase {

    override func setUpWithError() throws {
        // 读不到 → **失败**（不是 `XCTSkip`）：本组护栏是"结构化编辑器的地基"，
        // 静默跳过等于这条地基在坏环境里根本没人守（口径同 `EntityTestSupport` 的夹具）
        try EntityTestSupport.requireParamSchema()
    }

    private var jsonItemKeys: Set<String> {
        Set(ParamSchema.shared.allItems.filter { $0.type == "json" }.map(\.key))
    }

    // MARK: - ① 覆盖性（最重要的一条）

    /// `ParamTableSpecs` 必须**恰好覆盖** schema 里全部 `type == "json"` 的参数。
    ///
    /// 为什么这条最重要：漏配一个 → 那个参数在参数中心**悄悄退回裸 JSON 文本框**，
    /// 没有任何报错、也没人会注意到。
    func testSpecsCoverEveryJSONParamExactly() {
        let speced = Set(ParamTableSpecs.all.keys)
        let declared = jsonItemKeys
        XCTAssertFalse(declared.isEmpty, "schema 里一个 json 参数都没有？元数据可能不完整")

        let missing = declared.subtracting(speced)
        let extra = speced.subtracting(declared)
        XCTAssertTrue(missing.isEmpty,
                      "这些 json 参数没配结构化编辑器（会悄悄退回裸 JSON 文本框）：\(missing.sorted())")
        XCTAssertTrue(extra.isEmpty,
                      "specs 里有 schema 中不存在（或已不是 json 类型）的键：\(extra.sorted())")
    }

    /// 形状 C 的表格列/行不能重名（重名会让渲染互相覆盖）
    func testTableShapeHasNoDuplicateKeys() {
        for (key, shape) in ParamTableSpecs.all {
            guard case .table(let rows, let columns) = shape else { continue }
            XCTAssertEqual(Set(rows.map(\.key)).count, rows.count, "\(key) 行键重名")
            XCTAssertEqual(Set(columns.map(\.key)).count, columns.count, "\(key) 列键重名")
            XCTAssertFalse(rows.isEmpty, "\(key) 没有行")
            XCTAssertFalse(columns.isEmpty, "\(key) 没有列")
        }
    }

    func testNamedFieldsShapeHasNoDuplicateKeys() {
        for (key, shape) in ParamTableSpecs.all {
            guard case .namedFields(let fields) = shape else { continue }
            XCTAssertEqual(Set(fields.map(\.key)).count, fields.count, "\(key) 字段键重名")
            XCTAssertFalse(fields.isEmpty, "\(key) 没有字段")
        }
    }

    // MARK: - ② 编解码互逆

    func testThresholdKeyRoundTrip() {
        let cases: [(String, Double)] = [
            ("<=", 1), ("<=", 2), ("<=", 3), ("<=", 8), ("<=", 12), ("<=", 15), ("<=", 25),
            (">", 3), (">", 5), (">", 7), (">", 15), (">", 25),
            ("<", 2), (">=", 1),
            ("<=", -5), (">", -5),        // _neg 形态
            ("<=", 2.5), ("<", 0.5),      // 小数阈值
        ]
        for (op, thr) in cases {
            guard let key = Screener.thresholdKey(op: op, threshold: thr) else {
                XCTFail("拼不出键名：(\(op), \(thr))"); continue
            }
            guard let back = Screener.keyThreshold(key) else {
                XCTFail("拼出的键名解析不回来：\(key)"); continue
            }
            XCTAssertEqual(back.op, op, "键名 \(key) 的比较符往返不一致")
            XCTAssertEqual(back.threshold, thr, accuracy: 1e-9, "键名 \(key) 的阈值往返不一致")
        }
    }

    /// 整数阈值不写小数点 —— 与 5 个出厂表的写法一致（`le1` 而不是 `le1.0`）
    func testThresholdKeyOmitsTrailingZero() {
        XCTAssertEqual(Screener.thresholdKey(op: "<=", threshold: 1), "le1")
        XCTAssertEqual(Screener.thresholdKey(op: ">", threshold: 15), "gt15")
        XCTAssertEqual(Screener.thresholdKey(op: "<=", threshold: -5), "le_neg5")
        XCTAssertEqual(Screener.thresholdKey(op: "<", threshold: 2.5), "lt2.5")
    }

    /// **出厂表里每一个键都必须能被解析** —— 这是"引擎真的会读它"的前提
    /// （`_lookup_table` 按键名解析阈值，解析不了就 `continue` 静默跳过）
    func testEveryFactoryThresholdKeyParses() {
        let factory = ParamSchema.shared.factoryParams
        for (key, shape) in ParamTableSpecs.all {
            guard case .thresholdTable = shape else { continue }
            guard let table = ParamSchema.getValue(factory, key) as? [String: Any] else {
                XCTFail("\(key) 在工厂参数里不是对象"); continue
            }
            XCTAssertFalse(table.isEmpty, "\(key) 是空表")
            for k in table.keys {
                XCTAssertNotNil(Screener.keyThreshold(k),
                                "\(key) 的键「\(k)」无法被引擎解析（会被静默跳过）")
            }
        }
    }

    // MARK: - ③ 形状校验

    /// 5 个出厂参数版本 × 12 个 json 参数：**全部必须通过形状校验**。
    /// 新校验不得误伤既有配置。
    func testFactoryParamsPassShapeCheck() throws {
        let names = ["classic_2026_7_16", "backtest_v1_1_0", "backtest_v1_2_0",
                     "backtest_v1_3_0", "backtest_strict"]
        for name in names {
            let json = try EntityTestSupport.fixture("engine/params/\(name).json")
            let raw = (json.raw as? [String: Any]) ?? [:]
            for (key, _) in ParamTableSpecs.all {
                guard let v = ParamSchema.getValue(raw, key), !(v is NSNull) else { continue }
                XCTAssertNil(ParamTableSpecs.problem(key, value: v),
                             "\(name) 的 \(key) 未通过形状校验：\(ParamTableSpecs.problem(key, value: v) ?? "")")
            }
        }
    }

    func testShapeCheckRejectsBadInput() {
        // ① 阈值表：无法解析的键名
        XCTAssertNotNil(ParamTableSpecs.problem("scoring.bonus.consec_up",
                                                value: ["连续上涨": 10]))
        // ② 阈值表：非规范写法（lt2 与 le1.999 语义相近但不互逆）
        XCTAssertNotNil(ParamTableSpecs.problem("scoring.bonus.consec_up",
                                                value: ["le01": 10]))
        // ③ 阈值表：空表
        XCTAssertNotNil(ParamTableSpecs.problem("scoring.bonus.consec_up", value: [String: Any]()))
        // ④ 命名行：缺子键
        XCTAssertNotNil(ParamTableSpecs.problem("scoring.penalty.vol_shrink",
                                                value: ["threshold": 1.0]))
        // ⑤ 表格：缺一行
        XCTAssertNotNil(ParamTableSpecs.problem("predict_rules.strategies",
                                                value: ["up_consensus": [String: Any]()]))
        // ⑥ 非对象
        XCTAssertNotNil(ParamTableSpecs.problem("scoring.bonus.consec_up", value: [1, 2, 3]))
    }

    func testShapeCheckAcceptsWellFormedInput() {
        XCTAssertNil(ParamTableSpecs.problem("scoring.bonus.consec_up",
                                             value: ["le1": 15, "le2": 10, "le3": 5, "gt3": 0]))
        XCTAssertNil(ParamTableSpecs.problem("scoring.penalty.vol_shrink",
                                             value: ["threshold": 1.0, "score": -5]))
    }

    // MARK: - ④ 门槛浮动：工厂参数 vs 引擎内置默认表

    /// `predict_rules.regime_thresholds` 的工厂值必须与引擎内置默认表
    /// `PredictRules.defaultRegimeThresholds` **逐值一致** ——
    /// 否则"参数里写着"与"缺键时回落"会给出两个不同的行为（漂移且不报错）。
    ///
    /// 与 `MarketRegimeTests.testDefaultTableMatchesFactoryParams` 是同一条不变式的两个方向：
    /// 那边测「出厂**文件** vs 引擎默认表」，这边测「工厂**参数** vs 引擎默认表」。
    func testRegimeThresholdsFactoryMatchesEngineDefault() throws {
        let factory = ParamSchema.shared.factoryParams
        let table = try XCTUnwrap(
            ParamSchema.getValue(factory, "predict_rules.regime_thresholds") as? [String: Any],
            "工厂参数缺 predict_rules.regime_thresholds")

        XCTAssertEqual(Set(table.keys), Set(PredictRules.defaultRegimeThresholds.keys),
                       "工厂参数的状态集必须与引擎默认表完全一致")
        for (regime, row) in PredictRules.defaultRegimeThresholds {
            let got = try XCTUnwrap(table[regime] as? [String: Any], "工厂参数缺 \(regime)")
            for k in ["target_adj", "stop_adj", "score_adj"] {
                let v = try XCTUnwrap((got[k] as? NSNumber)?.doubleValue, "\(regime).\(k) 不是数值")
                let want = try XCTUnwrap(row[k], "默认表缺 \(regime).\(k)")
                XCTAssertEqual(v, want, accuracy: 1e-9, "\(regime).\(k) 两处不一致")
            }
        }
    }

    /// 五种状态一个都不能少 —— 缺的那态会**静默回落**默认表（引擎用 `.get`，不崩），
    /// 界面上看不出"我设的值没生效"。`REQUIRED_JSON_KEYS` 已把它声明为必填子键。
    func testRegimeThresholdsRequiresAllFiveStates() throws {
        let required = Set(ParamSchema.shared.requiredSubKeys("predict_rules.regime_thresholds"))
        XCTAssertEqual(required, Set(PredictRules.defaultRegimeThresholds.keys),
                       "必填子键必须覆盖全部五种大盘状态")
        XCTAssertNotNil(ParamTableSpecs.problem("predict_rules.regime_thresholds",
                                                value: ["BULL_TREND": [String: Any]()]),
                        "只给一种状态应被形状校验拦下")
    }

    /// 未配 specs 的键 → 形状校验**必须放行**（它们走原来的文本路径，由 `validate` 管）
    func testShapeCheckIsNoOpForUnspecedKey() {
        XCTAssertNil(ParamTableSpecs.problem("hard_filter.price_min", value: "not a table"))
        XCTAssertFalse(ParamTableSpecs.has("hard_filter.price_min"))
    }

    /// `NSNumber` 会桥接 `Bool`—— 布尔不能被当成数值放行
    func testShapeCheckRejectsBoolAsScore() {
        XCTAssertNotNil(ParamTableSpecs.problem("scoring.bonus.consec_up",
                                                value: ["le1": true, "le2": 10, "le3": 5, "gt3": 0]))
    }

    // MARK: - ⑤ 时间区间（`.timePair`：`HH:mm` 与起止顺序）

    func testTimePairValidationAcceptsClockTimesAndDoubleDash() {
        XCTAssertNil(ParamTableSpecs.timePairProblem(start: "09:30", end: "15:00"))
        XCTAssertNil(ParamTableSpecs.timePairProblem(start: "10:00", end: "10:00"))
        XCTAssertNil(ParamTableSpecs.timePairProblem(start: "--", end: "--"),
                     "暴跌日策略占位符 [--, --] 必须放行")
        XCTAssertNil(ParamTableSpecs.timePairProblem(start: " 09:45 ", end: " 10:30 "))
    }

    func testTimePairValidationRejectsMalformedOrInvertedPairs() {
        // 缺前导零（PhaseReview.minutes 要求 5 位且字符串序对比依赖零填充）
        XCTAssertNotNil(ParamTableSpecs.timePairProblem(start: "9:30", end: "10:30"))
        // 超范围钟点
        XCTAssertNotNil(ParamTableSpecs.timePairProblem(start: "24:00", end: "24:30"))
        XCTAssertNotNil(ParamTableSpecs.timePairProblem(start: "10:60", end: "11:00"))
        // 半截哨兵
        XCTAssertNotNil(ParamTableSpecs.timePairProblem(start: "--", end: "10:30"))
        XCTAssertNotNil(ParamTableSpecs.timePairProblem(start: "09:30", end: "--"))
        // 全角字符 / 非法分隔
        XCTAssertNotNil(ParamTableSpecs.timePairProblem(start: "09：30", end: "10:30"))
        // 起止倒挂
        XCTAssertNotNil(ParamTableSpecs.timePairProblem(start: "11:30", end: "10:30"))
        // 非二维字符串数组
        XCTAssertNotNil(ParamTableSpecs.timePairProblem(["09:30"]))
        XCTAssertNotNil(ParamTableSpecs.timePairProblem([930, 1030]))
    }

    func testShapeCheckEnforcesTimePairOnStrategiesAndIterateThresholds() {
        let factory = ParamSchema.shared.factoryParams
        if var it = ParamSchema.getValue(factory, "iterate.thresholds") as? [String: Any] {
            it["discipline_window"] = ["11:00", "10:00"]
            XCTAssertNotNil(ParamTableSpecs.problem("iterate.thresholds", value: it),
                            "纪律窗口起止倒挂应被形状校验拦下")
            it["discipline_window"] = ["09:30", "10:30"]
            XCTAssertNil(ParamTableSpecs.problem("iterate.thresholds", value: it))
        } else {
            XCTFail("工厂参数缺少 iterate.thresholds")
        }

        if var st = ParamSchema.getValue(factory, "predict_rules.strategies") as? [String: Any],
           var up = st["up_consensus"] as? [String: Any] {
            up["window"] = ["9:30", "11:30"]
            st["up_consensus"] = up
            XCTAssertNotNil(ParamTableSpecs.problem("predict_rules.strategies", value: st),
                            "策略卖出窗口缺少前导零应被形状校验拦下")
        } else {
            XCTFail("工厂参数缺少 predict_rules.strategies.up_consensus")
        }
    }
}
