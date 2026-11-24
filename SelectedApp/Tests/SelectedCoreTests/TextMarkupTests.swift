import XCTest
@testable import SelectedCore

/// `TextMarkup.toCJK` 的行为锁。
///
/// 为什么值得单测：它是引擎冻结文案（不能改）到用户眼睛之间
/// **唯一**的一道归一化。它错了没有别的机制兜底 —— 而它错的表现是"用户看到半个书名号"，
/// 比星号更难解释。
final class TextMarkupTests: XCTestCase {

    func testConvertsSinglePair() {
        XCTAssertEqual(TextMarkup.toCJK("（**不是**中性）"), "（「不是」中性）")
    }

    func testConvertsMultiplePairs() {
        XCTAssertEqual(
            TextMarkup.toCJK("当日**全部已评分标的**（含三档）……**仍未覆盖**：全市场阶段被淘汰的"),
            "当日「全部已评分标的」（含三档）……「仍未覆盖」：全市场阶段被淘汰的")
    }

    /// 这条是"为什么不用 `AttributedString(markdown:)`"的证据：
    ///   引擎文案里有下划线和竖线，Markdown 解析会吃掉它们；本函数只动 `**`。
    func testLeavesOtherMarkdownCharactersAlone() {
        let s = "缺口说明：excluded_stocks 没有那列 | 见 a_b_c"
        XCTAssertEqual(TextMarkup.toCJK(s), s, "没有 ** 时一个字符都不许动")
    }

    /// 不成对 → 原样返回（配半个「比星号更难解释）
    func testOddCountReturnsUnchanged() {
        XCTAssertEqual(TextMarkup.toCJK("a**b"), "a**b")
        XCTAssertEqual(TextMarkup.toCJK("a**b**c**d"), "a**b**c**d")
    }

    func testNoMarkerReturnsSameInstance() {
        let s = "本轮仅有 2/3 轮数据（缺 14:50）"
        XCTAssertEqual(TextMarkup.toCJK(s), s)
    }

    func testEmptyString() {
        XCTAssertEqual(TextMarkup.toCJK(""), "")
    }

    /// 真实文案回归：`compare_reports` **历史落库**的 JSON 仍含 `**`，
    ///   展示层 toCJK 负责渲染兼容。
    func testRealSignalsWarningsText() {
        let w = "⚠ 本轮仅有 2/3 轮数据（缺 14:50），**无法判定三轮持续性**：所有标的标记为「未验证」，"
            + "不得按持续信号对待（补跑窗口 25 分钟，超时该轮永久缺失）"
        let got = TextMarkup.toCJK(w)
        XCTAssertFalse(got.contains("**"), "归一化后不该再有星号")
        XCTAssertTrue(got.contains("「无法判定三轮持续性」"))
        // 原本就在文案里的「未验证」必须保持原样（别把已有的书名号再折一次）
        XCTAssertTrue(got.contains("「未验证」"))
    }
}
