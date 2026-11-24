import Foundation

/// 风险等级 —— rawValue = **线上值**（参数表 `strategies.*.risk` 的取值，也是
/// `watch_judgments.risk_level` 与各阶段 JSON `risk_level` 的落库值）。
///
/// 取值域的唯一来源：`strategies` 表那一列的下拉选项直接由 `RiskLevel.allCases` 生成 ——
/// "新增一个风险档"不可能只加在一处。
///
/// `init?(rawValue:)` 就是唯一解析器：缺失 / 空串 / 未识别 → nil，
/// 调用点保留各自原有回落（配色 → 次级 / 复盘不加分），**不引入新默认值**。
/// ⚠ 引擎不做改写：参数表里真正写了什么就落什么，枚举只服务解析 / 分支 / 配色。
public enum RiskLevel: String, Sendable, CaseIterable {
    case low = "低"
    case medium = "中"
    case high = "高"
    case extreme = "极高"

    /// 从 JSON/字典落库值解析（缺失 / 非字符串 / 空串 / 未识别 → nil）
    public init?(json: Any?) {
        guard let s = json as? String, let v = RiskLevel(rawValue: s) else { return nil }
        self = v
    }
}

/// 参数中心里 `json` 类型参数的**展示层元数据**（结构化编辑器用）。
///
/// ## 为什么不放进 schema（`engine/params/param_schema_export.json`）
///
/// - 这里是**展示**信息（中文标签 / 单位 / 枚举选项 / 控件形状），
///   不是参数元数据（键 / 类型 / 范围 / 默认值）—— 后者才是 schema 的职责
/// - schema 结构里**没有**"子键标签"这个字段，塞进去要扩 schema 结构
/// - 既有先例：`ParamEditorSheet` 里 `num_pair` 的「下限 / 上限」占位文案就是 Swift 侧硬编码
///
/// ## 放在 `SelectedCore` 而不是 `SelectedApp` 的原因
///
/// 它是**纯数据**（零 UI 依赖，不 import SwiftUI），放 Core 才能被
/// `Tests/SelectedCoreTests` 覆盖到 —— 而覆盖性断言是本文件最重要的护栏（见下）。
///
/// ## ⚠ 漂移防护（两道）
///
/// 1. `ParamTableSpecsTests` 断言本文件的键集合 **== schema 里 `type == "json"` 的键集合**。
///    将来新增 json 参数忘了配 specs → **测试红**，而不是悄悄退回裸 JSON 文本框。
/// 2. 形状 `.thresholdTable` 的键名规则**不在这里重复实现** —— 解析/拼接走
///    `Screener.keyThreshold` / `Screener.thresholdKey`（紧邻放置，编解码同源）。
///
/// 未知子键**不隐藏**（用键名原样显示），所以 specs 不必覆盖到子键粒度。
public enum ParamTableSpecs {

    // MARK: - 元数据类型

    /// 分值框的正负倾向 —— **只用于提示，不阻断输入**
    /// （标定结论可能就是要给负分，比如 `tail_vol_ratio_score`）
    public enum Sign: String, Sendable {
        case bonus      // 加分表：期望正数
        case penalty    // 扣分表：期望负数
        case any        // 不提示
    }

    /// 子键的控件类型
    public enum FieldKind: Equatable, Sendable {
        case number
        case percent
        /// `["HH:MM", "HH:MM"]`
        case timePair
        /// 固定枚举（下拉，防手滑写错）
        case choice([String])
        /// 自由文案（单行文本）
        case text
    }

    /// 命名行（形状 B / C-2）：键名固定，一行一个字段
    public struct Field: Equatable, Sendable {
        public let key: String
        public let label: String
        public var kind: FieldKind
        public var unit: String
        public var note: String

        public init(key: String, label: String, kind: FieldKind = .number,
                    unit: String = "", note: String = "") {
            self.key = key; self.label = label; self.kind = kind
            self.unit = unit; self.note = note
        }
    }

    /// 表格的行（形状 C-1 的策略行）
    public struct Row: Equatable, Sendable {
        public let key: String
        public let label: String
        public init(key: String, label: String) { self.key = key; self.label = label }
    }

