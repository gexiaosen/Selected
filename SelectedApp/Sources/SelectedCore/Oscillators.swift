import Foundation

/// 六条**固定阈值**超买超卖信号 —— KDJ · RSI · CCI · CR · WR · VR
///
/// ## ⚠ 姿势：**只展示，不进评分**
///
/// 这类固定阈值信号与 Selected 的评分体系（档位门槛可调且带锁档）是两套哲学；
/// 且六条读数**不是六份独立证据**：KDJ / WR / CR 都基于「当前价在 N 日最高/最低之间的位置」，
/// CCI 是 TP 相对均值的偏离，只有 VR 用到成交量 —— 高度同源，
/// 当独立证据加总会**高估可信度**（`CorrelationDiagnostic` 量过同源特征的 ρ）。
///
/// ## ⚠ 阈值是外部给定，公式是**本实现选定的读法**（来源没给公式）
///
/// 判据只给了数（如 `K>80/D>70/J>90`），KDJ 的**初始化**、RSI 的**平滑方式**、
/// CR 的**中间价定义**、VR 的**平盘日定义**均由本实现逐条选定并写明（见各函数注释），
/// 全部集中到 `Config`，**改它等于改口径**。
public enum Oscillators {

    // MARK: - 阈值

    public struct Config: Sendable {
        // ① KDJ
        public var kdjPeriod = 9
        /// ⚠ 递推初值。国内通行 `K=D=50`；换个初值只影响最早几十根的收敛过程。
        public var kdjInit = 50.0
        public var kdjObK = 80.0, kdjObD = 70.0, kdjObJ = 90.0
        public var kdjOsK = 20.0, kdjOsD = 30.0
        // ② RSI
        public var rsiPeriod = 6
        public var rsiOb = 80.0, rsiSevereOb = 90.0
        public var rsiOs = 20.0, rsiSevereOs = 10.0
        // ③ CCI
        public var cciPeriod = 14
        public var cciOb = 100.0, cciOs = -100.0
        // ④ CR
        public var crPeriod = 26
        public var crSell = 160.0, crBuy = 40.0
        // ⑤ WR
        public var wrPeriod = 14
        public var wrOb = 20.0, wrOs = 80.0
        // ⑥ VR（⚠ 唯一的**区间型**判据）
        public var vrPeriod = 26
        public var vrSellLow = 160.0, vrSellHigh = 450.0
        public var vrBuyLow = 40.0, vrBuyHigh = 70.0

        public init() {}
    }

    // MARK: - 类型

    /// 六条指标。**互不排斥**（可同时处于超买）。
    public enum Kind: String, CaseIterable, Sendable {
        case kdj, rsi, cci, cr, wr, vr

        public var title: String {
            switch self {
            case .kdj: return "KDJ"
            case .rsi: return "RSI"
            case .cci: return "CCI"
            case .cr: return "CR"
            case .wr: return "WR"
            case .vr: return "VR"
            }
        }
    }

    /// 三态 + 两个"严重"档（⚠ **只有 RSI 有"严重"档**）
    public enum Zone: String, Sendable {
        case severeOverbought, overbought, oversold, severeOversold, neutral

        public var title: String {
            switch self {
            case .severeOverbought: return "严重超买"
            case .overbought: return "超买"
            case .oversold: return "超卖"
            case .severeOversold: return "严重超卖"
            case .neutral: return "中性"
            }
        }
    }

    public struct NamedValue: Sendable {
        public let name: String
        public let value: Double
    }

    public struct Reading: Sendable {
        public let kind: Kind
        public let zone: Zone
        /// 全部数值（KDJ 是三个：K/D/J）
        public let values: [NamedValue]
        /// 命中的**依据**（把数值与阈值都写出来，让用户能核对，而不是只给一个"超买"）
        public let note: String
    }

    /// 评估结果。
    ///
    /// ⚠ **`skipped` 不是"中性"** —— 日K不足 / `MD==0`（无波动）/ 分母为 0 时，
    /// 该条**根本没跑**。混进"中性"会让界面显示"这只票不超买不超卖"，
    /// 而真相是"**我们没能力判断**"。
    public struct Outcome: Sendable {
        public let readings: [Reading]
        public let skipped: [Kind: String]
    }

    // MARK: - 入口

