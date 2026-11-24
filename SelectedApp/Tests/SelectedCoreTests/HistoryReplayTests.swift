import XCTest
@testable import SelectedCore

/// `HistoryBarsSource` / `HistoryReplay` 的契约测试。
///
/// 本模块的**纯计算部分**全部钉在这里；缓存（`HistoryBarStore`）需要真实 SQLite 文件，
/// 由 `Tools/` 下的一次性驱动覆盖（那里会把 `SELECTED_DATA_DIR` 指到临时目录，
/// **不碰真实库**）。
///
/// 全部输入**人工构造**：解析与重建都是纯算术，期望值可以手算 ——
/// 比"跑一遍网络看看对不对"可靠得多，而且不会因为行情变动而随机红。
final class HistoryReplayTests: XCTestCase {

    // MARK: - 构造工具

    private func hbar(_ day: String, close: Double, volume: Double = 1000,
                      open: Double? = nil, high: Double? = nil, low: Double? = nil,
                      amount: Double = 0, turnover: Double = 0,
                      amplitude: Double = 0, changePct: Double = 0,
                      code: String = "600519") -> HistoryBar {
        HistoryBar(code: code, day: day,
                   open: open ?? close, close: close,
                   high: high ?? close, low: low ?? close,
                   volume: volume, amount: amount,
                   amplitude: amplitude, changePct: changePct, turnover: turnover)
    }

    /// 一段「前 5 根 + 目标根」的序列：`closes` 的最后一项是目标日
    private func series(_ days: [String], _ closes: [Double],
                        volumes: [Double]? = nil) -> [HistoryBar] {
        days.enumerated().map { i, d in
            hbar(d, close: closes[i], volume: volumes?[i] ?? 1000)
        }
    }

    private let days6 = ["2026-01-05", "2026-01-06", "2026-01-07",
                         "2026-01-08", "2026-01-09", "2026-01-12"]

    // MARK: - 解析：东财响应体

    /// 实测样本（真实响应体的字段顺序），逐字段核对下标没串位
    func testParseRealEastmoneyShape() {
        let json = #"{"rc":0,"rt":17,"svr":183124922,"lt":1,"full":0,"dlmkts":"","dsc":"0","data":{"code":"600519","market":1,"name":"贵州茅台","decimal":2,"dktotal":6010,"preKPrice":1827.06,"klines":["2022-01-04,1832.06,1828.29,1846.01,1791.06,33843,6913653248.00,3.01,0.07,1.23,0.27"]}}"#
        let bars = HistoryBarsSource.parse(json, code: "600519")
        XCTAssertEqual(bars.count, 1)
        guard let b = bars.first else { return }
        XCTAssertEqual(b.day, "2022-01-04")
        XCTAssertEqual(b.open, 1832.06)
        XCTAssertEqual(b.close, 1828.29)
        XCTAssertEqual(b.high, 1846.01)
        XCTAssertEqual(b.low, 1791.06)
        XCTAssertEqual(b.volume, 33843)          // 手
        XCTAssertEqual(b.amount, 6913653248.00)  // 元
        XCTAssertEqual(b.amplitude, 3.01)
        XCTAssertEqual(b.changePct, 0.07)
        XCTAssertEqual(b.turnover, 0.27)
    }

