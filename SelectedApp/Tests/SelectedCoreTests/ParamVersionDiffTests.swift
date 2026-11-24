import XCTest
@testable import SelectedCore

/// 版本 diff 纯函数：
/// 逐键比对、深比较不受键序影响、展示口径（浮点保 ".0"、布尔开/关）。
final class ParamVersionDiffTests: XCTestCase {

    override func setUpWithError() throws {
        try EntityTestSupport.requireParamSchema()
    }

    private var factory: [String: Any] { ParamSchema.shared.factoryParams }

    // MARK: 基线一致

    func testIdenticalParamsProduceNoDiff() {
        XCTAssertFalse(factory.isEmpty, "factory_params 为空（元数据不完整）")
        XCTAssertTrue(ParamVersionDiff.diff(old: factory, new: factory).isEmpty)
    }

    // MARK: 标量差异

    func testScalarChangeProducesSingleEntryWithFormattedTexts() {
        let changed = ParamSchema.shared.applyDiff(base: factory,
                                                   diff: ["hard_filter.price_min": 5.0])
        let d = ParamVersionDiff.diff(old: factory, new: changed)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d.first?.key, "hard_filter.price_min")
        // 浮点保 ".0"（与 PyJSON 口径一致），中文标签来自 schema
        XCTAssertEqual(d.first?.oldText, "3.0")
        XCTAssertEqual(d.first?.newText, "5.0")
        XCTAssertFalse(d.first?.label.isEmpty ?? true)
    }

    func testBoolFormatsAsOpenClose() {
        guard let boolItem = ParamSchema.shared.allItems.first(where: { $0.type == "bool" }),
              let cur = ParamSchema.getValue(factory, boolItem.key) as? Bool else {
            return XCTFail("schema 里应有 bool 项且出厂值可读")
        }
        let changed = ParamSchema.shared.applyDiff(base: factory, diff: [boolItem.key: !cur])
        let d = ParamVersionDiff.diff(old: factory, new: changed)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d.first?.oldText, cur ? "开" : "关")
        XCTAssertEqual(d.first?.newText, cur ? "关" : "开")
    }

    // MARK: 容器深比较（键序无关）

    func testDictDiffIgnoresKeyOrder() {
        guard let jsonItem = ParamSchema.shared.allItems.first(where: {
            $0.type == "json" && ParamSchema.getValue(factory, $0.key) is [String: Any]
        }), let obj = ParamSchema.getValue(factory, jsonItem.key) as? [String: Any],
           obj.count >= 2 else {
            return XCTFail("schema 里应有对象型 json 项")
        }
        // 重排键序（Swift Dictionary 本无序，这里显式重建一份同内容的）→ 深比较必须相等
        let reordered = Dictionary(uniqueKeysWithValues: obj.keys.sorted().reversed().map { ($0, obj[$0]!) })
        XCTAssertTrue(ParamVersionDiff.valuesEqual(obj, reordered))
        // 数组同理
        let arr: [Any] = [1.0, "x", true]
        XCTAssertTrue(ParamVersionDiff.valuesEqual(arr, arr))
        XCTAssertFalse(ParamVersionDiff.valuesEqual(arr, [1.0, "x", false]))
    }

    func testDictContentChangeProducesEntry() {
        guard let jsonItem = ParamSchema.shared.allItems.first(where: {
            $0.type == "json" && ParamSchema.getValue(factory, $0.key) is [String: Any]
        }), let obj = ParamSchema.getValue(factory, jsonItem.key) as? [String: Any] else {
            return XCTFail("schema 里应有对象型 json 项")
        }
        var mutated = obj
        // 改一个标量叶子（数组/对象叶子都可能是容器，取第一个非容器值）
        guard let leaf = obj.first(where: { !($0.value is [String: Any]) && !($0.value is [Any]) })
        else { return XCTFail("json 项应含标量叶子：\(jsonItem.key)") }
        let newVal: Any = (leaf.value as? NSNumber)?.doubleValue ?? 0
        mutated[leaf.key] = "\(newVal)_x"
        let changed = ParamSchema.shared.applyDiff(base: factory, diff: [jsonItem.key: mutated])
        let d = ParamVersionDiff.diff(old: factory, new: changed)
        XCTAssertEqual(d.count, 1, "json 内容变化应只报一条（整对象替换）")
        XCTAssertEqual(d.first?.key, jsonItem.key)
    }

    // MARK: 数值口径

    func testIntFloatEquivalentValuesAreEqual() {
        // 7（int）与 7.0（float）语义等价 → 不报差异（int/float 混写不该产生假 diff）
        XCTAssertTrue(ParamVersionDiff.valuesEqual(7, 7.0))
        XCTAssertFalse(ParamVersionDiff.valuesEqual(true, 1))
        XCTAssertFalse(ParamVersionDiff.valuesEqual(nil, NSNull()))  // nil 与非 nil
        XCTAssertTrue(ParamVersionDiff.valuesEqual(["a": 1], ["a": 1.0]))
    }
}
