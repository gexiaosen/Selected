import XCTest
@testable import SelectedCore

/// `JSONValue` —— 引擎结果 → 视图/落库这条链路里**唯一的动态取值入口**。
///
/// 它承载两类静默 bug：
///   1. **缺键 / 类型不符不报错**：`item["x"].double ?? 0` 在字段名写错时安静地给 0
///   2. **`ForEach` 身份键**：视图必须用 `codeKey`/`groupidKey` 这类稳定主键，
///      不能用 `\.self`（会退化成"整个字典的字符串描述"，分数一变就整行重建）
/// 这里把两条语义都钉住。
final class JSONValueTests: XCTestCase {

    private let sample: [String: Any] = [
        "code": "SZ000001",
        "name": "平安银行",
        "price": 12.5,
        "count": 7,
        "flag": true,
        "list": [1, 2, 3],
        "nested": ["a": 1],
        "empty": NSNull(),
    ]

    // MARK: - 取值语义

    func testSubscriptOnMissingKeyReturnsNull() {
        let v = JSONValue(sample)
        XCTAssertTrue(v["nope"].isNull)
        XCTAssertNil(v["nope"].string)
        XCTAssertNil(v["nope"].double)
        XCTAssertEqual(v["nope"].stringOrDash, "-")
        XCTAssertEqual(v["nope"].doubleOrZero, 0)
        XCTAssertEqual(v["nope"].intOrZero, 0)
    }

    /// 显式 `NSNull` 与「键缺失」在取值上等价（都退化成 `isNull`），
    /// `subscript` 直接取原始字典键因此是安全的。
    func testExplicitNullBehavesLikeMissingKey() {
        let v = JSONValue(sample)
        XCTAssertTrue(v["empty"].isNull)
        XCTAssertNil(v["empty"].nilIfNull)
        XCTAssertNil(v["nope"].nilIfNull)
        XCTAssertNotNil(v["code"].nilIfNull)
    }

    func testScalarCoercion() {
        let v = JSONValue(sample)
        XCTAssertEqual(v["code"].string, "SZ000001")
        XCTAssertEqual(v["price"].double, 12.5)
        XCTAssertEqual(v["count"].int, 7)
        XCTAssertEqual(v["flag"].bool, true)
        // 字符串数字也按数值读（引擎 JSON 里数值有时是字符串）
        XCTAssertEqual(JSONValue(["n": "3.5"])["n"].double, 3.5)
        // int 走 double 再截断
        XCTAssertEqual(JSONValue(["n": 3.9])["n"].int, 3)
    }

    /// 非字典 / 非数组的 raw：取子键、取下标都必须安全退化，不崩。
    func testSubscriptOnWrongShapeDegradesSafely() {
        XCTAssertTrue(JSONValue("just a string")["code"].isNull)
        XCTAssertTrue(JSONValue(nil)["code"].isNull)
        XCTAssertTrue(JSONValue(nil)[0].isNull)
        XCTAssertTrue(JSONValue([1, 2])[5].isNull, "越界下标 → NSNull，不是崩溃")
        XCTAssertEqual(JSONValue([1, 2])[1].int, 2)
    }

    func testArrayAndDictAccessors() {
        let v = JSONValue(sample)
        XCTAssertEqual(v["list"].array.map(\.int), [1, 2, 3])
        XCTAssertEqual(v["nested"].dict["a"]?.int, 1)
        XCTAssertTrue(v["code"].array.isEmpty, "非数组 → 空数组而非 nil 崩溃")
        XCTAssertTrue(v["code"].dict.isEmpty)
        XCTAssertEqual(v["nested"].dictAny["a"] as? Int, 1)
    }

    func testInitNilBecomesNull() {
        XCTAssertTrue(JSONValue(nil).isNull)
        XCTAssertTrue(JSONValue(Optional<Any>.none).isNull)
    }

    // MARK: - ForEach 身份键

    func testIdentityKeysFallBackDeterministically() {
        let empty = JSONValue([String: Any]())
        XCTAssertEqual(empty.codeKey, "")
        XCTAssertEqual(empty.nameKey, "")
        XCTAssertEqual(empty.paramGroupKey, "")
        XCTAssertEqual(empty.paramItemKey, "")
        XCTAssertEqual(empty.dateStringKey, "")
        XCTAssertEqual(empty.sourceKey, "")
        // 这两个**不是空串兜底**：分组 id 兜 1、轮次兜 0（历史行为，视图依赖它）
        XCTAssertEqual(empty.groupIdKey, 1)
        XCTAssertEqual(empty.slotKey, 0)
    }

    func testIdentityKeysReadBusinessKeys() {
        let v = JSONValue(["code": "SH600519", "name": "贵州茅台", "id": 9, "slot": 2,
                           "group": "打分", "title": "备选", "key": "scoring.ma_pass",
                           "date": "2026-09-18", "source": "tencent"])
        XCTAssertEqual(v.codeKey, "SH600519")
        XCTAssertEqual(v.nameKey, "贵州茅台")
        XCTAssertEqual(v.groupIdKey, 9)
        XCTAssertEqual(v.slotKey, 2)
        XCTAssertEqual(v.paramGroupKey, "打分")
        XCTAssertEqual(v.paramItemKey, "scoring.ma_pass")
        XCTAssertEqual(v.dateStringKey, "2026-09-18")
        XCTAssertEqual(v.sourceKey, "tencent")
    }

