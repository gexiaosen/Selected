import SwiftUI
import SwiftTradingView
import SelectedCore

// MARK: - 详情页卡片（二）：策略命中 → 超买超卖 → 基本面 → 资金流向 → 龙虎榜 → 尾盘结构

extension StockDetailSheet {
    // MARK: 资金流向

    /// 资金流向：**主力资金最近在进还是在出**。
    ///
    /// ⚠ **只展示、不参与评分**（见 `FundFlowSource` 文件头与
    /// `docs/specs/README.md`）。
    /// 与筹码分布的区别：筹码是纯计算的派生量（可随时从日K重算，故不落库），
    /// 资金流是**外部时点数据**（今天不记下来就永久取不回）→ 必须落库。
    ///
    /// ## 口径（必须写在界面上）
    ///
    /// 展示的是 **`r0_net`（主力净额 = 超大单 + 大单）**，**不是** `netamount`（总净流入）。
    /// 两个字段实测都存在且含义不同，混用会让"主力"二字失去意义。
    ///
    /// ## 数据从哪来
    ///
    /// 先读库（收盘后调度任务每天写一行），库里不足 `defaultHistoryDays` 天时
    /// **回源一次并落库**。所以首次打开某只票会等一次网络（约 1MB，见 `loadFundFlow`），
    /// 之后都走库（毫秒级）。
    @ViewBuilder
    var fundFlowCard: some View {
        // 非 `securities` 里的标的（ETF / 指数 / 搜索到的冷门代码）不显示这张卡：
        // `stock_fund_flows` 的口径是「A 股个股」，见 `FundFlowStore.isKnownStock`。
        // 用 `EmptyView` 而不是"显示一张空卡"—— 后者会让用户以为"这只票没有资金流"，
        // 而真相是"这张表不装这类标的"。
        if !fundFlowUnsupported { fundFlowCardBody }
    }

