import SwiftUI
import SelectedCore

// MARK: - 板块热度

/// 行业板块的当日板块分析页。
///
/// ## 数据
/// 收盘后 15:10 调度任务落库（`BoardHeatJob`），页面只读库不现取
/// （源只有当日截面，盘中现取会把"未定稿的盘中值"当排行）。
/// 跟随全局 `viewDate`：选哪天看哪天。涨停相关（家数徽章 / 强度第四因子）
/// 取自同日 `limit_up_pool`（按行业名匹配，实测只对上一部分，拿不到的只是涨停加分）。
/// 强势股走成份接口 `BoardMembersSource`（按板块代码直查涨幅 Top5，历史口径回退涨停池列表）。
///
/// ## 版面
/// ```
/// ① 四张 KPI：最强主线 / 最大风险 / 涨跌板块 / 资金活跃
/// ② 左：板块矩阵（撑满剩余高度，可搜索 + 按 强度/涨幅/跌幅/成交额/龙头 排序，
///          不内部滚动、底部翻页，行数随窗口高度实时变化）
///    右：选中板块详情（强度构成 + 指标格 + 强势股 + 一句话分析）
/// ```
///
/// ⚠ 「强度」是当日横截面的相对强弱（四因子分位加权，公式见 `BoardStrength`），
///   不是收益预测；界面上如实标注口径（标题行的「强度口径」help）。
struct BoardView: View {
    private let store = Store.shared

    /// 矩阵排序维度
    private enum MatrixSort: String, CaseIterable {
        case strength = "强度", change = "涨幅", drop = "跌幅", amount = "成交额", leader = "龙头"
    }

    @State private var sort: MatrixSort = .strength
    @State private var query = ""
    /// 选中的板块代码（右侧详情跟随；nil = 用强度第一名兜底）
    @State private var selected: String?
    /// 详情里的强势股展开条数
    @State private var showAllLimitUp = false
    /// 矩阵当前页（0 起）；排序/搜索变化时回第 0 页
    @State private var page = 0
    /// 页面视口高（`FitScrollView` 的实测高 —— 有界、与渲染分支无关）
    @State private var viewportH: CGFloat = 0
    /// KPI 行实测高（自然高，不参与行数回路 ⇒ 无自指）
    @State private var kpiH: CGFloat = 0
    /// 矩阵卡实测高：右侧详情卡更高时左卡会被撑高，视口推算看不到这段余量
    @State private var matrixCardH: CGFloat = 0
    /// 矩阵表实测宽（表头与数据行共用这一份列宽，替代两套 HStack 各自算）
    @State private var matrixTableW: CGFloat = 0

    /// 矩阵**回退**行数（视口/KPI 高度还没量到的首帧用）
    private static let matrixViewportRows = 10