    /// `data` 为 `null`（代码非法 / 退市 / 无权限）→ 空，**不是崩也不是 0 根假数据**
    func testParseNullDataYieldsEmpty() {
        XCTAssertTrue(HistoryBarsSource.parse(#"{"rc":0,"data":null}"#, code: "999999").isEmpty)
    }

    func testParseMissingKlinesYieldsEmpty() {
        XCTAssertTrue(HistoryBarsSource.parse(#"{"rc":0,"data":{"code":"600519"}}"#,
                                              code: "600519").isEmpty)
        XCTAssertTrue(HistoryBarsSource.parse("not json at all", code: "600519").isEmpty)
        XCTAssertTrue(HistoryBarsSource.parse("", code: "600519").isEmpty)
    }

    /// **全有或全无**：字段数不足 → 整体空，不做"能解析几行算几行"
    func testParseShortRowYieldsEmptyNotPartial() {
        let json = #"{"data":{"klines":["2022-01-04,1832.06,1828.29,1846.01,1791.06,33843,6913653248.00,3.01,0.07,1.23,0.27","2022-01-05,1,2,3"]}}"#
        XCTAssertTrue(HistoryBarsSource.parse(json, code: "600519").isEmpty)
    }

    func testParseNonNumericRowYieldsEmpty() {
        let json = #"{"data":{"klines":["2022-01-04,-,1828.29,1846.01,1791.06,33843,6913653248.00,3.01,0.07,1.23,0.27"]}}"#
        XCTAssertTrue(HistoryBarsSource.parse(json, code: "600519").isEmpty)
    }

    /// 东财本来就是升序，但下游「前一根 close 当 pre_close」**完全依赖顺序**，
    /// 不能靠数据源的好意 → 解析后显式排序
    func testParseSortsByDayAscending() {
        let json = #"{"data":{"klines":["2022-01-06,2,2,2,2,1,1,0,0,0,0","2022-01-04,1,1,1,1,1,1,0,0,0,0","2022-01-05,3,3,3,3,1,1,0,0,0,0"]}}"#
        XCTAssertEqual(HistoryBarsSource.parse(json, code: "600519").map(\.day),
                       ["2022-01-04", "2022-01-05", "2022-01-06"])
    }

    /// `code` 取**调用方给的**，不是响应体里的 —— 指数响应的 `data.code` 是 `000001`（去掉了 `sh`）
    func testParseStampsCallerCodeNotResponseCode() {
        let json = #"{"data":{"code":"000001","klines":["2022-01-04,1,1,1,1,1,1,0,0,0,0"]}}"#
        XCTAssertEqual(HistoryBarsSource.parse(json, code: "sh000001").first?.code, "sh000001")
    }

    // MARK: - secid / url

    /// 与 `DataSources.marketOf` 同口径：6 开头 → 1（沪），其余 → 0（深 / 北）
    func testSecidMatchesMarketOfCaliber() {
        XCTAssertEqual(HistoryBarsSource.secid("600519"), "1.600519")
        XCTAssertEqual(HistoryBarsSource.secid("000001"), "0.000001")
        XCTAssertEqual(HistoryBarsSource.secid("300750"), "0.300750")
        // 北交所：实测 0.920427 可用（不能被"8/4 开头"之类的猜测改掉）
        XCTAssertEqual(HistoryBarsSource.secid("920427"), "0.920427")
    }

    /// 东财要 `yyyyMMdd`；`adjust` 决定 `fqt`（个股 1 / 指数 0）
    func testURLStripsDashesAndSetsAdjust() {
        let u = HistoryBarsSource.url(secid: "1.600519",
                                      beg: "2022-01-04", end: "2026-09-22", adjust: true)
        XCTAssertTrue(u.contains("secid=1.600519"))
        XCTAssertTrue(u.contains("beg=20220104"))
        XCTAssertTrue(u.contains("end=20260922"))
        XCTAssertTrue(u.contains("fqt=1"))
        XCTAssertTrue(u.contains("klt=101"))
        XCTAssertTrue(u.hasPrefix("https://push2his.eastmoney.com/api/qt/stock/kline/get"))
        let idx = HistoryBarsSource.url(secid: "1.000001",
                                        beg: "2022-01-01", end: "2022-01-02", adjust: false)
        XCTAssertTrue(idx.contains("fqt=0"), "指数必须不复权")
    }

    /// `HistoryBar` 是 `KLineBar` 的**超集** —— 回放模式就是靠这个把缓存喂给引擎的
    func testKlineBarViewCarriesOHLCV() {
        let b = hbar("2026-01-05", close: 10, volume: 123, open: 9, high: 11, low: 8)
        let k = b.klineBar
        XCTAssertEqual(k.day, "2026-01-05")
        XCTAssertEqual(k.open, 9)
        XCTAssertEqual(k.high, 11)
        XCTAssertEqual(k.low, 8)
        XCTAssertEqual(k.close, 10)
        XCTAssertEqual(k.volume, 123)
    }

    func testQuoteTimeIsReplayDayClose() {
        XCTAssertEqual(HistoryReplay.quoteTime("2026-01-05"), "20260105150000")
    }

    // MARK: - 重建：正常路径

    func testQuoteRebuildsEngineCaliberFields() {
        // 前 5 根各 1000 手 / 收 10；目标根 2000 手 / 收 11 / 高 11.5 / 低 10.5
        var bars = series(days6, [10, 10, 10, 10, 10, 11])
        bars[5] = hbar("2026-01-12", close: 11, volume: 2000,
                       open: 10.2, high: 11.5, low: 10.5,
                       amount: 500_000_000, turnover: 1.5)
        let q = HistoryReplay.quote(code: "600519", name: "贵州茅台",
                                    day: "2026-01-12", bars: bars)
        guard let q = q else { return XCTFail("应当重建成功") }
        XCTAssertEqual(q["code"] as? String, "600519")
        XCTAssertEqual(q["name"] as? String, "贵州茅台")
        XCTAssertEqual(q["price"] as? Double, 11)
        XCTAssertEqual(q["pre_close"] as? Double, 10)          // 前一根 close
        XCTAssertEqual(q["open"] as? Double, 10.2)
        XCTAssertEqual(q["high"] as? Double, 11.5)
        XCTAssertEqual(q["low"] as? Double, 10.5)
        XCTAssertEqual(q["volume"] as? Double, 2000)
        XCTAssertEqual(q["change_pct"] as? Double, 10)          // (11-10)/10*100
        XCTAssertEqual(q["amplitude"] as? Double, 10)           // (11.5-10.5)/10*100
        XCTAssertEqual(q["volume_ratio"] as? Double, 2)         // 2000 / mean(1000×5)
        XCTAssertEqual(q["turnover"] as? Double, 1.5)
        XCTAssertEqual(q["quote_time"] as? String, "20260112150000")
    }

    /// **单位换算**：东财成交额是**元**，引擎口径是**万元**（腾讯字段 37）。
    /// 漏了这一步不会报错，只会让落库的成交额差 10000 倍。
    func testQuoteConvertsAmountFromYuanToWanYuan() {
        var bars = series(days6, [10, 10, 10, 10, 10, 10])
        bars[5] = hbar("2026-01-12", close: 10, volume: 2000, amount: 500_000_000)
        let q = HistoryReplay.quote(code: "600519", name: "", day: "2026-01-12", bars: bars)
        XCTAssertEqual(q?["amount"] as? Double, 50000)          // 5 亿元 = 5 万万元
    }

    /// 均价是**推导值**：成交额(元) ÷ 成交量(手) ÷ 100 = 元/股
    func testQuoteDerivesAvgPriceFromAmountAndVolume() {
        var bars = series(days6, [10, 10, 10, 10, 10, 10])
        bars[5] = hbar("2026-01-12", close: 10, volume: 2000, amount: 500_000_000)
        let q = HistoryReplay.quote(code: "600519", name: "", day: "2026-01-12", bars: bars)
        XCTAssertEqual(q?["avg_price"] as? Double, 2500)        // 500e6 / (2000×100)
    }

    /// 成交量 0 → 均价 0，**不是**除零得 inf/NaN（inf 落库后排序会乱）
    func testQuoteZeroVolumeGivesZeroAvgPriceNotInf() {
        var bars = series(days6, [10, 10, 10, 10, 10, 10])
        bars[5] = hbar("2026-01-12", close: 10, volume: 0, amount: 500_000_000)
        let q = HistoryReplay.quote(code: "600519", name: "", day: "2026-01-12", bars: bars)
        XCTAssertEqual(q?["avg_price"] as? Double, 0)
        XCTAssertEqual(q?["volume_ratio"] as? Double, 0)        // 均量为 0 → 0，不是 inf
    }

    /// 涨跌幅走 `PyMath.round`（printf 半偶），**不是** Swift 的 `rounded()`
    /// （半远离零）。构造一个恰好落在 `.xx5` 上的值，两种口径会给出不同答案。
    func testQuoteUsesPyMathRoundNotSwiftRounding() {
        var bars = series(days6, [800, 800, 800, 800, 800, 817])
        bars[5] = hbar("2026-01-12", close: 817, volume: 1000)
        let q = HistoryReplay.quote(code: "600519", name: "", day: "2026-01-12", bars: bars)
        // (817-800)/800*100 = 2.125
        XCTAssertEqual(q?["change_pct"] as? Double, PyMath.round(2.125, 2))
        XCTAssertEqual(q?["change_pct"] as? Double, 2.12)
        XCTAssertNotEqual((2.125 * 100).rounded() / 100, 2.12, "Swift 的 rounded 会得 2.13")
    }

    /// 量比用**恰好过去 5 个**交易日 —— 更早的根不参与。
    ///
    /// 这里必须用 **7 根**（1 根更早 + 5 根前史 + 目标根）：若只用 6 根，
    /// 那个"更早"的根**本来就在窗口内**，断言恒真 —— 测不出任何东西。
    func testVolumeRatioUsesExactlyPriorFiveBars() {
        let days7 = ["2026-01-02"] + days6
        var bars = series(days7, [10, 10, 10, 10, 10, 10, 10],
                          volumes: [100, 1000, 1000, 1000, 1000, 1000, 1000])
        bars[6] = hbar("2026-01-12", close: 10, volume: 1000)
        let q = HistoryReplay.quote(code: "600519", name: "", day: "2026-01-12", bars: bars)
        XCTAssertEqual(q?["volume_ratio"] as? Double, 1)        // 1000 / mean(bars[1...5])
        // 反证：把那个更早的根算进去会得到不同的值（1.22），所以这条断言**真的**在测窗口大小
        XCTAssertNotEqual(q?["volume_ratio"] as? Double, PyMath.round(1000 / (4100.0 / 5), 2))
    }

    /// 不足 5 根前史（新股）→ 用**已有的**根算，不编造
    func testVolumeRatioFallsBackToAvailableHistory() {
        let bars = [hbar("2026-01-05", close: 10, volume: 1000),
                    hbar("2026-01-06", close: 10, volume: 3000)]
        let q = HistoryReplay.quote(code: "600519", name: "", day: "2026-01-06", bars: bars)
        XCTAssertEqual(q?["volume_ratio"] as? Double, 3)        // 3000 / 1000
    }

    // MARK: - 重建：必须**剔除**的情形

    /// 缺目标日那根 → nil（该票当轮剔除，不是"填 0 继续"）
    func testQuoteNilWhenDayMissing() {
        let bars = series(days6, [10, 10, 10, 10, 10, 10])
        XCTAssertNil(HistoryReplay.quote(code: "600519", name: "", day: "2026-01-13", bars: bars))
    }

    /// 目标日是序列首根 → 拿不到前收 → nil
    func testQuoteNilWhenDayIsFirstBar() {
        let bars = [hbar("2026-01-05", close: 10)]
        XCTAssertNil(HistoryReplay.quote(code: "600519", name: "", day: "2026-01-05", bars: bars))
    }

    /// 前收非正 → nil。若当成 0 继续，`change_pct` 会变成一个巨大的假值。
    func testQuoteNilWhenPreCloseNonPositive() {
        let bars = [hbar("2026-01-05", close: 0), hbar("2026-01-06", close: 10)]
        XCTAssertNil(HistoryReplay.quote(code: "600519", name: "", day: "2026-01-06", bars: bars))
    }

    func testQuoteNilOnDegenerateInput() {
        let bars = series(days6, [10, 10, 10, 10, 10, 10])
        XCTAssertNil(HistoryReplay.quote(code: "", name: "", day: "2026-01-12", bars: bars))
        XCTAssertNil(HistoryReplay.quote(code: "600519", name: "", day: "", bars: bars))
        XCTAssertNil(HistoryReplay.quote(code: "600519", name: "", day: "2026-01-12", bars: []))
    }

    // MARK: - 批量重建

    /// 批量重建：缺当日的票被**跳过**（不产出半截行情），有当日的票都在
    func testQuotesSkipsCodesWithoutTheDay() {
        let byCode: [String: [HistoryBar]] = [
            "600519": series(days6, [10, 10, 10, 10, 10, 11]),
            "300750": [hbar("2026-01-05", close: 10), hbar("2026-01-06", close: 10)],
        ]
        let qs = HistoryReplay.quotes(day: "2026-01-12", byCode: byCode, names: ["600519": "贵州茅台"])
        XCTAssertEqual(Set(qs.keys), ["600519"])
        XCTAssertEqual(qs["600519"]?["name"] as? String, "贵州茅台")
    }

    /// 名称缺省为空串（当前清单里查不到的票）—— 不能让整个重建失败
    func testQuotesToleratesMissingName() {
        let qs = HistoryReplay.quotes(day: "2026-01-12",
                                      byCode: ["600519": series(days6, [10, 10, 10, 10, 10, 11])],
                                      names: [:])
        XCTAssertEqual(qs["600519"]?["name"] as? String, "")
    }

    // MARK: - 静态护栏

    /// `warmupBars` 是「1 根前收 + 5 根量比」的**下界**，取窗口时靠它。
    /// 改小会让量比静默退化（数字偏低但看起来正常）。
    func testWarmupBarsCoversPreCloseAndVolumeRatio() {
        XCTAssertEqual(HistoryReplay.warmupBars, 6)
        let bars = series(days6, [10, 10, 10, 10, 10, 11])
        XCTAssertNotNil(HistoryReplay.quote(code: "600519", name: "", day: "2026-01-12", bars: bars))
        // 只给 warmupBars - 1 根时，目标日就成了首根 → 必须失败
        XCTAssertNil(HistoryReplay.quote(code: "600519", name: "",
                                         day: days6[0], bars: Array(bars.prefix(1))))
    }

    /// 缓存表的列名是**契约**（`bar(_:)` 与 DDL 必须逐字对上，错了只会静默读到 0）
    func testCacheSchemaHasEveryColumnTheReaderExpects() {
        let sql = HistoryBarStore.createSQL
        for col in ["code", "day", "open", "close", "high", "low", "volume",
                    "amount", "amplitude", "change_pct", "turnover"] {
            XCTAssertTrue(sql.contains(col), "daily_bars 缺列 \(col)")
        }
        // `req_beg` / `req_end`（**请求窗口**）不是 `first_day` / `last_day`（数据实际跨度）：
        //   存实际跨度会让「请求 2020 起、东财只给到 2022 起」的票**永远判为未覆盖**
        //   → 每次启动重下全市场，而且不报错。见 `Coverage` 的注释。
        for col in ["code", "req_beg", "req_end", "bars", "fetched_at"] {
            XCTAssertTrue(sql.contains(col), "bar_coverage 缺列 \(col)")
        }
        XCTAssertFalse(sql.contains("first_day"), "bar_coverage 不该再有 first_day（已改名为 req_beg）")
        XCTAssertTrue(sql.contains("PRIMARY KEY (code, day)"))
        // 重建"某一天的全市场"是**按日**查的，必须有 day 索引
        XCTAssertTrue(sql.contains("idx_daily_bars_day ON daily_bars(day)"))
        // 指数单独一张表（混进 daily_bars 会污染硬过滤的统计口径）
        XCTAssertTrue(sql.contains("CREATE TABLE IF NOT EXISTS index_bars"))
        XCTAssertEqual(HistoryBarStore.fileName, "history.sqlite3")
        XCTAssertEqual(HistoryBarStore.indexTable, "index_bars")
    }

    /// 断点续传的判据：**完全覆盖请求窗口**才算覆盖
    func testCoverageRequiresFullSpan() {
        let c = HistoryBarStore.Coverage(reqBeg: "2020-01-01", reqEnd: "2026-09-22", bars: 1145)
        XCTAssertTrue(c.covers(beg: "2020-01-01", end: "2026-09-22"))
        XCTAssertTrue(c.covers(beg: "2023-01-01", end: "2024-01-01"))
        XCTAssertFalse(c.covers(beg: "2019-12-01", end: "2026-09-22"), "起点更早 → 没覆盖")
        XCTAssertFalse(c.covers(beg: "2020-01-01", end: "2026-10-01"), "终点更晚 → 没覆盖")
        XCTAssertFalse(HistoryBarStore.Coverage(reqBeg: "", reqEnd: "", bars: 0)
            .covers(beg: "2022-01-01", end: "2022-01-02"), "空覆盖不能算覆盖")
        // 只有一半（req_end 为空）也不算 —— 半条记录当成"覆盖过"就是静默缺数据
        XCTAssertFalse(HistoryBarStore.Coverage(reqBeg: "2020-01-01", reqEnd: "", bars: 5)
            .covers(beg: "2022-01-01", end: "2022-01-02"))
    }
}
