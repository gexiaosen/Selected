import Foundation

/// 成交量类指标 —— **VWAP / CMF / EMV / FI / MFM / MFV**
///
/// ## ⚠ MFM 口径（夹具锁定，与教科书 TP 版不同）
/// 教科书 MFM 用典型价 `TP=(H+L+C)/3`；夹具 `mfm.csv` 首行（C==H）实测输出 **1**，
/// 只有 `((C−L)−(H−C))/(H−L)`（即 `(2C−H−L)/(H−L)`，收盘版）能对上
/// （TP 版给 0.33）。本项目**跟夹具口径**，测试锁死；接筛选规则前如需 TP 版
/// 要另立指标 id，不许原地改公式。
///
/// ## 通用约定
/// 序列优先、等长对齐、预热 `nil`；`H == L`（一字板）→ MFM 记 0（当日无位置信息，
/// 资金流中性）；`ΣV == 0`（停牌段）→ 该位 `nil`。
public enum VolumeIndicators {

    // MARK: - MFM / MFV

    /// 资金流乘数 MFM（收盘版，见文件头口径说明）。
    public static func moneyFlowMultiplier<B: Sequence>(_ bars: B) -> [Double]
    where B.Element: OHLCBar {
        let bars = Array(bars)
        return bars.map { bar in
            let range = bar.high - bar.low
            guard range != 0 else { return 0 }
            return ((bar.close - bar.low) - (bar.high - bar.close)) / range
        }
    }

    /// 资金流体积 MFV = MFM × Volume。
    public static func moneyFlowVolume<B: Sequence>(_ bars: B) -> [Double]
    where B.Element: VolumeBar {
        let bars = Array(bars)
        let mfm = moneyFlowMultiplier(bars)
        return zip(mfm, bars).map { $0 * $1.volume }
    }

    // MARK: - CMF

    /// 蔡金资金流 —— `CMF(n) = Σ(MFV, n) / Σ(V, n)`。
    ///
    /// ⚠ `ΣV == 0` → `nil`（整窗停牌，不是"资金流为 0"）。
    public static func cmf<B: Sequence>(_ bars: B, period: Int = 20) -> [Double?]
    where B.Element: VolumeBar {
        let bars = Array(bars)
        let mfv = moneyFlowVolume(bars)
        let vol = IndicatorPrimitives.volumes(bars)
        guard period >= 1, bars.count >= period else {
            return Array(repeating: nil, count: bars.count)
        }
        var out: [Double?] = Array(repeating: nil, count: bars.count)
        for i in (period - 1)..<bars.count {
            let sumV = PyMath.sum(vol[(i - period + 1)...i])
            guard sumV != 0 else { continue }
            out[i] = PyMath.sum(mfv[(i - period + 1)...i]) / sumV
        }
        return out
    }

    // MARK: - VWAP

    /// 滚动 VWAP —— `Σ(C·V, n) / Σ(V, n)`。
    ///
    /// ⚠ 夹具口径：`vwap.csv` **只有 Close/Volume 两列**（无 H/L），即 TP 取收盘价；
    ///   且是 **n 根滚动窗口**（VWAP(14)），不是"当日分时累计"口径 —— 两者是不同的量，
    ///   接分时图时别混用。`ΣV == 0` → `nil`。
    public static func vwap<B: Sequence>(_ bars: B, period: Int = 14) -> [Double?]
    where B.Element: VolumeBar {
        let bars = Array(bars)
        let cv = bars.map { $0.close * $0.volume }
        let vol = IndicatorPrimitives.volumes(bars)
        guard period >= 1, bars.count >= period else {
            return Array(repeating: nil, count: bars.count)
        }
        var out: [Double?] = Array(repeating: nil, count: bars.count)
        for i in (period - 1)..<bars.count {
            let sumV = PyMath.sum(vol[(i - period + 1)...i])
            guard sumV != 0 else { continue }
            out[i] = PyMath.sum(cv[(i - period + 1)...i]) / sumV
        }
        return out
    }

    // MARK: - EMV

    /// 简易波动指标 EMV —— `raw = 中价位移 × (H−L) / V`，`EMV = SMA(raw, n)`。
    ///
    /// ```
    /// distance = (H+L)/2 − (H'+L')/2
    /// ratio    = V / (H − L)          （比值型"每单位波幅吃掉多少量"）
    /// raw      = distance / ratio     （H==L 或 V==0 → 0：当日位移无成本信息）
    /// ```
    /// ⚠ 首根无昨期中价 → raw[0] 记 0（与夹具首行 0 占位一致）。
    /// ⚠ **×1e8 缩放**是 EMV 的通行展示口径（夹具 `emv.csv` 同此：差恰为 1e8 倍）。
    ///   EMV 的绝对值跨标的不可比，缩放只为可读性；
    ///   筛选规则若用阈值，必须按缩放后的量纲标定。
    public static func emv<B: Sequence>(_ bars: B, period: Int = 14) -> [Double?]
    where B.Element: VolumeBar {
        let bars = Array(bars)
        guard !bars.isEmpty else { return [] }
        var raw: [Double] = [0]
        raw.reserveCapacity(bars.count)
        for i in 1..<bars.count {
            let distance = (bars[i].high + bars[i].low) / 2 - (bars[i - 1].high + bars[i - 1].low) / 2
            let range = bars[i].high - bars[i].low
            let v = bars[i].volume
            raw.append(range != 0 && v != 0 ? distance * range / v * 1e8 : 0)
        }
        return IndicatorPrimitives.smaSeries(raw, period)
    }

    // MARK: - Force Index

    /// 强力指数 FI —— `raw = V × (C − C')`，`FI = EMA(raw, n)`。
    ///
    /// ⚠ 夹具口径：平滑是 **EMA(13)**（种子=SMA，见 `emaSeries`），不是 SMA。
    /// ⚠ 首根无昨收 → raw[0] `nil`，EMA 在有值段上递推。
    public static func forceIndex<B: Sequence>(_ bars: B, period: Int = 13) -> [Double?]
    where B.Element: VolumeBar {
        let bars = Array(bars)
        var raw: [Double?] = Array(repeating: nil, count: bars.count)
        for i in 1..<bars.count {
            raw[i] = bars[i].volume * (bars[i].close - bars[i - 1].close)
        }
        return IndicatorPrimitives.emaSeries(raw, period)
    }
}
