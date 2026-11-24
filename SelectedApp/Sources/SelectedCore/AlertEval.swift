import Foundation

// MARK: - 提醒触发判据（纯函数）
//
// 本文件是**唯一**的触发判定实现。App 层的 `AlertMonitor` 只负责
// "取行情 → 调这里 → 落库 → 弹通知"，不做任何判据。判据保持纯函数，
// 以便被 `swift test` 覆盖、并在任何页面评估。

/// 待评估的一只标的（行情 + 规则 + 时间窗）
public struct AlertSubject: Equatable, Sendable {
    public let code: String
    public let name: String
    /// 现价。**`0` 表示取不到行情** → 一律不评估（否则"跌破"类规则会拿 0 当价格触发）
    public let price: Double
    /// 当日涨跌**额**（元，`-0.10` = 跌 1 毛）。取**接口原值** `StockQuote.change`（腾讯 `f[31]`）。
    ///
    /// ⚠ 判据必须与用户看到的那个数同源：自选表「涨跌额」列与详情页显示的就是
    ///   `q.change`；`f[31]` 缺失时解析回落 0、界面也显示 0.00，两边一致。
    ///   若改成自算 `price - previousClose`，缺失时会出现"界面显示 0.00、判据按真实差额判"的分叉。
    public let changeAmount: Double
    /// 当日涨跌幅（百分比数值，`-3.12` = 跌 3.12%）
    public let changePercent: Double
    public let rules: [AlertRule]
    public let window: AlertWindow

    public init(code: String, name: String, price: Double, changeAmount: Double,
                changePercent: Double, rules: [AlertRule], window: AlertWindow) {
        self.code = code
        self.name = name
        self.price = price
        self.changeAmount = changeAmount
        self.changePercent = changePercent
        self.rules = rules
        self.window = window
    }
}

/// 评估时刻（**注入**而不是内部读时钟 → 判据完全可测、无时区依赖）
public struct AlertClock: Equatable, Sendable {
    /// `yyyy-MM-dd`（北京时间）
    public let day: String
    /// 北京时间当日已过分钟数（0..1439）
    public let minuteOfDay: Int
    /// 当日是否交易日。
    ///
    /// ⚠ 由调用方提供而不是在这里算：`DataSources.isTradingDay()` **会发网络请求**，
    ///   5 秒一次的评估循环里不能直接调；`AlertMonitor` 按天缓存并注入。
    public let isTradingDay: Bool
    /// `yyyy-MM-dd HH:mm:ss`，写入 `last_fired_at`
    public let stamp: String

    public init(day: String, minuteOfDay: Int, isTradingDay: Bool, stamp: String) {
        self.day = day
        self.minuteOfDay = minuteOfDay
        self.isTradingDay = isTradingDay
        self.stamp = stamp
    }
}

/// 一次触发（App 层拿它落库 + 弹通知）
public struct AlertFiring: Equatable, Sendable {
    public let code: String
    public let name: String
    public let kind: AlertKind
    public let threshold: Double
    public let price: Double
    /// 触发时的当日涨跌额（元）—— 与 `AlertSubject.changeAmount` 同源（接口 `f[31]`）
    public let changeAmount: Double
    public let changePercent: Double
    public let repeatMode: AlertRepeat
    public let firedAt: String
    public let day: String

    public init(code: String, name: String, kind: AlertKind, threshold: Double,
                price: Double, changeAmount: Double, changePercent: Double,
                repeatMode: AlertRepeat, firedAt: String, day: String) {
        self.code = code
        self.name = name
        self.kind = kind
        self.threshold = threshold
        self.price = price
        self.changeAmount = changeAmount
        self.changePercent = changePercent
        self.repeatMode = repeatMode
        self.firedAt = firedAt
        self.day = day
    }

    /// 会话内去重键。
    ///
    /// ⚠ 这是**第二层**去重（第一层是库里的 `last_fired_*`）：库写入失败时，
    ///   若只靠库里那层，规则会每 5 秒重新触发一次 → 通知轰炸。
    public var dedupKey: String {
        let base = "\(code)|\(kind.rawValue)|\(alertThresholdKey(threshold))"
        return repeatMode == .daily ? "\(base)|\(day)" : base
    }