    /// 表格的列
    public struct Column: Equatable, Sendable {
        public let key: String
        public let label: String
        public var kind: FieldKind
        /// 该字段的**控件宽度**（pt）。
        ///
        /// ⚠ 名字叫 Column，实际渲染是**逐行分块**而不是横向表格 ——
        /// 参数 sheet 只有 580pt 宽，6 列横排每列只剩 ~80pt，
        /// 「操作提示」这种文案字段会挤成一条缝。分块后每个字段都有正常宽度。
        public var width: Double

        public init(key: String, label: String, kind: FieldKind = .number, width: Double = 70) {
            self.key = key; self.label = label; self.kind = kind; self.width = width
        }
    }

    /// 控件形状 —— 决定参数中心里这一项渲染成什么
    public enum Shape: Equatable, Sendable {
        /// **阈值→分值表**：键名编码阈值（`le1` / `gt15` / `le_neg5`），可增删档位
        case thresholdTable(unit: String, sign: Sign)
        /// **命名行**：键名固定，每个键一个中文标签
        case namedFields([Field])
        /// **行 × 列 表格**
        case table(rows: [Row], columns: [Column])
    }

    // MARK: - 12 项元数据

    /// 键 = 参数点路径（与 schema 的 `item.key` 完全一致）
    public static let all: [String: Shape] = [

        // ── 形状 A：阈值→分值表（6 项）
        // 键名编码阈值，见 `Screener.keyThreshold`。`unit` 是**阈值**的单位（分值是"分"）。
        "scoring.bonus.consec_up":      .thresholdTable(unit: "天", sign: .bonus),
        "scoring.bonus.cum_5d":         .thresholdTable(unit: "%",  sign: .bonus),
        "scoring.bonus.dist_low":       .thresholdTable(unit: "%",  sign: .bonus),
        "scoring.bonus.dist_high":      .thresholdTable(unit: "%",  sign: .bonus),
        "scoring.penalty.prev_1d":      .thresholdTable(unit: "%",  sign: .penalty),
        "scoring.penalty.ma_deviation": .thresholdTable(unit: "%",  sign: .penalty),

        // ── 形状 B：参数化判据（4 项，键名固定）
        "scoring.penalty.stagnation": .namedFields([
            Field(key: "vol_ratio_min", label: "量比下限",
                  note: "当日量比低于此值不判滞涨"),
            Field(key: "gain_ratio", label: "涨幅比下限",
                  note: "涨幅/振幅比低于此值才算「放量滞涨」"),
            Field(key: "score", label: "扣分", kind: .number,
                  note: "命中时加到总分的分值（负数）"),
        ]),
        "scoring.penalty.long_shadow": .namedFields([
            Field(key: "vol_ratio_min", label: "量比下限",
                  note: "量比达到此值才检查上影线"),
            Field(key: "shadow_body", label: "影线/实体比下限"),
            Field(key: "score", label: "扣分", kind: .number),
        ]),
        "scoring.penalty.vol_shrink": .namedFields([
            Field(key: "threshold", label: "量比阈值", note: "低于此值视为缩量"),
            Field(key: "score", label: "扣分", kind: .number),
        ]),
        "scoring.penalty.cum_5d_low": .namedFields([
            Field(key: "threshold", label: "5日累计涨幅阈值", kind: .percent,
                  note: "低于此值视为涨幅不足"),
            Field(key: "score", label: "扣分", kind: .number),
        ]),

        // ── 形状 C-1：早盘预判策略表（5 行 × 6 列）
        // `direction` / `risk` / `position` 三个字段**被引擎消费**
        // （`PredictRules.buildStrategy` → 输出 `predict_direction` / `risk_level` / `position_advice`），
        // 所以它们是**参数**而不是展示文案 —— 给它们像样的控件（下拉 / 文本框），不让人手写 JSON。
        "predict_rules.strategies": .table(
            rows: [
                Row(key: "up_consensus",   label: "上涨 · 持续"),
                Row(key: "up_pulse",       label: "上涨 · 脉冲"),
                Row(key: "down_consensus", label: "下跌 · 持续"),
                Row(key: "down_pulse",     label: "下跌 · 脉冲"),
                Row(key: "crash",          label: "暴跌日"),
            ],
            columns: [
                Column(key: "window",     label: "卖出窗口", kind: .timePair, width: 130),
                Column(key: "target_pct", label: "目标价",   kind: .percent,  width: 76),
                Column(key: "stop_pct",   label: "止损价",   kind: .percent,  width: 76),
                Column(key: "risk",       label: "风险",
                       kind: .choice(RiskLevel.allCases.map(\.rawValue)), width: 110),
                Column(key: "position",   label: "仓位",
                       kind: .choice(["正常仓位", "半仓", "轻仓", "空仓观望"]), width: 110),
                Column(key: "direction",  label: "操作提示", kind: .text,     width: 300),
            ]),

        // ── 形状 C-3：大盘状态门槛浮动（5 态 × 3 调整量）
        // 符号约定：**负 = 降门槛**（更容易止盈、更容易买入），正 = 升门槛。
        // 单位：target_adj / stop_adj 是**百分点**，score_adj 是**分**。
        // ⚠ 引擎侧 `PredictRules.defaultRegimeThresholds` 是同一份默认值，
        //   `ParamTableSpecsTests` 有断言钉住两处一致。
        "predict_rules.regime_thresholds": .table(
            rows: [
                Row(key: "BULL_TREND",      label: "多头趋势"),
                Row(key: "BULL_CORRECTION", label: "多头回调"),
                Row(key: "BEAR_TREND",      label: "空头趋势"),
                Row(key: "PANIC",           label: "恐慌"),
                Row(key: "RECOVERY",        label: "修复反弹"),
            ],
            columns: [
                Column(key: "target_adj", label: "目标价", kind: .percent, width: 84),
                Column(key: "stop_adj",   label: "止损价", kind: .percent, width: 84),
                Column(key: "score_adj",  label: "打分线", kind: .number,  width: 84),
            ]),

        // ── 形状 C-2：三日迭代阈值（12 个命名行）
        "iterate.thresholds": .namedFields([
            Field(key: "window_vs_snap",        label: "窗口优于跳空", kind: .percent,
                  note: "窗口收益 − 跳空收益 超过此值 → 记为「窗口更优」"),
            Field(key: "window_vs_close",       label: "窗口优于收盘", kind: .percent),
            Field(key: "high_vs_window",        label: "最高点优于窗口", kind: .percent),
            Field(key: "low_winrate",           label: "低胜率线", kind: .percent,
                  note: "窗口胜率低于此值 → 触发警示"),
            Field(key: "low_high_winrate",      label: "低高点胜率线", kind: .percent),
            Field(key: "group_market",          label: "大盘归因组差异", kind: .percent),
            Field(key: "group_signal",          label: "信号归因组差异", kind: .percent),
            Field(key: "morning_ratio",         label: "晨间高点占比",
                  note: "0.6 = 60% 的高点落在上午则归因晨间"),
            Field(key: "afternoon_ratio",       label: "午后高点占比"),
            Field(key: "discipline_target_pct", label: "纪律目标幅度", kind: .percent),
            Field(key: "avg_profit_cap",        label: "平均收益封顶", kind: .percent),
            Field(key: "discipline_window",     label: "纪律窗口", kind: .timePair),
        ]),
    ]

