import Foundation

/// 有序 JSON 值 + Python 风格渲染（`json.dumps(..., ensure_ascii=False, indent=1)` 等价）。
///
/// 用于生成随包资源 `engine/params/{db,param_schema}_export.json`（Swift 侧生成，
/// 见 `SchemaExport`），输出格式必须与历史 Python 渲染**逐字节一致**。
///
/// ⚠ 三个必须与 Python 对齐的细节（差一个字节 `SchemaExportTests` 就报红）：
///   1. **键序 = 插入序**（Python dict 保序）⇒ 必须用 `[(String, PyVal)]` 而不是 `[String: PyVal]`；
///   2. **缩进是 1 个空格**，且分隔符是 `", "`（数组内联时）与 `": "`；
///   3. **浮点用 `repr` 形态**（`3.0` 而不是 `3`）—— 走 `PyJSON.floatStr` 的同一口径。
public indirect enum PyVal: Sendable {
    case obj([(String, PyVal)])
    case arr([PyVal])
    case str(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
}

public enum PyPrettyJSON {

    /// `json.dumps(obj, ensure_ascii=False, indent=1)` 等价 + 末尾换行
    public static func render(_ v: PyVal) -> String {
        body(v, level: 0) + "\n"
    }

    private static func indent(_ n: Int) -> String { String(repeating: " ", count: n) }

    private static func body(_ v: PyVal, level: Int) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return PyJSON.floatStr(d)
        case .str(let s): return "\"\(escape(s))\""
        case .arr(let items):
            if items.isEmpty { return "[]" }
            let inner = items.map { indent(level + 1) + body($0, level: level + 1) }
                .joined(separator: ",\n")
            return "[\n" + inner + "\n" + indent(level) + "]"
        case .obj(let pairs):
            if pairs.isEmpty { return "{}" }
            let inner = pairs.map { key, value in
                indent(level + 1) + "\"\(escape(key))\": " + body(value, level: level + 1)
            }.joined(separator: ",\n")
            return "{\n" + inner + "\n" + indent(level) + "}"
        }
    }

    /// 非 ASCII 原样保留（`ensure_ascii=False`），只转义 JSON 必需字符。
    /// ⚠ `\b` / `\f` 也必须转成短转义，漏了会与之形态不一致。
    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 2)
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out
    }
}