    /// 通知去重标识（交给 `Notifier` 作 `identifier`）。
    ///
    /// ⚠ 必须**按规则稳定**：`Notifier` 对同一 identifier 的请求会被系统**替换**而不是堆叠，
    /// 这正是"同一只票同一条规则反复触发只留最新一条"的语义。
    public var identifier: String {
        "selected.alert.\(code).\(kind.rawValue).\(alertThresholdKey(threshold))"
    }

    public var title: String { kind.notifyTitle }

    /// 通知正文。名称缺失时回落代码（与 `WatchItemRow.displayName` 同口径）。
    ///
    /// ⚠ 必须**按 `kind.family` 穷尽 switch，不要用 `if isPercent`**：新增族别会静默
    ///   落进 else 分支，产出骗人的文案且不报错、不崩。
    public var body: String {
        let n = name.isEmpty ? code : name
        let t: String
        let now: String
        switch kind.family {
        case .price:
            // 小数位跟着标的走：提醒对象可以是场内基金（净值 3 位），写死 %.2f
            // 会让推送正文把 1.052 报成 1.05 —— 与它自己要核对的阈值对不上
            t = StockFmt.price(threshold, code: code)
            now = StockFmt.price(price, code: code)
        case .amount:
            t = String(format: "%.2f", threshold) + kind.unitSuffix
            // 取绝对值：方向已由 `directionWord` 表达，再带负号会读成双重否定
            now = String(format: "%.2f", abs(changeAmount)) + kind.unitSuffix
        case .percent:
            t = String(format: "%.2f%%", threshold)
            now = String(format: "%.2f%%", abs(changePercent))
        }
        let tail = kind.family == .price ? "现价 \(now)" : "\(kind.nowPrefix) \(now)"
        return "\(n) \(kind.directionWord) \(t)（\(tail)）"
    }
}

public enum AlertEval {

    /// 批量评估。返回**本次应当触发**的条目（已过滤窗口、交易日、去重状态、无行情）。
    ///
    /// 调用方拿到结果后要做两件事：① 落库记 `last_fired_*`；② 弹通知。
    /// 顺序在 `AlertMonitor` 里定（先落库，避免写失败时反复轰炸）。
    public static func evaluate(_ subjects: [AlertSubject], at clock: AlertClock) -> [AlertFiring] {
        // ⚠ 非交易日一律不评估：否则「每日重复」会在周末拿周五收盘价再弹一次。
        guard clock.isTradingDay, !clock.day.isEmpty else { return [] }

        var out: [AlertFiring] = []
        for s in subjects {
            guard !s.code.isEmpty else { continue }
            // ⚠ 无行情（price == 0 / 非有限）→ 跳过，否则 `price <= threshold` 恒真，
            //   一次行情抖动就会把所有"跌破"规则全部触发。
            guard s.price > 0, s.price.isFinite else { continue }
            guard s.changeAmount.isFinite, s.changePercent.isFinite else { continue }
            guard s.window.contains(minuteOfDay: clock.minuteOfDay) else { continue }
            for r in s.rules {
                guard r.isArmed(day: clock.day) else { continue }
                guard triggered(r.kind, threshold: r.threshold,
                                price: s.price,
                                changeAmount: s.changeAmount,
                                changePct: s.changePercent) else { continue }
                out.append(AlertFiring(code: s.code, name: s.name, kind: r.kind,
                                       threshold: r.threshold, price: s.price,
                                       changeAmount: s.changeAmount,
                                       changePercent: s.changePercent,
                                       repeatMode: r.repeatMode,
                                       firedAt: clock.stamp, day: clock.day))
            }
        }
        return out
    }

    /// 单条判据。**闭区间** —— "涨到 5.00" 含 5.00（`>=` 不是 `>`）。
    ///
    /// ⚠ `downPct` / `downAmount` 的阈值在界面与库里都存**正数**，比较时才取负。
    /// ⚠ 六个 case **穷尽、无 `default:`** —— 新增类型时编译器在这里报错。
    public static func triggered(_ kind: AlertKind, threshold: Double,
                                 price: Double,
                                 changeAmount: Double,
                                 changePct: Double) -> Bool {
        switch kind {
        case .upPrice:    return price >= threshold
        case .downPrice:  return price <= threshold
        case .upAmount:   return changeAmount >= threshold
        case .downAmount: return changeAmount <= -threshold
        case .upPct:      return changePct >= threshold
        case .downPct:    return changePct <= -threshold
        }
    }
}
