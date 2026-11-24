import Foundation

/// 预判口径的纯函数：`fresh3dTrend` / `classifyMarketLight` / `buildStrategy`。
///
/// **为什么单独抽出来**：这三者同时被自选判定（`WatchJudge`）与早盘预判（`PhasePredict`）
/// 使用，必须只有一份实现 —— 各写一份必然漂移出「预判页红灯、自选页绿灯」这类两页打架的故障。
public enum PredictRules {

    /// 现算大盘 3 日趋势（截至昨日的最近 3 个完成交易日）。
    ///
    /// ⚠ **不读参数**里的 lookback / decline_days（固定 3 / 2）：
    ///   红灯阈值那条在 `classifyMarketLight` 里读 `rules["red_decline_days"]`。
    public static func fresh3dTrend(todayChangePct: Double) -> EngineIndicators.MarketDecline {
        let kline = DataSources.fetchIndexDailyKline(symbol: "sh000001",
                                                     datalen: indexKlineDatalen)
        return EngineIndicators.marketConsecutiveDecline(
            kline, todayChangePct: todayChangePct, lookback: 3,
            // 「当日」走**回放感知**取法：正常模式 = 墙上时钟（**不能改**），回放模式 = 回放日。
            // 用墙上时钟做回放会让回放日那根 bar 既进 deltas 又被当成 todayChangePct
            // 加一次 —— 同一个交易日被数两遍。见 `HistoryReplayMode.currentDay`。
            today: HistoryReplayMode.currentDay, declineDays: 2)
    }

    // MARK: - 市场状态机

    /// 指数日K请求根数 —— **扫描 / 预判 / 自选三处共用**，故是同一个 `cacheKey`，
    /// 一个交易日只取一次。
    ///
    /// 为什么是 70：市场状态机要算 MA60 的 5 日斜率 → 至少 `60 + 5 = 65` 根**已完成**日K。
    /// 取 70 留余量；`marketConsecutiveDecline` 只取 `suffix(lookback)`，多给不影响它。
    public static let indexKlineDatalen = 70

    /// MA 周期的阶梯（**从长到短**）—— 取历史能支持的最长那档
    public static let regimeMaLadder = [60, 20, 10]
    /// MA 斜率的回看根数
    public static let regimeSlopeLookback = 5

    /// 市场状态机结果（`regime` / `ma_period_used`）—— 两个键一起写进 `market_env`
    public struct MarketRegime {
        /// 五态之一；历史不足时为 `UNKNOWN`
        public var regime = "UNKNOWN"
        /// 实际用到的 MA 周期；历史不足时为 0
        public var maPeriodUsed = 0
        public var json: [String: Any] {
            ["regime": regime, "ma_period_used": maPeriodUsed]
        }
    }

    /// 红灯条件（`classifyMarketLight` 的第一分支）。
    ///
    /// **为什么抽出来**：`regime == "PANIC"` 与 `light == "红灯"` 必须是同一个判据 ——
    /// 各写一遍迟早漂移成"预判页红灯、状态机说 BEAR_TREND"。抽成一处后**结构上不可能不一致**。
    public static func isRedLight(consecutiveDecline: Bool, declineCount: Int,
                                  rules: [String: Any]) -> Bool {
        let redDays = num(rules["red_decline_days"]) ?? 2
        return consecutiveDecline && Double(declineCount) >= redDays
    }

