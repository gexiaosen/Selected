import Foundation

// MARK: - 引擎输入类型

/// 单根日K。字段缺失时按 0 处理
public struct KLineBar {
    public var day: String = ""
    public var open: Double = 0
    public var high: Double = 0
    public var low: Double = 0
    public var close: Double = 0
    public var volume: Double = 0

    public init() {}
    public init(day: String, open: Double, high: Double, low: Double, close: Double, volume: Double) {
        self.day = day; self.open = open; self.high = high
        self.low = low; self.close = close; self.volume = volume
    }
}

/// 引擎计算用的行情（只含引擎需要的字段）
public struct EngineQuote {
    public var code: String = ""
    public var name: String = ""
    public var price: Double = 0
    public var preClose: Double = 0
    public var open: Double = 0
    public var high: Double = 0
    public var low: Double = 0
    public var volume: Double = 0          // 手
    public var quoteTime: String = ""      // YYYYMMDDHHMMSS
    public var changePct: Double = 0
    public var volumeRatio: Double = 0
    public var turnover: Double = 0
    public var amplitude: Double = 0
    public var amount: Double = 0
    public var avgPrice: Double = 0

    public init() {}

    /// 从 JSON 字典构造（fixture quotes.json / 服务端返回）
    public init(json: [String: Any]) {
        func num(_ k: String) -> Double {
            if let d = json[k] as? Double { return d }
            if let i = json[k] as? Int { return Double(i) }
            if let s = json[k] as? String { return Double(s) ?? 0 }
            return 0
        }
        code = (json["code"] as? String) ?? ""
        name = (json["name"] as? String) ?? ""
        price = num("price"); preClose = num("pre_close")
        open = num("open"); high = num("high"); low = num("low")
        volume = num("volume"); changePct = num("change_pct")
        volumeRatio = num("volume_ratio"); turnover = num("turnover")
        amplitude = num("amplitude"); amount = num("amount"); avgPrice = num("avg_price")
        quoteTime = (json["quote_time"] as? String) ?? ""
    }
}

/// 深度指标（`computeDeepInfo` 的返回结构）
public struct DeepInfo {
    public var ma5: Double?
    public var ma10: Double?
    public var ma20: Double?
    public var maPass: Bool
    public var volMult5d: Double
    public var consecUp: Int
    public var cum5d: Double?
    public var prev1d: Double
    public var distFromLow: Double
    public var distFromHigh: Double
    public var ma20SlopeUp: Bool
    public var maDeviation: Double
    public var gainRatio: Double
    public var shadowBodyRatio: Double

    /// 键名即落库字段名（Swift 直读层与历史落库数据依赖这些名字）
    public var json: [String: Any] {
        var d: [String: Any] = [:]
        d["ma5"] = ma5 as Any
        d["ma10"] = ma10 as Any
        d["ma20"] = ma20 as Any
        d["ma_pass"] = maPass
        d["vol_mult_5d"] = volMult5d
        d["consec_up"] = consecUp
        d["cum_5d"] = cum5d as Any
        d["prev_1d"] = prev1d
        d["dist_from_low"] = distFromLow
        d["dist_from_high"] = distFromHigh
        d["ma20_slope_up"] = ma20SlopeUp
        d["ma_deviation"] = maDeviation
        d["gain_ratio"] = gainRatio
        d["shadow_body_ratio"] = shadowBodyRatio
        return d
    }
}

// MARK: - 深度指标

/// Selected 引擎 — 深度指标计算（纯函数，附录A 全部公式）
///
/// ⚠ 不可破坏的契约：所有函数都假定 **kline 的最后一根 = 今日**。
/// 新浪日K盘中不含当日 bar，调用方必须先经 `appendTodayBar` 合成当日 bar，
/// 否则 vol_mult_5d / cum_5d / consec_up / prev_1d 会整体错位一个交易日。
public enum EngineIndicators {

    // MARK: 均线

    public static func sma(_ values: [Double], _ n: Int) -> Double? {
        if values.count < n || n <= 0 { return nil }
        return PyMath.sum(values.suffix(n)) / Double(n)      // Neumaier 补偿求和
    }