    var body: some View {
        VStack(spacing: 0) {
            PageActionBar {
                // ⚠ 这里不要写 `Spacer()`：`PageActionBar` 内部已有 `Spacer()` 把 content
                //   右对齐；多写一个会把日期推到左边
                DateChip()
                ActionBarButton(title: "更新", isBusy: store.busy.contains("boardheat"),
                                isDisabled: store.isHistorical,
                                helpText: store.isHistorical
                                    ? "源只有当日截面，历史日不可重抓（请回到最新交易日）"
                                    : "抓取当日板块行情（收盘定稿值，\(ScheduleTimes.shared.clock("boardheat")) 自动执行）") {
                    store.refreshBoardHeat()
                }
            }
            FitScrollView {
                content
                    .padding(16)
            }
            // 页面视口高（= 窗口详情区可用高，与内容无关 ⇒ 矩阵行数倒推的稳定输入）
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportH = $0 }
        }
        // 进入本页默认展示今天（板块热度要看最新实时信息）。
        //   ⚠ 副作用（已确认接受）：`viewDate` 是全局的 ⇒ 从历史日期切到本页，
        //   全局日期会被重置为今天，其它页面也跟着变。
        .task {
            if store.viewDate != store.today { store.jump(toDate: store.today) }
        }
    }

    @ViewBuilder
    private var content: some View {
        let rows = store.boardHeatRows
        if rows.isEmpty {
            emptyState
        } else {
            // ⚠ 强度只算一次（四因子分位扫描，别在每行里重算）
            //   —— 实际计算已上移到 `Store.loadBoardHeat()`（审查 B3）：
            //   `content` 会随任何 store 变化与搜索框每次击键重渲染，现算是每键一次全表扫描。
            let strength = store.boardStrength

            let focus = focused(rows, strength)
            VStack(spacing: 14) {
                kpiRow(rows, strength)
                    // KPI 行实测高（自然高、内容固定 ⇒ 矩阵行数倒推的另一路稳定输入）
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { kpiH = $0 }
                HStack(alignment: .top, spacing: 14) {
                    matrixCard(rows, strength)
                    detailCard(rows, strength, focus: focus)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            EmptyStateView(icon: "square.3.layers.3d",
                           title: "该日板块数据未入库",
                           hint: store.isHistorical
                                ? "板块行情每日 \(ScheduleTimes.shared.clock("boardheat")) 自动抓取（源只给当日截面，历史日无法补抓）"
                                : "收盘后 \(ScheduleTimes.shared.clock("boardheat")) 自动抓取，也可点右上角「更新」立即抓取",
                           compact: true,
                           actionTitle: "立即抓取",
                           actionDisabled: store.isHistorical || store.busy.contains("boardheat")) {
                store.refreshBoardHeat()
            }
            if store.boardHeatCoveredDays > 0 {
                RecentRecordHint(lead: "库内已覆盖 \(store.boardHeatCoveredDays) 个交易日") { d in
                    store.jump(toDate: d)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.top, 8)
    }

    // MARK: - 选中板块

    /// 当前详情焦点：选中项 → 强度第一名
    private func focused(_ rows: [BoardHeatPoint],
                         _ strength: [String: BoardStrength.Breakdown]) -> BoardHeatPoint? {
        if let code = selected, let hit = rows.first(where: { $0.boardCode == code }) { return hit }
        return rows.max { (strength[$0.boardCode]?.score ?? 0) < (strength[$1.boardCode]?.score ?? 0) }
    }

    private func limitUp(_ name: String) -> [LimitUpRecord] {
        store.boardLimitUpByIndustry[name] ?? []
    }

    // MARK: - ① KPI

    private func kpiRow(_ rows: [BoardHeatPoint],
                        _ strength: [String: BoardStrength.Breakdown]) -> some View {
        let best = rows.max { (strength[$0.boardCode]?.score ?? 0) < (strength[$1.boardCode]?.score ?? 0) }
        let worst = rows.min { $0.changePct < $1.changePct }
        let upBoards = rows.filter { $0.changePct > 0 }.count
        let downBoards = rows.filter { $0.changePct < 0 }.count
        let totalNet = rows.reduce(0) { $0 + $1.mainNet }
        let netIn = rows.filter { $0.mainNet > 0 }.count
        let topNet = rows.max { $0.mainNet < $1.mainNet }
        return HStack(alignment: .top, spacing: 12) {
            // ⚠ 四枚 KPI 图标**一律中性**（2026-10-22 P5 / 设计文档 M5）：
            //   改造前「最强主线」是红、「最大风险」是**绿**、「涨跌板块」蓝、「资金活跃」紫 ——
            //   绿色在本 App 里 = 跌 / 完成 / 绿灯可操作，紫色 = 最强信号 / 极高风险，
            //   把它们用在**装饰性图标**上，等于让颜色不再只在数据上才有意义。
            //   方向与好坏仍然可读：`sub` 里的百分比恒带 `+/-`，「下跌 N 家」是文字。
            kpiCard("最强主线", icon: "flame.fill", tint: Tok.dim,
                    main: best?.boardName ?? "—",
                    sub: best.map { String(format: "%+.2f%%　强度 %.0f", $0.changePct,
                                           strength[$0.boardCode]?.score ?? 0) } ?? "")
            kpiCard("最大风险", icon: "exclamationmark.triangle.fill", tint: Tok.dim,
                    main: worst?.boardName ?? "—",
                    sub: worst.map { String(format: "%+.2f%%　下跌 %d 家", $0.changePct, $0.downCount) } ?? "")
            kpiCard("涨跌板块", icon: "arrow.up.arrow.down", tint: Tok.dim,
                    main: "\(upBoards) / \(downBoards)",
                    sub: "上涨 / 下跌（共 \(rows.count) 个）")
            kpiCard("资金活跃", icon: "banknote.fill", tint: Tok.dim,
                    main: StockFmt.signedFlowYi(totalNet),
                    sub: "净流入 \(netIn) 个　最多 \(topNet?.boardName ?? "—")")
        }
    }

    private func kpiCard(_ title: String, icon: String, tint: Color,
                         main: String, sub: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: icon).font(.caption).foregroundStyle(tint)
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                Text(main).font(.title3.weight(.medium)).lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - ② 板块矩阵（撑满剩余高度 + 翻页）

    /// 矩阵卡 chrome 固定开销（卡内边距 32 + 标题行 ~29 + 工具行 ~30 + 表头 28 +
    /// 分隔线 1 + 翻页条 ~30）—— 行区可用高 = 卡片高 − 这个
    /// ⚠ 2026-10-26 表格统一：表头/行高改读 `TableMetrics`（28/30），这枚常量随之 122→130。
    private static let matrixChrome: CGFloat = 130

    /// 每页行数：`视口高 − KPI 行 − 间距 − 内边距 − chrome` 倒推（行高 = `TableMetrics.rowHeight`，
    /// 与全站表格同一枚常量 —— 各页各写一份行高就是老板 2026-10-26 报"行高不对、还是没统一"的来源）。
    /// ⚠ 输入必须全部来自与渲染分支无关的量（视口实测高 + KPI 自然高）：
    ///   量"行区自身实测高"会形成自指回路（卡片撑住行区、行区又撑住卡片），
    ///   窗口缩小方向永远量不到变矮，行数双向不跟手。
    private func visibleRowCount() -> Int {
        guard viewportH.isFinite, viewportH > 0, kpiH > 0 else { return Self.matrixViewportRows }
        let expected = viewportH - 32 - kpiH - 14
        let viewportPer = max(1, Int((expected - Self.matrixChrome) / TableMetrics.rowHeight))
        // 卡片被右侧详情撑得比视口推算更高时，用实测高把多出来的行补上；
        // 多补上限 8 行，防止滚动模式下"行数↑→卡高↑→行数↑"的自激。
        guard matrixCardH.isFinite, matrixCardH > 0, matrixCardH >= expected - 1 else {
            return viewportPer
        }
        let measuredPer = max(1, Int((matrixCardH - Self.matrixChrome) / TableMetrics.rowHeight))
        return min(max(viewportPer, measuredPer), viewportPer + 8)
    }

    private func matrixCard(_ rows: [BoardHeatPoint],
                            _ strength: [String: BoardStrength.Breakdown]) -> some View {
        let hits = sortedMatrixRows(rows, strength)
        let per = visibleRowCount()
        let pageCount = max(1, (hits.count + per - 1) / per)
        // 窗口拉高每页条数变多 ⇒ 当前页可能越界：就地收敛，不回写 @State（body 里不写状态）
        let pageIdx = min(page, pageCount - 1)
        let slice = hits.isEmpty ? [] : Array(hits[(pageIdx * per)..<min((pageIdx + 1) * per, hits.count)])
        return Card {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("板块矩阵").font(.title3.weight(.medium))
                    Text("\(hits.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("强度口径").font(.caption2).foregroundStyle(.secondary)
                        .help("强度 = 当日全板块内的「相对」强弱：\n"
                              + "40% 涨幅分位 + 25% 上涨家数占比 + 20% 主力净流入分位 + 15% 涨停家数分位。\n"
                              + "不含未来信息，不是收益预测；只有同一天内的比较才有意义。")
                }
                .padding(.bottom, 8)

                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(.tertiary)
                        TextField("搜索板块", text: $query)
                            .textFieldStyle(.plain).font(.caption)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Tok.chip, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Tok.stroke))
                    .frame(maxWidth: 170)
                    Spacer(minLength: 4)
                    ForEach(MatrixSort.allCases, id: \.self) { s in
                        Button {
                            sort = s
                        } label: {
                            Text(s.rawValue)
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(sort == s ? Tok.chipStrong : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(sort == s ? Color.primary : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 6)

                if hits.isEmpty {
                    Text("没有匹配「\(query)」的板块")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                        .frame(maxHeight: .infinity)
                } else {
                    // 表头与所有数据行放进**同一个 Grid**：列宽由 Grid 统一，表头不会再和数据错位。
                    let nameW = max(88, matrixTableW - 270)
                    Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow {
                            Text("#").frame(width: 22, alignment: .trailing)
                            Text("板块").frame(width: nameW, alignment: .leading)
                            Text("涨幅").frame(width: 64, alignment: .trailing)
                            Text("净流入").frame(width: 82, alignment: .trailing)
                            Text("强度").frame(width: 92, alignment: .trailing)
                        }
                        .font(TableMetrics.headerFont)
                        .foregroundStyle(TableMetrics.headerColor)
                        .frame(height: TableMetrics.headerHeight)
                        GridRow {
                            TableRule().gridCellColumns(5)
                        }
                        ForEach(Array(slice.enumerated()), id: \.offset) { idx, r in
                            matrixRow(rank: pageIdx * per + idx + 1, r: r,
                                      strength: strength[r.boardCode], nameW: nameW)
                        }
                    }
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { matrixTableW = $0 }
                    .frame(height: CGFloat(slice.count) * TableMetrics.rowHeight
                           + TableMetrics.headerHeight + 1)

                    Spacer(minLength: 0)

                    // 翻页条（贴卡片底部，不随内容滚动）
                    HStack(spacing: 10) {
                        Button {
                            page = max(0, pageIdx - 1)
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "chevron.left").font(.caption2)
                                Text("上一页").font(.caption2)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(pageIdx == 0)
                        Text("第 \(pageIdx + 1) / \(pageCount) 页")
                            .font(AppFont.numeric(.caption2)).foregroundStyle(.secondary)
                        Button {
                            page = min(pageCount - 1, pageIdx + 1)
                        } label: {
                            HStack(spacing: 2) {
                                Text("下一页").font(.caption2)
                                Image(systemName: "chevron.right").font(.caption2)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(pageIdx >= pageCount - 1)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                }
            }
        }
        // 撑满主窗口下方剩余空间（行数钉死 ⇒ 卡片高 = 内容 + Spacer 吸收富余，无自指）
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 实测卡片高（只用来补"被右侧详情撑高"的余量，见 `visibleRowCount()`）
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { matrixCardH = $0 }
        // 排序/搜索变了 ⇒ 回到第一页（旧页码对新结果集没有意义）
        .onChange(of: sort) { page = 0 }
        .onChange(of: query) { page = 0 }
    }

    private func sortedMatrixRows(_ rows: [BoardHeatPoint],
                                  _ strength: [String: BoardStrength.Breakdown]) -> [BoardHeatPoint] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? rows : rows.filter {
            $0.boardName.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || $0.boardCode.range(of: q, options: [.caseInsensitive]) != nil
        }
        switch sort {
        case .strength: return base.sorted { (strength[$0.boardCode]?.score ?? 0) > (strength[$1.boardCode]?.score ?? 0) }
        case .change:   return base.sorted { $0.changePct > $1.changePct }
        case .drop:     return base.sorted { $0.changePct < $1.changePct }
        case .amount:   return base.sorted { $0.amount > $1.amount }
        case .leader:   return base.sorted { limitUp($0.boardName).count > limitUp($1.boardName).count }
        }
    }

    @ViewBuilder
    private func matrixRow(rank: Int, r: BoardHeatPoint, strength: BoardStrength.Breakdown?,
                           nameW: CGFloat) -> some View {
        let score = strength?.score ?? 0
        let lus = limitUp(r.boardName)
        let bg = selected == r.boardCode ? Tok.chip : Color.clear
        func cell<C: View>(@ViewBuilder _ content: () -> C) -> some View {
            content()
                .frame(height: TableMetrics.rowHeight)
                .contentShape(Rectangle())
                .onTapGesture { selected = r.boardCode }
                .clickableRow()
                .background(bg)
        }
        return GridRow {
            cell {
                Text("\(rank)")
                    .frame(width: 22, alignment: .trailing)
                    .font(TableMetrics.rowNumericFont).foregroundStyle(Tok.dim)
            }
            cell {
                HStack(spacing: 4) {
                    Text(r.boardName).font(TableMetrics.rowFont).lineLimit(1)
                    if !lus.isEmpty {
                        Text("\(lus.count)")
                            .font(AppFont.numeric(.caption2))
                            .padding(.horizontal, 3)
                            .background(Tok.tint(Sem.up, .chip), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(Sem.up)
                    }
                }
                .frame(width: nameW, alignment: .leading)
            }
            cell {
                Text(String(format: "%+.2f%%", r.changePct))
                    .frame(width: 64, alignment: .trailing)
                    .font(TableMetrics.rowNumericFont)
                    .foregroundStyle(Sem.pnl(r.changePct))
            }
            cell {
                Text(StockFmt.signedFlowYi(r.mainNet))
                    .frame(width: 82, alignment: .trailing)
                    .font(TableMetrics.rowNumericFont)
                    .foregroundStyle(Sem.pnl(r.mainNet))
            }
            cell {
                HStack(spacing: 0) {
                    Text(String(format: "%.0f", score))
                        .frame(width: 40, alignment: .trailing)
                        .font(TableMetrics.rowNumericFont.weight(.medium))
                        .foregroundStyle(score >= 70 ? Sem.up : (score <= 30 ? Sem.down : Color.secondary))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Tok.chip)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(score >= 50 ? Sem.up : Sem.down)
                                .frame(width: max(geo.size.width * score / 100, 2))
                        }
                    }
                    .frame(width: 52, height: 6)
                }
                .frame(width: 92, alignment: .trailing)
            }
        }
    }

    // MARK: - ③ 右：板块详情

    private func detailCard(_ rows: [BoardHeatPoint],
                            _ strength: [String: BoardStrength.Breakdown],
                            focus: BoardHeatPoint?) -> some View {
        Card {
            // 详情不内部滚动。
            // ⚠ `Spacer` 让卡内内容吃满行高 ⇒ `Card` 的背景表面跟着撑到整行
            //   （否则只有外层 frame 变大、表面仍停在内容自然高，底边看着没对齐）；
            //   超页滚动分支里 Spacer 塌成 0 ⇒ 表面 = 内容自然高，不裁切。
            VStack(spacing: 0) {
                if let r = focus, let b = strength[r.boardCode] {
                    detailBody(r, b)
                } else {
                    Text("选择左侧任一板块查看详情")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                }
                Spacer(minLength: 0)
            }
        }
        // 详情与矩阵底边对齐：撑满行高，内容顶部对齐、富余留在卡内；
        // 超页滚动分支里 `maxHeight:.infinity` 自动塌回内容自然高，不会裁切。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 焦点板块变化时按需抓成份涨幅榜（强势股）。
        // ⚠ 挂在 `detailCard` 而不是页面顶层：焦点板块在这里才算得出来（选中项→强度第一名兜底）。
        // ⚠ id 带上 `viewDate`：切到历史日再切回同一板块时，缓存已按日清空但板块代码没变
        //   ⇒ 光用 boardCode 做 id 不会重触发（元组不满足 Equatable ⇒ 拼字符串）。
        //   已有缓存 / 在途 / 历史口径时 `loadBoardMembers` 自己短路，重复触发无额外请求。
        .task(id: "\(store.viewDate)|\(focus?.boardCode ?? "")") {
            if let code = focus?.boardCode { store.loadBoardMembers(for: code) }
        }
    }

    @ViewBuilder
    private func detailBody(_ r: BoardHeatPoint, _ b: BoardStrength.Breakdown) -> some View {
        // 强势股（该板块涨幅 Top5，成份接口按板块代码直查）。
        // ⚠ 不用「涨停池按行业名 join」：`hybk` 被截断到 4 字、申万粒度对不上，实测只对上一部分，
        //   且默认选中的最强板块往往恰好匹配 0 只涨停 → 常年"今日无涨停"。
        //   历史口径成份接口抓不到（源只给实时），回退到当日涨停池列表。
        let members = Array((store.boardMembersByCode[r.boardCode] ?? []).prefix(5))
        let loading = store.boardMembersLoadingCodes.contains(r.boardCode)
        let lus = limitUp(r.boardName).sorted { ($0.boards, $0.changePct) > ($1.boards, $1.changePct) }
        let shownMembers = showAllLimitUp ? members : Array(members.prefix(3))
        let shownLimitUp = showAllLimitUp ? lus : Array(lus.prefix(5))
        let breadth = max(r.upCount + r.downCount + r.flatCount, 1)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(r.boardName).font(.title3.weight(.medium))
                Text(String(format: "%.0f", b.score))
                    .font(AppFont.numeric(.title3.weight(.semibold)))
                    .foregroundStyle(b.score >= 70 ? Sem.up : (b.score <= 30 ? Sem.down : Color.secondary))
                Text("强度").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(r.boardCode).font(.caption2).foregroundStyle(.secondary)
            }

            // 指标格（2×3）
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)], spacing: 8) {
                metric("涨幅", String(format: "%+.2f%%", r.changePct), Sem.pnl(r.changePct))
                metric("上涨占比", String(format: "%.0f%%", 100.0 * Double(r.upCount) / Double(breadth)), .primary)
                metric("主力净流入", StockFmt.signedFlowYi(r.mainNet), Sem.pnl(r.mainNet))
                metric("成交额", yiPlain(r.amount), .primary)
                metric("换手率", String(format: "%.2f%%", r.turnoverRate), .primary)
                metric("总市值", yiPlain(r.totalCap), .primary)
                metric("板块指数", String(format: "%.2f", r.index), .primary)
                metric("平盘家数", "\(r.flatCount)", .primary)
                metric("领涨股", r.leaderName.isEmpty ? "—" : r.leaderName, .primary)
            }

            // 强度构成（四因子分位）
            VStack(alignment: .leading, spacing: 5) {
                Text("强度构成").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                factorBar("涨幅分位", b.changePctile, "40%")
                factorBar("上涨占比", b.upRatio, "25%")
                factorBar("净流入分位", b.netPctile, "20%")
                factorBar("涨停分位", b.limitUpPctile, "15%")
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("强势股").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(store.isHistorical ? "当日涨停" : "涨幅 Top\(members.count)")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if store.isHistorical ? lus.count > 5 : members.count > 3 {
                        Button(showAllLimitUp ? "收起"
                               : (store.isHistorical ? "全部 \(lus.count)" : "全部 \(members.count)")) {
                            showAllLimitUp.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(Sem.brand)
                    }
                }
                if store.isHistorical {
                    if lus.isEmpty {
                        Text("该板块当日没有涨停股（历史日成份行情不可回补，此处按涨停池行业名匹配）")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(shownLimitUp.enumerated()), id: \.offset) { _, s in
                            HStack(spacing: 6) {
                                Text(s.name).font(AppFont.bodySmall).lineLimit(1)
                                Text(s.code).font(AppFont.monoSmall).foregroundStyle(.secondary)
                                if s.boards > 1 {
                                    Text("\(s.boards)板")
                                        .font(AppFont.numeric(.caption2))
                                        .padding(.horizontal, 3)
                                        .background(Tok.tint(Sem.up, .chip), in: RoundedRectangle(cornerRadius: 3))
                                        .foregroundStyle(Sem.up)
                                }
                                Spacer(minLength: 4)
                                Text(yiPlain(s.amount)).font(AppFont.numeric(.caption2)).foregroundStyle(.secondary)
                                Text(String(format: "%+.2f%%", s.changePct))
                                    .frame(width: 54, alignment: .trailing)
                                    .font(AppFont.numeric(.caption)).foregroundStyle(Sem.pnl(s.changePct))
                            }
                        }
                    }
                } else if loading && members.isEmpty {
                    Text("成份行情加载中…")
                        .font(.caption).foregroundStyle(.secondary)
                } else if members.isEmpty {
                    Text("该板块成份行情暂未取到（源可能限流，切换板块后重试）")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(shownMembers.enumerated()), id: \.offset) { _, s in
                        HStack(spacing: 6) {
                            Text(s.name).font(AppFont.bodySmall).lineLimit(1)
                            Text(s.code).font(AppFont.monoSmall).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text(yiPlain(s.amount)).font(AppFont.numeric(.caption2)).foregroundStyle(.secondary)
                            Text(String(format: "%+.2f%%", s.changePct))
                                .frame(width: 54, alignment: .trailing)
                                .font(AppFont.numeric(.caption)).foregroundStyle(Sem.pnl(s.changePct))
                        }
                    }
                }
            }

            Divider()

            // 一句话分析（**只陈述事实**，不给预测/建议）
            Text(narrative(r, b))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metric(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(AppFont.numeric(.caption.weight(.medium))).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private func factorBar(_ label: String, _ pctile: Double, _ weight: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Tok.chip)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Tok.tint(Sem.info, .strong))
                        .frame(width: max(geo.size.width * min(max(pctile, 0), 1), 2))
                }
            }
            .frame(height: 5)
            Text(String(format: "%.0f%%", pctile * 100))
                .font(AppFont.numeric(.caption2)).foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
            Text(weight).font(.caption2).foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
        }
    }

    /// 一句话分析：**只描述当日事实**（排名 / 家数 / 资金 / 涨停），不含预测与建议
    private func narrative(_ r: BoardHeatPoint, _ b: BoardStrength.Breakdown) -> String {
        let all = store.boardHeatRows
        let rank = all.filter { $0.changePct > r.changePct }.count + 1
        let breadth = max(r.upCount + r.downCount + r.flatCount, 1)
        var parts: [String] = []
        parts.append("涨幅 \(String(format: "%+.2f%%", r.changePct))，居全部 \(all.count) 个板块第 \(rank) 位")
        parts.append("上涨 \(r.upCount) / 下跌 \(r.downCount) 家（占比 \(String(format: "%.0f%%", 100.0 * Double(r.upCount) / Double(breadth)))）")
        parts.append("主力净流入 \(StockFmt.signedFlowYi(r.mainNet))")
        if b.limitUpCount > 0 { parts.append("涨停 \(b.limitUpCount) 只") }
        if !r.leaderName.isEmpty { parts.append("领涨 \(r.leaderName)") }
        return "当日：" + parts.joined(separator: "；") + "。"
            + "（强度 \(String(format: "%.0f", b.score)) 为当日全板块内的相对分位加权，非收益预测）"
    }

    // MARK: - 数字格式

    /// 元 → 亿 / 万亿（成交额、市值这类量级差异大的字段仍分档）
    private func yiPlain(_ v: Double) -> String {
        if v >= 1e12 { return String(format: "%.2f 万亿", v / 1e12) }
        if v >= 1e8 { return String(format: "%.1f 亿", v / 1e8) }
        if v >= 1e4 { return String(format: "%.0f 万", v / 1e4) }
        return String(format: "%.0f", v)
    }
}

#Preview("板块（真实库 · 禁网络）") {
    Store.shared.previewMode = true
    return BoardView()
        .frame(width: 1180, height: 820)
}