    private var fundFlowCardBody: some View {
        Card("资金流向", subtitle: fundFlowSubtitle) {
            if let s = FundFlowStats.summarize(fundFlow) {
                VStack(alignment: .leading, spacing: 9) {
                    fundFlowBars(fundFlow)
                    HStack(spacing: 14) {
                        flowCell("最近一日", StockFmt.signedFlow(s.latestMainNet),
                                 (s.latestMainNet ?? 0) >= 0)
                        flowCell("近 \(s.days) 日累计", StockFmt.signedFlow(s.sumMainNet), s.isNetInflow)
                        flowCell("净流入天数", "\(s.inflowDays) / \(s.days)", s.inflowRatio >= 0.5)
                        flowCell("最近连续流入",
                                 s.consecutiveInflow > 0 ? "\(s.consecutiveInflow) 天" : "—",
                                 s.consecutiveInflow > 0)
                    }
                    CaliberTip(text: "主力净额 = 超大单 + 大单（新浪 r0_net），单位元 · 只展示，不参与评分",
                               title: "资金流口径")
                }
            } else if fundFlowLoading {
                // 骨架用与数字块**逐行等高**的占位，避免加载完成时跳动（与 chipCard 同款）
                VStack(alignment: .leading, spacing: 9) {
                    RoundedRectangle(cornerRadius: 4).fill(Tok.skeleton).frame(height: 32)
                    RoundedRectangle(cornerRadius: 4).fill(Tok.skeleton).frame(height: 30)
                }
            } else {
                Text("暂无资金流数据 · 收盘后自动抓取（每只票需先有至少一个交易日的记录）")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 逐日主力净额迷你柱：红 = 净流入、绿 = 净流出（A股惯例），高度按绝对值归一。
    private func fundFlowBars(_ pts: [FundFlowPoint]) -> some View {
        // ⚠ 归一化基准取**绝对值最大值**而不是最大值：全为流出时用最大值（负数）做分母
        //   会让所有柱子高度变负 → 画面空白，而且不报错。
        let peak = max(pts.map { abs($0.mainNet) }.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(pts, id: \.date) { p in
                Capsule()
                    .fill(p.mainNet >= 0 ? Tok.tint(Sem.up, .strong) : Tok.tint(Sem.down, .strong))
                    .frame(width: 5, height: max(2, 30 * abs(p.mainNet) / peak))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 32, alignment: .bottom)
        .help("从左到右：由早到晚")
    }

    /// ⚠ 收敛到 `MetricCell`：`positive` 就是它的 `valueColor`。
    func flowCell(_ label: String, _ value: String, _ positive: Bool) -> some View {
        MetricCell(label: label, value: value, valueColor: positive ? Sem.up : Sem.down)
    }

    private var fundFlowSubtitle: String {
        guard let s = FundFlowStats.summarize(fundFlow) else { return "" }
        return "近 \(s.days) 个交易日 · 截至 \(s.latestDate ?? "—")"
    }

    /// 读资金流：**库优先**，不足则回源一次并落库。
    ///
    /// ⚠ 回源必须在后台：新浪这个端点**忽略 `num`**（实测 `num=1`/`5`/`20` 都返回
    /// 4017 行 / 1,092,141 字节 ≈ 全部历史），一次就是 1MB，放主线程会卡住整个窗口。
    ///
    /// ⚠ 落库失败**不影响展示**（只是下次还要再下一次），所以 catch 后仍用 `fetched` ——
    /// 用户看得到数据，比"因为写库失败所以什么都不显示"合理。
    func loadFundFlow() async {
        fundFlowLoading = true
        // 口径闸门：只有 `securities` 里的 A 股个股才进这张表（详情页对任何代码都能打开，
        // 但 ETF / 指数不该被写进「个股资金流」）。与 `FundFlowJob` 用同一个全集。
        guard FundFlowStore.isKnownStock(code) else {
            fundFlowUnsupported = true
            fundFlow = []
            fundFlowLoading = false
            return
        }
        fundFlowUnsupported = false
        let days = FundFlowSource.defaultHistoryDays
        let cached = FundFlowStore.history(code: code, days: days)
        if cached.count >= days {
            fundFlow = cached
            fundFlowLoading = false
            return
        }
        let fetched = await Task.detached(priority: .utility) {
            FundFlowSource.fetchHistory(code: code, days: days)
        }.value
        guard !Task.isCancelled else { return }
        if !fetched.isEmpty {
            do { try FundFlowStore.save(fetched) }
            catch { NSLog("[ERROR] 资金流回填落库失败（%@）：%@", code, String(describing: error)) }
            fundFlow = Array(fetched.suffix(days))
        } else {
            fundFlow = cached
        }
        fundFlowLoading = false
    }

    // MARK: 龙虎榜

    /// 龙虎榜：**这只票最近一次为什么上榜、谁在买卖**。
    ///
    /// ⚠ **只展示、不参与评分**（见 `LhbSource` 文件头与
    /// `docs/specs/README.md`）。
    ///
    /// ## 口径（必须写在界面上）
    ///
    /// · 只含交易所**公布的前 5 个买卖席位** —— 那是龙虎榜的公布口径本身，不是抓漏
    /// · 同一日可有多条上榜口径（涨幅偏离 / 换手率 / 连续三日累计…）：**原因全列**，
    ///   但**金额与席位只取一条**（当日净额最大者，界面上用「金额依据」标出）——
    ///   实测有两条口径金额完全相同，逐条展示会像重复抓取（见 `LhbDigest`）
    /// · 席位里的「机构专用」是交易所**匿名化**的机构席位（`dept_code` 为 `0`），
    ///   同一家机构可能拆成多行 → **行数 ≠ 机构家数**，所以不做"机构合计"这类推算
    ///
    /// ## 数据从哪来
    ///
    /// **只读库**（收盘后 17:30 的调度任务写入，并会回看补漏最近几个交易日）。
    /// **不回源**：东财的龙虎榜接口是**按日出全量**的（一次 68 只 / 680 条席位），
    /// 为看一只票去拉一整天的数据，是点开详情不该付的代价 —— 那是 `LhbJob` 的活。
    ///
    /// ⚠ **不做 `securities` 口径闸门**（与资金流卡不同）：龙虎榜的标的集合**不是** `securities`
    /// —— 北交所个股会合法上榜却不在 `securities` 里（实测 `920427 华维设计`）。
    /// 用 `isKnownStock` 当闸门会**把北交所的卡整个隐藏掉**。ETF / 指数确实不会上榜，
    /// 那种情况下"未上榜"本身就是真实结论。
    @ViewBuilder
    var lhbCard: some View {
        Card("龙虎榜", subtitle: lhbSubtitle) {
            if let c = lhb {
                VStack(alignment: .leading, spacing: 9) {
                    // 上榜原因（可能多条，逐条列出）
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(c.reasons, id: \.self) { r in
                            HStack(alignment: .top, spacing: 4) {
                                Text("·").font(AppFont.detail).foregroundStyle(.secondary)
                                Text(r).font(AppFont.detail).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if c.caliberCount > 1, r == c.primary.explanation {
                                    miniBadge("金额依据", Sem.info)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    HStack(spacing: 14) {
                        // 净额有方向（红=净买入），其余三项都是正数 —— 涂色会误导
                        flowCell("净额", StockFmt.signedFlow(c.primary.netAmount), c.primary.netAmount >= 0)
                        plainCell("买入额", StockFmt.signedFlow(c.primary.buyAmount))
                        plainCell("卖出额", StockFmt.signedFlow(c.primary.sellAmount))
                        plainCell("成交占比", pct(c.primary.dealAmountRatio))
                    }
                    if !lhbSeats.isEmpty { lhbSeatList }
                    CaliberTip(text: "交易所公开披露的龙虎榜 · 只含公布的前 5 买卖席位"
                               + " · 金额单位元 · 只展示，不参与评分",
                               title: "龙虎榜口径")
                }
            } else if lhbLoading {
                // 骨架用与数字块**逐行等高**的占位，避免加载完成时跳动（与 chipCard 同款）
                VStack(alignment: .leading, spacing: 9) {
                    RoundedRectangle(cornerRadius: 4).fill(Tok.skeleton).frame(height: 16)
                    RoundedRectangle(cornerRadius: 4).fill(Tok.skeleton).frame(height: 30)
                }
            } else if let cov = lhbCoverage {
                // ⚠ 有覆盖数据但这只票没记录 → **"未上榜"是有价值的信息**，不是"数据缺失"
                Text("数据截至 \(cov) · 该股未上榜")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                // 表是空的 → 这才是"还没抓到"，不能与上一档混为一谈
                Text("龙虎榜数据尚未抓取 · 收盘后 \(ScheduleTimes.shared.clock("lhb")) 自动抓取")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 买入前五 / 卖出前五席位。每行：排名 · 营业部 · 标记 · 金额
    private var lhbSeatList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(LhbSource.sides, id: \.self) { side in
                let rows = lhbSeats.filter { $0.side == side }
                if !rows.isEmpty {
                    Text(side == "BUY" ? "买入前五席位" : "卖出前五席位")
                        .font(AppFont.detailSmall.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(rows, id: \.rank) { s in
                        HStack(spacing: 6) {
                            Text("\(s.rank)")
                                .font(AppFont.detailSmall).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 12, alignment: .trailing)
                            Text(s.deptName)
                                .font(AppFont.detail)
                                .lineLimit(1).truncationMode(.middle)
                            if s.isInstitution { miniBadge("机构专用", Sem.accent) }
                            if s.isStockConnect { miniBadge("股通", Sem.info) }
                            Spacer(minLength: 4)
                            Text(StockFmt.signedFlow(side == "BUY" ? s.buy : s.sell))
                                .font(AppFont.monoSmall.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// 小标签（机构专用 / 股通 / 金额依据）。色底统一走 `Tok.tint`，不写裸透明度。
    func miniBadge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(AppFont.micro.weight(.semibold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Tok.tint(color), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
    }

    /// 中性数字块（金额本身没有方向时用：买入额 / 卖出额都是正数，
    /// 涂红涂绿都会让"红=涨"的既有语义串味）
    /// ⚠ 收敛到 `MetricCell`。
    func plainCell(_ label: String, _ value: String) -> some View {
        MetricCell(label: label, value: value)
    }

    /// ⚠ 东财的 `*_RATIO` 列**已经是百分数**（`31.478792078775` = 31.48%），
    /// **不是** 0–1 的小数 —— 再乘 100 会变成 3147.9%。
    private func pct(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f%%", v)
    }

    private var lhbSubtitle: String {
        guard let c = lhb else { return "" }
        return c.caliberCount > 1 ? "\(c.date) · \(c.caliberCount) 条上榜口径" : c.date
    }

    /// 读龙虎榜：**只读库**（不回源，理由见 `lhbCard` 的「数据从哪来」）。
    ///
    /// ⚠ 必须同时读"表内最新日期"（`latestDate`）：没有记录时靠它区分
    /// **「未上榜」**（数据已抓到，这只票不在名单里）与 **「还没抓」**（表是空的）。
    /// 两者都显示成"暂无数据"会把"这只票没上榜"误报成"数据缺失"。
    func loadLhb() async {
        lhbLoading = true
        let records = LhbStore.records(code: code, limit: 30)
        lhbCoverage = LhbStore.latestDate()
        if let c = LhbDigest.card(from: records) {
            lhb = c
            lhbSeats = LhbStore.seats(date: c.date, code: code, changeType: c.primary.changeType)
        } else {
            lhb = nil
            lhbSeats = []
        }
        lhbLoading = false
    }

}