    /// 评估六条。`bars` 需**时间正序、末根是今日**。
    public static func evaluate<B: Sequence>(_ bars: B, config: Config = .init()) -> Outcome
    where B.Element: VolumeBar {
        let b = Array(bars)
        var readings: [Reading] = []
        var skipped: [Kind: String] = [:]

        if let v = kdj(b, config) {
            readings.append(Reading(kind: .kdj, zone: kdjZone(v, config),
                values: [NamedValue(name: "K", value: v.k),
                         NamedValue(name: "D", value: v.d),
                         NamedValue(name: "J", value: v.j)],
                // ⚠ note / skipped 由 UI 逐字渲染（不解析 Markdown），
                //   强调统一用「」、连接词去掉，不要用星号。
                note: "K=\(fmt(v.k)) · D=\(fmt(v.d)) · J=\(fmt(v.j))"
                    + "｜超买需 K>\(fmt(config.kdjObK)) 且 D>\(fmt(config.kdjObD))"
                    + " 且 J>\(fmt(config.kdjObJ))；超卖需 K<\(fmt(config.kdjOsK))"
                    + " 且 D<\(fmt(config.kdjOsD))"))
        } else {
            skipped[.kdj] = "日K不足（有 \(b.count) 根，需要 \(config.kdjPeriod) 根）"
        }

        if let v = rsi(b, config) {
            readings.append(Reading(kind: .rsi, zone: rsiZone(v, config),
                values: [NamedValue(name: "RSI\(config.rsiPeriod)", value: v)],
                note: "RSI(\(config.rsiPeriod))=\(fmt(v))"
                    + "｜>\(fmt(config.rsiSevereOb)) 严重超买 / >\(fmt(config.rsiOb)) 超买 /"
                    + " <\(fmt(config.rsiOs)) 超卖 / <\(fmt(config.rsiSevereOs)) 严重超卖"))
        } else {
            skipped[.rsi] = "日K不足（有 \(b.count) 根，需要 \(config.rsiPeriod + 1) 根）"
        }

        if let v = cci(b, config) {
            readings.append(Reading(kind: .cci, zone: cciZone(v, config),
                values: [NamedValue(name: "CCI\(config.cciPeriod)", value: v)],
                note: "CCI(\(config.cciPeriod))=\(fmt(v))"
                    + "｜>+\(fmt(config.cciOb)) 超买 / <\(fmt(config.cciOs)) 超卖"))
        } else {
            // ⚠ 两种"算不出"要分开说：bar 不够 vs **无波动**（`MD==0`，如长期停牌或一字板）
            skipped[.cci] = b.count < config.cciPeriod
                ? "日K不足（有 \(b.count) 根，需要 \(config.cciPeriod) 根）"
                : "区间内无波动（MD=0）→ 算不出 CCI（不是中性）"
        }

        if let v = cr(b, config) {
            readings.append(Reading(kind: .cr, zone: crZone(v, config),
                values: [NamedValue(name: "CR\(config.crPeriod)", value: v)],
                note: "CR(\(config.crPeriod))=\(fmt(v))"
                    + "｜>\(fmt(config.crSell)) 获利了结 / <\(fmt(config.crBuy)) 建仓"))
        } else {
            skipped[.cr] = b.count < config.crPeriod + 1
                ? "日K不足（有 \(b.count) 根，需要 \(config.crPeriod + 1) 根）"
                : "区间内价格从未低于昨中价（分母=0）→ 算不出 CR（不是中性）"
        }

        if let v = wr(b, config) {
            readings.append(Reading(kind: .wr, zone: wrZone(v, config),
                values: [NamedValue(name: "WR\(config.wrPeriod)", value: v)],
                note: "WR(\(config.wrPeriod))=\(fmt(v))"
                    + "｜<\(fmt(config.wrOb)) 超买 / >\(fmt(config.wrOs)) 超卖"
                    + "（⚠ 正向口径 0~100，大 = 超卖）"))
        } else {
            skipped[.wr] = b.count < config.wrPeriod
                ? "日K不足（有 \(b.count) 根，需要 \(config.wrPeriod) 根）"
                : "区间内最高=最低（无位置可言）→ 算不出 WR（不是中性）"
        }

        if let v = vr(b, config) {
            readings.append(Reading(kind: .vr, zone: vrZone(v, config),
                values: [NamedValue(name: "VR\(config.vrPeriod)", value: v)],
                note: "VR(\(config.vrPeriod))=\(fmt(v))"
                    + "｜\(fmt(config.vrSellLow))–\(fmt(config.vrSellHigh)) 获利了结 /"
                    + " \(fmt(config.vrBuyLow))–\(fmt(config.vrBuyHigh)) 买进（「区间型」，区间外为中性）"))
        } else {
            skipped[.vr] = b.count < config.vrPeriod + 1
                ? "日K不足（有 \(b.count) 根，需要 \(config.vrPeriod + 1) 根）"
                : "区间内成交量全为 0 或无下跌/平盘（分母=0）→ 算不出 VR（不是中性）"
        }

        return Outcome(readings: readings, skipped: skipped)
    }

