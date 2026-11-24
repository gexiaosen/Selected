import XCTest
@testable import SelectedCore

/// 个股基本面。
///
/// 这个文件的重点是**三件容易搞错的事**：
/// · **`"-"` 哨兵 → `nil`，不是 `0`**（"负债率 0%" = 无负债，与"没数据"完全不同）
/// · **长小数要正确舍入** —— `JSONSerialization` 把 17 位小数解析成 `NSDecimalNumber`，
///   而它的 `doubleValue` **不是正确舍入**（实测差 1 ULP）
/// · **六组只做五组** —— 「股本股东」的字段实测校验不过，宁缺勿错
final class FundamentalTests: XCTestCase {

    /// 真实响应片段（`600000` 浦发银行，价 `9.04`；第二行是**已退市票**，
    /// 所有字段都是 `"-"`）
    private let realSample = #"""
    {"rc":0,"rt":6,"svr":181669473,"lt":1,"full":1,"data":{"total":5560,"diff":[
      {"f12":"600000","f14":"浦发银行","f9":4.86,"f23":0.4,"f37":3.96,
       "f40":93777000000.0,"f41":3.5534844687,"f45":30951000000.0,"f46":4.082456199348,
       "f57":91.9206504728,"f112":0.929296531,"f113":22.634180028,"f114":6.02,"f115":5.88},
      {"f12":"600001","f14":"邯郸钢铁","f9":"-","f23":"-","f37":"-","f40":"-","f41":"-",
       "f45":"-","f46":"-","f57":"-","f112":"-","f113":"-","f114":"-","f115":"-"},
      {"f12":"12345","f14":"代码太短","f9":1.0,"f23":1.0,"f37":1.0,"f40":1,"f41":1,
       "f45":1,"f46":1,"f57":1,"f112":1,"f113":1,"f114":1,"f115":1},
      {"f12":"600519","f14":"贵州茅台","f9":20.0,"f23":8.0,"f37":30.0,"f40":1,"f41":2,
       "f45":3,"f46":4,"f57":20,"f112":60,"f113":250,"f114":21,"f115":19}
    ]}}
    """#

    // MARK: - 解析

    func testParseRealResponse() {
        let (rows, total) = FundamentalSource.parse(realSample)
        XCTAssertEqual(total, 5560, "源报总数照读（完整性检查要用）")
        XCTAssertEqual(rows.map(\.code), ["600000", "600001", "600519"], "代码非法的行被跳过")
        let p = try? XCTUnwrap(rows.first)
        XCTAssertEqual(p?.peDynamic, 4.86)
        XCTAssertEqual(p?.peStatic, 6.02)
        XCTAssertEqual(p?.peTtm, 5.88)
        XCTAssertEqual(p?.pb, 0.4)
        XCTAssertEqual(p?.eps, 0.929296531)
        XCTAssertEqual(p?.bvps, 22.634180028)
        XCTAssertEqual(p?.roe, 3.96)
        XCTAssertEqual(p?.revenue, 93777000000.0)
        XCTAssertEqual(p?.revenueYoy, 3.5534844687)
        XCTAssertEqual(p?.netProfit, 30951000000.0)
        XCTAssertEqual(p?.netProfitYoy, 4.082456199348)
        XCTAssertEqual(p?.debtRatio, 91.9206504728)
    }

    /// **`"-"` 是哨兵值 → `nil`**。
    /// 折成 `0` 会让界面显示"资产负债率 0%"（= 无负债），
    /// 而真相是"**这只票没有数据**"（这里是已退市的票）。
    func testDashSentinelBecomesNilNotZero() {
        let (rows, _) = FundamentalSource.parse(realSample)
        guard let dead = rows.first(where: { $0.code == "600001" }) else {
            return XCTFail("退市票那行应保留在结果里（它只是**没数据**，不是非法行）")
        }
        XCTAssertNil(dead.peDynamic)
        XCTAssertNil(dead.debtRatio)
        XCTAssertNil(dead.roe)
        XCTAssertNotEqual(dead.debtRatio, 0, "⚠ 绝不能折成 0")
    }

    /// 字段**缺失**（不是 `"-"`，是根本没这个键）→ 也是 `nil`
    func testMissingFieldBecomesNil() {
        let json = #"{"data":{"total":1,"diff":[{"f12":"600000","f14":"x","f9":5.0}]}}"#
        let (rows, _) = FundamentalSource.parse(json)
        XCTAssertEqual(rows.first?.peDynamic, 5.0)
        XCTAssertNil(rows.first?.pb, "没给的字段是 nil")
        XCTAssertNil(rows.first?.debtRatio)
    }

    /// **长小数必须正确舍入**。
    ///
    /// `JSONSerialization` 把 17 位文本解析成 `NSDecimalNumber`，而它的 `doubleValue`
    /// **不是正确舍入** —— 实测：`NSDecimalNumber(string: "0.070000000000000007")`
    /// 的 `.doubleValue` 得到 `0.07000000000000003`（**差 1 ULP**）。
    /// 实现走 `stringValue` → `Double(_:)`（Swift 的字符串转 Double **是**正确舍入的）。
    ///
    /// 本用例是**判别性**的：若实现退回 `n.doubleValue`，它会红。
    func testLongDecimalIsCorrectlyRounded() {
        let json = #"{"data":{"total":1,"diff":[{"f12":"600000","f14":"x","f23":0.070000000000000007}]}}"#
        let (rows, _) = FundamentalSource.parse(json)
        XCTAssertEqual(rows.first?.pb, 0.07, "长小数差 1 ULP 也要测出来")
    }

    /// **反向的坑：普通 `NSNumber` 不能走 `stringValue`**（会丢精度）。
    ///
    /// 实测（`swiftc` 直接验 `JSONSerialization` 的输出）：
    /// `1.6992965936660767` 被解析成 **`__NSCFNumber`**（不是 `NSDecimalNumber`），
    /// 它的 `doubleValue` 恰好就是正确值，而 `stringValue` 会**重新格式化成
    /// `1.699296593666077`**（~15 位有效数字）→ 走字符串反而**引入**误差。
    ///
    /// 所以实现里 `NSDecimalNumber` 分支**必须先判且只对那一支走字符串**。
    /// 本用例是**判别性**的：若有人"统一改成走 stringValue"，它会红。
    func testPlainNSNumberKeepsFullPrecision() {
        let json = #"{"data":{"total":1,"diff":[{"f12":"600000","f14":"x","f23":1.6992965936660767}]}}"#
        let (rows, _) = FundamentalSource.parse(json)
        XCTAssertEqual(rows.first?.pb, 1.6992965936660767,
                       "普通 NSNumber 要走 doubleValue（走 stringValue 会丢精度）")
    }

    /// 字典形态的 `diff`（不带 `np` 时源返回字典，键是序号）也要认
    func testParseAcceptsDictionaryForm() {
        let json = #"""
        {"data":{"total":2,"diff":{"1":{"f12":"600519","f14":"贵州茅台","f9":20.0},
                                   "0":{"f12":"600000","f14":"浦发银行","f9":4.86}}}}
        """#
        let (rows, _) = FundamentalSource.parse(json)
        XCTAssertEqual(rows.map(\.code), ["600000", "600519"], "字典形态按序号升序还原")
    }

    func testParseRejectsMalformed() {
        XCTAssertTrue(FundamentalSource.parse("").rows.isEmpty)
        XCTAssertTrue(FundamentalSource.parse("not json").rows.isEmpty)
        XCTAssertTrue(FundamentalSource.parse(#"{"data":{}}"#).rows.isEmpty)
    }

    // MARK: - URL 与常量

    func testURLAndConstants() {
        let u = FundamentalSource.url(page: 7)
        for token in ["/api/qt/clist/get", "pn=7", "pz=100", "np=1", "fltt=2", "invt=2",
                      "f12,f14,f9,f23,f37,f40,f41,f45,f46,f57,f112,f113,f114,f115",
                      "m:0+t:6", "m:1+t:23"] {
            XCTAssertTrue(u.contains(token), "URL 缺 \(token)：\(u)")
        }
        XCTAssertEqual(FundamentalSource.pageSize, 100, "服务端强制上限")
        XCTAssertGreaterThanOrEqual(FundamentalSource.maxPages, 56)
        // 票池是"全市场"的定义，四个市场段一个都不能少（少了就有一批票永远没基本面）
        XCTAssertEqual(FundamentalSource.fs, "m:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23")
    }

    /// **不抓未校验的字段** —— 清单六组里的「股本股东」就是因此做不了
    func testOnlyVerifiedFieldsAreRequested() {
        let f = FundamentalSource.fields
        for bad in ["f48", "f61", "f129", "f130", "f131", "f132", "f133", "f134", "f173"] {
            XCTAssertFalse(f.contains(bad), "\(bad) 未经算术校验，不该抓：\(f)")
        }
    }

    func testMinStocksBoundary() {
        // 下界 = 全市场（约 5560 只）的**合理缩水线**，不是随手取的整数：
        // 太松拦不住"只拿到三分之一"，太紧则市场略缩水就永久刷不进。
        XCTAssertEqual(Fundamental.minStocks, 4000)
        XCTAssertGreaterThan(Fundamental.minStocks, 5560 / 3, "太松 → 拦不住'只拿到三分之一'")
        XCTAssertLessThan(Fundamental.minStocks, 5560, "太紧 → 全市场略缩水就永久刷不进")
    }

    // MARK: - 分组口径

    private func sample() -> Fundamental.Item {
        Fundamental.Item(code: "600000", name: "浦发银行",
                         peDynamic: 4.86, peStatic: 6.02, peTtm: 5.88, pb: 0.4,
                         eps: 0.929296531, bvps: 22.634180028, roe: 3.96,
                         revenue: 93777000000.0, netProfit: 30951000000.0,
                         revenueYoy: 3.5534844687, netProfitYoy: 4.082456199348,
                         debtRatio: 91.9206504728)
    }

    /// 清单六组里做了**五组**（第六组「股本股东」字段校验不过）
    func testGroupsCoverFiveOfSix() {
        let g = sample().groups
        XCTAssertEqual(g.count, 5, "六组里做了五组")
        XCTAssertEqual(g.map(\.title),
                       ["估值指标", "每股指标", "盈利能力", "成长能力", "资本结构与偿债能力"])
        XCTAssertEqual(g.map(\.id), g.map(\.title), "ForEach 的 id 要稳定")
        XCTAssertEqual(g.map { $0.metrics.count }, [4, 2, 3, 2, 1])
    }

    /// 量纲要标对（界面按量纲格式化：倍 / % / 元每股 / 元）
    func testGroupUnitsAreTagged() {
        let g = sample().groups
        XCTAssertTrue(g[0].metrics.allSatisfy { $0.unit == .multiple }, "估值组都是倍数")
        XCTAssertTrue(g[1].metrics.allSatisfy { $0.unit == .perShare }, "每股指标组都是元/股")
        XCTAssertEqual(g[2].metrics[0].unit, .percent, "ROE 是百分数")
        XCTAssertEqual(g[2].metrics[1].unit, .money, "营收是金额")
        XCTAssertTrue(g[3].metrics.allSatisfy { $0.unit == .percent }, "成长组都是百分数")
        XCTAssertEqual(g[4].metrics[0].unit, .percent, "资产负债率是百分数")
    }

    /// `nil` **不能**被折成 0（"没数据"与"0 倍 PE"是两回事）
    func testNilValuesSurviveGrouping() {
        let empty = Fundamental.Item(code: "600000", name: "x",
                                     peDynamic: nil, peStatic: nil, peTtm: nil, pb: nil,
                                     eps: nil, bvps: nil, roe: nil,
                                     revenue: nil, netProfit: nil,
                                     revenueYoy: nil, netProfitYoy: nil, debtRatio: nil)
        for group in empty.groups {
            for m in group.metrics {
                XCTAssertNil(m.value, "\(group.title)/\(m.label) 应为 nil（不是 0）")
            }
        }
    }

    // MARK: - 报告文案

    func testReportSummaryNamesBothOutcomes() {
        var ok = Fundamental.Report()
        ok.stocks = 5480
        ok.withData = 5200
        XCTAssertTrue(ok.summary.contains("5480"))
        XCTAssertTrue(ok.summary.contains("5200"), "「落库了几只」与「几只有数据」要分开报：\(ok.summary)")

        var bad = Fundamental.Report()
        bad.rejected = "只拿到 120 只 < 下界 4000"
        XCTAssertTrue(bad.summary.contains("保留旧数据"), "必须写清旧数据还在：\(bad.summary)")
    }

    // MARK: - 建表契约

    func testStoreSchemaMatchesTheReader() {
        let sql = FundamentalStore.createSQL
        for col in ["code", "name", "pe_dynamic", "pe_static", "pe_ttm", "pb", "eps", "bvps",
                    "roe", "revenue", "net_profit", "revenue_yoy", "net_profit_yoy",
                    "debt_ratio", "fetched_at"] {
            XCTAssertTrue(sql.contains(col), "stock_fundamentals 缺列 \(col)")
        }
        XCTAssertTrue(sql.contains("PRIMARY KEY"), "一只票一行")
    }

    /// 数值列**一律不给 `DEFAULT`** —— `NULL` 才是"源没给"的正确表示。
    /// 给了 `DEFAULT 0` 会让界面显示"资产负债率 0%"（= 无负债），与"没数据"完全不同。
    /// （这与 `reviews.scan_mode` 的 `DEFAULT 'live'` **恰好相反** —— 那里 DEFAULT 是必须的。）
    func testNumericColumnsHaveNoDefault() {
        let lines = FundamentalStore.createSQL
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for numeric in ["pe_dynamic", "pb", "roe", "revenue", "debt_ratio"] {
            let line = lines.first { $0.hasPrefix(numeric) } ?? ""
            XCTAssertFalse(line.isEmpty, "找不到列 \(numeric)")
            XCTAssertFalse(line.uppercased().contains("DEFAULT"),
                           "\(numeric) 不该有 DEFAULT：\(line)")
        }
    }

    /// **不建二级索引**：本表只按主键 `code` 查
    /// （对比：需要按某列聚合读回一批代码的那类表才配索引，本表只按 code 点查）。
    /// 少一个索引 = 少一处要登记的东西。
    func testNoSecondaryIndex() {
        XCTAssertFalse(FundamentalStore.createSQL.uppercased().contains("CREATE INDEX"))
    }

    /// REAL 列 → `Double?`：`NULL` 保持 `nil`
    func testStoreNumKeepsNullAsNil() {
        XCTAssertNil(FundamentalStore.num(nil))
        XCTAssertNil(FundamentalStore.num(NSNull()))
        XCTAssertEqual(FundamentalStore.num(4.86), 4.86)
        XCTAssertEqual(FundamentalStore.num(5), 5.0)
    }
}
