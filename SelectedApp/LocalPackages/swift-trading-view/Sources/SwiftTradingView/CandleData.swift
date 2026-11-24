import Foundation

public struct CandleData: Identifiable, Equatable {
    public var id: String {
        return "\(time)"
    }
    public var time: Double
    public var open: Double
    public var close: Double
    public var high: Double
    public var low: Double
    public var volume: Double
    /// 成交额（元）。仅副图「成交额」模式使用；缺数据为 0。
    public var amount: Double
    /// 均价（VWAP，分时黄线用）。仅分时数据填充；nil = 无均价（K线等既有场景不受影响）。
    /// （2026-09-17 分时形态改造）
    public var avgPrice: Double?

    public init(
        time: Double,
        open: Double,
        close: Double,
        high: Double,
        low: Double,
        volume: Double,
        amount: Double = 0,
        avgPrice: Double? = nil
    ) {
        self.time = time
        self.close = close
        self.high = high
        self.low = low
        self.open = open
        self.volume = volume
        self.amount = amount
        self.avgPrice = avgPrice
    }

    public static func generateSampleData(count: Int = 1000) -> [Self] {
        var items: [Self] = []
        let startTime = Date().timeIntervalSince1970 - Double(count * 60)
        var lastClose = Double.random(in: 100...200)

        for i in 0..<count {
            let time = startTime + Double(i * 60)
            let changePercent = Double.random(in: -0.02...0.02)
            let close = lastClose * (1 + changePercent)
            let open = lastClose
            let high = max(open, close) * Double.random(in: 1.0...1.01)
            let low = min(open, close) * Double.random(in: 0.99...1.0)
            let volume = Double.random(in: 1000...100000)

            let item = Self(
                time: time,
                open: open,
                close: close,
                high: high,
                low: low,
                volume: volume
            )

            items.append(item)
            lastClose = close
        }

        return items
    }
}
