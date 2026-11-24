import Foundation

// MARK: - 参数中心**域**映射
//
// 参数中心页左侧域导航的**单一来源**：域 → schema 分组键。
// 分组本身仍以 `param_schema_export.json` 的 `schema_groups` 为准（本枚举只做
// 「原样映射」——把 13 组归拢成 5 个可浏览的域 + 1 个调优面板，**不重新切分组**）。
//
// ⚠ 契约测试（`ParamDomainSpecTests`）钉死：
//   · 每个 schema 分组**恰好属于一个域**（新增分组忘了归域 → 测试变红，
//     防止"参数存在但任何域都看不到"）；
//   · 每个域声明的分组键都必须真实存在于 schema（防止 schema 改名后域里挂着幽灵键）。

/// 参数中心的域（侧栏导航项；`tune` 不是 schema 域，是参数调优面板）
public enum ParamDomain: String, CaseIterable, Identifiable {
    case scoring
    case filter
    case tierBudget
    case predict
    case iterate
    case tune

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .scoring: return "打分规则"
        case .filter: return "过滤链"
        case .tierBudget: return "档位与预算"
        case .predict: return "预判策略"
        case .iterate: return "复盘迭代"
        case .tune: return "参数调优"
        }
    }

    /// 该域覆盖的 schema 分组键（`schema_groups[].group`）；调优面板 = 空
    public var groupKeys: [String] {
        switch self {
        case .scoring: return ["scoring_bonus", "scoring_penalty", "scoring_intraday"]
        case .filter: return ["hard_filter", "profile_filter", "form_filter", "deep_filter", "exclusion"]
        case .tierBudget: return ["tiers", "budget", "etf"]
        case .predict: return ["predict"]
        case .iterate: return ["iterate"]
        case .tune: return []
        }
    }

    /// 有 schema 内容的域（编辑器可停留的域）
    public static var paramDomains: [ParamDomain] { allCases.filter { !$0.groupKeys.isEmpty } }

    /// 分组键 → 域（未知键返回 nil，由契约测试兜底）
    public static func domain(forGroupKey key: String) -> ParamDomain? {
        allCases.first { $0.groupKeys.contains(key) }
    }
}
