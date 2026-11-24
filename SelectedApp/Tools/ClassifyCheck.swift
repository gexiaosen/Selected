import Foundation
import SQLite3
@testable import SelectedCore

/// **个股档案类 Swift-only 表**的真实库自检 —— 指数成份 + 基本面：
/// 建表 / 整表替换 / 读取 / **下界护栏** / 清空。
///
/// 两个 `Store` 的 `refresh` 形状完全一样（注入 fetch + 数量下界护栏 + 整表替换），
/// 所以共用一套驱动与断言模板；差别只在 `minCount`（指数按指数给，基本面 4000）
/// 与**票池是否同一份**。
///
/// ⚠ 本驱动原先还覆盖「所属行业 + 上市日期」那一组（含唯一能测到 `ALTER TABLE` 的老库迁移段），
///   2026-10-28 该模块整条下线后一并删除 —— 表由 `DBBootstrap.dropStockIndustry` 清掉。
///
/// **本驱动由 `swiftc` 单独编译，不经 `swift test`** → 这里的类型错误
/// **只有 `run_all.sh` 看得见**。改完先单独跑一次 `classify_test.sh`。
///
/// 跑之前必须把 `SELECTED_DATA_DIR` 指到**现造的库**（`classify_test.sh` 负责）。
/// **全程离线**：`refresh` 的抓取闭包由本驱动注入，不打网络 ——
///   这正是 `refresh(fetch:)` 那个注入点的用途（否则"拦下就不写库"这段逻辑没有测试）。
///
/// `@MainActor`：本驱动的读检查走的是两个 Store 的读方法，
/// 而它们全是 `@MainActor`（内部用主线程专用的 `SQLiteReader.shared`）。
/// CLI 的 `main()` 本来就跑在**进程主线程**上，所以整类型标 `@MainActor` 既是最省事的
/// 写法、也如实反映了"这些调用在主线程"这件事。
@main
@MainActor
struct ClassifyCheck {
    static var failures: [String] = []
    static var checks = 0

    static func check(_ cond: Bool, _ label: String) {
        checks += 1
        if !cond { failures.append(label) }
        print("   \(cond ? "✅" : "❌") \(label)")
    }

    static func eq<T: Equatable>(_ got: T, _ want: T, _ label: String) {
        check(got == want, "\(label)（实得 \(got)）")
    }

    /// 长数组比较：标签里只打**长度 + 首尾** ——
    /// 300 个元素全打出来会把回归日志淹掉（失败时更糟，恰好是最需要看清的时候）。
    static func eqLong(_ got: [String], _ want: [String], _ label: String) {
        let ok = got == want
        checks += 1
        if !ok { failures.append(label) }
        print("   \(ok ? "✅" : "❌") \(label)（实得 \(brief(got))，期望 \(brief(want))）")
    }

    private static func brief(_ a: [String]) -> String {
        guard a.count > 6 else { return "\(a)" }
        return "\(a.count) 项 \(a.prefix(2).joined(separator: ","))…\(a.suffix(2).joined(separator: ","))"
    }

    static func main() {
        print("== classify 自检 ==")
        stageBootstrap()
        stageReplaceAndRead()
        stageReplacementIsWholeTable()
        stageLowerBoundGuard()
        stageDeleteAll()
        stageFundamentalsSaveAndRead()
        stageFundamentalsLowerBoundGuard()
        stageFundamentalsDeleteAll()

        print("—— 检查 \(checks) 项，失败 \(failures.count) 项")
        if !failures.isEmpty {
            for f in failures { print("   ❌ \(f)") }
            exit(1)
        }
        exit(0)
    }

    // MARK: - 建表（Swift-only 迁移）

    static func stageBootstrap() {
        print("\n[1] 建库 + Swift-only 迁移")
        let dir = DataDirectory.resolve()
        check(!FileManager.default.fileExists(atPath: dir + "/selected.sqlite3"),
              "起点是空目录：\(dir)")
        let err = DBBootstrap.ensureReady()
        check(err == nil, "ensureReady 成功（\(err ?? "ok")）")
        DBBootstrap.ensureSwiftOnlySchemaOnDisk()
        let cols = tableColumns("index_members")
        for c in ["index_code", "code", "name", "fetched_at"] {
            check(cols.contains(c), "index_members 有列 \(c)")
        }
        check(tableIndexes("index_members").contains(IndexMembersStore.codeIndexName),
              "有 \(IndexMembersStore.codeIndexName) 索引（详情页按 code 查）")
    }