    public static func ma5(_ closes: [Double]) -> Double? { sma(closes, 5) }
    public static func ma10(_ closes: [Double]) -> Double? { sma(closes, 10) }

    /// K线不足20日时用全部收盘价均值（有意行为）
    public static func ma20(_ closes: [Double]) -> Double? {
        if closes.count >= 20 { return PyMath.sum(closes.suffix(20)) / 20 }
        if !closes.isEmpty { return PyMath.sum(closes) / Double(closes.count) }
        return nil
    }

    /// ma_pass：MA5 > MA10 且 现价 > MA5
    public static func maBullish(_ ma5: Double?, _ ma10: Double?, _ price: Double) -> Bool {
        guard let a = ma5, let b = ma10 else { return false }
        return a > b && price > a
    }

    // MARK: 交易时段折算

    /// HH:MM（也容忍 HHMM / HHMMSS / HH:MM:SS）→ 自 9:30 起的已交易分钟数（上限 240）。
    /// 非法输入返回 0（调用方据此跳过归一化、退回原口径，不猜）。
    public static func elapsedMinutesAt(_ hhmm: String) -> Int {
        if hhmm.isEmpty { return 0 }
        let digits = hhmm.filter { $0.isASCII && $0.isNumber }
        if digits.count < 4 { return 0 }
        let chars = Array(digits)
        guard let hh = Int(String(chars[0...1])), let mm = Int(String(chars[2...3])) else { return 0 }
        if !(0 <= hh && hh <= 24 && 0 <= mm && mm <= 59) { return 0 }
        let t = hh * 60 + mm
        let amOpen = 9 * 60 + 30, amClose = 11 * 60 + 30
        let pmOpen = 13 * 60, pmClose = 15 * 60
        if t <= amOpen { return 0 }
        if t <= amClose { return t - amOpen }
        if t < pmOpen { return 120 }                 // 午间休市 → 上午满额
        if t <= pmClose { return 120 + (t - pmOpen) }
        return 240
    }

    /// 腾讯行情时间戳 YYYYMMDDHHMMSS → 自 9:30 起已交易分钟数。
    /// 解析失败返回 0 → 调用方跳过归一化、退回原口径（不猜、不编）。
    public static func sessionElapsedMinutes(_ quoteTime: String) -> Int {
        if quoteTime.isEmpty { return 0 }
        guard quoteTime.count >= 14 else { return 0 }
        let head = quoteTime.prefix(14)
        if !head.allSatisfy({ $0.isASCII && $0.isNumber }) { return 0 }
        let s = Array(quoteTime)
        return elapsedMinutesAt(String(s[8...13]))
    }

    // MARK: 量能 / 涨幅 / 位置

    /// 今日量 / 前 n 日均量（去今日）
    ///
    /// ⚠ `n == 0` 必须兜底成 5：若写成 `max(1, n)`，0 会变 1，
    ///   「5 日均量倍数」静默退化成「1 日均量」，量能加分与缩量扣分**全错**且无任何报错。
    ///   参数 schema 的 min 是 3，正常改参到不了 0；但直改库 / 越权改参就会踩到。
    public static func volMult5d(_ volumes: [Double], _ n: Int = 5) -> Double {
        let n = max(1, n == 0 ? 5 : n)
        if volumes.count < n + 1 { return 0 }
        let window = volumes[(volumes.count - n - 1)..<(volumes.count - 1)]
        let avg = PyMath.sum(window) / Double(n)
        return avg > 0 ? volumes[volumes.count - 1] / avg : 0
    }

    /// 连涨天数：从最新回溯按日涨幅>0计数，遇跌即停
    public static func consecutiveUpDays(_ closes: [Double]) -> Int {
        var count = 0
        var i = closes.count - 1
        while i > 0 {
            if closes[i - 1] <= 0 { break }
            let dailyChg = (closes[i] - closes[i - 1]) / closes[i - 1] * 100
            if dailyChg > 0 { count += 1 } else { break }
            i -= 1
        }
        return count
    }

