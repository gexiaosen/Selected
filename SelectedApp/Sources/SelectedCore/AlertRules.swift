import Foundation

// MARK: - 自选提醒（用户自定义告警）的规则定义与输入解析
//
// 本模块是**唯一**的提醒来源：用户在「修改提醒」弹窗里填的观察条件（"到价了告诉我"），
// 落 `watch_alerts` / `watch_alert_settings` 两张表。
// 引擎从 `watch_judgments` 算出的目标价/止损价只做**参考**（可一键填入），不会自动提醒。
//
// 本文件只放**纯定义与解析**，触发判据在 `AlertEval.swift`（同为纯函数，可被 `swift test` 覆盖）。

/// 提醒类型。`rawValue` **就是落库值**（英文枚举，不是展示名）——
/// 展示名会随文案改，拿它当键会在改文案时把存量数据读成"未知类型"。
///
/// ⚠ **声明顺序 = 弹窗行序 = 设置页一览的顺序**（`CaseIterable` 保序），
///   按"单位"分组：价格 → 金额 → 比例。
public enum AlertKind: String, CaseIterable, Sendable {
    case upPrice = "up_price"
    case downPrice = "down_price"
    /// 当日涨跌**额**（元）。⚠ 不是成交额，见 `family` 的注释
    case upAmount = "up_amount"
    case downAmount = "down_amount"
    case upPct = "up_pct"
    case downPct = "down_pct"

    /// 族别。**唯一**的"这个类型是什么量"的判据 ——
    /// 三个族别在**输入校验范围 / 默认重复方式 / 输入提示 / 通知文案 / 一览格式**上全都不同，
    /// 用一个 `Bool` 表达不了。
    ///
    /// ⚠ 对 `family` 的 `switch` 一律**穷尽、不写 `default:`** ——
    ///   再加类型时编译器会直接报错，而不是悄悄落进某个分支。
    public var family: AlertFamily {
        switch self {
        case .upPrice, .downPrice: return .price
        case .upAmount, .downAmount: return .amount
        case .upPct, .downPct: return .percent
        }
    }

    /// 弹窗里的行标题
    public var title: String {
        switch self {
        case .upPrice: return "价格上涨到"
        case .downPrice: return "价格下跌到"
        case .upAmount: return "当日涨额达"
        case .downAmount: return "当日跌额达"
        case .upPct: return "当日涨幅达"
        case .downPct: return "当日跌幅达"
        }
    }

    /// 阈值的单位后缀（用于设置页一览与通知正文）。
    ///
    /// ⚠ 价格类**故意留空**（显示「价格上涨到 5.20」），不给既有输出引入单位。
    public var unitSuffix: String {
        switch self {
        case .upPrice, .downPrice: return ""
        case .upAmount, .downAmount: return " 元"
        case .upPct, .downPct: return "%"
        }
    }

    /// 弹窗输入框的占位符（三个族别口径不同，混用会误导）
    public var placeholder: String {
        switch self {
        case .upPrice, .downPrice: return "如 5.20"
        case .upAmount, .downAmount: return "如 0.50,1.00"
        case .upPct, .downPct: return "如 1.00,3.00,5.00"
        }
    }

    /// 出厂默认重复方式（弹窗初次打开、以及用户没动那个下拉时的值）。
    ///
    /// · 价格类 → **单次**：价格是"到一个点位就完了"（到过即已告知）
    /// · 涨跌额 / 涨跌幅 → **每日重复**：这两个是"当日累计量"的水平线，
    ///   日内会**反复穿越**（跌破又涨回），设成单次会漏掉后面的穿越
    ///
    /// 只保留 Core 这一份定义，视图侧不要另写。
    public var defaultRepeat: AlertRepeat {
        switch self {
        case .upPrice, .downPrice: return .once
        case .upAmount, .downAmount, .upPct, .downPct: return .daily
        }
    }

    /// 通知标题。
    /// ⚠ 六个标题**两两不同**：用户可能同时设「涨 1 元」与「涨 5%」，
    ///   标题一样就分不出是哪条在响（有单测钉住）。
    public var notifyTitle: String {
        switch self {
        case .upPrice, .downPrice: return "到价提醒"
        case .upAmount: return "涨额提醒"
        case .downAmount: return "跌额提醒"
        case .upPct: return "涨幅提醒"
        case .downPct: return "跌幅提醒"
        }
    }

    /// 通知正文里"往哪个方向"的措辞
    var directionWord: String {
        switch self {
        case .upPrice: return "涨到"
        case .downPrice: return "跌到"
        case .upAmount: return "涨额达"
        case .downAmount: return "跌额达"
        case .upPct: return "涨幅达"
        case .downPct: return "跌幅达"
        }
    }

    /// 通知正文里"当前值"的引导词
    var nowPrefix: String {
        switch self {
        case .upPrice, .downPrice: return "现价"
        case .upAmount, .downAmount, .upPct, .downPct:
            return self == .upAmount || self == .upPct ? "现涨" : "现跌"
        }
    }
}

