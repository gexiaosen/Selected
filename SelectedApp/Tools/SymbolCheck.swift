import AppKit

/// 图标名有效性自检的驱动
///
/// ## 为什么需要
/// `Image(systemName:)` / `Label(_:systemImage:)` / `MenuBarExtra(systemImage:)` 在
/// **符号名不存在**时**什么都不画** —— 不报错、不占位、编译照过、测试全绿
/// （如 `clock.badge.gearshape` 在 macOS 26 上**不存在**，没画出来没人发现）。
/// ⇒ 只能拿 AppKit 挨个问：「这个名字在本机解析得出来吗？」
///
/// ## 判据
/// `NSImage(systemSymbolName:accessibilityDescription:)` 返回 `nil` ⇔ 名字无效。
/// 用的是**本机**符号表（SF Symbols 随系统版本增删）—— 这正是要的效果：
///   名字必须在这台机器上真的画得出来，而不是"某版 SDK 里有"。
///
/// 用法：`SymbolCheck <名字清单文件>`（每行一个名字，由 `Tools/symbol_check.sh` 抽取）
@main
struct SymbolCheck {
    static func main() {
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
        guard !path.isEmpty, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("❌ symbol_names  读不到名字清单：\(path.isEmpty ? "(未传参)" : path)")
            exit(2)
        }
        let names = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !names.isEmpty else {
            print("❌ symbol_names  清单是空的（抽取步骤出了问题）")
            exit(2)
        }
        var bad: [String] = []
        for n in names where NSImage(systemSymbolName: n, accessibilityDescription: nil) == nil {
            bad.append(n)
        }
        if bad.isEmpty {
            print("✅ symbol_names  \(names.count) 个图标名在本机全部可解析（不会静默空白）")
            exit(0)
        }
        print("❌ symbol_names  \(bad.count) 个图标名在本机不存在 —— 界面上会是**什么都没有**：")
        for b in bad { print("     · \(b)") }
        print("     ⇒ 换一个真实存在的符号名：用「SF Symbols」app 查，或先跑 `bash Tools/symbol_check.sh` 试。")
        print("     ⇒ 有效名字的判据 = `NSImage(systemSymbolName:)` 非 nil（本机符号表，随系统版本变化）。")
        exit(1)
    }
}