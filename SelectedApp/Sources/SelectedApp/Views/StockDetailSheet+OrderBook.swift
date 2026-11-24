import SwiftUI
import SelectedCore

// MARK: - 详情页：图表右侧的盘口列（五档常驻 + 成交明细可折叠）
//
// ## 两个数据集分别按周期显示
// · **五档**：任何周期都显示 —— 它是"此刻的委托"，与看图的周期无关。
//   指数与港股**整列不出现**（接口对指数回全零、港股字段布局不同）——
//   与「资金流向」对 ETF 的处理一致：整列缺席，而不是留一列空壳。
// · **成交明细**：只在**分时**页显示。逐笔成交是日内的微观结构，挂在
//   日K/周K/月K 右侧没有可读的时间轴 —— 那三档看的是几十到几百根 K 线，
//   旁边放"最近 60 笔"只会让人以为它对应图上某一根。
//
// ⚠ 分时页能放右列的前提：槽宽已改成按实测图表宽现算
//   （`StockKLineChart.minuteSlotWidth(chartWidth:)`；原值 `524/240-1` 等于把
//   "640 窗、无右列"这一套布局当成常量）。否则图表被挤到 404pt 时仍按 524pt 画
//   ⇒ 下午那段被推到绘图区外，而分时又禁缩放，只能靠平移看到。
//
// ## 数据来源与刷新
// · 五档：`QuoteAPI.depth` —— 与行情同一条 `q=` 回包里的 f9…f28，纯解析；
// · 分笔：`QuoteAPI.ticks` —— 先 `action=last` 拿准确页数，再取末页（单次 2~5 个请求）。
// · **打开详情取一次 + 每 30s 复检一次**（与 Core 侧分笔缓存的 TTL 同值）。
//   ⚠ 不挂进 1 秒行情轮询：那样等于每秒重打分笔的分页请求。
//   折叠状态下不重取分笔（省请求），展开时若还没取到就立刻补一次。
//
// ## 不显示 / 降级（照接口真相）
// · 北交所：五档正常；分笔该接口返回空 body ⇒ 折叠头标「该接口无数据」，不报错。
// · 涨停/跌停：空档位换成一行文字，**不画 0 价档**（0 在本项目里是有意义的值）。
// · 只展示，不参与提醒判定（与资金流向 / 筹码分布同姿势）。
extension StockDetailSheet {

    /// 折叠状态的持久化键（与 `ChartSubPlot.defaultsKey` 同一套惯例）
    enum BookPrefs {
        static let ticksOpenKey = "detail.orderbook.ticksOpen"
    }

    /// 右列宽度：按内容实测（`卖5 8.58 102` / `买1 4.94 28.89万`）定的档
    static let bookColumnWidth: CGFloat = 168
    /// 展开后成交明细的限高（≈8 行）：超出内部滚动，**不撑高卡片**
    static let ticksPaneHeight: CGFloat = 132
    /// 复检间隔（与 Core 侧分笔缓存的 TTL 同值，改一边要改另一边）
    static let bookRefreshSeconds: Double = 30

    // MARK: 可见性

    /// 这一页是否放盘口列：**只有分时页**，且该标的有盘口（指数/港股没有 ⇒ 整列不出现）。
    var bookColumnVisible: Bool {
        guard period == .minute else { return false }
        let market = String(fullCode.prefix(2))
        guard market != "hk" else { return false }
        return !QuoteSymbol.isIndex(fullCode)
    }

    // MARK: 取数

