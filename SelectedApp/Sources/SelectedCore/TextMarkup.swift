import Foundation

/// 引擎文案里的 **Markdown 强调标记** → 中文书名号「」。
///
/// ## 定位：**历史数据兼容层**
///
/// 新产出的文案已在源头改用「」（不再含 `**`）。但 `compare_reports` 表里
/// **历史轮次落库的 JSON 仍含 `**` 形态**（`CompareView` / `DashboardView`
/// 会按日期回看这些旧轮次）⇒ 展示层的 `toCJK` 是旧数据的渲染兼容。
/// 哪天确认历史轮次不再回看（或做过一次文案迁移），才能连调用点一起移除。
///
/// ## 为什么不是"渲染成 Markdown"
///
/// 这些文案是**运行时 `String`**（从 JSON 取出来的），`Text(String)` 走 **verbatim**、
/// 不解析 Markdown → 用户看到的是**字面的星号**。要真渲染得引入
/// `AttributedString(markdown:)`，而引擎文案里含 `_`（如 `excluded_stocks`）、
/// `|`、`%`、`⚠` —— Markdown 解析会误伤（把 `_x_` 吃成斜体）。
/// 本函数**只动 `**`**，其余字符原样，零误伤风险。
/// 「」也是本项目既有的强调写法（视图侧已统一成同一套记号），不引入第三种。
///
/// ## 用法
///
/// ```swift
/// Text(TextMarkup.toCJK(s.text))     // ✅
/// Text(s.text)                       // ❌ 星号原样显示
/// ```
///
/// ⚠ **只在展示层用**。`Core` 内部的 JSON 输出**不许**过这个函数 ——
///   "输出层不改文案"是纪律：要改就改源头。
public enum TextMarkup {

    /// 把成对的 `**…**` 折成 `「…」`；**不成对时原样返回**。
    ///
    /// ⚠ 不成对（`**` 出现奇数次）时**不做任何替换**，而不是尽力而为地配一个半个「——
    ///   半个书名号比星号更难解释，而且说明输入本来就不是 Markdown 强调（可能是个乘积或通配）。
    public static func toCJK(_ s: String) -> String {
        // 先数一遍：奇数个 `**` → 不是成对强调，原样返回。
        var count = 0
        var probe = Substring(s)
        while let r = probe.range(of: "**") {
            count += 1
            probe = probe[r.upperBound...]
        }
        guard count % 2 == 0, count > 0 else { return s }

        var out = ""
        out.reserveCapacity(s.count)
        var rest = Substring(s)
        var opening = true
        while let r = rest.range(of: "**") {
            out += rest[rest.startIndex..<r.lowerBound]
            out += opening ? "「" : "」"
            opening.toggle()
            rest = rest[r.upperBound...]
        }
        out += rest
        return out
    }
}
