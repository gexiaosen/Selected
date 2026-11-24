import Foundation

// MARK: - 全链路记录（`SQLiteReader` 的读取结果）

/// 某个选股日的**全链路**记录（≡ `SQLiteReader.history(date:)`）
///
/// ⚠ 五个子对象**各自可能为 `null`**（那天该环节还没跑）——
/// 视图用 `exists(...)` 判存在，不是判"空对象"。
/// `predict` / `compare` 直接复用已有实体（它们是**同一份**产出，只是从库里读回来）。
public struct HistoryRecord: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "date", "rounds", "predict", "compare", "verify", "review", "iterate",
    ]
    /// 五个环节里任一都可能缺席（`null`）—— 只有 `date` / `rounds` 恒有
    public static let conditionalKeys: Set<String> = [
        "predict", "compare", "verify", "review", "iterate",
    ]

    public var date: String { json.str("date") }
    public var dateDash: String { json.strOrDash("date") }
    /// 当日已扫的轮次（按 slot 升序）
    public var rounds: [HistoryRoundRow] { json.objects("rounds").map(HistoryRoundRow.init) }

    /// 该环节是否存在 —— **不只看 null**：空对象也算"没有"。
    public func exists(_ key: String) -> Bool {
        let v = json[key]
        return !v.isNull && !v.dict.isEmpty
    }

    public var predict: PredictResult? {
        json["predict"].isNull ? nil : PredictResult(json.object("predict"))
    }
    public var compare: CompareReport? {
        json["compare"].isNull ? nil : CompareReport(json.object("compare"))
    }
    public var verify: HistoryVerifyRow? {
        json["verify"].isNull ? nil : HistoryVerifyRow(json.object("verify"))
    }
    public var review: HistoryReviewRow? {
        json["review"].isNull ? nil : HistoryReviewRow(json.object("review"))
    }
    public var iterate: HistoryIterateRow? {
        json["iterate"].isNull ? nil : HistoryIterateRow(json.object("iterate"))
    }
}

/// 全链路里的一轮（≡ `history.rounds` 元素）
///
/// ⚠ 与 `RoundSummaryRow`（`todayRounds`）**不是同一个形状**：这里少
/// `round_id` / `param_version` / `market_env`。同一张 `scan_rounds` 表的两条读路径。
public struct HistoryRoundRow: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = [
        "slot", "slot_label", "run_time", "tier1_count", "tier2_count",
    ]

    public var slot: Int { json.integer("slot") }
    public var slotLabel: String { json.str("slot_label") }
    public var slotLabelDash: String { json.strOrDash("slot_label") }
    public var runTime: String { json.str("run_time") }
    /// 展示用：`run_time` 去掉日期前缀
    public var runTimeClock: String { runTime.count > 11 ? String(runTime.dropFirst(11)) : runTime }
    public var tier1Count: Int { json.integer("tier1_count") }
    public var tier2Count: Int { json.integer("tier2_count") }
}

/// 全链路里的验证环节（**只有两个字段** —— 明细在别处）
public struct HistoryVerifyRow: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["sel_date", "verify_time"]

    public var selDate: String { json.str("sel_date") }
    public var verifyTime: String { json.str("verify_time") }
    /// 有执行时刻才算"跑过了"
    public var hasRun: Bool { !verifyTime.isEmpty }
    /// 键**存在**即为 true —— 与 `hasRun` 的区别：空串也算存在。视图文案用的就是这个口径。
    public var hasVerifyTimeKey: Bool { json["verify_time"].string != nil }
}

/// 全链路里的复盘环节
public struct HistoryReviewRow: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["sel_date", "review_time", "four_layer"]

    public var selDate: String { json.str("sel_date") }
    public var reviewTime: String { json.str("review_time") }
    public var hasRun: Bool { !reviewTime.isEmpty }
    /// 四层胜率（与 `ReviewFourLayer` 同构）
    public var fourLayer: ReviewFourLayer { ReviewFourLayer(json.object("four_layer")) }
}

/// 全链路里的迭代环节
public struct HistoryIterateRow: JSONEntity {
    public let json: JSONValue
    public init(_ json: JSONValue) { self.json = json }

    public static let declaredKeys: Set<String> = ["trigger_date", "counter", "insights"]

    public var triggerDate: String { json.str("trigger_date") }
    /// 迭代计数器（回放模式下不得推进）
    public var counter: Int { json.integer("counter") }
    public var insights: [String] { json.strings("insights") }
}