    /// 5日累计涨幅；K线不足 6 根返回 nil = 该项不参与评分（返回 0 会误送加分）
    public static func cumGain5d(_ closes: [Double]) -> Double? {
        if closes.count < 6 || closes[closes.count - 6] <= 0 { return nil }
        let base = closes[closes.count - 6]
        return (closes[closes.count - 1] - base) / base * 100
    }

    /// 前1日涨幅：(昨收-前日收)/前日收×100%
    public static func prev1dGain(_ closes: [Double]) -> Double {
        if closes.count < 3 || closes[closes.count - 3] <= 0 { return 0 }
        let base = closes[closes.count - 3]
        return (closes[closes.count - 2] - base) / base * 100
    }

    /// 距20日低点（近20日最低收盘）
    public static func distFromLow20d(_ closes: [Double], _ price: Double) -> Double {
        if closes.isEmpty { return 0 }
        guard let low20 = closes.suffix(20).min(), low20 > 0 else { return 0 }
        return (price - low20) / low20 * 100
    }

    /// 距60日高点（近60日最高收盘）
    public static func distFromHigh60d(_ closes: [Double], _ price: Double) -> Double {
        if closes.isEmpty { return 0 }
        guard let high60 = closes.suffix(60).max(), high60 > 0 else { return 0 }
        return (price - high60) / high60 * 100
    }

    /// 当前MA20 > lookback天前MA20；K线不足 (20+lookback) 根返回 false = 不加分
    public static func ma20SlopeUp(_ closes: [Double], _ lookback: Int = 5) -> Bool {
        let need = 20 + lookback
        if closes.count < need { return false }
        let now = PyMath.sum(closes.suffix(20)) / 20
        let prevSlice = closes[(closes.count - 20 - lookback)..<(closes.count - lookback)]
        let prev = PyMath.sum(prevSlice) / 20
        return now > prev
    }

    /// MA5/MA10偏离度 = |MA5-MA10|/MA10×100%
    public static func maDeviation(_ ma5: Double?, _ ma10: Double?) -> Double {
        guard let a = ma5, let b = ma10, b > 0 else { return 0 }
        return abs(a - b) / b * 100
    }

    // MARK: 形态

    /// 盘中最大涨幅 = (最高-开盘)/开盘×100%（基准=开盘；仅作展示）
    public static func intradayMaxGain(_ openP: Double, _ high: Double) -> Double {
        openP > 0 ? (high - openP) / openP * 100 : 0
    }

    /// 冲高回落保留度 = 收盘涨幅 ÷ 盘中最大涨幅，**分子分母统一以昨收为基准**。
    /// 统一到昨收基准后取值恒在 [0,1]：1.0 = 收在当日最高；0.0 = 涨幅全部回吐。
    public static func pulseRetentionRatio(_ price: Double, _ preClose: Double, _ high: Double) -> Double {
        let denom = high - preClose
        if preClose <= 0 || denom <= 0 { return 0 }
        let raw = (price - preClose) / denom
        return PyMath.round(max(0, min(1, raw)), 2)
    }

    /// 影体比 = 上影线/实体；实体=0 时取 0
    public static func shadowBodyRatio(_ openP: Double, _ closeP: Double, _ high: Double) -> Double {
        let upper = high - max(openP, closeP)
        let body = abs(closeP - openP)
        return body > 0 ? upper / body : 0
    }

    /// 当日K线形态三项检验。返回 (score 0-3, details)
    public static func formCheck(_ openP: Double, _ closeP: Double, _ high: Double, _ low: Double,
                          upperShadowRatio: Double, closeHighRatio: Double,
                          bodyRatioMin: Double) -> (Int, [String]) {
        if openP <= 0 || high <= 0 || low <= 0 { return (0, ["数据缺失"]) }
        var score = 0
        var details: [String] = []
        let upperShadow = high - max(openP, closeP)
        let body = abs(closeP - openP)
        let totalRange = high - low + 0.001

        if upperShadow <= body * upperShadowRatio {
            score += 1; details.append("上影线OK")
        } else {
            details.append("上影线长(\(fmt(PyMath.round(upperShadow, 2)))>"
                           + "\(fmt(PyMath.round(body * upperShadowRatio, 2))))")
        }
        if closeP >= high * closeHighRatio {
            score += 1; details.append("收盘高位OK")
        } else {
            details.append("收盘偏低(\(fmt(PyMath.round(closeP / high * 100, 1)))%)")
        }
        let bodyRatio = body / totalRange
        if bodyRatio >= bodyRatioMin {
            score += 1; details.append("实体\(fmtInt(PyMath.roundInt(bodyRatio * 100)))%OK")
        } else {
            details.append("实体低\(fmtInt(PyMath.roundInt(bodyRatio * 100)))%")
        }
        return (score, details)
    }

