import XCTest
@testable import SelectedCore

/// `StockQuotes.parse` 里**涨跌额（`change`）的来源契约**。
///
/// 背景：涨跌额有两个候选来源 —— ① 接口原值 `f[31]`；② 自算 `现价 − 昨收`。
///
/// **实测结论（10 个标的，含港股 / ETF / 指数 / 北交所，全精度）：两者完全相同**
///   （差 ~1e-13，纯浮点噪声）。所以这**不是**"哪个更准"的问题，而是**同源**问题：
///   自选表「涨跌额」列与详情页显示的就是 `q.change`，判据必须与用户看到的那个数一致。
///
/// 真正的分岔点在 `f[31]` **缺失**时：`parse` 回落 `?? 0` → **界面也显示 0.00**，
///   两边一致地"没有值"；若改成自算（`price` / `previousClose` 都是解析**必需**字段），
///   就会变成**界面显示 0.00、判据却按真实差额判** —— "界面说没动、提醒却响了"。
///   `testMissingField31FallsBackToZeroNotArithmetic` 就是钉这一条的**判别性用例**。
///
/// 注意：**核对数值时必须全精度打印** —— 格式化输出（如 `%.2f`）会制造不存在的差异。
final class StockQuotesTests: XCTestCase {

    /// 造一条腾讯响应。只填到 `f[32]`（其余留空）就够 —— `parse` 只要求 `f.count >= 40`，
    /// 而 `f[43]+` 的那些可选字段会被 `f.count > N` 的守卫置空。
    private func raw(price: String, preClose: String, change: String, pct: String) -> String {
        var f = Array(repeating: "", count: 40)
        f[0] = "1"          // 市场标记
        f[1] = "测试股份"    // 名称
        f[2] = "600000"     // 代码
        f[3] = price        // 现价
        f[4] = preClose     // 昨收
        f[31] = change      // 涨跌额
        f[32] = pct         // 涨跌幅
        return "v_sh600000=\"" + f.joined(separator: "~") + "\";"
    }

    /// **判别性用例**：`f[31]` 缺失（空串）而现价与昨收差 1 元时，
    /// `change` 必须回落 **0**，**不许**自算成 1.00。
    ///
    /// 若哪天有人把 `parse` 改成 `Double(f[31]) ?? (price - preClose)`（"顺手更稳"），
    /// **只有这条会红** —— 而那个改动会让界面显示 `+0.00`、提醒却按 `+1.00` 触发。
    func testMissingField31FallsBackToZeroNotArithmetic() {
        let parsed = StockQuotes.parse(rawString: raw(price: "10.00", preClose: "9.00",
                                                      change: "", pct: ""),
                                       market: "sh")
        guard let q = parsed else { return XCTFail("这条响应必须能解析出来") }
        XCTAssertEqual(q.change, 0, "f[31] 缺失时回落 0（与界面显示 0.00 一致），不许自算成 1.00")
        XCTAssertEqual(q.changePercent, 0, "涨跌幅同理")
        // 前提确认：现价与昨收**确实不同**，否则这条用例证明不了任何事
        XCTAssertEqual(q.currentPrice - q.previousClose, 1.00, accuracy: 1e-9,
                       "夹具必须让「自算值」远离 0，否则这条断言是空的")
    }

    /// 契约：`f[31] ≡ 现价 − 昨收`（全精度，实测 10/10）。
    /// 这条**不是**在挑来源，而是把"接口语义"钉住 —— 哪天厂商改了 `f[31]` 的含义
    /// （比如改成"相对昨收的某种调整值"），这里会红。
    func testChangeMatchesPriceMinusPrevCloseWhenPresent() {
        // 用真实响应里的形态：茅台 1258.19 / 1253.80 → f31 = 4.39
        let parsed = StockQuotes.parse(rawString: raw(price: "1258.19", preClose: "1253.80",
                                                      change: "4.39", pct: "0.35"),
                                       market: "sh")
        guard let q = parsed else { return XCTFail("这条响应必须能解析出来") }
        XCTAssertEqual(q.change, q.currentPrice - q.previousClose, accuracy: 1e-9,
                       "实测 f[31] ≡ 现价 − 昨收；不成立说明接口语义变了")
        XCTAssertEqual(q.changePercent, 0.35)
    }

    /// ETF / 基金的报价是**三位小数**（实测 159915：现价 `3.406`、昨收 `3.420`、
    /// 涨跌额 `-0.014`）—— 涨跌额阈值同样支持小数，别在界面上按"分"取整。
    func testFundQuotesKeepThreeDecimals() {
        let parsed = StockQuotes.parse(rawString: raw(price: "3.406", preClose: "3.420",
                                                      change: "-0.014", pct: "-0.41"),
                                       market: "sz")
        guard let q = parsed else { return XCTFail("这条响应必须能解析出来") }
        XCTAssertEqual(q.change, -0.014, accuracy: 1e-12, "涨跌额的三位小数不许被截断")
        XCTAssertEqual(q.change, q.currentPrice - q.previousClose, accuracy: 1e-9)
    }

    /// 严格 ASCII 数字校验：拒绝全角数字与阿拉伯-印度数字，防止 URL 拼接/解析误放行
    func testNonAsciiDigitsAreRejectedAcrossCodeValidators() {
        XCTAssertNil(StockQuotes.symbolKey(of: "v_sh６００５１９=\"1~x\";"))
        XCTAssertFalse(DataSourceEndpoints.isQuoteCode("６００５１９"))
        XCTAssertFalse(DataSourceEndpoints.isSixDigitCode("٠١٢٣٤٥"))
        XCTAssertNil(KLineService.eastmoneyMinuteURL(fullCode: "sh６００５１９"))
    }
}
