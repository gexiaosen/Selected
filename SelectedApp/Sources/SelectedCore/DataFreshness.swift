import Foundation

/// 数据源新鲜度。
///
/// **与设置页的「渠道状态灯」分工**（两者不重复）：
///   · 渠道状态灯回答「**通不通**」—— 探测当下能否取到数
///   · 本模块回答「**现在看到的数据是哪天的**」—— 缓存型数据源（证券/基金/港股列表）
///     可以几天不刷新而探测照样全绿，界面上完全看不出来
///
/// **为什么判据只用本地证据**：参照系取「应用自己观察到的交易日」（`dayMeta` 的日期集合），
/// 而不是按日历推算交易日。日历推算在长假期间会把"本来就不该有数据"误报成过期；
/// 用 `dayMeta` 则天然免疫：假期里参照系停在最后一个观察日，不会有假警报。
///
/// 本模块**不触网、不碰引擎输出**。
public enum FreshnessLevel: String, Sendable {
    /// 与最近观察到的交易日同步
    case fresh
    /// 落后 1 个观察到的交易日
    case lagging
    /// 落后 ≥2 个观察到的交易日（或早于全部观察日）
    case expired
    /// 无成功记录（该源可能压根没被用过 —— **不等于异常**，故不参与聚合告警）
    case unknown
}

/// 单个数据源的新鲜度
public struct SourceFreshness: Equatable, Sendable {
    public let key: String
    public let label: String
    /// 最近一次**成功**取数的日期（`YYYY-MM-DD`）；无成功记录 → nil
    public let asOf: String?
    /// 该源最近一条日志的事件名与时刻（**不区分成败**，仅供排查）
    public let lastEvent: String?
    public let lastEventAt: String?
    public let level: FreshnessLevel

    public init(key: String, label: String, asOf: String?,
                lastEvent: String?, lastEventAt: String?, level: FreshnessLevel) {
        self.key = key
        self.label = label
        self.asOf = asOf
        self.lastEvent = lastEvent
        self.lastEventAt = lastEventAt
        self.level = level
    }
}

/// 一个可观测源的规格：日志里哪些行属于它，以及哪些算「成功心跳」
public struct SourceSpec: Equatable, Sendable {
    public let key: String
    public let label: String
    /// 该源**独占**的 `data_source_logs.source`（降级/失败都记在这里）
    public let ownSources: Set<String>
    /// 成功心跳，形如 `source|event`
    public let successPairs: Set<String>

    public init(key: String, label: String, ownSources: Set<String>,
                pairs: [(source: String, event: String)]) {
        self.key = key
        self.label = label
        self.ownSources = ownSources
        self.successPairs = Set(pairs.map { "\($0.source)|\($0.event)" })
    }
}

public enum DataFreshness {

    /// 可观测源 → 成功心跳。
    ///
    /// ⚠ 事件名**逐一取自 `DataSources.logDataSource` 的调用点**，有个反直觉之处：
    ///   列表类刷新记在 `sina` 名下（`stock_list_refreshed` / `fund_list_refreshed` /
    ///   `hk_list_refreshed`），**不是** `stock_list` / `fund_list` / `hk_list` ——
    ///   后三者只在**降级/失败**时写日志（`fallback_cache` / `fallback_baseline` / `fatal`）。
    ///   把两者搞混，会把"从未成功过"读成"刚刚成功"。
    ///
    /// ⚠ `sina` 是**多个源共享**的 source：只按 source 过滤会把别家的事件算进来
    ///   （证券列表的"最近事件"显示成 `fund_list_refreshed`）。故判定相关行用
    ///   「**独占 source ∪ 本源成功心跳**」，而不是「所有出现过本源的 source」。
    ///
    /// **刻意不列入**（写在这里免得后人以为是漏了）：
    ///   · `mootdx` —— 当前实现不再产出该 source，日志里的行都是**历史遗留**；
    ///     列进来会让徽章常年显示一个死源
    ///   · `http` / `params` / `review` / `db` —— 不是数据源（传输层错误 / 参数 / 复盘 / 建库）
    public static let specs: [SourceSpec] = [
        SourceSpec(key: "tencent", label: "腾讯行情", ownSources: ["tencent"],
                   pairs: [("tencent", "full_scan")]),
        // `stock_list|refreshed` 是缓存写入成功，与 `sina|stock_list_refreshed` 属同一次刷新，
        // 两者任一先到即可，故都算心跳
        SourceSpec(key: "stock_list", label: "证券列表", ownSources: ["stock_list"],
                   pairs: [("sina", "stock_list_refreshed"), ("stock_list", "refreshed")]),
        SourceSpec(key: "fund_list", label: "场内基金列表", ownSources: ["fund_list"],
                   pairs: [("sina", "fund_list_refreshed")]),
        SourceSpec(key: "hk_list", label: "港股列表", ownSources: ["hk_list"],
                   pairs: [("sina", "hk_list_refreshed")]),
        // 分时K线：**逐只**记一条（`sina|5min`）。`ownSources` 为空 —— 它的降级事件
        // `sina|5min_fallback` 与成功事件同挂在共享的 `sina` 上，按当前规则无法归属，
        // 但这不影响核心判据（"深度验证的分时输入今天到底有没有取到"）。
        SourceSpec(key: "5min", label: "分时K线", ownSources: [],
                   pairs: [("sina", "5min")]),
    ]

