import Foundation

/// 反事实覆盖诊断 —— 显式暴露「被淘汰样本无法并入评估池」这个缺口。
///
/// **为什么只做诊断、不做并入**：`PhaseTune.evaluate` 必须拿到 `deepInfo` 才能重新评分，
/// 而 `excluded_stocks` 只有 `code` / `name` / `reason` —— 被淘汰样本的**行情与深度特征
/// 从未落库**（`ScanRunner` 只在深度排除时记了那三个字段）。要真正并入，得先让扫描
/// 把这些特征写下来。在那之前，把缺口做成**可测的数**，而不是 `scope_note` 里的一句散文 ——
/// 用户至少能看见"这次调优的结论覆盖了哪一层、漏了哪一层、漏了多少"。
///
/// ⚠ 「有多少淘汰样本可重新评分」的判据取自 `excluded_stocks` 的**实际列名**
/// （`PRAGMA table_info`），**不是写死的 0** —— 哪天那些列补上了，
/// 这里会自动变成真实计数，不需要回来改代码。
public enum CounterfactualCoverage {

    /// 重新评分一条样本所必需的列（与 `PhaseTune.buildPool` 读 `picks` 的字段一一对应）
    public static let requiredColumns = [
        "volume_ratio", "turnover", "change_pct", "deep_info_json", "score_details_json",
    ]

    /// 缺哪些列（空数组 = 已具备并入条件）
    public static func missingColumns(from columns: Set<String>) -> [String] {
        requiredColumns.filter { !columns.contains($0) }.sorted()
    }

    /// 写进调优结果 JSON 的键
    ///
    /// - Parameters:
    ///   - excludedInWindow: 同一评估窗口内 `excluded_stocks` 的行数
    ///   - excludedRescoreable: 其中**带齐特征、能重新评分**的行数（当前恒 0）
    ///   - poolSize: 实际参与调优的样本数（全部来自 `picks`）
    ///   - missingColumns: `excluded_stocks` 缺的列
    public static func json(excludedInWindow: Int, excludedRescoreable: Int,
                            poolSize: Int, missingColumns: [String]) -> [String: Any] {
        let covered = missingColumns.isEmpty
        let note: String
        if covered {
            note = "被淘汰样本已具备可重新评分的特征列；本窗口 \(excludedInWindow) 条中 "
                + "\(excludedRescoreable) 条可并入。"
        } else {
            // ⚠ 强调用「」不用 `**`：本串经 `TuneEntities.counterfactualNote` 取出来是 `String`，
            //   UI 侧 `Text(String)` 走 verbatim → 星号会原样显示。
            note = "被淘汰样本（本窗口 \(excludedInWindow) 条）「未并入评估池」："
                + "淘汰记录缺 \(missingColumns.joined(separator: " / ")) 字段 "
                + "→ 无法重新评分。要并入需先让扫描落库这些字段。"
        }
        return [
            "excluded_in_window": excludedInWindow,
            "excluded_rescoreable": excludedRescoreable,
            "pool_from_picks": poolSize,
            "missing_columns": missingColumns,
            "covered": covered,
            "note": note,
        ]
    }
}
