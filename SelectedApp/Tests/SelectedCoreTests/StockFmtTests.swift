import XCTest
@testable import SelectedCore

/// `StockFmt` 里**持仓金额链**的精度契约
///
/// ## 背景
///
/// 生产库里有成本价带 3 位小数的真实持仓：
///
/// | 代码 | 名称 | 成本价 | 数量 | 成本金额 |
/// |------|------|--------|------|----------|
/// | `159338` | 中证A500ETF国泰 | **1.249** | 44200 | 55205.8 |
/// | `600276` | 恒瑞医药 | **55.879** | 900 | 50291.1 |
/// | `300760` | 迈瑞医疗 | 11.0 | 100 | 1100 |
///
/// **成本价是 3 位小数是正常的** —— 券商端的摊薄成本（含手续费/分红摊薄）与 ETF 净值
/// 本来就是 3 位（同源事实见 `StockQuotesTests.testFundQuotesKeepThreeDecimals`：
/// ETF 报价实测就是 `3.406` / `-0.014`）。而 `金额 = 成本价 × 数量` ⇒ 金额本身也可能带 3 位。
///
/// ## 三条约束
///
/// | 处 | 要求 | 弄错会怎样 |
/// |---|---|---|
/// | 成本价显示（列 / 详情页） | 3 位 | `%.2f` 让用户看到的成本价是**错的**（`1.249` → `1.25`） |
/// | 编辑弹窗**预填** | 保值 | `%.2f` 预填后点「保存」会把库里的成本价**静默改写成 1.25** ⇒ 市值/盈亏从此永久错 |
/// | 金额 / 盈亏 | ≤3 位、不取整 | `%.0f` 让汇总栏与盈亏列**丢小数** |
///
/// 本文件是这三条的**回归锁**：谁把 `%.2f` / `%.0f` 加回来，`test*` 立刻红。
final class StockFmtTests: XCTestCase {

    // MARK: - 成本价：必须 3 位

    /// **判别性用例**：3 位成本价不许被压成 2 位
    func testCostPriceKeepsThreeDecimals() {
        XCTAssertEqual(StockFmt.costPrice(1.249), "1.249")
        XCTAssertEqual(StockFmt.costPrice(55.879), "55.879")
        XCTAssertEqual(StockFmt.costPrice(11.0), "11.000", "固定 3 位，价格列才好对齐")

        // 反向验证：`%.2f` 给出的**就是那个错值** —— 两者必须不同
        XCTAssertEqual(String(format: "%.2f", 1.249), "1.25")
        XCTAssertNotEqual(StockFmt.costPrice(1.249), String(format: "%.2f", 1.249),
                          "若这条相等，说明精度修正被回退了")
    }

    // MARK: - 金额：≤3 位、去尾随零、不取整

    func testMoneyKeepsThousandthAndDropsTrailingZeros() {
        XCTAssertEqual(StockFmt.money(55205.8), "55205.8")
        XCTAssertEqual(StockFmt.money(50291.1), "50291.1")
        XCTAssertEqual(StockFmt.money(50580.0), "50580", "整数不补 `.000`")
        XCTAssertEqual(StockFmt.money(3.702), "3.702", "真正的 3 位必须留住")
        XCTAssertEqual(StockFmt.money(-0.001), "-0.001")
        XCTAssertEqual(StockFmt.money(0), "0")
    }

    /// 浮点尾巴要归一：`1.001 × 300` 在 Double 里是 `300.29999999999995`
    func testMoneyNormalizesFloatNoise() {
        let raw = 1.001 * 300
        XCTAssertNotEqual(raw, 300.3, "前提：这个乘法确实带浮点尾巴")
        XCTAssertEqual(StockFmt.money(raw), "300.3", "归一后必须是干净的 0.001 元")
        // 另两个同类样本（8.7×100 / 0.29×100 也带尾巴）
        XCTAssertEqual(StockFmt.money(8.7 * 100), "870")
        XCTAssertEqual(StockFmt.money(0.29 * 100), "29")
    }