    /// 观察到的交易日（升序）。`dayMeta` 的键 = 应用确实拿到过数据的日期。
    public static func observedDays(_ dayMeta: [String: Int]) -> [String] {
        dayMeta.keys.filter { $0.count >= 10 }.sorted()
    }

    /// 参照系：最近观察到的交易日 + 它的前一个（不足两个时 `previous` 为 nil）
    public static func reference(_ observed: [String]) -> (latest: String?, previous: String?) {
        guard let latest = observed.last else { return (nil, nil) }
        let previous = observed.count >= 2 ? observed[observed.count - 2] : nil
        return (latest, previous)
    }

    /// 分级（纯函数）
    public static func classify(asOf: String?, latest: String?, previous: String?) -> FreshnessLevel {
        guard let asOf else { return .unknown }
        // 应用还没观察过任何交易日 → 没有参照系，如实说"不知道"，不猜成过期
        guard let latest else { return .unknown }
        if asOf >= latest { return .fresh }
        if let previous, asOf == previous { return .lagging }
        return .expired
    }

    /// 从 `data_source_logs` 的行派生每个源的新鲜度。
    /// `rows` 每项需含 `ts`（`yyyy-MM-dd'T'HH:mm:ss`）/ `source` / `event`，顺序无关。
    public static func derive(rows: [[String: Any]], latest: String?, previous: String?) -> [SourceFreshness] {
        specs.map { spec in
            var asOf: String?
            var lastEvent: String?
            var lastEventAt: String?
            for r in rows {
                let src = (r["source"] as? String) ?? ""
                let ev = (r["event"] as? String) ?? ""
                let isSuccess = spec.successPairs.contains("\(src)|\(ev)")
                // 只认「本源独占 source」或「本源成功心跳」——`sina` 被三个列表源共享，
                // 若只按 source 过滤，证券列表的"最近事件"会显示成 `fund_list_refreshed`
                guard isSuccess || spec.ownSources.contains(src) else { continue }
                let ts = (r["ts"] as? String) ?? ""
                // 最近一条相关日志（**不区分成败**，供排查降级/失败）；ts 是 ISO 文本，字典序即时序
                if lastEventAt == nil || ts > (lastEventAt ?? "") {
                    lastEventAt = ts
                    lastEvent = ev
                }
                if isSuccess, ts.count >= 10 {
                    let day = String(ts.prefix(10))
                    if asOf == nil || day > (asOf ?? "") { asOf = day }
                }
            }
            return SourceFreshness(key: spec.key, label: spec.label, asOf: asOf,
                                   lastEvent: lastEvent, lastEventAt: lastEventAt,
                                   level: classify(asOf: asOf, latest: latest, previous: previous))
        }
    }

    /// 聚合等级（供单枚徽章用）。
    ///
    /// ⚠ `unknown` **不参与**告警：它多半只是"这个源没被用过"（比如从没搜过港股），
    /// 把它算成异常会让徽章常年飘红 —— 那正是"狼来了"式的告警疲劳。
    /// 只有**全部**为 unknown 时才回 `unknown`（此时如实显示"无记录"）。
    public static func aggregate(_ items: [SourceFreshness]) -> FreshnessLevel {
        let known = items.filter { $0.level != .unknown }
        if known.contains(where: { $0.level == .expired }) { return .expired }
        if known.contains(where: { $0.level == .lagging }) { return .lagging }
        if known.isEmpty { return .unknown }
        return .fresh
    }
}