    // MARK: 深度指标主函数

    /// 65日K线深度验证 → DeepInfo。K线不足 10 根返回 nil。
    public static func computeDeepInfo(_ kline: [KLineBar], _ quote: EngineQuote,
                                volAvgDays: Int = 5, volMultNormalize: Bool = true,
                                ma20SlopeLookback: Int = 5) -> DeepInfo? {
        if kline.count < 10 { return nil }
        let closes = kline.map(\.close)
        let volumes = kline.map(\.volume)
        let price = quote.price

        let m5 = ma5(closes)
        let m10 = ma10(closes)
        let m20 = ma20(closes)

        // 量能倍数：末根若是"进行中"的当日 bar，须按已交易分钟数折算到全日口径
        var vm = volMult5d(volumes, volAvgDays)
        if volMultNormalize {
            let elapsed = sessionElapsedMinutes(quote.quoteTime)
            if elapsed > 0 && elapsed < 240 { vm *= 240.0 / Double(elapsed) }
        }

        let c5 = cumGain5d(closes)

        // ⚠ 值为 0.0 时输出 None（不是 0.0）—— 与落库数据的既有口径一致
        func roundOrNil(_ v: Double?) -> Double? {
            guard let v = v, v != 0 else { return nil }
            return PyMath.round(v, 2)
        }
        func round2(_ v: Double) -> Double { PyMath.round(v, 2) }

        return DeepInfo(
            ma5: roundOrNil(m5),
            ma10: roundOrNil(m10),
            ma20: roundOrNil(m20),
            maPass: maBullish(m5, m10, price),
            volMult5d: round2(vm),
            consecUp: consecutiveUpDays(closes),
            cum5d: c5.map { round2($0) },
            prev1d: round2(prev1dGain(closes)),
            distFromLow: round2(distFromLow20d(closes, price)),
            distFromHigh: round2(distFromHigh60d(closes, price)),
            ma20SlopeUp: ma20SlopeUp(closes, ma20SlopeLookback),
            maDeviation: round2(maDeviation(m5, m10)),
            gainRatio: pulseRetentionRatio(price, quote.preClose, quote.high),
            shadowBodyRatio: round2(shadowBodyRatio(quote.open, price, quote.high))
        )
    }

    /// 盘中日K不含当日 bar → 用实时 quote 合成一根追加（单位：手 → 股，×100）。
    /// 保守策略：缺字段 / 高低价自相矛盾 / 已含当日 bar → 原样返回。
    public static func appendTodayBar(_ kline: [KLineBar], _ quote: EngineQuote, today: String) -> [KLineBar] {
        if kline.isEmpty { return kline }
        if let last = kline.last, !last.day.isEmpty, last.day >= today { return kline }
        let o = quote.open, h = quote.high, l = quote.low, price = quote.price
        if min(min(o, h), min(l, price)) <= 0 || h < max(o, price) || l > min(o, price) {
            return kline
        }
        var out = kline
        out.append(KLineBar(day: today, open: o, high: h, low: l, close: price,
                            volume: quote.volume * 100))
        return out
    }

    // MARK: 大盘连跌

    public struct MarketDecline {
        public var shConsecutiveDecline = false
        public var sh3dDeclineCount = 0
        public var sh3dTrend = "未知"
        public var shD1: Double?
        public var shD2: Double?
        public var shDeclineStreak = 0
        public var shDeclineLookback = 3
        public var shDeclineDaysCfg = 2