    // MARK: - 整表替换 + 读取

    /// 造 n 只假成份（代码形如 600000/600001…，保证合法 6 位数字）
    static func fakeMembers(_ n: Int, prefix: Int = 600000) -> [IndexMembers.Member] {
        (0..<n).map { i in
            IndexMembers.Member(code: String(format: "%06d", prefix + i), name: "样本\(i)")
        }
    }

    static func stageReplaceAndRead() {
        print("\n[2] 写入 + 读取")
        let hs = IndexMembers.index("hs300")!
        let members = fakeMembers(300)
        let n = (try? IndexMembersStore.replace(indexCode: hs.code, members: members,
                                                at: "2026-09-22 12:00:00")) ?? -1
        eq(n, 300, "写入 300 条")

        let back = IndexMembersStore.members(ofIndex: hs.code)
        eq(back.count, 300, "读回 300 条")
        eqLong(back, members.map(\.code).sorted(), "按 code 升序（与写入顺序无关，保证可复现）")

        eq(IndexMembersStore.counts()[hs.code], 300, "counts 报 300")
        eq(IndexMembersStore.lastFetched()[hs.code], "2026-09-22 12:00:00", "记录刷新时间")

        // 详情页问的是"这只票属于哪些指数"
        eq(IndexMembersStore.indicesOf(code: "600005"), ["hs300"], "600005 属于 hs300")
        eq(IndexMembersStore.indicesOf(code: "999999"), [], "不在任何指数里 → 空")
        eq(IndexMembersStore.indicesOf(code: ""), [], "空 code → 空（不发查询）")

        // 再加一个指数，验证"多对多"
        let zz = IndexMembers.index("zz500")!
        _ = try? IndexMembersStore.replace(indexCode: zz.code, members: fakeMembers(5, prefix: 600003),
                                           at: "2026-09-22 12:00:00")
        eq(IndexMembersStore.indicesOf(code: "600005"), ["hs300", "zz500"],
           "同时属于两个指数")
        // 顺序必须跟**清单顺序**（沪深300 在前），不能随 SQL 的返回顺序漂
        eq(IndexMembersStore.indicesOf(code: "600003"), ["hs300", "zz500"],
           "两个指数都命中时按清单顺序返回")
    }

    /// 整表替换：新的一份**更少**时必须把旧的清掉（否则会留下"幽灵成份"）
    static func stageReplacementIsWholeTable() {
        print("\n[3] 整表替换语义（不是追加）")
        let zz = IndexMembers.index("zz500")!
        _ = try? IndexMembersStore.replace(indexCode: zz.code, members: fakeMembers(5, prefix: 600003),
                                           at: "t1")
        eq(IndexMembersStore.members(ofIndex: zz.code).count, 5, "先写 5 条")
        // 换一份完全不同的
        _ = try? IndexMembersStore.replace(indexCode: zz.code, members: fakeMembers(3, prefix: 900001),
                                           at: "t2")
        let after = IndexMembersStore.members(ofIndex: zz.code)
        eqLong(after, ["900001", "900002", "900003"], "换成 3 条后只剩这 3 条（旧的被清掉）")
        check(!after.contains("600003"), "旧的 600003 不该残留（幽灵成份）")
        // 其它指数不受影响
        eq(IndexMembersStore.members(ofIndex: "hs300").count, 300, "换 zz500 不影响 hs300")
    }