    /// 市场状态机（**纯函数**）—— 只吃「已完成日K + 连跌信息」，不碰网络。
    ///
    /// ⚠ **纯附加**：不改 `light`、不改任何判定分支。它只多产出两个键，
    /// 供看板展示与「按 regime 浮动门槛」使用。
    ///
    /// 判定顺序（**红灯优先**）：
    ///   1. 红灯条件（连跌 ≥ `red_decline_days`）→ `PANIC`
    ///   2. 否则用「最新已完成收盘价 vs MA」×「MA 的 5 日斜率」：
    ///      价>MA 且 MA 上行 → `BULL_TREND`；价<MA 且 MA 上行 → `BULL_CORRECTION`
    ///      价<MA 且 MA 下行 → `BEAR_TREND`；价>MA 且 MA 下行 → `RECOVERY`
    ///
    /// MA 周期走 `regimeMaLadder`（60/20/10）**取历史能支持的最长**，要求
    /// `已完成根数 ≥ P + 5`（斜率要 5 根前的 MA）；连 10 都支持不了 → `UNKNOWN` / 0。
    ///
    /// 口径与 `marketConsecutiveDecline` 一致：**剔除当日未完成 bar**，只用已完成日K。
    public static func classifyRegime(kline: [KLineBar], today: String,
                                      consecutiveDecline: Bool, declineCount: Int,
                                      rules: [String: Any]) -> MarketRegime {
        var out = MarketRegime()
        let closes = kline.filter { $0.close != 0 && $0.day != today }.map(\.close)
        let lb = regimeSlopeLookback
        guard let period = regimeMaLadder.first(where: { closes.count >= $0 + lb }),
              let ma = EngineIndicators.sma(closes, period),
              let maPrev = EngineIndicators.sma(Array(closes.dropLast(lb)), period),
              let price = closes.last else {
            return out                                  // 历史不足 → UNKNOWN / 0
        }
        out.maPeriodUsed = period
        if isRedLight(consecutiveDecline: consecutiveDecline,
                      declineCount: declineCount, rules: rules) {
            out.regime = "PANIC"
            return out
        }
        let maUp = ma > maPrev
        let above = price > ma
        switch (above, maUp) {
        case (true, true):   out.regime = "BULL_TREND"
        case (false, true):  out.regime = "BULL_CORRECTION"
        case (false, false): out.regime = "BEAR_TREND"
        case (true, false):  out.regime = "RECOVERY"
        }
        return out
    }

    /// 现算市场状态机（自带取数）。`today` 必须与调用方算连跌时用的那个「当日」一致，
    /// 否则两侧剔掉的 bar 不同（fixture 模式下 `runDate()` 与 `ChinaTime.day()` 可能不同）。
    public static func freshRegime(_ trend: EngineIndicators.MarketDecline,
                                   today: String, rules: [String: Any]) -> MarketRegime {
        let kline = DataSources.fetchIndexDailyKline(symbol: "sh000001",
                                                     datalen: indexKlineDatalen)
        return classifyRegime(kline: kline, today: today,
                              consecutiveDecline: trend.shConsecutiveDecline,
                              declineCount: trend.sh3dDeclineCount, rules: rules)
    }

    // MARK: - 门槛浮动

    /// 按大盘状态浮动门槛的**默认表**（可被参数里的 `predict_rules.regime_thresholds` 覆盖）。
    ///
    /// | regime | `target_adj` | `stop_adj` | `score_adj` | 含义 |
    /// |--------|--------------|------------|-------------|------|
    /// | `BULL_TREND` | 0 | 0 | 0 | 基准，不动 |
    /// | `BULL_CORRECTION` | −1.0 | +0.5 | −3 | 多头回调：目标下调（早止盈）、止损放宽（别被正常回调扫出）、买入线放松 |
    /// | `BEAR_TREND` | +1.0 | −0.5 | +5 | 空头：目标上调（不轻易进场）、止损收紧 |
    /// | `PANIC` | +2.0 | −1.0 | +10 | 恐慌：**结构上不生效** —— `PANIC ⟺ 红灯`，卖出策略走 `crash`、自选走"全部空仓观望" |
    /// | `RECOVERY` | −0.5 | 0 | −2 | 修复反弹：略放松 |
    ///
    /// 单位：`target_adj` / `stop_adj` 是**百分点**（直接加到策略矩阵的 `target_pct` / `stop_pct`），
    /// `score_adj` 是**分**（加到自选的买入线 / 观察线）。
    /// 符号约定：**负 = 降门槛**（更容易止盈、更容易买入），正 = 升门槛。
    public static let defaultRegimeThresholds: [String: [String: Double]] = [
        "BULL_TREND":      ["target_adj": 0, "stop_adj": 0, "score_adj": 0],
        "BULL_CORRECTION": ["target_adj": -1.0, "stop_adj": 0.5, "score_adj": -3],
        "BEAR_TREND":      ["target_adj": 1.0, "stop_adj": -0.5, "score_adj": 5],
        "PANIC":           ["target_adj": 2.0, "stop_adj": -1.0, "score_adj": 10],
        "RECOVERY":        ["target_adj": -0.5, "stop_adj": 0, "score_adj": -2],
    ]