    // MARK: - 查询

    /// 该参数是否有结构化编辑器（没有 → 退回原来的裸 JSON 文本框）
    public static func has(_ key: String) -> Bool { all[key] != nil }

    public static func shape(_ key: String) -> Shape? { all[key] }

    // MARK: - 时间区间校验

    /// 解析严格 `HH:mm`（5 位 ASCII 数字+冒号，`00:00`–`23:59`）为自 00:00 起的分钟数。
    /// 与 `PhaseReview.minutes` 同口径（禁止全角/缺前导零，避免字符串比较静默错位）。
    public static func parseClockMinutes(_ s: String) -> Int? {
        let bytes = Array(s.utf8)
        guard bytes.count == 5, bytes[2] == UInt8(ascii: ":") else { return nil }
        func twoDigits(_ a: UInt8, _ b: UInt8) -> Int? {
            let zero = UInt8(ascii: "0"), nine = UInt8(ascii: "9")
            guard a >= zero && a <= nine && b >= zero && b <= nine else { return nil }
            return Int(a - zero) * 10 + Int(b - zero)
        }
        guard let h = twoDigits(bytes[0], bytes[1]),
              let m = twoDigits(bytes[3], bytes[4]),
              h < 24, m < 60 else { return nil }
        return h * 60 + m
    }