    /// 下界护栏：抓回来的数量不够 → **不写库、保留旧数据**。
    ///
    /// 这是本项最重要的一条不变量。`IndexMembersSource.fetch` 对"抓取失败"与
    /// "这个指数没有成份"都返回 `[]`（它分不清），而节点名写错时新浪就是返回**空数组**
    /// （实测 `zhishu_000300`）→ 拿 `[]` 覆盖会让徽章**静默消失**，比不刷新更糟。
    static func stageLowerBoundGuard() {
        print("\n[4] 下界护栏（不足就不写，保留旧数据）")
        let hs = IndexMembers.index("hs300")!
        let before = IndexMembersStore.members(ofIndex: hs.code)
        eq(before.count, 300, "起点：库里已有 300 条好数据")

        // ① 抓取失败（空）→ 拦下，库里**一条不动**
        let r1 = IndexMembersStore.refresh([hs], fetch: { _ in [] })
        eq(r1.refreshed, [], "空结果 → 不算刷新成功")
        eq(r1.rejected[hs.code]?.contains("下界") ?? false, true, "拒绝原因写明是下界：\(r1.rejected)")
        eqLong(IndexMembersStore.members(ofIndex: hs.code), before,
               "⚠ 抓取失败后旧数据**逐条未变**（不是被清空）")

        // ② 抓到一半（比如只翻到 1 页）→ 同样拦下
        let r2 = IndexMembersStore.refresh([hs], fetch: { _ in fakeMembers(100) })
        eq(r2.refreshed, [], "只抓到 100 只（< 250）→ 拦下")
        eqLong(IndexMembersStore.members(ofIndex: hs.code), before, "旧数据仍逐条未变")

        // ③ 恰好等于下界 → 接受（`>=` 不是 `>`）
        let exact = fakeMembers(hs.minCount, prefix: 300000)
        let r3 = IndexMembersStore.refresh([hs], fetch: { _ in exact })
        eq(r3.refreshed, [hs.code], "恰好等于下界 → 接受")
        eqLong(IndexMembersStore.members(ofIndex: hs.code), exact.map(\.code).sorted(),
               "接受后库里换成新的那一份")

        // ④ 恢复成 300 条，供后续步骤用
        _ = IndexMembersStore.refresh([hs], fetch: { _ in fakeMembers(300) })
        eq(IndexMembersStore.members(ofIndex: hs.code).count, 300, "恢复 300 条")

        // ⑤ 部分成功部分失败：一个写进去、一个保留
        let zz = IndexMembers.index("zz500")!
        let zzBefore = IndexMembersStore.members(ofIndex: zz.code)
        let r5 = IndexMembersStore.refresh([hs, zz], fetch: { idx in
            idx.code == "hs300" ? fakeMembers(300) : []      // zz500 抓取失败
        })
        eq(r5.refreshed, [hs.code], "hs300 刷新成功")
        eq(r5.rejected.keys.sorted(), [zz.code], "zz500 被拦下")
        eqLong(IndexMembersStore.members(ofIndex: zz.code), zzBefore, "zz500 的旧数据保留")
    }

    static func stageDeleteAll() {
        print("\n[5] 清空（指数成份）")
        try? IndexMembersStore.deleteAll()
        eq(IndexMembersStore.counts(), [:], "counts 空")
        eq(IndexMembersStore.members(ofIndex: "hs300"), [], "成份空")
        eq(IndexMembersStore.indicesOf(code: "600005"), [], "反查空")
    }

    // MARK: - 库工具

    static func tableColumns(_ table: String) -> [String] {
        try! SQLiteWriter.shared.write { tx in
            try tx.query("PRAGMA table_info(\(table))", [])
        }.compactMap { $0["name"] as? String }
    }

    static func tableIndexes(_ table: String) -> [String] {
        try! SQLiteWriter.shared.write { tx in
            try tx.query("PRAGMA index_list(\(table))", [])
        }.compactMap { $0["name"] as? String }
    }
}


// MARK: - 基本面

extension ClassifyCheck {

    /// 造 n 只假票的基本面。
    ///
    /// 一半**有数据**、一半**全 `nil`** —— 这是本组最要紧的断言面：
    /// "源没给"必须原样存成 `NULL` 再读回 `nil`，**不能变成 `0`**
    /// （负债率 `0%` 是"无负债"，与"没数据"完全不同的结论）。
    static func fakeFundamentals(_ n: Int, prefix: Int = 600000,
                                 withData: Bool = true) -> [Fundamental.Item] {
        (0..<n).map { i in
            Fundamental.Item(code: String(format: "%06d", prefix + i), name: "样本\(i)",
                             peDynamic: withData ? 4.86 : nil,
                             peStatic: withData ? 6.02 : nil,
                             peTtm: withData ? 5.88 : nil,
                             pb: withData ? 0.4 : nil,
                             eps: withData ? 0.929296531 : nil,
                             bvps: withData ? 22.634180028 : nil,
                             roe: withData ? 3.96 : nil,
                             revenue: withData ? 93777000000.0 : nil,
                             netProfit: withData ? 30951000000.0 : nil,
                             revenueYoy: withData ? 3.5534844687 : nil,
                             netProfitYoy: withData ? 4.082456199348 : nil,
                             debtRatio: withData ? 91.9206504728 : nil)
        }
    }

