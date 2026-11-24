import Foundation

/// 数据源诊断 —— `data_source_logs` 的**读取侧**。
///
/// ## 为什么需要它
/// `data_source_logs` 一直在被写（`DataSources.logDataSource` / `ParamStore`），
/// `DBBootstrap` 还给它设了 30 天保留期 ⇒ 数据一直在攒，但长期**没有读取方** ——
/// 界面只写「抓取失败（源无响应或返回不完整）」，真因（如
/// `The network connection was lost.`）藏在**这张表里**。
/// ⇒ 本类把「用户报障 → 开发者查库」变成「用户自己能看到错误原文」。
///
/// ## 为什么放 Core 而不是 App 层
/// 读 SQLite 需要 `@MainActor`（`SQLiteReader.shared` 是 MainActor 隔离的共享连接），
/// 与 `FundCache` / `HkCache` 等同类 Store 一致；放在 Core 便于 `Tools/` 里的
/// 自检脚本也能直接用（不引 UI）。
///
/// ## 边界（刻意不做）
/// · **不写** —— 本类型只读。写入仍走 `DataSources.logDataSource`（那是唯一的写入口）。
/// · **不做删除 / 清空** —— 30 天保留期由 `DBBootstrap` 既有逻辑负责；
///   「手动清空」会清掉唯一的事故证据，不随手给。
/// · **不做趋势统计** —— 只有一条聚合查询（`GROUP BY event` 的**分类条数**，
///   供筛选条显示「错误 2,065」这种"这一类有多少"）。
@MainActor
public final class DataSourceLogStore {

    // MARK: 类型

    /// 一条日志。`detail` 在写入侧已截断到 500 字。
    public struct Entry: Identifiable {
        public let id: Int
        /// `yyyy-MM-dd'T'HH:mm:ss`
        public let ts: String
        /// 数据源名（`tencent` / `http` / `fundamental` / `scheduler` …）
        public let source: String
        /// 事件名（`error` / `full_scan` / `low_coverage` / `migration_failed` …）
        public let event: String
        public let detail: String
    }

    /// 一类事件的**库内总条数**（筛选条用）。
    ///
    /// ⚠ 与 `entries` 的区别：`entries` 是**当前窗口**（最近 200 条，翻页会变），
    ///   这个是**整库 30 天**的口径（`GROUP BY event`）—— 筛选条要回答的是
    ///   「点开这一类，库里到底有多少」，而不是「这 200 条里有几条」。
    public struct EventCount: Identifiable, Equatable {
        public let event: String
        public let count: Int
        public var id: String { event }
        /// ⚠ 显式 `public init`：成员逐一构造器默认是 `internal`，跨模块（View 那边要自己拼
        ///   "当前选中的那一类 + 排前几类"）就构造不出来（编译报 inaccessible）。
        public init(event: String, count: Int) {
            self.event = event
            self.count = count
        }
    }

    // MARK: 状态
    //
    // ⚠ **刻意不用 `@Observable`**：`CoreLayeringTests` 的 `bannedImports`
    //   明确禁 `Observation`（Core 不得依赖 UI 框架）。
    //   ⇒ 改用**显式回调**：View 在 `reload()` / `loadMore()` 之后手动刷新
    //   （`SettingsDiagSection` 就是这么做的）。
    //   这是 Core 层 Store 的**既有惯例**（`FundCache` / `SecuritiesCache` 等都这样）。

    /// 最近 N 条（按时间倒序）。
    public internal(set) var entries: [Entry] = []
    public internal(set) var isLoading = false
    /// 加载失败的原因（表不存在 / 库没建等）。nil = 上次加载成功。
    public internal(set) var loadError: String?
    /// 上次成功加载的时刻（供 UI 显示「数据截至 …」）
    public internal(set) var loadedAt: Date?
    /// 本次结果里**最早**一条的时刻 —— UI 必须显示它，否则用户会以为
    /// 「更早没有日志」（实测：只覆盖约 9 天）。
    public internal(set) var coveredFrom: String?

    /// 读多少条。
    ///
    /// ⚠ 默认 200：生产库 30 天有上万条，全拉会让设置页瞬间变慢。
    ///
    /// ⚠ **真实覆盖范围远小于保留期**：生产库平均每天约 600 条 ⇒ 最近 200 条只覆盖
    ///   约 8~9 天，超出部分的日志**在界面上看不到**。
    ///   ⇒ UI **必须**显示覆盖范围（`coveredFrom`），并提供「按事件全量查」
    ///   作为「更早的事故」的兜底路径（`reload(event:)`）。
    public static let defaultLimit = 200

    public let limit: Int

    public init(limit: Int = DataSourceLogStore.defaultLimit) {
        self.limit = limit
    }

    // MARK: 分类条数（筛选条的数据源）

