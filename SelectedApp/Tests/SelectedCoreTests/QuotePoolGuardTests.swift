import XCTest
@testable import SelectedCore

/// 接口池的**源码级护栏**（`swift test` 形态，不占 shell 护栏条数）。
///
/// 钉住五件容易"顺手回退"的事：
/// ① 界面层不得直连任何 provider / 盘口源 —— 否则"选哪家"又散回调用点，池形同虚设；
/// ② `StockQuotes` 不得再长出 `fetch*` 取数入口 —— 直连一家会在它挂时整页没价；
/// ③ 关键轮询点必须真的走 `QuoteAPI`（只留门面没人用 = 空转）；
/// ④ 五档 / 分笔在门面与账本上都得真的接上（数据层写了但没人调 = 白写）；
/// ⑤ 官方交易日历必须排在"靠行情日期猜"之前（顺序反了节假日照旧误判）。
final class QuotePoolGuardTests: XCTestCase {

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: packageRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    private func swiftFiles(in relative: String) -> [String] {
        let root = packageRoot.appendingPathComponent(relative)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [String] = []
        for case let url as URL in e where url.pathExtension == "swift" {
            if let s = try? String(contentsOf: url, encoding: .utf8) { out.append(s) }
        }
        return out
    }

    func testUILayerNeverInstantiatesProviders() {
        let appSources = swiftFiles(in: "Sources/SelectedApp")
        XCTAssertFalse(appSources.isEmpty, "没扫到 App 源码（路径漂了 → 护栏会空转）")
        // `QuoteBookSource.` 同一条纪律：五档/分笔也必须走 `QuoteAPI` 门面，
        // 否则"页码试探 + 缓存"这套成本约束会被调用点绕开。
        let names = ["TencentQuoteProvider(", "EastmoneyQuoteProvider(", "SinaQuoteProvider(",
                     "QuoteBookSource."]
        for s in appSources {
            for n in names {
                XCTAssertFalse(s.contains(n), "界面层直连了 \(n) —— 必须走 QuoteAPI")
            }
        }
    }

    /// 正对照：门面的盘口/分笔两条必须真的接在源上（只留门面没人用 = 空转）。
    func testDepthAndTicksAreRoutedThroughFacade() throws {
        let api = try source("Sources/SelectedCore/QuoteAPI.swift")
        XCTAssertTrue(api.contains("QuoteBookSource.depth"), "门面没接五档 —— 界面就取不到")
        XCTAssertTrue(api.contains("QuoteBookSource.latestTicks"), "门面没接分笔")
        let book = try source("Sources/SelectedCore/QuoteDepth.swift")
        XCTAssertTrue(book.contains("DataSourceRegistry.timedAsync(.depth)"),
                      "五档必须进健康度账本，否则单源挂了没人知道")
        XCTAssertTrue(book.contains("DataSourceRegistry.report(.ticks"),
                      "分笔必须进健康度账本")
        XCTAssertTrue(book.contains("ticks_no_page_index"),
                      "取不到页数信息必须留痕：退回第 0 页 = 把开盘那 70 笔当\"最新成交\"，界面上看不出破绽")
    }

    /// 正对照：官方交易日历必须真的排在"猜"之前（接了不用 = 节假日照旧误判）。
    func testOfficialCalendarPrecedesIndexGuess() throws {
        let ds = try source("Sources/SelectedCore/DataSources.swift")
        guard let official = ds.range(of: "TradingCalendarSource.verdict(for: d)"),
              let guess = ds.range(of: "return .unknown(reason: \"工作日(默认)\")") else {
            return XCTFail("官方日历判定或旧兜底判据被删 —— 两者都必须在")
        }
        XCTAssertLessThan(official.lowerBound, guess.lowerBound,
                          "顺序回退了：又变成先猜行情日期、后问官方日历")
    }

    func testPoolIsTheOnlyPlaceThatBuildsProviders() throws {
        let pool = try source("Sources/SelectedCore/QuotePool.swift")
        XCTAssertTrue(pool.contains("TencentQuoteProvider()"), "正对照：池里必须真的装配腾讯源")
        XCTAssertTrue(pool.contains("EastmoneyQuoteProvider()"), "正对照：池里必须真的装配东财源")
        XCTAssertTrue(pool.contains("SinaQuoteProvider()"), "正对照：池里必须真的装配新浪源")
    }

    func testLegacyDirectFetchEntryPointsAreGone() throws {
        let s = try source("Sources/SelectedCore/StockQuotes.swift")
        XCTAssertFalse(s.contains("func fetchBatch(codes:"), "取数入口又长回来了 —— 应走 QuoteAPI")
        XCTAssertFalse(s.contains("func fetchIndexBatch(symbols:"), "取数入口又长回来了")
        XCTAssertFalse(s.contains("func fetch(code:"), "取数入口又长回来了")
        XCTAssertTrue(s.contains("parseBatchFullKeys"), "正对照：纯解析必须保留（可离线单测）")
    }

    func testPollingCallSitesUseUnifiedAPI() throws {
        let files = [
            "Sources/SelectedApp/AlertMonitor.swift",
            "Sources/SelectedApp/DashboardLiveMonitor.swift",
            "Sources/SelectedApp/StoreRefresh.swift",
            "Sources/SelectedApp/Views/StockDetailSheet+Load.swift",
            "Sources/SelectedApp/StoreWatch.swift",
        ]
        for f in files {
            let s = try source(f)
            XCTAssertTrue(s.contains("QuoteAPI."), "\(f) 没有走统一门面")
        }
    }

    func testEveryDatasetIsRegistered() {
        XCTAssertEqual(DataSourceRegistry.entries.count, DataSetID.allCases.count)
        let registered = Set(DataSourceRegistry.entries.map(\.id))
        for id in DataSetID.allCases {
            XCTAssertTrue(registered.contains(id), "数据集 \(id.rawValue) 没登记")
        }
    }
}