    /// 反向验证：旧的 `%.0f` 会把金额取整成另一个数
    func testMoneyIsNotRoundedToWholeYuan() {
        XCTAssertEqual(String(format: "%.0f", 55205.8), "55206")
        XCTAssertEqual(StockFmt.money(55205.8), "55205.8")
        XCTAssertNotEqual(StockFmt.money(55205.8), String(format: "%.0f", 55205.8))
    }

    func testSignedMoneyAlwaysCarriesASign() {
        XCTAssertEqual(StockFmt.signedMoney(288.9), "+288.9")
        XCTAssertEqual(StockFmt.signedMoney(-288.9), "-288.9")
        XCTAssertEqual(StockFmt.signedMoney(0), "+0", "0 带 `+`，与旧 `%+.0f` 一致")
    }

    /// 1 亿以上缩到亿（个人持仓到不了，只是防列宽炸掉的兜底）
    func testMoneyScalesOnlyAtAHundredMillion() {
        XCTAssertEqual(StockFmt.money(1_2345_6789.0), "1.235亿")
    }

    // MARK: - 预填保值

    /// **本文件最重要的一条**：`exact` 预填**不许改变值**
    ///
    /// 若用 `%.2f` 预填，用户点「保存」就会把 `1.249` 写成 `1.25`。
    func testExactPrefillNeverRoundsTheCost() {
        XCTAssertEqual(StockFmt.exact(1.249), "1.249")
        XCTAssertNotEqual(StockFmt.exact(1.249), String(format: "%.2f", 1.249),
                          "若相等，说明预填又变成会改坏数据的那版了")
        XCTAssertEqual(StockFmt.exact(55.879), "55.879")
        XCTAssertEqual(StockFmt.exact(11.0), "11")
        XCTAssertEqual(StockFmt.exact(44200.0), "44200")
        XCTAssertEqual(StockFmt.exact(1.2495), "1.2495", "位数更多也要保真")
    }

    /// 往返不变量：`Double(exact(v)) == v` —— 这是"保真"的定义
    func testExactRoundTripsExactly() {
        let values: [Double] = [1.249, 55.879, 11.0, 44200, 0.1 + 0.2, 1.0 / 3.0,
                                123456.789, -0.001, 3.406, 1e-7]
        for v in values {
            let s = StockFmt.exact(v)
            XCTAssertEqual(Double(s), v, "exact(\(v)) = \(s) 解析回来不相等")
        }
    }

    /// 不用 `String(describing:)` 的理由：它会给出 17 位噪声；
    ///   `exact` 按需增精度，**取第一个能往返的位数**
    func testExactUsesShortestRoundTrippingForm() {
        XCTAssertEqual(StockFmt.exact(0.1 + 0.2).count, 19,
                       "0.30000000000000004 是唯一能往返的写法（不是 0.3）")
        XCTAssertEqual(StockFmt.exact(1.0 / 3.0).count, 18)
        XCTAssertEqual(StockFmt.exact(1.249).count, 5, "干净的 3 位值只给 5 个字符")
    }

    // MARK: - 端到端：真实持仓上的金额

    /// 用生产库里那两条**真的带 3 位成本价**的持仓，验证金额与盈亏对得上
    func testRealHoldingsProduceExactAmountsAndPnl() {
        // 159338 中证A500ETF国泰：成本 1.249 × 44200
        let etfCost = StockFmt.money(1.249 * 44200)
        XCTAssertEqual(etfCost, "55205.8")
        // 若按 2 位成本价算，成本金额会差 44.2 元
        XCTAssertEqual(StockFmt.money(1.25 * 44200), "55250")
        XCTAssertNotEqual(etfCost, StockFmt.money(1.25 * 44200))

        // 600276 恒瑞医药：成本 55.879 × 900
        XCTAssertEqual(StockFmt.money(55.879 * 900), "50291.1")

        // 盈亏 = 现价 × 数量 − 成本 × 数量（同样不许取整）
        let pnl = 56.20 * 900 - 55.879 * 900
        XCTAssertEqual(StockFmt.signedMoney(pnl), "+288.9")
    }

