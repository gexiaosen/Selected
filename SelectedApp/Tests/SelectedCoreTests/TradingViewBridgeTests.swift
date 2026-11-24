import XCTest
@testable import SwiftTradingView

/// 校验 TradingView 滚轮桥接快照与缩放边界逻辑（防 `#7` 值捕获锁死回退）。
final class TradingViewBridgeTests: XCTestCase {

    func testWheelBridgeAllowsZoomingDownToUpdatedLowerBoundAfterLoadEarlier() {
        let bridge = WheelHoverFlag()
        let viewport: CGFloat = 556
        // 首屏 500 根日 K：fit = 556/500/1.25 ≈ 0.89pt
        let fit500 = ChartZoomMath.fitCandleWidth(count: 500, viewportWidth: viewport,
                                                  configuredSpacing: 2, adaptive: true)
        bridge.isZoomable = true
        bridge.scrollDisabled = false
        bridge.viewportWidth = viewport
        bridge.candleWidth = fit500
        bridge.zoomLowerBound = max(0.1, fit500)
        bridge.zoomUpperBound = max(20, fit500)

        // 若没有扩容，在 500 根下限处已触底不能再缩小
        XCTAssertNil(bridge.stepZoomWidth(factor: 0.8), "触到 500 根下限时应停在下限")

        // 模拟两次 onLoadEarlier 后增至 1500 根（fit1500 ≈ 0.22pt → 新下限放宽到 0.22pt）
        let fit1500 = ChartZoomMath.fitCandleWidth(count: 1500, viewportWidth: viewport,
                                                   configuredSpacing: 2, adaptive: true)
        bridge.zoomLowerBound = max(0.1, fit1500)
        let stepped = bridge.stepZoomWidth(factor: 0.8)
        XCTAssertNotNil(stepped, "补齐至 1500 根后滚轮桥应立即读取新下限，不应锁死在旧值")
        XCTAssertLessThan(stepped!, fit500)
        XCTAssertGreaterThanOrEqual(stepped!, fit1500)
    }

    func testWheelBridgeClampsAnchorAndSkipsWhenDisabledOrScrollLocked() {
        let bridge = WheelHoverFlag()
        bridge.viewportWidth = 400
        bridge.x = nil
        XCTAssertEqual(bridge.resolvedAnchorX(), 200)

        bridge.x = 650
        XCTAssertEqual(bridge.resolvedAnchorX(), 400)

        bridge.candleWidth = 8
        bridge.zoomLowerBound = 1
        bridge.zoomUpperBound = 20
        bridge.scrollDisabled = true
        XCTAssertNil(bridge.stepZoomWidth(factor: 1.1))

        bridge.scrollDisabled = false
        bridge.isZoomable = false
        XCTAssertNil(bridge.stepZoomWidth(factor: 1.1))
    }
}
