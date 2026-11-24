import XCTest
@testable import Selected
@testable import SelectedCore

final class ParamEditorAndIndicatorDisplayTests: XCTestCase {

    override func setUpWithError() throws {
        XCTAssertTrue(ParamSchema.shared.isAvailable, "参数元数据读取失败")
    }

    private func sampleGroups() -> [JSONValue] {
        let strategies = ParamSchema.getValue(ParamSchema.shared.factoryParams, "predict_rules.strategies")
            ?? ["up_consensus": ["window": ["09:30", "11:30"]]]
        return [
            JSONValue([
                "group": "score_weights",
                "title": "打分阈值",
                "items": [
                    [
                        "key": "scoring.penalty.cum_5d_low",
                        "label": "5日累计涨幅过低",
                        "type": "json",
                        "optional": true,
                        "step": 1.0,
                        "value": NSNull()
                    ],
                    [
                        "key": "predict_rules.strategies",
                        "label": "早盘策略",
                        "type": "json",
                        "optional": false,
                        "step": 1.0,
                        "value": strategies
                    ],
                    [
                        "key": "filters.profile.change_pct",
                        "label": "涨幅画像",
                        "type": "num_pair",
                        "step": 0.5,
                        "value": [-2.0, 6.0]
                    ]
                ]
            ])
        ]
    }

    @MainActor
    func testJsonMutationUpdatesDiffImmediately() {
        let state = ParamEditorState()
        let snapshot = ParamSchema.shared.schemaPayload(ParamSchema.shared.factoryParams)
            .map { JSONValue($0) }
        state.buildEdits(from: snapshot)
        XCTAssertTrue(state.diff.isEmpty)
        XCTAssertTrue(state.invalidKeys.isEmpty)

        state.versionName = "test-v1"
        XCTAssertFalse(state.canSave)

        let specKey = ParamTableSpecs.all.keys.sorted().first { key in
            state.jsonValues[key] != nil && !state.jsonNulls.contains(key)
        }
        if let specKey, var obj = state.jsonValues[specKey] as? [String: Any] {
            obj["__probe_added__"] = 99
            state.setJSONValue(obj, forKey: specKey)
            XCTAssertNotNil(state.diff[specKey], "结构化 JSON 编辑后 diff 必须实时更新")
        } else {
            XCTFail("未在默认参数中找到非空结构化 JSON 键")
        }
    }

    @MainActor
    func testCum5dLowReEnableWithoutFieldsMarksInvalidAndBlocksSave() {
        let state = ParamEditorState()
        let cum5dKey = "scoring.penalty.cum_5d_low"
        XCTAssertTrue(ParamTableSpecs.has(cum5dKey))

        let cum5dNullGroup: [JSONValue] = [
            JSONValue([
                "group": "scoring_penalty",
                "title": "扣分规则",
                "items": [
                    [
                        "key": cum5dKey,
                        "label": "5日累计过低",
                        "type": "json",
                        "optional": true,
                        "step": 1.0,
                        "value": NSNull()
                    ]
                ]
            ])
        ]
        state.buildEdits(from: cum5dNullGroup)
        XCTAssertTrue(state.jsonNulls.contains(cum5dKey))
        XCTAssertTrue(state.invalidKeys.isEmpty)

        // 取消停用，但尚未填写字段 → diff 应出现 cum_5d_low，且 invalidKeys 拦住保存
        state.setJSONNull(false, forKey: cum5dKey)
        state.versionName = "re-enable-invalid"
        XCTAssertNotNil(state.diff[cum5dKey])
        XCTAssertTrue(state.invalidKeys.contains(where: { $0.hasPrefix(cum5dKey) }),
                      "重新启用 cum_5d_low 但未填必需字段时，必须进入 invalidKeys: \(state.invalidKeys)")
        XCTAssertFalse(state.canSave)

        // 补齐必需字段后应恢复合法且可保存
        state.setJSONValue(["threshold": -5.0, "score": -8], forKey: cum5dKey)
        XCTAssertTrue(state.invalidKeys.isEmpty, "补齐字段后应无无效项: \(state.invalidKeys)")
        XCTAssertTrue(state.canSave)

        // 再重新停用 → 回到无差异且合法
        state.setJSONNull(true, forKey: cum5dKey)
        XCTAssertNil(state.diff[cum5dKey])
        XCTAssertTrue(state.invalidKeys.isEmpty)
    }

