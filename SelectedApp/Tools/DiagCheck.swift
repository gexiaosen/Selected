import Foundation
@testable import SelectedCore

/// 数据源诊断读取侧（`DataSourceLogStore`）的**行为契约**自检
///
/// ## 为什么需要它
/// 这张卡片的 bug 全是"看着能用、其实没生效"，而每一个都不让任何测试变红：
///   ① 筛选条在整个生命周期里**一次都没显示过**（显示条件是"已选中"，而唯一写它的地方是它自己）
///      —— 那是 UI 接线，本自检测不到（靠代码注释 + 实机验证）；
///   ② "按事件筛选"若退化成**在已加载的 200 条里过滤**，用户点「错误」看到的只是
///      "这一窗里恰好有的错误"，而不是库里的错误 —— 本自检用**能被区分的构造**钉它：
///      错误行**全部排在窗口之外** ⇒ 窗口内过滤会得到 0 行，只有真的走 DB 侧
///      `WHERE event = ?` 才拿得到；
///   ③ 游标分页方向若写反（`id < cursor` 写成 `>`），现象是"翻 4 页只有 266 条"
///      —— 每一页都在**重复第一页**（替换而没追加）。
///
/// ## 口径
/// 全部在**隔离的临时库**上跑（`SELECTED_DATA_DIR`），绝不触碰生产库；
/// schema 由 `DBBootstrap.ensureReady()` 走**生产同款路径**建（不手抄建表语句）。
///
/// 跑法见 `Tools/diag_test.sh`（由 `engine/tests/run_all.sh` 调用）。
@main
struct DiagCheck {

    static var failures: [String] = []
    static var checked = 0

    static func check(_ cond: Bool, _ label: String) {
        checked += 1
        print(cond ? "   ✅ \(label)" : "   ❌ \(label)")
        if !cond { failures.append(label) }
    }

    // MARK: 构造数据

    struct Row {
        let ts: String
        let event: String
        let source: String
        let detail: String
    }

    /// **构造规则（本自检的关键）**：
    ///   · 最新 3 条（窗口 = `limit 3`）里**一条 error 都没有** ⇒ "在已加载窗口里过滤"必然是 0 行；
    ///   · `5min_insufficient` 共 6 条 > `error` 共 5 条 ⇒ 用来验「`error` 恒置首位」（不按条数排）；
    ///   · id 5 的 detail 有 600 字符 ⇒ 验读取侧的 `substr(detail, 1, 500)` 截断真的生效。
    static let seed: [Row] = [
        Row(ts: "2026-09-01T10:00:00", event: "error", source: "http",
            detail: "最老的一条错误 —— 只在 DB 侧筛选下才看得到"),
        Row(ts: "2026-09-01T11:00:00", event: "error", source: "http", detail: "e2"),
        Row(ts: "2026-09-02T10:00:00", event: "low_coverage", source: "tencent", detail: "l3"),
        Row(ts: "2026-09-02T11:00:00", event: "error", source: "tencent", detail: "e4"),
        Row(ts: "2026-09-03T10:00:00", event: "full_scan", source: "scheduler",
            detail: String(repeating: "x", count: 600)),
        Row(ts: "2026-09-03T11:00:00", event: "error", source: "http", detail: "e6"),
        Row(ts: "2026-09-04T10:00:00", event: "error", source: "http", detail: "e7"),
        Row(ts: "2026-09-05T10:00:00", event: "5min_insufficient", source: "tencent", detail: "n8"),
        Row(ts: "2026-09-05T11:00:00", event: "low_coverage", source: "tencent", detail: "l9"),
        Row(ts: "2026-09-06T10:00:00", event: "5min_insufficient", source: "tencent", detail: "n10"),
        Row(ts: "2026-09-06T11:00:00", event: "5min_insufficient", source: "tencent", detail: "n11"),
        Row(ts: "2026-09-07T10:00:00", event: "5min_insufficient", source: "tencent", detail: "n12"),
        Row(ts: "2026-09-07T11:00:00", event: "5min_insufficient", source: "tencent", detail: "n13"),
        Row(ts: "2026-09-07T12:00:00", event: "5min_insufficient", source: "tencent", detail: "n14"),
    ]

    // MARK: 入口