    /// 从生效参数里取门槛表：`predict_rules.regime_thresholds` 缺失 / 缺某一态 → **逐态回落默认表**。
    ///
    /// ⚠ 这是"工厂参数 + 读取处回落"模式（与 `iterate.tune_pool_days`、`phases` 同）——
    /// 不声明为 schema 项，所以**存量参数版本（含用户自存行）不会因为缺这个键而非法**。
    public static func regimeThresholds(from params: [String: Any])
        -> [String: [String: Double]] {
        var out = defaultRegimeThresholds
        // 键在 `predict_rules` 下（schema 项，进参数中心）
        guard let rules = params["predict_rules"] as? [String: Any],
              let raw = rules["regime_thresholds"] as? [String: Any] else { return out }
        for (regime, value) in raw {
            guard let d = value as? [String: Any] else { continue }
            var row = out[regime] ?? [:]
            for key in ["target_adj", "stop_adj", "score_adj"] {
                if let v = num(d[key]) { row[key] = v }
            }
            out[regime] = row
        }
        return out
    }

    /// 某状态下要加的三个偏移量。`UNKNOWN` / 空串 / 表里没有 → 全 0（**不动**，不是"猜一个"）。
    public static func regimeAdjustment(regime: String,
                                        thresholds: [String: [String: Double]])
        -> (targetAdj: Double, stopAdj: Double, scoreAdj: Double) {
        guard !regime.isEmpty, regime != "UNKNOWN", let row = thresholds[regime] else {
            return (0, 0, 0)
        }
        return (row["target_adj"] ?? 0, row["stop_adj"] ?? 0, row["score_adj"] ?? 0)
    }

    /// 红黄绿灯分级
    public static func classifyMarketLight(marketData: [String: Any], lastEnv: [String: Any],
                                    rules: [String: Any]) -> [String: Any] {
        let shOpenPct = num(marketData["sh_open_pct"]) ?? 0
        let openStatus = shOpenPct > 0.2 ? "高开" : (shOpenPct < -0.2 ? "低开" : "平开")

        let consec = bool(lastEnv["sh_consecutive_decline"]) ?? false
        let declineCount = int(lastEnv["sh_3d_decline_count"]) ?? 0
        let shOk = bool(lastEnv["sh_ok"]) ?? true
        let yellowThreshold = num(rules["yellow_open_threshold"]) ?? -0.5

        let light: MarketLightLevel, desc: String
        // 红灯判据抽到 `isRedLight`（市场状态机的 PANIC 用的是同一个）
        if isRedLight(consecutiveDecline: consec, declineCount: declineCount, rules: rules) {
            light = .red; desc = "大盘连跌≥2日，观望为主"
        } else if !shOk || shOpenPct < yellowThreshold {
            light = .yellow; desc = "大盘偏弱，降仓≤40%"
        } else {
            light = .green; desc = "大盘正常，可正常操作"
        }

        return [
            // ⚠ 这里恒为 Double —— 仅在"结果 JSON 的 0 vs 0.0"形态上有差异，不参与落库与判定
            "sh_open_pct": PyMath.round(shOpenPct, 2),
            "sh_change_pct": num(marketData["sh_change_pct"]) ?? 0,
            "open_status": openStatus,
            "sh_ok": shOk,
            "sh_3d_trend": lastEnv["sh_3d_trend"] ?? "未知",
            "sh_consecutive_decline": consec,
            "sh_3d_decline_count": declineCount,
            "light": light.rawValue, "light_desc": desc,
            "us_market": marketData["us_market"] ?? "",
        ]
    }

