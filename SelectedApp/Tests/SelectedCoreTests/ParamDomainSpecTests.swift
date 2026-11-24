import XCTest
@testable import SelectedCore

/// 参数中心**域映射**契约：
/// 每个 schema 分组恰好属于一个域；每个域声明的分组键都真实存在。
/// 防的是"参数存在但任何域都看不到"。
final class ParamDomainSpecTests: XCTestCase {

    override func setUpWithError() throws {
        try EntityTestSupport.requireParamSchema()
    }

    /// 每个 schema 分组**恰好属于一个域**（无遗漏、无重复）
    func testEverySchemaGroupBelongsToExactlyOneDomain() {
        let groupKeys = ParamSchema.shared.groups.map { $0.raw["group"] as? String ?? "" }
        XCTAssertFalse(groupKeys.isEmpty, "schema 分组为空（元数据不完整）")
        for key in groupKeys {
            let hits = ParamDomain.allCases.filter { $0.groupKeys.contains(key) }
            XCTAssertEqual(hits.count, 1,
                           "分组「\(key)」归属 \(hits.count) 个域（必须恰好 1 个）",
                           file: #filePath, line: #line)
        }
    }

    /// 每个域声明的分组键都必须真实存在于 schema（防 schema 改名后域里挂幽灵键）
    func testDomainGroupKeysAllExistInSchema() {
        let known = Set(ParamSchema.shared.groups.map { $0.raw["group"] as? String ?? "" })
        for d in ParamDomain.allCases {
            for key in d.groupKeys {
                XCTAssertTrue(known.contains(key),
                              "域「\(d.title)」声明了 schema 里不存在的分组「\(key)」",
                              file: #filePath, line: #line)
            }
        }
    }

    /// 调优面板不是 schema 域（导航靠它，编辑器不往它塞表单）
    func testTuneIsNotASchemaDomainPlaceholder() {
        XCTAssertTrue(ParamDomain.tune.groupKeys.isEmpty)
        XCTAssertEqual(ParamDomain.paramDomains.count, ParamDomain.allCases.count - 1)
    }
}