    /// 盘口轮询：打开取一次，之后每 30s 复检（弹窗在 ⇒ 才打请求；关闭由 `.task` 取消）。
    func runOrderBookLoop() async {
        await refreshOrderBook()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.bookRefreshSeconds))
            guard !Task.isCancelled else { break }
            await refreshOrderBook()
        }
    }

    func refreshOrderBook() async {
        guard bookColumnVisible else { return }
        // 五档：与行情同一条回包，成本就是一次 `q=`
        if let d = await QuoteAPI.depth(code) {
            depth = d
            depthFailed = false
        } else {
            depthFailed = true
        }
        depthLoading = false
        // 分笔：只在展开时取（收起时这列只占一行标题，没必要每 30s 打一轮分页请求）
        guard ticksOpen else { return }
        await loadTicksIfNeeded(force: false)
    }

    /// 取分笔。`force = true` 时忽略"已有数据"（用户刚点开折叠头）。
    func loadTicksIfNeeded(force: Bool) async {
        guard bookColumnVisible, ticksOpen else { return }
        if !force && !ticks.isEmpty { return }
        switch await QuoteAPI.ticksOutcome(code, limit: 60) {
        case .loaded(let rows):
            ticks = rows
            ticksUnavailable = false
            ticksFailed = false
        case .unsupported:
            ticksUnavailable = true
            ticksFailed = false
        case .empty:
            ticksUnavailable = false
            ticksFailed = false
        case .failed:
            // 瞬时网络/解析失败：不伪装成"该接口无数据"，保留已有分笔等下一轮重试
            ticksUnavailable = false
            ticksFailed = true
        }
    }

    // MARK: 视图

    /// 图表右侧那一列。宽度固定，高度跟着图表走（340），明细超出即内滚。
    var orderBookColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            depthSection
            ticksSection
        }
        .frame(width: Self.bookColumnWidth, alignment: .leading)
        .overlay(alignment: .leading) {
            // 与图表之间的分隔只靠一条 hairline（不再加卡片底：这一列坐在图表卡里）
            Rectangle().fill(Tok.hairline).frame(width: 0.5)
                .padding(.vertical, 2)
        }
        .padding(.leading, 12)
    }

    private var depthSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let d = depth {
                levels(d.asks, side: "卖")
                midRow(d)
                levels(d.bids, side: "买")
            } else if depthLoading {
                ForEach(0..<11, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 3).fill(Tok.skeleton)
                        .frame(height: 12).padding(.vertical, 3)
                }
            } else {
                Text(depthFailed ? "盘口取不到" : "暂无盘口")
                    .font(AppFont.detail).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    /// 一档：`卖5 8.58 102`。**卖盘按卖五→卖一**（卖一贴近中间价），买盘按买一→买五。
    private func levels(_ rows: [QuoteLevel], side: String) -> some View {
        // 卖盘要反着排（卖五在最上），但**档位标号必须跟着原始下标**：
        // 按渲染顺序重新数会把整列卖档标号弄反（买一/卖一 会跑到最远的那一档上）。
        let view: [(n: Int, level: QuoteLevel)] = side == "卖"
            ? rows.enumerated().map { ($0.offset + 1, $0.element) }.reversed()
            : rows.enumerated().map { ($0.offset + 1, $0.element) }
        return VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text(side == "卖" ? "卖盘无委托" : "买盘无委托")
                    .font(AppFont.detail).foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(view, id: \.n) { item in
                    levelRow(side: side, n: item.n, level: item.level)
                }
            }
        }
    }

    private func levelRow(side: String, n: Int, level: QuoteLevel) -> some View {
        HStack(spacing: 4) {
            Text("\(side)\(n)")
                .font(AppFont.detailSmall).foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)
            Text(StockFmt.price(level.price, code: code))
                .font(AppFont.numeric(AppFont.bodySmall))
            Spacer(minLength: 2)
            Text(lots(level.volumeLots))
                .font(AppFont.numeric(AppFont.bodySmall))
                .foregroundStyle(.secondary)
        }
        // 买一 / 卖一是当前最活跃的两档，给一层底色（不是隔行纹）
        .padding(.vertical, 2).padding(.horizontal, 3)
        .background(n == 1 ? Tok.chip : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
    }

    private func midRow(_ d: QuoteDepth) -> some View {
        HStack(spacing: 4) {
            Text(StockFmt.price(d.bestBid ?? quote?.currentPrice, code: code))
                .font(AppFont.numeric(AppFont.bodySmall).weight(.semibold))
                .foregroundStyle(Sem.pnl(quote?.changePercent))
            Spacer(minLength: 2)
            Text(spreadText(d))
                .font(AppFont.detailSmall).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4).padding(.horizontal, 3)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { Rectangle().fill(Tok.hairline).frame(height: 0.5) }
        .overlay(alignment: .bottom) { Rectangle().fill(Tok.hairline).frame(height: 0.5) }
    }

    /// 中间行右侧：有双边挂单就报价差，被封死时报状态（不报一个 0 价差糊弄）
    private func spreadText(_ d: QuoteDepth) -> String {
        if d.asks.isEmpty { return "封涨停" }
        if d.bids.isEmpty { return "封跌停" }
        guard let a = d.bestAsk, let b = d.bestBid else { return "" }
        return "价差 " + StockFmt.price(a - b, code: code)
    }

    @ViewBuilder
    private var ticksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            foldHeader
            if ticksOpen {
                if ticks.isEmpty {
                    Text(ticksUnavailable ? "该接口无数据"
                         : (ticksFailed ? "分笔获取失败"
                            : (depthLoading ? "" : "暂无成交")))
                        .font(AppFont.detailSmall).foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // 新成交在上：盘口是"看现在"，往下翻才是更早的笔
                            ForEach(ticks.reversed(), id: \.index) { tickRow($0) }
                        }
                    }
                    .frame(height: Self.ticksPaneHeight)
                }
            }
        }
        .padding(.top, 4)
    }

    private var foldHeader: some View {
        Button {
            ticksOpen.toggle()
            if ticksOpen { Task { await loadTicksIfNeeded(force: true) } }
        } label: {
            HStack(spacing: 4) {
                Text("成交明细").font(AppFont.detail)
                Image(systemName: ticksOpen ? "chevron.up" : "chevron.down")
                    .font(AppFont.micro).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(ticksTail)
                    .font(AppFont.detailSmall).foregroundStyle(.secondary)
            }
            // ⚠ 命中区 = 整行（撑满列宽 + 把上下内边距也算进去）：
            //   只让"成交明细"四个字能点，是这一列最容易踩的坏体验（与周期胶囊同一条纪律）。
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(Tok.hairline).frame(height: 0.5) }
    }

    /// 折叠头右侧：已取到时报「最新一笔时间」，取不到时按状态提示或留空
    private var ticksTail: String {
        if ticksUnavailable { return "无数据" }
        if ticksFailed && ticks.isEmpty { return "失败" }
        return ticks.last.map { String($0.time.prefix(5)) } ?? ""
    }

    private func tickRow(_ t: TickTrade) -> some View {
        HStack(spacing: 4) {
            Text(String(t.time.prefix(5)))
                .font(AppFont.detailSmall).foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            Text(StockFmt.price(t.price, code: code))
                .font(AppFont.numeric(AppFont.detail))
            Spacer(minLength: 2)
            Text(lots(t.volumeLots))
                .font(AppFont.numeric(AppFont.detail)).foregroundStyle(.secondary)
            Circle().fill(sideColor(t.side)).frame(width: 4, height: 4)
                .padding(.leading, 2)
        }
        .padding(.vertical, 2.5).padding(.horizontal, 3)
    }

    /// 方向只给一个 4pt 圆点：整行涂色会和"红涨绿跌"抢语义（这行的价格是成交价，不是涨跌）
    private func sideColor(_ side: TickSide) -> Color {
        switch side {
        case .buy: return Sem.up
        case .sell: return Sem.down
        case .neutral: return Tok.dim
        }
    }

    /// 委托量/成交量：单位**手**，≥1万折「万」（列宽按内容实测，超宽会把价格挤掉）
    func lots(_ v: Double) -> String {
        if v >= 1_0000 { return String(format: "%.2f万", v / 1_0000) }
        return String(format: "%.0f", v)
    }
}