/// 提醒类型的**族别** —— 见 `AlertKind.family`。
///
/// ⚠ 用独立枚举而不是若干个 `Bool`：`Bool` 允许"两个都是 true / 两个都是 false"这种
///   不存在的状态，而族别是**互斥且穷尽**的。三处族别相关的行为
///   （校验范围 / 默认重复方式 / 文案格式）都挂在它上面。
public enum AlertFamily: String, CaseIterable, Sendable {
    /// 绝对价格（元）
    case price
    /// 当日涨跌额（元）。⚠ 与 `turnover`（成交额，万元）**不是一回事**，别混
    case amount
    /// 当日涨跌幅（%）
    case percent
}

/// 重复方式。题面要求「单次提醒 / 交易日重复」。
///
/// ⚠ **必须落库才能成立**：只靠内存态去重，App 一退就清空 ——
/// 那只是"本次运行内一次"，不是"单次"。
public enum AlertRepeat: String, CaseIterable, Sendable {
    case once
    case daily

    public var title: String {
        switch self {
        case .once: return "单次"
        case .daily: return "每日重复"
        }
    }
}

/// 提醒时间窗。
///
/// ⚠ **三种窗口都只在交易日评估**（`AlertEval` 的第一道闸门）——
/// 否则「每日重复」会在周末拿周五收盘价再弹一次。
/// ⚠ 时段口径 09:30–11:30 / 13:00–15:00，**含午休跳过**，全项目只保留这一套，勿另写第二份。
public enum AlertWindow: String, CaseIterable, Sendable {
    /// 随时提醒：交易时段内**不限子时段**
    case anytime
    /// 开盘提醒：09:30–10:00
    case open
    /// 尾盘提醒：14:30–15:00
    case tail

    public var title: String {
        switch self {
        case .anytime: return "随时提醒"
        case .open: return "开盘提醒"
        case .tail: return "尾盘提醒"
        }
    }

    /// 覆盖的分钟区间（0..1439，北京时间）。用数组是因为上午/下午**不连续**。
    public var minuteRanges: [ClosedRange<Int>] {
        switch self {
        case .anytime: return Self.sessionRanges
        case .open:    return [570...600]              // 09:30–10:00
        case .tail:    return [870...900]              // 14:30–15:00
        }
    }

    /// A 股交易时段（09:30–11:30 / 13:00–15:00）—— **全项目唯一一份定义**。
    /// 视图侧与 `AlertMonitor` 都走它，抄第二份必然漂移。
    public static let sessionRanges: [ClosedRange<Int>] = [570...690, 780...900]

    /// 某分钟是否在交易时段内
    public static func inSession(minuteOfDay m: Int) -> Bool {
        sessionRanges.contains { $0.contains(m) }
    }

    public func contains(minuteOfDay m: Int) -> Bool {
        minuteRanges.contains { $0.contains(m) }
    }
}

/// 一条**已落库**的提醒规则（含触发状态）。
public struct AlertRule: Equatable, Sendable {
    public let kind: AlertKind
    public let threshold: Double
    public let repeatMode: AlertRepeat
    /// `yyyy-MM-dd HH:mm:ss`；**空串 = 从未触发**
    public let lastFiredAt: String
    /// `yyyy-MM-dd`（交易日口径）；**空串 = 从未触发**
    public let lastFiredDay: String

    public init(kind: AlertKind, threshold: Double, repeatMode: AlertRepeat,
                lastFiredAt: String = "", lastFiredDay: String = "") {
        self.kind = kind
        self.threshold = threshold
        self.repeatMode = repeatMode
        self.lastFiredAt = lastFiredAt
        self.lastFiredDay = lastFiredDay
    }

    /// 剥掉触发状态，得到"用户填的那部分"（回填弹窗初值用）
    public var draft: AlertDraft {
        AlertDraft(kind: kind, threshold: threshold, repeatMode: repeatMode)
    }

    /// 当前是否**待触发**（去重的唯一判据）。
    ///
    /// · `once`：从未触发过才可再触发（触发一次后**永久**哑火，直到用户重新保存该条）
    /// · `daily`：今天还没触发过才可再触发
    ///
    /// ⚠ `day` 为空时**一律判未武装**：那是调用方没给日期（编程错误）。
    ///   两种失效方向里，"不响"比"每 5 秒响一次"安全得多。
    public func isArmed(day: String) -> Bool {
        guard !day.isEmpty else { return false }
        switch repeatMode {
        case .once: return lastFiredAt.isEmpty
        case .daily: return lastFiredDay != day
        }
    }
}

/// 用户填的规则（**不含**触发状态）。
///
/// 单独一个类型是为了让「保存时不许把触发状态带进来」由**类型系统**保证：
/// 带进来的后果是每次编辑都会重新武装，而那种错**不会报错**。
public struct AlertDraft: Equatable, Sendable {
    public let kind: AlertKind
    public let threshold: Double
    public let repeatMode: AlertRepeat

    public init(kind: AlertKind, threshold: Double, repeatMode: AlertRepeat) {
        self.kind = kind
        self.threshold = threshold
        self.repeatMode = repeatMode
    }
}

