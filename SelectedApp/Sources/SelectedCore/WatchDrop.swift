import Foundation

/// 从「拖进来的文本」里提取股票 / 基金代码（支持从别的 App 拖入自选）。
///
/// ## 为什么要抽成 Core 纯函数
/// 拖入的文本**形态完全不可控**（可能是 `600000`、`600000 浦发银行`、`SZ600000`、
/// `00700 腾讯控股`、一段含代码的笔记…）⇒ 提取规则必须可单测（同 `AlertInput.parse` 的纪律）。
///
/// ## 判据（刻意保守）
/// · 只认**独立**的 5~6 位数字串（前后都不能再有数字）——
///   否则 `1234567` 会被截成 `123456`、`20261007` 会变成 `202610`；
/// · **6 位优先**：A 股 / 场内基金（ETF/LOF）都是 6 位，5 位（港股）只在没有 6 位时才取；
/// · 只取**第一处**命中；**是否真实存在不在这里判** ——
///   交给 `Store.addWatchByCode` 的行情校验（取不到名称即明确拒绝）。
///
/// ⚠ 与 `WatchSearchField` 的"整串是 5~6 位数字"判据**不同**（那个是"输入框里只有代码"，
///   这里是"从一段任意文本里捞代码"）—— 两者刻意不合并：合并会让搜索框把
///   `600000 浦发` 这种含空格的输入也当代码（而那是**搜索**，应走搜索路径）。
public enum WatchDrop {

    /// 从任意文本里提取代码；提取不到返回 `nil`（调用方负责给出明确提示，不许静默）。
    public static func extractCode(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let six = firstMatch(in: trimmed, digits: 6) { return six }
        return firstMatch(in: trimmed, digits: 5)
    }

    /// 找第一处**独立**的 `digits` 位数字串（前后非数字）。
    private static func firstMatch(in text: String, digits: Int) -> String? {
        // ⚠ 用 lookaround 而不是 `\b`：`\b` 只认"词边界"（下划线也算词字符），
        //   而 `SZ_600000` 这类形态里我们需要的是"前后不是数字"这一条更强的约束。
        let pattern = "(?<![0-9])[0-9]{\(digits)}(?![0-9])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range),
              let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }
}