        public var json: [String: Any] {
            var d: [String: Any] = [
                "sh_consecutive_decline": shConsecutiveDecline,
                "sh_3d_decline_count": sh3dDeclineCount,
                "sh_3d_trend": sh3dTrend,
                "sh_decline_streak": shDeclineStreak,
                "sh_decline_lookback": shDeclineLookback,
                "sh_decline_days_cfg": shDeclineDaysCfg,
            ]
            d["sh_d1"] = shD1 as Any
            d["sh_d2"] = shD2 as Any
            return d
        }
    }

    /// 大盘连跌检测：回看最近 lookback 个**已完成**交易日，统计尾部连续下跌天数。
    ///
    /// 先按日期剔除当日 bar（指数日K盘中不含当日未完成 bar），再取最近 lookback 根。
    /// `today` 必须显式传入「本轮当日」，否则回放结果会随墙上时钟漂移。
    public static func marketConsecutiveDecline(_ indexKline: [KLineBar],
                                         todayChangePct: Double?,
                                         lookback: Int = 3,
                                         today: String,
                                         declineDays: Int = 2) -> MarketDecline {
        // ⚠ sh_decline_lookback 记的是**传入值**（钳位发生在后面）
        var result = MarketDecline()
        result.shDeclineLookback = lookback

        let bars = indexKline.filter { $0.close != 0 && $0.day != today }
        let closes = bars.map(\.close)
        let lb = max(3, lookback)                    // 判定连跌2日至少需要3根完成日K
        if closes.count < lb { return result }

        let window = Array(closes.suffix(lb))
        var deltas: [Double] = []
        for i in 1..<window.count where window[i - 1] > 0 {
            deltas.append((window[i] - window[i - 1]) / window[i - 1] * 100)
        }
        if deltas.count < 2 { return result }
        let d1 = deltas[deltas.count - 1]
        let d2 = deltas[deltas.count - 2]

        var streak = 0
        for d in deltas.reversed() {
            if d < 0 { streak += 1 } else { break }
        }
        if let tc = todayChangePct, tc < 0 { streak += 1 }   // 昨日跌 + 今日跌 = 连跌2日

        let declineCount = deltas.filter { $0 < 0 }.count
        let daysCfg = max(1, declineDays)

        result.sh3dDeclineCount = declineCount
        result.shConsecutiveDecline = streak >= daysCfg
        result.shDeclineStreak = streak
        result.shDeclineDaysCfg = daysCfg
        result.shD1 = PyMath.round(d1, 2)
        result.shD2 = PyMath.round(d2, 2)

        if streak >= daysCfg {
            var tail = String(format: "昨日%+.2f%%", d1)
            if let tc = todayChangePct, tc < 0 {
                tail += String(format: "且今日%+.2f%%", tc)
            }
            result.sh3dTrend = "连续\(streak)日下跌（\(tail)）"
        } else {
            result.sh3dTrend = String(format: "前日%+.2f%% 昨日%+.2f%% 趋势正常", d2, d1)
        }
        return result
    }

    // MARK: 格式化（与落库文本口径一致）

    /// `%g` 风格：整数不带小数位，否则去掉尾随 0
    public static func fmt(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int(v)) }
        var s = String(format: "%g", v)
        if s.contains("e") { s = String(v) }
        return s
    }

    /// 整数格式化。
    ///
    /// ⚠ 必须挡非有限值：`String(Int(v))` 对 `inf` / `nan` 是 **Swift trap 且不可 catch**。
    ///   调用点传的是 `PyMath.roundInt(bodyRatio * 100)`，而 `PyMath.roundInt` 对非有限值
    ///   **原样返回** —— 上游不挡，这里必须挡。
    ///   （正常 OHLC 算不出非有限值；但 `high`/`low` 本身若为 inf（脏数据），
    ///   `inf - inf = nan` 就会到这里。）
    ///   回落 `"—"`：与项目里 `strOrDash` 的"没这个数"口径一致。
    public static func fmtInt(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        return String(Int(v))
    }
}
