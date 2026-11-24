import XCTest
@testable import SelectedCore

/// `PhaseTune.metrics` 表的**不变量**。
///
/// ## 为什么值得单测
/// 表本身是 `static let`，看着"常量不会错"—— 但**两处回落逻辑都依赖它的形状**：
///   · `evaluate` / `tune` 入口把 `metric` 规范化为 `metrics.contains ? metric : defaultMetric`
///     （`PhaseTune.swift:309` / `:607`）；
///   · `profitSrc` 的两层回落（`metrics[key] ?? metrics[defaultMetric]`）。
/// 一旦 `defaultMetric` 不在表里、或 key 重复，这些回落**全部落空**，而症状是
/// "某个口径的收益静默取不到"（不是崩溃、不是报错）—— 正是本项目最怕的那类失效。
/// ⇒ 用单测把三条不变量钉住：非空 / `defaultMetric` 在表里 / key 唯一且 field 非空。
final class PhaseTuneMetricTests: XCTestCase {

    func testMetricTableInvariants() {
        let metrics = PhaseTune.metrics
        XCTAssertFalse(metrics.isEmpty, "metrics 表不能为空（两处回落都靠它）")

        XCTAssertTrue(metrics.contains { $0.key == PhaseTune.defaultMetric },
                      "defaultMetric(\(PhaseTune.defaultMetric)) 必须真的在 metrics 表里 —— "
                      + "否则入口规范化与 profitSrc 的回落都会落空")

        let keys = metrics.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "metric key 不能重复：\(keys)")

        XCTAssertTrue(metrics.allSatisfy { !$0.field.isEmpty },
                      "每个 metric 都要有非空 field（取 `it.actual[field]` 用）")
        XCTAssertTrue(metrics.allSatisfy { !$0.label.isEmpty },
                      "每个 metric 都要有非空 label（`metric_label` 直接进界面）")

        // 口径表里必须同时有 l3（默认）与 close（`profitSrc` 的回退目标）
        XCTAssertTrue(keys.contains("l3") && keys.contains("close"),
                      "l3 / close 是回退链上的两个锚点，缺一个都会静默改口径")
    }
}