    static func stageFundamentalsSaveAndRead() {
        print("\n[10] 基本面：写入 + 读取")
        let items = fakeFundamentals(300, withData: true)
            + fakeFundamentals(200, prefix: 300000, withData: false)
        let n = (try? FundamentalStore.replaceAll(items, at: "2026-09-22 15:30:00")) ?? -1
        eq(n, 500, "整表替换 500 只")
        eq(FundamentalStore.total(), 500, "total 报 500")
        eq(FundamentalStore.lastFetched(), "2026-09-22 15:30:00", "记录刷新时间")

        let a = FundamentalStore.fundamentals(of: "600005")
        eq(a?.peDynamic, 4.86, "市盈率往返")
        eq(a?.debtRatio, 91.9206504728, "⚠ 长小数往返（17 位，检验写入/读出都没被改写）")
        eq(a?.revenue, 93777000000.0, "营收往返（大额）")

        // 本组最要紧的一条：**"源没给"读回来必须是 nil，不能是 0**
        let b = FundamentalStore.fundamentals(of: "300005")
        eq(b?.peDynamic, nil, "⚠ 没数据 → nil（不是 0）")
        eq(b?.debtRatio, nil, "⚠ 资产负债率不能变成 0%")
        eq(b?.roe, nil, "ROE 也不能变成 0")
        // 分组也要保住 nil
        eq(b?.groups.first?.metrics.first?.value, nil, "分组后仍是 nil")

        eq(FundamentalStore.fundamentals(of: "999999"), nil, "表里没有 → nil")
        eq(FundamentalStore.fundamentals(of: ""), nil, "空 code → nil（不发查询）")

        // 五组（第六组「股本股东」字段校验不过 → 不做）
        eq(FundamentalStore.fundamentals(of: "600005")?.groups.count, 5, "五组")
    }

    static func stageFundamentalsLowerBoundGuard() {
        print("\n[11] 基本面：下界护栏（不足就不写，保留旧数据）")
        let before = FundamentalStore.total()
        eq(before, 500, "起点：库里已有 500 只")

        let r1 = FundamentalStore.refresh(fetch: { nil })
        eq(r1.rejected != nil, true, "nil → 判为失败：\(r1.rejected ?? "")")
        eq(r1.summary.contains("保留旧数据"), true, "文案要写清旧数据还在")
        eq(FundamentalStore.total(), before, "⚠ 抓取失败后旧数据**逐条未变**")

        let half = FundamentalFetch(items: fakeFundamentals(200), expected: 5560)
        let r2 = FundamentalStore.refresh(fetch: { half })
        eq(r2.rejected != nil, true, "200 只 < 下界 \(Fundamental.minStocks) → 拦下")
        eq(FundamentalStore.total(), before, "旧数据仍逐条未变")

        let exact = FundamentalFetch(items: fakeFundamentals(Fundamental.minStocks, prefix: 100000),
                                     expected: Fundamental.minStocks)
        let r3 = FundamentalStore.refresh(fetch: { exact })
        eq(r3.rejected, nil, "恰好等于下界 → 接受")
        eq(FundamentalStore.total(), Fundamental.minStocks, "库里换成新的那一份")
        eq(r3.stocks, Fundamental.minStocks, "报告如实带出条数")
        // 「落库了几只」与「几只有数据」是两件事（退市票会全 `-`）
        eq(r3.withData, Fundamental.minStocks, "这批都有数据")

        // 混入一批"全 nil"的 → withData 必须**小于** stocks
        let mixed = FundamentalFetch(items: fakeFundamentals(3000, prefix: 200000, withData: true)
                                            + fakeFundamentals(2000, prefix: 400000, withData: false),
                                     expected: 5000)
        let r4 = FundamentalStore.refresh(fetch: { mixed })
        eq(r4.stocks, 5000, "落库 5000 只")
        eq(r4.withData, 3000, "⚠ 只有 3000 只有数据（不能把 5000 都算成'有数据'）")
    }

    static func stageFundamentalsDeleteAll() {
        print("\n[12] 清空（基本面）")
        try? FundamentalStore.deleteAll()
        eq(FundamentalStore.total(), 0, "total 归零")
        eq(FundamentalStore.fundamentals(of: "600005"), nil, "查不到")
    }
}
