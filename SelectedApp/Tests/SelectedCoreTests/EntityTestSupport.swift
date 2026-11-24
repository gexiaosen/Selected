import XCTest
@testable import SelectedCore

/// 实体测试的共用工具（键覆盖 + 无损往返 + 夹具定位）
///
/// 抽出来是因为**每个数据族都要用同一套验证**：键覆盖与无损往返
/// 是唯一能证明"实体与生产者一致"的手段，不能有第二份实现。
enum EntityTestSupport {

    /// 仓库根目录（`Tests/SelectedCoreTests/X.swift` 上溯 4 层）
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // Tests/SelectedCoreTests
        .deletingLastPathComponent()      // Tests
        .deletingLastPathComponent()      // SelectedApp
        .deletingLastPathComponent()      // 仓库根

    /// 夹具缺失 → **测试失败**（**不是** `XCTSkip`）：
    /// 黄金夹具**已纳入版本管理**，且**手工一次性捕获、不可重新生成**
    /// （脚本造不出来）—— 缺失 = 仓库不完整 / 有人误删，
    /// **不是"当前环境不具备这个条件"**。
    /// 跳过会把"全新 clone 上整批实体验证静默少跑"伪装成"全绿"
    /// （见 `.gitignore` 里 `engine/tests/fixtures/` 那段说明）。
    struct FixtureMissing: Error, CustomStringConvertible {
        let path: String
        var description: String {
            "找不到夹具 \(path) —— 黄金夹具随仓库提供（已纳入版本管理）；"
                + "缺失说明仓库不完整或被误删，请用 `git checkout -- engine/tests/fixtures` 恢复"
        }
    }

    static func fixture(_ relative: String) throws -> JSONValue {
        let url = repoRoot.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FixtureMissing(path: relative)
        }
        let data = try Data(contentsOf: url)
        return JSONValue(try JSONSerialization.jsonObject(with: data))
    }

    /// 参数元数据（`engine/params/param_schema_export.json`）读不到 → **测试失败**（不是 `XCTSkip`）
    ///
    /// 与 `FixtureMissing` 同一口径：该文件**已纳入版本管理**，且是**随包资源**
    /// （`ParamSchema.resourceCandidates` 先找 Bundle 资源目录、再按 cwd 上溯 3 层）。
    /// 读不到 = 仓库不完整 / 打包漏了资源，**不是"当前环境不具备这个条件"**。
    ///
    /// 跳过会让 `ParamSchemaContractTests` / `ParamTableSpecsTests` /
    /// `KLinePatternsTests` 里那批**参数兼容性契约**与**展示元数据覆盖性**断言静默少跑，
    /// 而 `swift test` 仍报 **0 failures**（与黄金夹具同一口径，见 `.gitignore` 说明）。
    struct ParamSchemaUnavailable: Error, CustomStringConvertible {
        var description: String {
            "参数元数据读不到（engine/params/param_schema_export.json）—— 该文件随仓库提供、"
                + "且是随包资源；缺失说明仓库不完整或打包漏了资源，请先确认资源已随包"
        }
    }

    /// 前置断言：参数元数据必须可读（读不到 → 抛错失败，**不跳过**）
    static func requireParamSchema() throws {
        guard ParamSchema.shared.isAvailable else { throw ParamSchemaUnavailable() }
    }

    /// 规范形式：只用于比较，不参与断言逻辑
    ///
    /// 用 **`PyJSON.encode`**（生产同款编码器），**不是** `JSONSerialization.data`：
    /// `JSONSerialization` 的浮点格式化**取决于 `NSNumber` 的具体类** ——
    /// 短小数是 `__NSCFNumber`（写 `%.17g`），长小数被解析成 `NSDecimalNumber`（写精确十进制），
    /// 于是"同一个数"可能写出两种文本，比较结果不可预期。
    /// `PyJSON.encode` 走 `floatStr`，格式化与类无关，且**就是落库时用的那份**。
    static func canonical(_ v: JSONValue) throws -> String {
        PyJSON.encode(v.raw)
    }

    /// 走真实落库路径：实体 → JSON 文本 → 解析回来
    ///
    /// 必须用 **`PyJSON.encode`** 而不是 `JSONEncoder`：
    /// ① 那才是真实落库路径（`ScanStore.persistRound` 写 `PyJSON.encode(...)`，
    ///    `SQLiteReader` 读回来再 `JSONSerialization` 解析）——
    ///    用 `JSONEncoder` 只是"看起来像"，它并不是生产用的编码器；
    /// ② `JSONEncoder` 会把 `NSDecimalNumber` 走 `doubleValue`，而那个转换
    ///    **不是正确舍入的**（实测 `0.070000000000000007` → `0.07000000000000003`，差 1 ULP），
    ///    于是测试会报一个**生产路径根本不会发生**的"精度丢失"；
    /// ③ `JSONDecoder` 会把 `110` 与 `110.0` 都归一化（`NSNumber.isEqual` 按值比较），
    ///    正好把 int/float 形态漂移盖掉。
    static func roundTrip(_ v: JSONValue) throws -> JSONValue {
        let text = PyJSON.encode(v.raw)
        return JSONValue(try JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    /// 键覆盖：真实键集必须落在 `declaredKeys` 内；`declaredKeys` 的"多余键"只允许是条件键
    static func assertKeyCoverage<T: JSONEntity>(
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
    static func assertLossless<T: JSONEntity>(
        _ entity: T, _ original: JSONValue, _ path: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let back = try roundTrip(entity.json)
        XCTAssertEqual(try canonical(back), try canonical(original),
                       "\(path)：JSON → 实体 → JSON 之后内容变了（丢字段或改类型）",
                       file: file, line: line)
    }

    /// 一条龙：键覆盖 + 无损往返
    ///
    /// **空对象跳过键覆盖**：引擎在某些变体里给的是 `{}`（如 `CompareStability` 在
    /// `status=no_data` 时）。那是一种**不同的形状**，拿"并集 declaredKeys"去比一个空对象
    /// 只会误报（"实体声明了引擎输出里不存在的键"）。空对象只做无损往返断言。
    static func check<T: JSONEntity>(
        _ type: T.Type, _ json: JSONValue, _ path: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        if !json.dict.isEmpty {
            assertKeyCoverage(type, json, path, file: file, line: line)
        }
        try assertLossless(type.init(json), json, path, file: file, line: line)
    }

    /// 断言某个访问器**真的读到了值**（而不是静默落回默认）
    ///
    /// 为什么必须有这一类断言：键覆盖只验证"键在不在"，无损往返只验证"raw 没被改"，
    /// **两者都验不了"访问器的取值口径对不对"** ——
    /// 例如把 `{"1": 110}` 当数组读会得到空集合，而前两道检查全绿。
    /// 所以在真实夹具上必须逐字段断言一遍取值。
    static func assertNonEmpty<T>(
        _ value: T?, _ path: String, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertNotNil(value, "\(path)：\(what) 读不到值（键名/形态写错？）", file: file, line: line)
    }
}