    /// 校验时间区间对 `["HH:mm", "HH:mm"]`（或暴跌日占位 `["--", "--"]`）；返回 nil = 合法。
    public static func timePairProblem(start: String, end: String) -> String? {
        let s = start.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = end.trimmingCharacters(in: .whitespacesAndNewlines)
        if s == "--" && e == "--" { return nil }
        guard let sm = parseClockMinutes(s), let em = parseClockMinutes(e) else {
            return "时间格式应为 HH:mm（如 09:30，或双 -- 停用）"
        }
        if sm > em {
            return "起止时间倒挂：\(s) 晚于 \(e)"
        }
        return nil
    }

    /// 从 JSON 数组校验 `.timePair`；返回 nil = 合法。
    public static func timePairProblem(_ value: Any) -> String? {
        guard let arr = value as? [Any], arr.count == 2,
              let s = arr[0] as? String, let e = arr[1] as? String else {
            return "应为两个时间字符串 [开始, 结束]"
        }
        return timePairProblem(start: s, end: e)
    }

    // MARK: - 形状校验（编辑器在保存前调用；返回 nil = 合法）

    /// 结构化值是否满足**形状要求**。
    ///
    /// ⚠ 这是**编辑器侧的前置检查**，不替代 `ParamSchema.validate`：
    ///   `validate` 管"键在不在、类型对不对"（权威）；这里只管"控件能不能渲染、
    ///   键名能不能被引擎解析"——两者**故意重叠**，因为编辑器要在用户改的当下就标红，
    ///   而不是等保存时才报错。
    public static func problem(_ key: String, value: Any) -> String? {
        guard let shape = all[key] else { return nil }

        switch shape {
        case .thresholdTable:
            guard let dict = value as? [String: Any] else { return "应为 JSON 对象" }
            if dict.isEmpty { return "表不能为空（至少一档）" }
            for (k, v) in dict {
                guard let parsed = Screener.keyThreshold(k) else {
                    return "阈值键「\(k)」无法解析（应形如 le1 / gt15 / le_neg5）"
                }
                guard let n = asNumber(v) else { return "「\(k)」的分值应为数值" }
                if n.isFinite == false { return "「\(k)」的分值不是有限数" }
                // 与 keyThreshold 严格互逆：拼回去必须得到同一个键名
                if Screener.thresholdKey(op: parsed.op, threshold: parsed.threshold) != k {
                    return "阈值键「\(k)」不是规范写法（应写成 "
                         + (Screener.thresholdKey(op: parsed.op, threshold: parsed.threshold) ?? "?") + "）"
                }
            }
            return nil

        case .namedFields(let fields):
            guard let dict = value as? [String: Any] else { return "应为 JSON 对象" }
            for f in fields {
                guard let raw = dict[f.key] else {
                    return "缺少「\(f.label)」（\(f.key)）"
                }
                if f.kind == .timePair, let why = timePairProblem(raw) {
                    return "「\(f.label)」\(why)"
                }
            }
            return nil

        case .table(let rows, let columns):
            guard let dict = value as? [String: Any] else { return "应为 JSON 对象" }
            for r in rows {
                guard let row = dict[r.key] as? [String: Any] else {
                    return "缺少「\(r.label)」（\(r.key)）"
                }
                for c in columns {
                    guard let raw = row[c.key] else {
                        return "「\(r.label)」缺少「\(c.label)」（\(c.key)）"
                    }
                    if c.kind == .timePair, let why = timePairProblem(raw) {
                        return "「\(r.label) · \(c.label)」\(why)"
                    }
                }
            }
            return nil
        }
    }

    /// `NSNumber` 也会桥接 `Bool`，所以这里显式排除 —— 与 `JSONValue` 的取值语义一致
    private static func asNumber(_ v: Any) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
}
