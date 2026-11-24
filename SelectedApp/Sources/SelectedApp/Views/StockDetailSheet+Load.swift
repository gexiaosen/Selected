import SwiftUI
import SwiftTradingView
import SelectedCore

// MARK: - 数据加载与轮询（行情 / K 线 / 分时 / 各 Store 的读取）

extension StockDetailSheet {
    // MARK: 数据加载

    /// 行情轮询：分时页 1s（盘中实时体验，同步刷分时折线），其余 5s。弹窗在即刷新，关闭即停。
    ///
    /// ⚠ **不要嵌套 `Task`**：循环必须跑在 `.task` 自己的任务里、由 `.task` 生命周期统一取消 ——
    ///   若先 `await` 再新建 `Task`，`.onDisappear` 的取消可能落在 await 期间（句柄还没赋值），
    ///   新建的任务不继承取消 ⇒ 弹窗关闭后仍以 1s/5s 持续打行情、并写已消失视图的 @State。
    ///   不需要额外的 `quoteTask` 句柄，也就没有"赋值晚于取消"的窗口。
    func runQuoteLoop() async {
        await refreshTick()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(period == .minute ? 1 : 5))
            guard !Task.isCancelled else { break }
            await refreshTick()
        }
    }

    /// 单次刷新：行情 + （分时模式下）分时数据。
    /// 分时折线也走 1s 节奏（用户需求：页面每秒更新现价/成交量/折线）。
    /// 失败静默保留旧数据（轮询场景重试成本低，不闪错误提示）。
    private func refreshTick() async {
        if period == .minute {
            async let q = QuoteAPI.single(code)
            async let m = KLineService.fetchMinute(fullCode: fullCode)
            let (quoteResult, minuteResult) = await (q, m)
            if let q = quoteResult {
                quote = q
                quoteFailed = false
            } else if quote == nil {
                quoteFailed = true
            }
            if let res = minuteResult, !res.points.isEmpty {
                minute = res.points   // 增量到达：固定槽数组按时间归位，折线自动生长
                chartMinuteFallback = res.usedFallback
            }
        } else {
            await refreshQuote()
        }
    }

    private func refreshQuote() async {
        if let q = await QuoteAPI.single(code) {
            quote = q
            quoteFailed = false
        } else if quote == nil {
            quoteFailed = true
        }
    }

    /// 重新上锁「加载更早历史」，1.5 秒后放开。
    ///
    /// ⚠ 两处调用：① 打开详情（`.task`）；② **每次切周期**（`.onChange(of: period)`）——
    ///   切周期时图表被 `.id(period)` 重建，库又会在首帧报一次「偏移≈0」
    ///   （`scrollOffset <= step * 3`），此时 `allowLoadEarlier` 若已是 true ⇒ 误触发白拉一页。
    ///   与「首帧遮罩」是同一个成因（库把首帧 offset=0 当真）。
    func rearmLoadEarlier() {
        allowLoadEarlier = false
        rearmTask?.cancel()
        rearmTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            allowLoadEarlier = true
        }
    }

    /// 按周期加载 K 线 / 分时
    func loadChart() async {
        chartLoading = true
        chartError = nil
        chartKLineSource = nil
        chartKLineAdjusted = true
        chartMinuteFallback = false
        let fc = fullCode
        // 失败提示要能定位问题（含代码+周期），而不是笼统的"加载失败"
        if period == .minute {
            if let res = await KLineService.fetchMinute(fullCode: fc), !res.points.isEmpty {
                minute = res.points
                kline = []
                chartMinuteFallback = res.usedFallback
            } else {
                minute = []
                chartError = "分时数据获取失败（\(fc)）\n\(KLineService.minuteFailureSummary())\n"
                    + "可能原因：网络受限、该股停牌或非交易时段"
            }
        } else {
            if let res = await KLineService.fetchKLine(fullCode: fc, period: period,
                                                       count: KLineService.initialCount(for: period)),
               !res.items.isEmpty {
                let items = res.items
                kline = items
                minute = []
                chartKLineSource = res.source
                chartKLineAdjusted = res.adjusted
                // 日K顺带填派生卡片那一份（同一次请求、同一批 bar）—— 见 `dailyKline` 注释
                if period == .daily {
                    dailyKline = items
                    dailyKlineCode = fc
                    dailyKlineLoading = false
                }
                // 取回根数达到请求量 → 左侧可能还有更早历史，拖到最左时再分页拉
                hasMoreHistory = items.count >= KLineService.initialCount(for: period)
            } else {
                kline = []
                hasMoreHistory = false
                // 日K取失败 → 派生卡片该"不显示"，不能让骨架永远转下去
                if period == .daily { dailyKlineLoading = false }
                chartError = "\(period.displayName)数据获取失败（\(fc)）\n可能原因：网络受限或该股数据缺失"
            }
        }
        chartLoading = false
    }

    /// 加载**日K**（图表默认是分时，`kline` 里没有日K）—— 只服务"按交易日定义"的派生卡片。
    ///
    /// ⚠ 与 `loadChart` 共用 `KLineService.fetchKLine`、同参数（500 根），**不新增数据源**。
    /// ⚠ 图表本来就是日K时直接跳过：那时 `loadChart` 会把同一批 bar 写进 `dailyKline`，
    ///   再取一次等于白打一次腾讯。
    /// ⚠ 失败**静默**（不写 `chartError`）：图表本身好好的，派生卡片少几张不该让整块图表报错；
    ///   卡片自身在 `dailyKline` 为空时整张不显示（不是显示 0 或"无数据"）。
    func loadDailyBars() async {
        let fc = fullCode
        guard period != .daily else { return }             // 由 loadChart 顺带填（并复位 loading）
        guard dailyKlineCode != fc || dailyKline.isEmpty else {
            dailyKlineLoading = false
            return
        }
        defer { dailyKlineLoading = false }
        guard let res = await KLineService.fetchKLine(
            fullCode: fc, period: .daily, count: KLineService.initialCount(for: .daily)),
            !res.items.isEmpty else { return }
        guard !Task.isCancelled else { return }
        dailyKline = res.items
        dailyKlineCode = fc
    }

    /// 拖到最左边缘时补齐更早历史。
    /// 缺口口径：以**当前最早一根的日期**作为分页上界，取回的根数严格早于它才并入，
    /// 因此不会与已有数据重叠；取不到更多（含腾讯不可用）即停止分页，避免反复无效请求。
    func loadEarlierHistory() async {
        guard !loadingMoreHistory, hasMoreHistory, period != .minute,
              let oldest = kline.first?.date,
              let oldestDate = ChinaTime.parseDay(oldest) else { return }
        loadingMoreHistory = true
        defer { loadingMoreHistory = false }
        // 上界取"最早那根的前一天"，避免把当根重复取回
        let end = ChinaTime.calendar.date(byAdding: .day, value: -1, to: oldestDate) ?? oldestDate
        let res = await KLineService.fetchKLine(fullCode: fullCode, period: period,
                                                count: KLineService.pageSize(for: period),
                                                before: end)
        // ⚠ 取数期间可能已被取消（详情页关闭 / 切周期）——
        //   取消后不再 prepend，避免往已销毁视图写数据
        guard !Task.isCancelled else { return }
        let older = (res?.items ?? []).filter { $0.date < oldest }
        if older.isEmpty {
            hasMoreHistory = false      // 没有更早数据了（或分页不可用）→ 停止
        } else {
            kline = older + kline       // prepend：图表库检测到左侧补入会自动平移偏移，画面不跳
        }
    }

    static func fmtSigned(_ v: Double) -> String {
        (v >= 0 ? "+" : "") + String(format: "%.2f", v)
    }
}