    /// 五分支卖出策略矩阵。
    ///
    /// **只有已确认持续的信号（strongest / consensus）才走 consensus 分支**；
    /// 未验证（轮次不足）与脉冲一律走 pulse（更短窗口、更小目标）。
    ///
    /// 目标价 / 止损价按大盘状态**浮动**（`predict_rules.regime_thresholds`）：
    /// `regime == UNKNOWN`（历史不足）时偏移恒为 0 —— 等同固定策略矩阵。
    public static func buildStrategy(marketClass: [String: Any], signalType: SignalType?,
                              selPrice: Double, strategies: [String: Any],
                              regimeThresholds: [String: [String: Double]] = defaultRegimeThresholds)
        -> [String: Any] {
        let isUp = (bool(marketClass["sh_ok"]) ?? true)
            && !(bool(marketClass["sh_consecutive_decline"]) ?? false)
        let isCrash = MarketLightLevel(json: marketClass["light"]) == .red
        // 缺失 / 空串 / 未识别 → 非「持续」→ 落 pulse 分支
        let isConsensus = signalType?.isVerified == true

        let key: String
        if isCrash {
            key = "crash"
        } else if isUp {
            key = isConsensus ? "up_consensus" : "up_pulse"
        } else {
            key = isConsensus ? "down_consensus" : "down_pulse"
        }

        guard let s = strategies[key] as? [String: Any] else {
            // strategies 缺子键时返回残缺字典；参数校验已把 5 个分支列为必填子键，正常不会走到
            return ["strategy_key": key]
        }
        let window = (s["window"] as? [Any]) ?? []
        // 大盘状态偏移（未知状态 → 0）。
        // ⚠ `crash` 分支**不做偏移**：它的仓位建议是"空仓"，目标价/止损价没有实际含义
        //   （PANIC ⟺ 红灯 → 恒走 crash）→ 让状态去"调"一个不进场的目标价纯属噪声。
        let adj = key == "crash" ? (targetAdj: 0.0, stopAdj: 0.0, scoreAdj: 0.0)
            : regimeAdjustment(regime: (marketClass["regime"] as? String) ?? "",
                               thresholds: regimeThresholds)
        let targetPct = (num(s["target_pct"]) ?? 0) + adj.targetAdj
        let stopPct = (num(s["stop_pct"]) ?? 0) + adj.stopAdj
        return [
            "strategy_key": key,
            "sell_window_start": window.count > 0 ? window[0] : NSNull(),
            "sell_window_end": window.count > 1 ? window[1] : NSNull(),
            "target_price": selPrice > 0 ? PyMath.round(selPrice * (1 + targetPct / 100), 2) : 0,
            "stop_loss_price": selPrice > 0 ? PyMath.round(selPrice * (1 + stopPct / 100), 2) : 0,
            "risk_level": s["risk"] ?? NSNull(),
            "position_advice": s["position"] ?? NSNull(),
            "predict_direction": s["direction"] ?? NSNull(),
        ]
    }

    // MARK: 取值工具（动态类型 → Swift 显式转换）

    /// 实现委托 `Num.doubleOrNilKeepingNonFinite`（遗留口径，**保留** `inf` / `nan`；语义勿改）
    public static func num(_ v: Any?) -> Double? { Num.doubleOrNilKeepingNonFinite(v) }

    public static func int(_ v: Any?) -> Int? {
        guard let v = v else { return nil }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? 1 : 0 }
            return n.intValue
        }
        if let s = v as? String { return Int(s) }
        return nil
    }

    public static func bool(_ v: Any?) -> Bool? {
        guard let v = v else { return nil }
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        if let b = v as? Bool { return b }
        return nil
    }

    /// 真值判断（数字 0/非 0、布尔、字符串非空）。
    ///
    /// ⚠ **为什么需要它**：`1 as? Bool` 在 Swift 里是 nil ——
    /// 凡是从 SQLite（INTEGER 列）或 JSON（数字）拿到 1/0 当标志位的地方，
    /// 用 `bool()` 都会**静默取到 false**（如 `stock_outcomes.skipped` 取不到真值时，
    /// 红灯日标的没被标记为"不参与统计"，四层胜率口径整体失真）。
    public static func truthy(_ v: Any?) -> Bool {
        guard let v = v else { return false }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            return n.doubleValue != 0
        }
        if let b = v as? Bool { return b }
        if let s = v as? String { return !s.isEmpty && s != "0" && s.lowercased() != "false" }
        return false
    }
}