    /// 库内各事件的条数（按条数降序）。
    ///
    /// ⚠ **只在「从头查」时刷新**（点刷新 / 加载日志 / 换筛选），翻页不动它 ——
    ///   翻页不改变整库的构成。
    /// ⚠ 代价是一次全表扫 `GROUP BY`（万行级 ≈ 毫秒，一次性）——
    ///   这就是它敢在主线程跑的**唯一**理由；再大一个数量级就要挪到独立连接去（同 `FundCache`）。
    public internal(set) var eventCounts: [EventCount] = []

    /// 库内总条数（= 各分类求和）。`0` = 没查过 / 空表。
    public var totalCount: Int { eventCounts.reduce(0) { $0 + $1.count } }

    /// 筛选条上**直接摆出来**的快速筛选项。
    ///
    /// ⚠ `error` **恒置首位**（不按条数）：本卡片存在的理由就是「错误原文可查」，
    ///   而库里 `error` 按条数只排第 2（第 1 是 `5min_insufficient` 的海量噪声）
    ///   ⇒ 纯按条数排会把它挤到后面。
    ///   其余按条数降序 ⇒ 用户一眼看到「哪一类在刷屏」。
    /// ⚠ 上限 6 个：筛选条只有一行，多的收进「更多」菜单（`eventCounts` 给全量清单）。
    public var quickFilterEvents: [EventCount] {
        var ordered = eventCounts
        if let i = ordered.firstIndex(where: { $0.event == "error" }) {
            ordered.insert(ordered.remove(at: i), at: 0)
        }
        return Array(ordered.prefix(DataSourceLogStore.quickFilterMax))
    }

    /// 筛选条上摆几个（其余进「更多」菜单）。
    public static let quickFilterMax = 6

    /// 拉一次分类条数（`GROUP BY event`）。
    ///
    /// ⚠ 失败（表不存在 / 库打不开）时**保持上一次的值**，不清空 ——
    ///   计数是"锦上添花"的导航信息，清空会让筛选条突然少一排（看起来像坏了）。
    ///   真正的错误仍由 `loadMore` 的 `loadError` 如实报出。
    private func loadEventCounts() {
        guard SQLiteReader.shared.hasTable(DataSourceLogStore.table) else { return }
        let rows = SQLiteReader.shared.queryRaw(
            "SELECT event, COUNT(*) AS n FROM \(DataSourceLogStore.table) GROUP BY event ORDER BY n DESC",
            [])
        let mapped = rows.compactMap { r -> EventCount? in
            guard let ev = r["event"] as? String, let n = r["n"] as? Int else { return nil }
            return EventCount(event: ev, count: n)
        }
        // ⚠ 空结果**不覆盖**：`query` 在"表不存在/查询失败"时也返回空数组，
        //   与"表是空的"不可区分 ⇒ 与 `loadMore` 里"空响应 vs 请求失败"同一个取舍。
        if !mapped.isEmpty { eventCounts = mapped }
    }

    // MARK: 查询

    /// ⚠ 真正的读逻辑在下面的 `loadMore(event:)`（游标分页），
    ///   这里只是它的薄封装：清空游标从头查。改筛选 / 点刷新都走它。
    ///
    /// ⚠ 不吞错：表不存在（老库没跑 Swift-only 迁移）时给出**可操作**的提示
    ///   （「去跑数据迁移」），而不是静默显示「暂无日志」——
    ///   那两种情况在界面上长得一样正是本条要消灭的歧义。

    /// 翻页游标：`nil` = 从最新开始；非 nil = 从这条**之后**（更早）继续。
    private var cursor: Int?

    /// 是否还有更早的记录（UI 据此决定「再往前」按钮是否可用）。
    public internal(set) var hasMore = false