    // MARK: - ① KDJ

    /// `RSV=(C−L_n)/(H_n−L_n)×100`；`K=⅔K₋₁+⅓RSV`；`D=⅔D₋₁+⅓K`；`J=3K−2D`。
    ///
    /// ⚠ **初始化 `K=D=50`**（国内通行）。递推从第 `n` 根开始，前 `n-1` 根不参与。
    /// ⚠ `H_n == L_n`（一字板 / 长期停牌）时 `RSV` **无定义** → 取**中性 50**。
    ///   这是**有意**的：取 0 会把一字板读成"极度超卖"，取 100 会读成"极度超买"，
    ///   两者都是在**没有位置信息**的地方硬造一个结论。
    static func kdj<B: OHLCBar>(_ b: [B], _ c: Config)
        -> (k: Double, d: Double, j: Double)? {
        let n = c.kdjPeriod
        guard n > 0, b.count >= n else { return nil }
        var k = c.kdjInit, d = c.kdjInit
        for i in (n - 1)..<b.count {
            let win = b[(i - n + 1)...i]
            let hi = win.map(\.high).max() ?? 0
            let lo = win.map(\.low).min() ?? 0
            let rsv = hi > lo ? (b[i].close - lo) / (hi - lo) * 100 : 50
            k = (2 * k + rsv) / 3
            d = (2 * d + k) / 3
        }
        return (k, d, 3 * k - 2 * d)
    }

    static func kdjZone(_ v: (k: Double, d: Double, j: Double), _ c: Config) -> Zone {
        // `K>80/D>70/J>90` 读作**合取**（三项全满足才算超买）
        if v.k > c.kdjObK && v.d > c.kdjObD && v.j > c.kdjObJ { return .overbought }
        // 超卖判据只有 K/D 两项（J 没给下界）→ 不替它补
        if v.k < c.kdjOsK && v.d < c.kdjOsD { return .oversold }
        return .neutral
    }

    // MARK: - ② RSI

    /// `RSI = 100×Σ涨/(Σ涨+Σ跌)`，**简单平均**。
    ///
    /// ⚠ **简单平均**口径（国内通行），**不是 Wilder 平滑** —— 两者数值不同；
    ///   Wilder 序列在 `MomentumIndicators.rsiSeries`，别混用。
    /// ⚠ `Σ涨+Σ跌 == 0`（区间内收盘全平）→ 返回 **50**（中性），不是 0 或 100。
    static func rsi<B: OHLCBar>(_ b: [B], _ c: Config) -> Double? {
        let n = c.rsiPeriod
        guard n > 0, b.count >= n + 1 else { return nil }
        var gain = 0.0, loss = 0.0
        for i in (b.count - n)..<b.count {
            let ch = b[i].close - b[i - 1].close
            if ch > 0 { gain += ch } else if ch < 0 { loss -= ch }
        }
        guard gain + loss > 0 else { return 50 }
        return gain / (gain + loss) * 100
    }

    static func rsiZone(_ v: Double, _ c: Config) -> Zone {
        // ⚠ 顺序有意义：先判"严重"再判"普通"，否则 92 会被 >80 先接住
        if v > c.rsiSevereOb { return .severeOverbought }
        if v > c.rsiOb { return .overbought }
        if v < c.rsiSevereOs { return .severeOversold }
        if v < c.rsiOs { return .oversold }
        return .neutral
    }

    // MARK: - ③ CCI