    @MainActor static func main() {
        // 与 AuditFixesTest 同一模式：临时库由**驱动自己**走生产启动路径建
        //   （`DBBootstrap.ensureReady()`），不手抄建表语句。
        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "bootstrap" {
            if let e = DBBootstrap.ensureReady() {
                print("❌ DBBootstrap.ensureReady 失败：\(e)")
                exit(2)
            }
            print("   schema 就绪（DBBootstrap.ensureReady，与真实 App 同构）")
            exit(0)
        }

        print("== 数据源诊断读取侧自检（P1-14 筛选改造）==")
        print("   SELECTED_DATA_DIR = \(ProcessInfo.processInfo.environment["SELECTED_DATA_DIR"] ?? "(未设置)")")

        guard seedRows() else {
            print("❌ 构造数据失败（临时库没建好？见上面的报错）")
            exit(2)
        }
        // 换库后必须让共享只读连接重新打开（它缓存 dirPath 与句柄）
        SQLiteReader.shared.invalidate()

        let store = DataSourceLogStore(limit: 3)   // 窗口 = 3 行（便于用 12 行数据构造"翻页"）

        // ① 分类条数（筛选条的数据源）
        store.reload()
        check(store.loadError == nil, "首次加载无错误（loadError = \(store.loadError ?? "nil")）")
        check(store.totalCount == seed.count, "库内总条数 = \(seed.count)（实得 \(store.totalCount)）")
        check(store.eventCounts.first?.event == "5min_insufficient",
              "分类条数按条数降序（第一 = \(store.eventCounts.first?.event ?? "空")，应为 5min_insufficient 6 条）")
        check(store.eventCounts.first?.count == 6, "5min_insufficient 计 6（实得 \(store.eventCounts.first?.count ?? -1)）")
        check(store.eventCounts.first { $0.event == "error" }?.count == 5, "error 计 5")
        check(store.quickFilterEvents.first?.event == "error",
              "⚠ error 恒置首位（即使 5min_insufficient 更多）—— 实得 \(store.quickFilterEvents.first?.event ?? "空")")
        check(store.quickFilterEvents.count <= DataSourceLogStore.quickFilterMax,
              "快速筛选项不超过 \(DataSourceLogStore.quickFilterMax) 个（实得 \(store.quickFilterEvents.count)）")

        // ② 无筛选：窗口 = 最新 3 条，且**一条 error 都没有**（构造使然）
        check(store.entries.count == 3, "无筛选加载 3 条（实得 \(store.entries.count)）")
        check(store.entries.allSatisfy { $0.event != "error" },
              "窗口里没有 error（构造使然 ⇒ 下面那条筛选若不是查库，会拿到 0 行）")
        check(store.hasMore, "库内 \(seed.count) 条 > 窗口 3 条 ⇒ hasMore = true")
        let trunc = store.entries.first { $0.event == "full_scan" }
        check(trunc == nil, "full_scan（600 字 detail）不在最新窗口里（构造使然）")

        // ③ 按事件筛选：**必须**从库里取样，而不是在窗口里过滤
        //    这一段同时钉住"换筛选是**替换**而不是追加"（若按 id 比较猜"追加还是替换"，
        //      换筛选时会被误判成翻页 ⇒ 列表里混着上一筛选的行）
        store.setFilter("error")
        check(store.diagFilter == "error", "筛选态记录在 Store（diagFilter = \(store.diagFilter)）")
        check(store.entries.count == 3,
              "筛选 error 得到 3 条（**窗口内过滤会得 0 条**；误判成追加会得 6 条 —— 实得 \(store.entries.count)）")
        check(store.entries.allSatisfy { $0.event == "error" }, "筛选结果逐条都是 error")
        check(store.entries.first?.ts == "2026-09-04T10:00:00",
              "取的是**最新**的 error（实得 \(store.entries.first?.ts ?? "空")）")
        check(store.hasMore, "库里 5 条 error > 窗口 3 条 ⇒ hasMore = true")

        // ④ 翻页：**追加**而不是替换（曾写反成"每页都重复第一页"）
        store.loadMore(event: store.diagFilter)
        check(store.entries.count == 5, "翻一页后共 5 条 error（替换的话会是 2 条，实得 \(store.entries.count)）")
        check(store.entries.allSatisfy { $0.event == "error" }, "翻页保持筛选（没有混进别的类）")
        check(store.entries.last?.ts == "2026-09-01T10:00:00",
              "翻到最老的那条 error（实得 \(store.entries.last?.ts ?? "空")）")
        check(!store.hasMore, "5 条 error 翻完 ⇒ hasMore = false")
        check(store.coveredFrom == "2026-09-01T10:00:00",
              "覆盖范围 = 已加载里最早一条（实得 \(store.coveredFrom ?? "空")）")

        // ⑤ 600 字 detail 在读取侧被截到 500（写入侧已截断，这里是**第二道**）
        store.setFilter("full_scan")
        check(store.entries.count == 1, "full_scan 只 1 条（实得 \(store.entries.count)）")
        check(store.entries.first?.detail.count == 500,
              "detail 读回来被截到 500 字（实得 \(store.entries.first?.detail.count ?? -1)）")

        // ⑥ 库里没有的事件：给空结果而不是崩 / 而不是"看起来没筛选"
        store.setFilter("migration_failed")
        check(store.entries.isEmpty, "库里不存在的事件 → 空结果（实得 \(store.entries.count) 条）")
        check(!store.hasMore, "空结果 ⇒ hasMore = false")
        check(store.loadError == nil, "空结果**不是**错误（loadError 仍为 nil）")

        // ⑦ 回到「全部」：窗口回到最新 3 条（游标必须被清掉）
        store.setFilter("")
        check(store.entries.count == 3, "回到全部又是 3 条（实得 \(store.entries.count)）")
        check(store.entries.first?.ts == "2026-09-07T12:00:00",
              "回到全部取的是**最新**的一条（实得 \(store.entries.first?.ts ?? "空")）")

        print("")
        if failures.isEmpty {
            print("✅ diag_check     数据源诊断读取侧 \(checked) 项断言全部通过")
            exit(0)
        }
        print("❌ diag_check     失败 \(failures.count)/\(checked) 项：")
        for f in failures { print("     · \(f)") }
        exit(1)
    }

    // MARK: 构造数据（走生产同款写入路径）

    @MainActor private static func seedRows() -> Bool {
        do {
            try SQLiteWriter.shared.write { tx in
                for r in seed {
                    _ = try tx.execute(
                        "INSERT INTO data_source_logs(ts, source, event, detail) VALUES(?,?,?,?)",
                        [r.ts, r.source, r.event, r.detail])
                }
            }
            return true
        } catch {
            print("   ❌ 构造日志行失败：\(error)")
            return false
        }
    }
}