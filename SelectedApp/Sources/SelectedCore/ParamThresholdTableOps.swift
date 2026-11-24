import Foundation

/// 阈值→分值表的**纯逻辑**（参数中心的行编辑器调用它，自己只负责画）。
///
/// 抽到 `SelectedCore` 成纯函数以便 `swift test` 覆盖（UI 层只经过类型检查，
/// "键名怎么变、冲突怎么处理"这类逻辑不能只靠手点）。
///
/// 键名规则不在这里实现，走 `Screener.keyThreshold` / `Screener.thresholdKey`（编解码同源）。
public enum ParamThresholdTableOps {

    /// 一行：键名 + 解析出的比较符 / 阈值 / 分值
    public struct Row: Equatable {
        public let key: String
        public let op: String
        public let threshold: Double
        public let score: Double
    }

    /// 解析成行，**按阈值从小到大**排序（与键名在字典里的顺序无关 ——
    /// 用户读起来应该从松到紧，而不是按插入顺序）。
    ///
    /// 解析不了的行（键名非法 / 分值非数值）**跳过**：它们由
    /// `ParamTableSpecs.problem` 在保存前报错，这里不猜。
    public static func rows(_ table: [String: Any]) -> [Row] {
        table.compactMap { k, v -> Row? in
            guard let p = Screener.keyThreshold(k), let n = asDouble(v) else { return nil }
            return Row(key: k, op: p.op, threshold: p.threshold, score: n)
        }
        .sorted { a, b in a.threshold == b.threshold ? a.op < b.op : a.threshold < b.threshold }
    }

    /// 换键名（改比较符或改阈值都走这里）。
    ///
    /// **冲突（新键已存在）或新键非法 → 返回 nil**，由调用方提示。
    /// 不静默覆盖：两个档位合并成一个，用户不会察觉。
    public static func replacingKey(_ table: [String: Any],
                                    from oldKey: String,
                                    to newKey: String) -> [String: Any]? {
        guard Screener.keyThreshold(newKey) != nil else { return nil }
        guard newKey != oldKey else { return table }
        guard table[newKey] == nil else { return nil }
        guard let score = table[oldKey] else { return nil }
        var out = table
        out.removeValue(forKey: oldKey)
        out[newKey] = score
        return out
    }

    /// 新增一档，默认落在现有档位之外（`>` 取比最大阈值更大的一档）。
    ///
    /// 返回新表与新键；极端情况下找不到空位（1000 次仍冲突）→ 返回 nil。
    public static func addingRow(_ table: [String: Any],
                                 startAfter: Double? = nil) -> (table: [String: Any], key: String)? {
        var t = (startAfter ?? rows(table).map(\.threshold).max() ?? 0) + 1
        for _ in 0..<1000 {
            if let key = Screener.thresholdKey(op: ">", threshold: t), table[key] == nil {
                var out = table
                out[key] = 0
                return (out, key)
            }
            t += 1
        }
        return nil
    }

    /// `NSNumber` 会桥接 `Bool`，显式排除 —— 与 `JSONValue` 的取值语义一致
    private static func asDouble(_ v: Any) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
}