    // MARK: - 价格小数位按标的定档（2026-10-29：基金只显示 2 位的修复）
    //
    /// 用例里的 `1.052 / 3.406 / -0.014` 都是**实测值**：
    /// `159915` 创业板ETF 行情现价 `3.406`、涨跌额 `-0.014`（见 `StockQuotesTests` 的解析用例），
    /// 生产库里的持仓成本 `159338 = 1.249` —— 精度一路都在，只在出口被 `%.2f` 砍掉。

    func testPriceDigitsByInstrumentKind() {
        XCTAssertEqual(StockFmt.priceDigits(code: "600519"), 2, "沪主板股票 2 位")
        XCTAssertEqual(StockFmt.priceDigits(code: "300750"), 2, "创业板股票 2 位")
        XCTAssertEqual(StockFmt.priceDigits(code: "159915"), 3, "深市 ETF 3 位")
        XCTAssertEqual(StockFmt.priceDigits(code: "510300"), 3, "沪市 ETF 3 位")
        XCTAssertEqual(StockFmt.priceDigits(code: "588000"), 3, "科创 ETF（58 段）3 位")
        // 可转债不在 `isFundCode` 口径里（那是债券，价格档位另说）⇒ 保持 2，别顺手扩档
        XCTAssertEqual(StockFmt.priceDigits(code: "110043"), 2)
        XCTAssertEqual(StockFmt.priceDigits(code: "sh159915"), 3, "带市场前缀同样认得出")
    }

    func testPriceNeverLosesTheThirdDecimalForFunds() {
        XCTAssertEqual(StockFmt.price(1.052, code: "159338"), "1.052")
        XCTAssertEqual(StockFmt.price(1.052, code: "600276"), "1.05", "股票仍按 2 位，别一律加位")
        XCTAssertEqual(StockFmt.price(3.406, code: "159915"), "3.406")
        XCTAssertEqual(StockFmt.price(nil, code: "159915"), "—", "无值走破折号，不是 0.000")
    }

    func testSignedPriceKeepsSignAndDigits() {
        XCTAssertEqual(StockFmt.signedPrice(-0.014, code: "159915"), "-0.014")
        XCTAssertEqual(StockFmt.signedPrice(0.02, code: "600519"), "+0.02")
        // 0 显示成 +0.xxx：涨跌额列的"不亏不赚"也要有符号（与 signedMoney 同一取向）
        XCTAssertEqual(StockFmt.signedPrice(0, code: "159915"), "+0.000")
        XCTAssertEqual(StockFmt.signedPrice(nil, code: "159915"), "—")
    }

    func testAlertThresholdEchoKeepsFundDigits() {
        // 阈值回显必须与显示同档：回显成 1.05 再存回去 = 把 1.052 静默改成 1.05
        XCTAssertEqual(AlertInput.format([1.052], digits: StockFmt.priceDigits(code: "159338")), "1.052")
        XCTAssertEqual(AlertInput.format([1.052]), "1.05", "默认档不变（百分比/金额族沿用旧口径）")
    }

    // MARK: - 指标紧凑数值（万 / 亿分档，回归锁防 100_0000 缩放错误）

    func testCompactIndicatorFormattingUsesTenThousandForWan() {
        XCTAssertEqual(StockFmt.compact(5_000_000), "500.00万")
        XCTAssertEqual(StockFmt.compact(50_000), "5.00万")
        XCTAssertEqual(StockFmt.compact(10_000), "1.00万")
        XCTAssertEqual(StockFmt.compact(500_000_000), "5.00亿")
        XCTAssertEqual(StockFmt.compact(-50_000), "-5.00万")
        XCTAssertEqual(StockFmt.compact(-500_000_000), "-5.00亿")
        XCTAssertEqual(StockFmt.compact(123.456), "123.46")
        XCTAssertEqual(StockFmt.compact(9999.0), "9999.00")
        XCTAssertEqual(StockFmt.compact(nil), "—")
        XCTAssertEqual(StockFmt.compact(.nan), "—")
        XCTAssertEqual(StockFmt.compact(.infinity), "—")
    }
}