    @MainActor
    func testTimePairValidationThroughParamEditorStateBlocksSave() throws {
        let state = ParamEditorState()
        let snapshot = ParamSchema.shared.schemaPayload(ParamSchema.shared.factoryParams)
            .map { JSONValue($0) }
        state.buildEdits(from: snapshot)
        state.versionName = "time-pair-check"

        var it = try XCTUnwrap(state.jsonValues["iterate.thresholds"] as? [String: Any])
        it["discipline_window"] = ["14:30", "14:00"]
        state.setJSONValue(it, forKey: "iterate.thresholds")
        XCTAssertFalse(state.invalidKeys.isEmpty)
        XCTAssertFalse(state.canSave)

        it["discipline_window"] = ["9:30", "14:00"]
        state.setJSONValue(it, forKey: "iterate.thresholds")
        XCTAssertFalse(state.invalidKeys.isEmpty)
        XCTAssertFalse(state.canSave)

        it["discipline_window"] = ["09:45", "14:30"]
        state.setJSONValue(it, forKey: "iterate.thresholds")
        XCTAssertTrue(state.invalidKeys.isEmpty, "合法时间区间应通过校验: \(state.invalidKeys)")
        XCTAssertTrue(state.canSave)
    }

    @MainActor
    func testPerformSaveFailurePreservesDraftAndVersionName() {
        let state = ParamEditorState()
        state.buildEdits(from: sampleGroups())
        state.setValue("8.0", forKey: "filters.profile.change_pct#1")
        state.versionName = "draft-keep"
        XCTAssertTrue(state.canSave)

        let okFail = state.performSave { _, _, _ in false }
        XCTAssertFalse(okFail)
        XCTAssertEqual(state.versionName, "draft-keep", "写库失败时不能清空 versionName")
        XCTAssertEqual(state.localReload, 0, "写库失败时不能重建基线丢草稿")
        XCTAssertEqual(state.values["filters.profile.change_pct#1"], "8.0")
        XCTAssertFalse(state.diff.isEmpty)

        let okPass = state.performSave { name, diff, activate in
            XCTAssertEqual(name, "draft-keep")
            XCTAssertFalse(activate)
            XCTAssertNotNil(diff["filters.profile.change_pct"])
            return true
        }
        XCTAssertTrue(okPass)
        XCTAssertEqual(state.versionName, "")
        XCTAssertEqual(state.localReload, 1)
    }

    @MainActor
    func testIndicatorScreenerFormattedValueMatchesWanAndYiUnits() {
        XCTAssertEqual(IndicatorScreenerView.formattedValue(5_000_000), "500.00万")
        XCTAssertEqual(IndicatorScreenerView.formattedValue(50_000), "5.00万")
        XCTAssertEqual(IndicatorScreenerView.formattedValue(500_000_000), "5.00亿")
        XCTAssertEqual(IndicatorScreenerView.formattedValue(nil), "—")
    }

    @MainActor
    func testDecimalStepAvoidsBinaryTailAndRestoresCleanZeroDiff() {
        let state = ParamEditorState()
        let groups: [JSONValue] = [
            JSONValue([
                "group": "step_test",
                "title": "步进测试",
                "items": [
                    ["key": "a.float_tenth", "label": "小数步长", "type": "float", "step": 0.2, "value": 0.1],
                    ["key": "a.float_whole", "label": "整型写法浮点", "type": "float", "step": 0.5, "value": 1.0],
                    ["key": "a.int_item", "label": "整数步长", "type": "int", "step": 5, "value": 10]
                ]
            ])
        ]
        state.buildEdits(from: groups)

        state.stepValue(forKey: "a.float_tenth", dir: 1)
        XCTAssertEqual(state.values["a.float_tenth"], "0.3", "Decimal 步进不应产出 0.30000000000000004")
        XCTAssertEqual(state.diff["a.float_tenth"] as? Double, 0.3)

        state.stepValue(forKey: "a.float_whole", dir: 1)
        XCTAssertEqual(state.values["a.float_whole"], "1.5")
        state.stepValue(forKey: "a.float_whole", dir: -1)
        XCTAssertNil(state.diff["a.float_whole"], "步进回原始数值 1.0 (\"1\") 时应归零 diff")

        state.stepValue(forKey: "a.int_item", dir: -1)
        XCTAssertEqual(state.values["a.int_item"], "5")
        XCTAssertEqual(state.diff["a.int_item"] as? Int, 5)
    }

    @MainActor
    func testNumPairTrimsWhitespaceAndComparesNumerically() {
        let state = ParamEditorState()
        state.buildEdits(from: sampleGroups())

        // 仅空白或小数格式差异（-2 vs -2.0， 6 vs 6.0）不应产生假 diff 或假校验失败
        state.setValue(" -2 ", forKey: "filters.profile.change_pct#0")
        state.setValue(" 6 ", forKey: "filters.profile.change_pct#1")
        XCTAssertTrue(state.invalidKeys.isEmpty, "含空白的数字对仍应合法: \(state.invalidKeys)")
        XCTAssertNil(state.diff["filters.profile.change_pct"], "数值相等时不该产出假 diff")

        // 真实改大上限并保留前后空白 → 应产出解析后数组
        state.setValue(" 8.5 ", forKey: "filters.profile.change_pct#1")
        XCTAssertTrue(state.invalidKeys.isEmpty)
        XCTAssertEqual(state.diff["filters.profile.change_pct"] as? [Double], [-2.0, 8.5])
    }
}