    /// 往前翻一页（`WHERE id < cursor`，走 id 主键，很快）。
    ///
    /// ## 为什么用游标分页而不是「按事件全量查」
    /// ⚠ 「一次全查」盖不住：生产库 `event='error'` 有数千条，任何固定上限都有
    ///   翻不到的区段，全拉列表又没法用。⇒ 只能**翻页**：一页 200 条，
    ///   点「再往前」就能翻到任意早。
    ///
    /// - Parameter event: 只看某一类（`""` = 全部）。**翻页时保持当前筛选**。
    public func loadMore(event: String) {
        isLoading = true
        defer { isLoading = false }

        guard SQLiteReader.shared.hasTable(DataSourceLogStore.table) else {
            loadError = "日志表不存在（老库未迁移）。到「设置 → 维护」跑一次数据迁移即可。"
            entries = []
            return
        }
        // ⚠ **追加还是替换，只由"本次是不是从头查"决定**（`cursor == nil`）。
        //   按 id 大小**猜**会在换筛选时必然猜错：新筛选的第一页 id 比旧列表最后一条更小
        //   ⇒ 被当成"翻页"**追加**进旧列表 ⇒ 列表里混着**上一个筛选**的行。
        //   现由 `Tools/DiagCheck.swift` 钉住（换筛选后条数与事件种类都要对）。
        let isFreshQuery = (cursor == nil)
        // 只有「从头查」才重拉分类条数：翻页不改变整库构成。
        // 放在 hasTable 之后 ⇒ 表不存在时不会白跑一趟（那条分支已经报了 loadError）。
        if isFreshQuery { loadEventCounts() }
        let ev = event.trimmingCharacters(in: .whitespaces)
        let extra = 1   // 多取 1 条用来判断「还有没有下一页」，不显示
        let cols = "SELECT id, ts, source, event, substr(detail, 1, 500) AS detail FROM \(DataSourceLogStore.table)"

        // ⚠ **参数个数必须与 `?` 严格一致**：SQL 里写字面量、参数里却带占位符的值
        //   ⇒ 绑定整体右移 ⇒ SQLite 不报错、静默返回错数据。
        //   ⇒ 一律用占位符，并让 `where` 与 `params` 在同一个表达式里成对构造，
        //   从此不存在"字面量 SQL + 带占位符的参数"这种错位可能。
        // ⚠ 变量名不能叫 `where`（SQL 关键字，Swift 也保留）⇒ 用 whereSQL
        var whereSQL = ""
        var params: [Any] = []
        if !ev.isEmpty { whereSQL = " WHERE event = ?"; params.append(ev) }
        if let c = cursor {
            whereSQL += whereSQL.isEmpty ? " WHERE id < ?" : " AND id < ?"
            params.append(c)
        }
        params.append(limit + extra)

        // ⚠ 游标分页用 `id < cursor` 而不是 OFFSET：OFFSET 越翻越慢，
        //   而 `id` 单调递增 ⇒ 游标稳定且每页都是 O(limit)。
        let rows = SQLiteReader.shared.queryRaw("\(cols)\(whereSQL) ORDER BY id DESC LIMIT ?", params)

        hasMore = rows.count > limit
        let shown = rows.prefix(limit)
        let mapped = shown.compactMap { r -> Entry? in
            guard let id = r["id"] as? Int else { return nil }
            return Entry(id: id,
                         ts: (r["ts"] as? String) ?? "",
                         source: (r["source"] as? String) ?? "",
                         event: (r["event"] as? String) ?? "",
                         detail: (r["detail"] as? String) ?? "")
        }
        // ⚠ 方向：往回翻拿到的记录 id **更小**（倒序）⇒ 追加只可能发生在**翻页**上；
        //   而"是不是翻页"由 `isFreshQuery` 明确判定，不靠比较 id 猜（见上面的注释）。
        if isFreshQuery {
            entries = mapped
        } else {
            entries.append(contentsOf: mapped)
        }
        cursor = mapped.last?.id
        loadError = nil
        loadedAt = Date()
        coveredFrom = entries.last?.ts
    }

    /// 重新从头查（清空游标）。改筛选或点「刷新」时调。
    public func reload() {
        cursor = nil
        hasMore = false
        loadMore(event: diagFilter)
    }

    /// 当前筛选（`""` = 全部）。翻页时必须保持它，所以存在 Store 上。
    public var diagFilter: String = ""

    /// 换筛选并重新从头查。
    public func setFilter(_ ev: String) {
        diagFilter = ev
        expandedDiag.removeAll()
        reload()
    }

    /// UI 展开明细的 id 集合放在 Store（跨页保留）—— 只放一页的话，
    /// 翻页后展开状态就丢了，行为会显得莫名其妙。
    public var expandedDiag: Set<Int> = []

    // MARK: 事件名的中文映射
    //
    // ⚠ 为什么要映射：界面若直接显示 `full_scan` / `low_coverage` 这些 snake_case，
    //   用户看不懂。⇒ 映射收在 Core 一处，未知事件**原样显示**
    //   （与 `CompareReport.statusLabel` 的取舍**相反**：这里 event 是排查线索，
    //   显示 `chunk_partial` 反而帮用户搜到对应代码/文档）。
    public static func eventLabel(_ event: String) -> String {
        switch event {
        case "error": return "错误"
        case "full_scan": return "全量扫描"
        case "low_coverage": return "覆盖率偏低"
        case "insufficient": return "数据不足中止"
        case "chunk_partial": return "分片部分返回"
        case "chunk_failed": return "分片失败"
        case "chunk_budget_skip": return "分片因预算跳过"
        case "round_budget_exceeded": return "整轮预算耗尽"
        case "round_cancelled": return "取数被取消"
        case "migration_failed": return "迁移失败"
        case "5min": return "5 分钟线"
        case "5min_insufficient": return "5 分钟线不足"
        case "accuracy_track": return "准确度跟踪"
        case "outcome_windows": return "结果窗口"
        case "refresh_failed": return "刷新失败"
        case "classify_failed": return "分类抓取失败"
        case "cancelled": return "已取消"
        default: return event            // 未知事件原样显示
        }
    }

    // MARK: 常量

    public static let table = "data_source_logs"
}