    /// `paramGroupKey` 的二级兜底（`group` → `title`）与 `dateStringKey` 的（`date` → `sel_date`）
    func testIdentityKeySecondaryFallbacks() {
        XCTAssertEqual(JSONValue(["title": "备选"]).paramGroupKey, "备选")
        XCTAssertEqual(JSONValue(["sel_date": "2026-09-18"]).dateStringKey, "2026-09-18")
    }

    // MARK: - Hashable（身份判定退化时的最后一道）

    func testHashableIsByDescription() {
        XCTAssertEqual(JSONValue(["a": 1]), JSONValue(["a": 1]))
        XCTAssertNotEqual(JSONValue(["a": 1]), JSONValue(["a": 2]))
        // 同一份内容两次构造，hash 必须稳定（否则 ForEach 每帧都判定为新行）
        XCTAssertEqual(JSONValue(["a": 1, "b": 2]).hashValue, JSONValue(["a": 1, "b": 2]).hashValue)
        // 相等与哈希必须**顺序无关**：字典文本顺序受每进程随机种子影响，
        // 直接比 `String(describing: raw)` 会让内容相同的两份字典判为不相等
        // （违反 Hashable 铁律）。嵌套字典同样按键排序递归展开。
        XCTAssertEqual(JSONValue(["a": 1, "b": 2]), JSONValue(["b": 2, "a": 1]))
        XCTAssertEqual(JSONValue(["a": 1, "b": 2]).hashValue, JSONValue(["b": 2, "a": 1]).hashValue)
        XCTAssertEqual(JSONValue(["x": ["p": 1, "q": 2]]), JSONValue(["x": ["q": 2, "p": 1]]))
        XCTAssertEqual(JSONValue(["x": ["p": 1, "q": 2]]).hashValue,
                       JSONValue(["x": ["q": 2, "p": 1]]).hashValue)
    }

    // MARK: - 字面量构造（视图/测试里大量使用）

    func testLiteralConstruction() {
        let d: JSONValue = ["code": "SZ000001", "count": 3]
        XCTAssertEqual(d["code"].string, "SZ000001")
        XCTAssertEqual(d["count"].int, 3)
        let a: JSONValue = [1, 2, 3]
        XCTAssertEqual(a.array.count, 3)
        let s: JSONValue = "hello"
        XCTAssertEqual(s.string, "hello")
    }

    // MARK: - Codable（实体化的底座）

    /// 回归锁：**长小数编码不能变值**
    ///
    /// `JSONSerialization` 把长小数解析成 `NSDecimalNumber`（保持十进制精确），
    /// 而它的 `doubleValue` **不是正确舍入的** —— 实测
    /// `NSDecimalNumber(string: "0.070000000000000007").doubleValue == 0.07000000000000003`（差 1 ULP）。
    ///
    /// 若编码走 `doubleValue`，`JSON → 实体 → JSON` 会**静默改值**，
    /// 违反本类型"编码即原样输出、不做任何类型转换"的契约。
    /// 所以 `NSDecimalNumber` 必须走 `decimalValue`（精确十进制）。
    ///
    /// 这条测试同时是"平台怪癖"的探针：即使哪天系统把 `doubleValue` 修对了，
    /// 断言依然成立（精确十进制编码两边都对）。
    func testCodableKeepsLongDecimalExact() throws {
        let text = #"{"x":0.070000000000000007}"#
        let v = JSONValue(try JSONSerialization.jsonObject(with: Data(text.utf8)))
        XCTAssertTrue(v["x"].raw is NSDecimalNumber,
                      "前提：长小数被 JSONSerialization 解析成 NSDecimalNumber")

        let back = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(v)) as! [String: Any]
        XCTAssertEqual(back["x"] as? NSDecimalNumber,
                       NSDecimalNumber(string: "0.070000000000000007"),
                       "编码后必须还是同一个十进制值（走 doubleValue 会漂 1 ULP）")
    }

    /// `NSNumber` 会桥接到 `Bool` —— 分支顺序写错会把整数 `1` 编成 `true`
    func testCodableKeepsIntAndBoolDistinct() throws {
        let v = JSONValue(["one": 1, "zero": 0, "yes": true, "no": false])
        let text = String(data: try JSONEncoder().encode(v), encoding: .utf8)!
        XCTAssertTrue(text.contains("\"one\":1"), "整数 1 不能变成 true：\(text)")
        XCTAssertTrue(text.contains("\"zero\":0"), "整数 0 不能变成 false：\(text)")
        XCTAssertTrue(text.contains("\"yes\":true"))
        XCTAssertTrue(text.contains("\"no\":false"))
    }
}
