import Foundation

// MARK: - 参数版本 diff
//
// 两版本参数**按 schema 点路径逐键比对**的纯函数（无库、无 UI，可单测）：
//   · 参数中心顶部「与激活版本差异 (n)」的展示。
//
// 比对范围 = `ParamSchema.allItems`（schema 里有什么比什么）：
//   · schema 外的键不参与（存量版本 JSON 里残留的未知键无害，与 `validate` 同口径）；
//   · 「显式 null」与「键缺失」都读成 nil（`getValue` 的 `nonNull` 折叠），
//     两者在 diff 里等价 —— 展示都是「—」。

/// 一条差异（schema 点路径 + 中文名 + 新旧值的展示文本）
public struct ParamDiffEntry {
    public let key: String
    public let label: String
    public let newValue: Any?
    public let oldText: String
    public let newText: String

    public init(key: String, label: String, newValue: Any?, oldText: String, newText: String) {
        self.key = key
        self.label = label
        self.newValue = newValue
        self.oldText = oldText
        self.newText = newText
    }
}

public enum ParamVersionDiff {

    /// 逐键比对（old=基线，new=对比对象；顺序 = schema 项顺序，确定性输出）
    public static func diff(old: [String: Any], new: [String: Any]) -> [ParamDiffEntry] {
        var out: [ParamDiffEntry] = []
        for it in ParamSchema.shared.allItems {
            let a = ParamSchema.getValue(old, it.key)
            let b = ParamSchema.getValue(new, it.key)
            if valuesEqual(a, b) { continue }
            out.append(ParamDiffEntry(key: it.key, label: it.label, newValue: b,
                                      oldText: format(a), newText: format(b)))
        }
        return out
    }

    // MARK: 比较与格式化（与引擎口径一致的细节见文件头注释）

    /// 深比较：字典/数组递归（不受键序影响）、数值跨 int/float 相等、布尔与数值不混等
    static func valuesEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (x?, y?):
            if let dx = x as? [String: Any], let dy = y as? [String: Any] {
                return NSDictionary(dictionary: dx).isEqual(to: dy)
            }
            if let ax = x as? [Any], let ay = y as? [Any] {
                return (ax as NSArray).isEqual(ay as NSArray)
            }
            if let nx = x as? NSNumber, let ny = y as? NSNumber {
                let bx = CFGetTypeID(nx) == CFBooleanGetTypeID()
                let by = CFGetTypeID(ny) == CFBooleanGetTypeID()
                if bx != by { return false }
                if bx { return nx.boolValue == ny.boolValue }
                return nx.doubleValue == ny.doubleValue
            }
            if let sx = x as? String, let sy = y as? String { return sx == sy }
            return false
        }
    }

    /// 展示文本：布尔→开/关、数值走 `PyJSON`（7.0 保持浮点形态）、容器→紧凑 JSON
    static func format(_ v: Any?) -> String {
        guard let v, !(v is NSNull) else { return "—" }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "开" : "关" }
            return PyJSON.numStr(n)
        }
        if let s = v as? String { return s }
        if let d = v as? [String: Any] { return PyJSON.encode(d) }
        if let a = v as? [Any] { return PyJSON.encode(a) }
        return String(describing: v)
    }

}