// MARK: - 输入解析

/// 解析结果。**空 ≠ 错**：空串表示"删掉这一条"，非法则显式失败。
public enum AlertParseResult: Equatable, Sendable {
    /// 空输入 → 该条规则删除（不是错误）
    case empty
    /// 去重 + 升序后的阈值
    case ok([Double])
    /// 显式失败，带原因（界面**逐行**显示，不静默丢弃、不静默截断）
    case invalid(String)
}

public enum AlertInput {

    /// 单条规则最多几个阈值。超过**报错**，不静默截断 ——
    /// 静默截断会让用户以为"填进去了"，而实际只生效前 N 个。
    public static let maxThresholds = 10

    /// 解析逗号分隔的多值输入。
    ///
    /// 宽容之处（都是有意的）：
    ///   · **全角逗号 `，`、顿号 `、` 一并当分隔符**（中文输入法下这是常态）
    ///   · 空段直接跳过（`5,,7` 视作 `5,7`）
    ///   · 前后空白去掉
    ///
    /// 严格之处（都是必须的）：
    ///   · 解析不出数字 → `.invalid`，把**出错的那一段**原样回显
    ///   · 价格与涨跌额必须 `> 0`；百分比必须 `(0, 100]`
    ///   · ⚠ **必须排除 `inf` / `nan`**：`Double("inf")` 解析成功，而 NaN 参与比较
    ///     恒为 false → 落库后是一条**永不触发**的规则，界面上却显示得好好的
    public static func parse(_ text: String, kind: AlertKind) -> AlertParseResult {
        let normalized = text
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "、", with: ",")
        let tokens = normalized
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return .empty }

        var values: [Double] = []
        for t in tokens {
            guard let v = Double(t), v.isFinite else {
                return .invalid("「\(t)」不是有效数字")
            }
            // ⚠ 穷尽 switch（无 default）—— 加新族别时编译器会在这里报错，
            //   逼人明确"这个新族别的取值范围是什么"，而不是默默沿用上一个分支。
            switch kind.family {
            case .percent:
                guard v > 0, v <= 100 else {
                    return .invalid("「\(t)」超出范围（百分比需在 0 与 100 之间）")
                }
            case .price:
                guard v > 0 else { return .invalid("「\(t)」超出范围（价格需大于 0）") }
            case .amount:
                guard v > 0 else { return .invalid("「\(t)」超出范围（涨跌额需大于 0）") }
            }
            if !values.contains(v) { values.append(v) }
        }
        guard values.count <= maxThresholds else {
            return .invalid("最多 \(maxThresholds) 个值，当前 \(values.count) 个")
        }
        return .ok(values.sorted())
    }

    /// 阈值数组 → 输入框回显文本。
    ///
    /// ⚠ `digits` 由调用方按**标的**给（价格族阈值 = `StockFmt.priceDigits`）：
    ///   写死 2 位会让场内基金（净值 3 位）的阈值回显成 `1.05`，用户存回去就把
    ///   `1.052` 静默改成 `1.05`。默认 2 = 百分比/金额族沿用旧口径。
    public static func format(_ values: [Double], digits: Int = 2) -> String {
        values.sorted().map { String(format: "%.\(digits)f", $0) }.joined(separator: ",")
    }
}

// MARK: - 新旧规则合并（**本模块最容易静默出错的一处**）

public enum AlertMerge {

    /// 保存时把**未变**规则的触发状态继承过来。
    ///
    /// 判据：`(kind, threshold, repeatMode)` **三者全同**才继承。
    /// 任一不同 = 用户改了语义 → **重新武装**（改了阈值就按新阈值重新算）。
    ///
    /// ⚠ 漏了继承**不会报错、不会崩、界面全对** —— 只是「每日重复」退化成
    /// "每次保存后都能再响一次"（`lastFiredDay` 被清成空串），故有单测钉住。
    public static func carryOver(existing: [AlertRule], drafts: [AlertDraft]) -> [AlertRule] {
        var old: [String: AlertRule] = [:]
        for r in existing { old[key(r.kind, r.threshold, r.repeatMode)] = r }
        return drafts.map { d in
            let prev = old[key(d.kind, d.threshold, d.repeatMode)]
            return AlertRule(kind: d.kind, threshold: d.threshold, repeatMode: d.repeatMode,
                             lastFiredAt: prev?.lastFiredAt ?? "",
                             lastFiredDay: prev?.lastFiredDay ?? "")
        }
    }

    private static func key(_ k: AlertKind, _ t: Double, _ r: AlertRepeat) -> String {
        "\(k.rawValue)|\(alertThresholdKey(t))|\(r.rawValue)"
    }
}

/// 阈值 → 稳定字符串键。
///
/// ⚠ 不用 `String(describing:)`：它对 `5.0` / `5` 的产出依赖类型推断路径，
/// 而这个键要**跨进程、跨读写**稳定。
/// 统一 `%.4f` —— 与"阈值最多两位小数"的界面口径相容，且与 REAL 列的精度相容。
public func alertThresholdKey(_ v: Double) -> String { String(format: "%.4f", v) }