    /// `CCI = (TP − MA(TP,n)) / (0.015 × MD)`，`TP=(H+L+C)/3`，`MD=mean|TP−MA|`。
    ///
    /// ⚠ `MD == 0`（区间内 TP 全同 → 无波动）时**返回 `nil`**，不硬给 0 ——
    /// 那会把"算不出"伪装成"中性"。
    static func cci<B: OHLCBar>(_ b: [B], _ c: Config) -> Double? {
        let n = c.cciPeriod
        guard n > 0, b.count >= n else { return nil }
        let tps = b[(b.count - n)...].map { ($0.high + $0.low + $0.close) / 3 }
        guard let last = tps.last else { return nil }
        let ma = tps.reduce(0, +) / Double(n)
        let md = tps.map { abs($0 - ma) }.reduce(0, +) / Double(n)
        guard md > 0 else { return nil }
        return (last - ma) / (0.015 * md)
    }

    static func cciZone(_ v: Double, _ c: Config) -> Zone {
        if v > c.cciOb { return .overbought }
        if v < c.cciOs { return .oversold }
        return .neutral
    }

    // MARK: - ④ CR

    /// `CR = Σ(H − 昨中价) / Σ(昨中价 − L) × 100`，`中价 = (H+L)/2`。
    ///
    /// ⚠ **中价取 `(H+L)/2`**（另一口径 `(H+L+C)/3` 数值不同，本实现锁定 `(H+L)/2`）。
    /// ⚠ 分母为 0（区间内价格从未低于昨中价）→ `nil`。
    static func cr<B: OHLCBar>(_ b: [B], _ c: Config) -> Double? {
        let n = c.crPeriod
        guard n > 0, b.count >= n + 1 else { return nil }
        var up = 0.0, dn = 0.0
        for i in (b.count - n)..<b.count {
            let mid = (b[i - 1].high + b[i - 1].low) / 2
            up += max(0, b[i].high - mid)
            dn += max(0, mid - b[i].low)
        }
        guard dn > 0 else { return nil }
        return up / dn * 100
    }

    static func crZone(_ v: Double, _ c: Config) -> Zone {
        if v > c.crSell { return .overbought }
        if v < c.crBuy { return .oversold }
        return .neutral
    }

    // MARK: - ⑤ WR

    /// `WR = (H_n − C) / (H_n − L_n) × 100`（**正向口径 0~100**）。
    ///
    /// ⚠ **国内正向口径**（大 = 超卖），**不是**西方的 `−100~0` 负值口径；
    ///   阈值"20 超买 / 80 超卖"与正向口径一致。
    /// ⚠ `H_n == L_n` → `nil`（无位置可言）。
    static func wr<B: OHLCBar>(_ b: [B], _ c: Config) -> Double? {
        let n = c.wrPeriod
        guard n > 0, b.count >= n, let last = b.last else { return nil }
        let win = b[(b.count - n)...]
        let hi = win.map(\.high).max() ?? 0
        let lo = win.map(\.low).min() ?? 0
        guard hi > lo else { return nil }
        return (hi - last.close) / (hi - lo) * 100
    }

    static func wrZone(_ v: Double, _ c: Config) -> Zone {
        if v < c.wrOb { return .overbought }   // 价靠近区间高点
        if v > c.wrOs { return .oversold }     // 价靠近区间低点
        return .neutral
    }

    // MARK: - ⑥ VR

    /// `VR = (涨量 + 平量/2) / (跌量 + 平量/2) × 100`。
    ///
    /// ⚠ **平盘 = `收 == 昨收`**（不是 `收 == 开`）。
    /// ⚠ **唯一的区间型判据**：`160–450 获利了结 / 40–70 买进`，
    ///   区间**之外**是中性 —— 不是"反向信号"。
    /// ⚠ 分母为 0（无下跌也无平盘）→ `nil`。
    static func vr<B: VolumeBar>(_ b: [B], _ c: Config) -> Double? {
        let n = c.vrPeriod
        guard n > 0, b.count >= n + 1 else { return nil }
        var up = 0.0, dn = 0.0, flat = 0.0
        for i in (b.count - n)..<b.count {
            let ch = b[i].close - b[i - 1].close
            if ch > 0 { up += b[i].volume } else if ch < 0 { dn += b[i].volume }
            else { flat += b[i].volume }
        }
        let den = dn + flat / 2
        guard den > 0 else { return nil }
        return (up + flat / 2) / den * 100
    }

    static func vrZone(_ v: Double, _ c: Config) -> Zone {
        if v >= c.vrSellLow && v <= c.vrSellHigh { return .overbought }
        if v >= c.vrBuyLow && v <= c.vrBuyHigh { return .oversold }
        return .neutral
    }

    // MARK: - 工具

    static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
}
