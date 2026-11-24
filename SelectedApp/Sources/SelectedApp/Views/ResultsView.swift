import SwiftUI
import AppKit
import Charts
import SelectedCore

// MARK: - P2 选股结果

struct ResultsView: View {
    private let store = Store.shared
    /// 时间线当前停在哪一段（三轮之一 / 三轮对比）。
    /// ⚠ 初值读深链标志：通知「三轮对比已生成」把人从别的页带进来时，这一段是**新建**的，
    ///   `.onChange` 对"出生时就位"的值不响应 —— 只有初值这条路接得住（消费在 `.task` 里）。
    @State private var leg: Leg = Store.shared.compareLegRequested ? .compare : .round(3)
    @State private var expandedCode: String?
    @State private var autoSelected = false
    @State private var scanStartAt: Date?
    /// 页面实测宽（**窗口驱动**，指标列按内容定宽 + 均匀间隙的唯一宽度来源，见 `pickTableLayout`）
    @State private var pickPageW: CGFloat = 0
    /// 「减弱动态」：详情展开/折叠的位移过渡在开关打开时退化为瞬时
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 结果页时间线的一段：某一轮扫描，或排在末轮之后的「三轮对比」。
    ///
    /// 2026-10-29 老板拍板 M2：「三轮入口调整到这，不要平铺在最下面 —— 他们正好是一个时间线，
    /// 第一轮、第二轮、第三轮、三轮对比」。⇒ 对比不再是页尾的一段，而是时间线的第四格。
    enum Leg: Hashable {
        case round(Int)
        case compare

        /// 轮次号（对比段为 `nil`）—— 加载/扫描/横幅都按这个判"这一格是不是某一轮"
        var slot: Int? {
            if case .round(let s) = self { return s }
            return nil
        }
    }

    /// 当前段对应的轮次（对比段回落**末轮**：操作栏「选股」在时间线任何一格都不该变成死按钮，
    /// 而末轮就是"把今天这一轮再扫一遍"的默认对象）
    private var scanSlot: Int { leg.slot ?? RoundPlan.slots.last ?? 3 }

    /// 复制任意文本（右键菜单用，带 toast 反馈）
    private func copyText(_ text: String, feedback: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ToastCenter.shared.show(feedback)
    }

    /// 扫描已进行时间（mm:ss）
    private var scanElapsed: String {
        guard let start = scanStartAt else { return "00:00" }
        let s = Int(Date().timeIntervalSince(start))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageActionBar {
                DateChip()
                ActionBarButton(title: "选股", isBusy: store.busy.contains("round"),
                                isDisabled: store.isHistorical,
                                helpText: store.isHistorical ? "历史模式下不可扫描，请先回到最新交易日" : "全量扫描约 40~60 秒") {
                    store.manualRunRound(slot: scanSlot)
                }
                // 三轮对比是时间线的第四格（2026-10-29 M2），但它的动作仍与「选股」并排在操作栏 ——
                // 段选器只管"看哪一格"，不管"跑哪一格"。
                // ⚠ `secondary`：同一页最多一颗实底 primary（`button_style` 的口径）。
                ActionBarButton(title: "生成对比", secondary: true,
                                isBusy: store.busy.contains("compare"),
                                isDisabled: store.isHistorical,
                                helpText: store.isHistorical ? "历史模式下不可重新生成，请先回到最新交易日" : "汇总三轮生成对比报告") {
                    store.generateCompare()
                }
            }

            // 时间线选择器：三轮 + 三轮对比（内容区顶部，不占操作栏）
            HStack(spacing: 10) {
                // ⚠ 「轮次」两个字**不要**：留着占位、把三个按钮推右 ~57pt，
                //   与下方卡片内容的左边界对不齐 ⇒ Picker 用空 label 自然左对齐。
                //   ⚠ `label: EmptyView()` + `.labelsHidden()` **不能省**：不写的话系统会补一个
                //     默认 label，又把按钮推右（这一步不是冗余）。
                Picker(selection: $leg) {
                    // ⚠ 时刻读 `ScheduleTimes`、轮数读 `RoundPlan`：写死 "14:00" 会在
                    //   用户改调度后失真，写死 `[1,2,3]` 会在加轮次后静默少一格
                    //   （与下面标题里去掉 `slot_label` 是同一件事的两面）。
                    ForEach(RoundPlan.slots, id: \.self) { s in
                        Text("\(ScheduleTimes.shared.clock(RoundPlan.roundKey(s))) \(RoundPlan.ordinal(s))").tag(Leg.round(s))
                    }
                    // 第四格（M2）：时刻同样读调度表（出厂 15:02，本机存了什么就用什么）
                    Text("\(ScheduleTimes.shared.clock("compare")) 三轮对比").tag(Leg.compare)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // ⚠ 用 `.fixedSize()` 按内容宽，**不要写死 `.frame(width: 344)`**（2026-10-19）：
                //   写死宽度比 3 段实际宽度大 ~44pt，segmented 内容在 frame 里**居中** ⇒
                //   第一个按钮左缘比页面 18pt 边距多出 22pt（老板报"轮次按钮偏右"）。
                //   自适应宽度下左缘严格贴 18pt；轮数变化时宽度跟着变，也不会再错。
                .fixedSize()

                // 扫描进行中提示（徽章 + 已进行时间）——只有"某一轮"那几格有本轮，对比段没有
                if let slot = leg.slot, store.busy.contains("round") {
                    HStack(spacing: 5) {
                        ThinkingDot(design: .searching, diameter: 14)
                        Text("第\(slot)轮扫描中 · \(scanElapsed)")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(Sem.info)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Tok.tint(Sem.info), in: Capsule())
                    .help("全量扫描约 40~60 秒（含降级链），完成后自动刷新")
                }

                Spacer()
                if !store.busy.contains("round"), let slot = leg.slot, let round = store.roundDetails[slot] {
                    // 走 `ScanResult` 实体（与下方 `roundBody` 一致）
                    let rh = ScanResult(round)
                    Text("\(rh.paramVersionDash) · 入档 \(rh.stats.finalCount) 只")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            // ⚠ 左右 18（2026-10-19 老板要求：轮次按钮左缘与页面/卡片左缘同一条 18pt 边距）
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            Divider()

            // 滚动容器在**页面级**（2026-10-29 M1）：宽度测量必须挂在这一层 ——
            // 量卡片或表头会被定宽行反向撑宽（见下面 `pickPageW`）。
            FitScrollView {
                // 时间线四段共用这一条流：切段 = 换内容，不是往下滚（M2 老板拍板）。
                VStack(spacing: 14) {
                    if let slot = leg.slot {
                        roundLeg(slot)
                    } else {
                        CompareSection()
                    }
                }
                // ⚠ 18 与 `PageActionBar` / 轮次栏同一套边距（2026-10-19）。改这里会同时改
                //   表格的可用宽 ⇒ 下面那枚实测宽就是唯一真相（`pickTableLayout` 的输入）。
                .padding(18)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pickPageW = $0 }
        }
        // 扫描中：记录起始时间驱动计时徽章；结束后清零
        //
        // ⚠ **不要用 Combine**（`Timer.publish` + `onReceive`）：用 `.task` + 异步循环 ——
        //   纯 Swift Concurrency，且**随视图销毁自动取消**（Timer publisher 不会）。
        .task {
            while !Task.isCancelled {
                // ⚠ 只在**值真的变了**才写（2026-10-16 审查 B3）：
                //   原先每秒无条件 `scanStartAt = nil`，即使本来就是个"每秒写一次同一个值"的
                //   空操作 —— `@State` 每次被赋相同值仍会让 body 失效，
                //   于是"这一页开着 = 每秒重建一次三档列表"（`tier1/2/3` 是**计算属性**，
                //   每轮要重建上万个 `JSONValue`）。空闲时这就是持续的 CPU 占用与掉帧。
                if store.busy.contains("round") {
                    if scanStartAt == nil { scanStartAt = Date() }
                } else if scanStartAt != nil {
                    scanStartAt = nil
                }
                // 取消时 `sleep` 抛错 → `try?` 吞掉 → 下一轮 `Task.isCancelled` 为 true 退出
                try? await Task.sleep(for: .seconds(1))
            }
        }

        // 默认选中最后有数据的轮次（如 14:50 已扫则选第三轮；全部无数据回落第一轮）
        //
        // ⚠ `leg = .round(target)` 之后**别再显式** `store.loadRound(slot:)`：下面有
        //   `.onChange(of: leg) { loadRound }` ⇒ 只要目标段与当前不同就会**连查两次库**。
        //   ⇒ 收敛成：段变了交给 `onChange`；没变才自己加载。
        .task {
            guard !autoSelected else { return }
            autoSelected = true
            // 出生即深链（点通知跨页进来）：第四格已经由 `leg` 的初值兑现，这里只把请求作废 ——
            // **不能**再往下走自动选轮那段，否则等于把他刚从通知里带来的那一格又拽回某一轮。
            if store.compareLegRequested {
                store.consumeCompareLeg()
                return
            }
            let target = [3, 2, 1].first { store.roundDetails[$0] != nil } ?? 1
            if leg.slot == target {
                store.loadRound(slot: target)   // 段未变 ⇒ onChange 不会触发 ⇒ 自己加载
            } else {
                leg = .round(target)            // 变了 ⇒ 由 .onChange(of: leg) 统一加载
            }
        }
        .onChange(of: store.viewDate) { _, _ in
            // 停在「三轮对比」那格时不抢段：对比报告随 `setViewDate → refresh()` 自己重读，
            // 切回某一轮时下面的 `onChange(of: leg)` 会按新日期加载。
            guard let slot = leg.slot else { return }
            let target = [3, 2, 1].first { store.roundDetails[$0] != nil } ?? 1
            // ⚠ 同上：只在"当前轮次无数据 或 超出可用范围"时才切（原语义保留）；
            //   切换交给 `onChange(of: leg)`，不切则自己加载（换了日期必须重读）。
            if store.roundDetails[slot] == nil || slot > target {
                leg = .round(target)
            } else {
                store.loadRound(slot: slot)
            }
        }
        .onChange(of: leg) { _, new in
            if let slot = new.slot { store.loadRound(slot: slot) }
        }
        // 深链（**已经停在这一页**时点通知）：跨页那条路走 `leg` 的初值，这一条只能靠 onChange。
        // 两路都要作废请求，否则它会在下次进页时无端把人扔到第四格。
        .onChange(of: store.compareLegRequested) { _, want in
            guard want else { return }
            leg = .compare
            store.consumeCompareLeg()
        }
        // ⚠ **别加** `.onAppear { store.loadRound(slot:) }`：它与上面的 `.task` **都调 `loadRound`**
        //   → 进页面加载两次（`.task` 有 `autoSelected` 守卫、只跑一次；`.onAppear` 没有，每次出现都跑）。
        //   ⚠ 不加它**不会漏刷新**：① 切日期 / 切轮次由上面两个 `.onChange` 负责；
        //   ② 扫描进行中由上面的 `.task` 循环每秒刷新。
    }

    /// 时间线里"某一轮"那三格的正文（滚动容器与边距由 `body` 那层的 `FitScrollView` 统一给）
    @ViewBuilder
    private func roundLeg(_ slot: Int) -> some View {
        // 扫描失败**只挂在那儿**的场景：toast 是瞬时的（error 档"点别处即走"），
        //   而 `staleWhileBusy` 让旧结果留在了屏上 —— 提示一消失，
        //   用户面对的是一份看起来完全像新鲜的旧数字。这条横幅补的就是那段静默期，
        //   并把"重试"就近给出（判据与归属见 `RunFailureBanner`）。
        // ⚠ 只在**有旧数据在场**时挂：没数据时下面走空态，空态自带「立即选股」，
        //   两条动作上下叠着等于同一件事说两遍。
        if store.roundDetails[slot] != nil {
            RunFailureBanner(key: "round",
                             staleNote: "屏上仍是上一次成功扫描的结果，本轮未更新",
                             retryTitle: "重试本轮") {
                store.manualRunRound(slot: slot)
            }
        }

        // 扫描中**不清屏**：上一轮结果留在原位（`staleWhileBusy` 淡化 + 禁交互），
        //   进度由上面那条「第N轮扫描中 · mm:ss」胶囊承担。
        //   判据是"有没有数据"而不是"在不在跑" —— 重跑期间用户最想对照的恰恰是
        //   上一轮选出了什么，整块换成 LoadingView 等于在他最需要参照时拿走参照。
        if let round = store.roundDetails[slot] {
            roundBody(round)
                .staleWhileBusy(store.busy.contains("round"))
        } else if store.busy.contains("round") {
            LoadingView(text: "全量扫描约 40~60 秒（含降级链）…", design: .searching)
                .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            EmptyStateView(icon: "doc.text.magnifyingglass",
                   // ⚠ 三态措辞要分开：「暂无数据」把
                   //   "**未生成**（引擎还没跑这一轮）"与"**无记录**（跑过，没选出来）"
                   //   混成一句。实时路径这里是前者 —— 明说"尚未生成"。
                   title: store.isHistorical ? "该日本轮无选股记录" : "本轮尚未生成",
                   hint: store.isHistorical
                        ? "可切换日期或轮次查看"
                        : "交易日尾盘自动运行，或点下方「立即选股」手动执行",
                   actionTitle: store.isHistorical ? nil : "立即选股",
                   actionDisabled: store.busy.contains("round")) {
                store.manualRunRound(slot: slot)
            }
                    .frame(maxWidth: .infinity, minHeight: 220)
        }
    }

    /// 结果段正文（滚动容器与边距由 `body` 那层的 `FitScrollView` 统一给）
    @ViewBuilder
    private func roundBody(_ round: JSONValue) -> some View {
        // 整段走 `ScanResult` 实体 —— 键名编译期检查。
        // 若写 `round["stats"]["total_scanned"]` 这类裸下标：键名写错、
        // 引擎改键名都只会**安静地显示 0 / "-"**。
        let r = ScanResult(round)
        // ⚠ 宽度测量在 `body` 那层的 FitScrollView 上做（窗口驱动层），
        //   **不能**量卡片或表头：行是定宽 HStack，一旦超过卡片宽就会把卡片→VStack→整页撑宽，
        //   下一轮量到的还是那个更大的宽 ⇒ 窗口缩小时永远回不去（实测 920 宽下右侧两列被裁掉）。
        VStack(spacing: 14) {
                let me = r.marketEnv
                // 红灯日横幅：暴跌日策略不操作，大量标的 skipped 属预期行为（否则像数据异常）
                if me.shConsecutiveDecline {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .foregroundStyle(Sem.up)
                        Text("红灯日 · 连续下跌，策略空仓观望")
                            .font(.callout.bold()).foregroundStyle(Sem.up)
                        Spacer()
                        // ⚠ 别写 `skipped` 这个英文：它在界面上是**未译**的
                        //   引擎字段名，用户读不懂；而且引擎侧列名一变这句话就悄悄失真。
                        Text("本日标的不建议操作，「未评估」为策略预期行为")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Tok.tint(Sem.up, .block), in: RoundedRectangle(cornerRadius: 10))
                }
                let st = r.stats
                // ⚠ 标题**不带 `slot_label`**：那一列恒等于默认表
                //   （`Scheduler` 调 `runRound` 不传 `slotLabel` → `ScanRunner` 回落 `[1:"14:00",…]`），
                //   用户把第一轮改到 14:10 后，标题会写"14:00"、副标题写"14:10"——**两个时间打架**。
                //   实际执行时刻看副标题的 `run_time`（那才是真值），所以这里只留轮次号。
                Card("第\(r.slot)轮",
                     subtitle: "\(r.runTimeDash) · \(r.paramVersionDash)") {
                    HStack(spacing: 28) {
                        VStack(alignment: .leading, spacing: 4) {
                            // ⚠ 走 `Terms.shangHaiIndex`（术语唯一来源，别在视图里散写「上证」简称）。
                            Text(Terms.shangHaiIndex).font(.caption).foregroundStyle(.secondary)
                            PnlText(value: me.shChangePctOrNil)
                                .font(.title3.bold())
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            // ⚠ 涨:平:跌 **三段**（2026-10-19 老板要求：原先只有涨跌两段，
                            //   平盘家数被藏掉）。口径与看板 hero 同一条，比例条共用 `BreadthBar`。
                            Text("涨跌比").font(.caption).foregroundStyle(.secondary)
                            Text("\(me.upCount):\(me.flatCount):\(me.downCount)")
                                .font(.title3.bold().monospacedDigit())
                            if me.upCount + me.downCount > 0 {
                                BreadthBar(up: me.upCount, flat: me.flatCount, down: me.downCount)
                                    .frame(width: 104)
                            }
                        }
                        Spacer()
                        // 口径标注：入档总数 = 二档 + 三档（一档为二档中达门槛者）
                        let t1 = r.tier1.count
                        let t2 = r.tier2.count
                        let t3 = r.tier3.count
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("全量 \(st.totalScanned) → 硬过滤 \(st.afterHardFilter) → 稳健 \(st.afterProfileFilter) → 形态 \(st.afterFormFilter) → 入档 \(st.finalCount)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("入档 = 一档 \(t1) + 二档 \(t2 - t1 > 0 ? t2 - t1 : t2) + 三档 \(t3)（一档含于二档）")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                // 三档 picks 各读一次（`ScanResult` 的 tierN 是计算属性，重复取会重复解 JSON）
                let tier1 = r.tier1
                let tier2 = r.tier2
                let tier3 = r.tier3
                // 列宽按**三档全部标的**的最长内容算 ⇒ 三张卡的列边界完全对齐
                //（各卡按自己的行算会三套宽度，纵向扫读时列会跳）。
                // 卡片内容宽 = 页面宽 − 页面 padding 18×2 − 卡片 padding 16×2
                let pickLayout = pickTableLayout(all: tier1 + tier2 + tier3,
                                                 available: max(320, pickPageW - 68))
                pickSection("一档推荐", picks: tier1, storedTier: 1, layout: pickLayout)
                // ⚠ 文案是"二档候选"不是"二档关注"："关注"与"自选"概念混淆
                //   （用户可能以为这档可点击加入自选），与"三档观察"同族。
                pickSection("二档候选", picks: tier2, storedTier: 2, layout: pickLayout)
                // 三档含两类：分数确实不足的，以及**均线未多头被纪律否决**的（后者显示原始分）
                pickSection("三档观察", picks: tier3, storedTier: 3, dimmed: true,
                            subtitle: "含均线未多头（按纪律回避，显示原始分）",
                            layout: pickLayout)
                    // 三档卡「拉伸吞留白」：未消费的高度吸进这张卡，页面底部不露白
                    .frame(maxHeight: .infinity, alignment: .top)

                // ⚠ 「深度排除」名单**不再展示**（2026-11-04 用户要求）：这一屏列的全是
                //   已被排除的标的，看完不能做任何决定 —— 展示它只占高度、不承载行动。
                //   引擎侧完全不动：`ScanRunner` 照旧排除并写 `excluded_stocks`，
                //   漏斗的 `excluded_count` 与三轮对比的 `excluded_table` 也照旧产出
                //   —— 数字仍然参与统计，只是不再逐只列出来。

                let etfs = r.etfRecommendations
                if !etfs.isEmpty {
                    Card("ETF 推荐") {
                        SharedDataTable(
                            columns: [
                                DataTableColumn("name", "标的"),
                                DataTableColumn("pct", "涨跌幅", width: 90, alignment: .trailing, isNumeric: true),
                                DataTableColumn("ratio", "量比", width: 80, alignment: .trailing, isNumeric: true),
                            ],
                            rows: etfs
                        ) { e, c in
                            switch c.id {
                            case "name":
                                Text("\(e.code) \(e.nameDash)")
                            case "pct":
                                PnlText(value: e.changePctOrNil)
                            default:
                                Text(String(format: "%.2f", e.volumeRatio))
                            }
                        }
                    }
                }
        }
    }

    /// 选股结果表的几何（表头与数据行共用，谁也不许在调用点写数字）
    enum ResultsTableMetrics {
        /// 分数列宽度（2026-10-26 由 46 放到 66：46 装不下"原始分被均线锁档"时 badge + help 的行内宽度，
        /// 表头「分数」二字与徽章右边缘也会挤在一起。
        /// 2026-11-04 再放到 76：66 装不下最深的锁档行「123 分·未多头」——实测该串 71.8pt
        /// （`123` callout 粗圆体 23.8 + ` 分·未多头` caption2 48.0），按本文件「实测 +4」的余量取 76。
        /// 66 差的那 5.8pt 让文字在 32pt 的行高里折成两行、断在「未/多头」中间，
        /// 三档观察一屏全是这种半截词。
        /// ⚠ 深选 v2.0 之后三档里几乎**每一行**都带这个后缀（非多头一律锁档），
        /// 原先它是个边角场景，现在是这一列的常态内容 —— 宽度必须按常态算。
        /// 预算：多出的 10pt 由 8 段等间隙分摊（~39 → ~37.8），仍高于 32pt 下限。
        static let scoreWidth: CGFloat = 76
        /// 名称列**下限**宽度（放得下「创 SZ300221」这类"徽章 + 交易所前缀"的长名约 108pt；
        /// 实际宽由 `pickTableLayout` 按内容实测，上限 170）。
        static let nameMinWidth: CGFloat = 110
        /// 三轮分列宽度（三个两位数字 + 两个分隔点）。
        static let roundWidth: CGFloat = 88
        /// 行尾「警告图标 + 展开箭头」那一格的宽度（图标 ~14 + 间距 6 + 箭头 ~10，留 2 冗余）。
        /// ⚠ 表头占位与数据行容器**必须**读它 —— 分开写就会错开（实测错过 14pt）。
        static let tailWidth: CGFloat = 32
        /// 列间距（表头与数据行同一处定义，含行本体 `pickRowLine` 的 HStack spacing）。
        static let columnSpacing: CGFloat = 6
    }

    /// 指标列的实测布局（表头与所有数据行共用同一份，谁也不许自己算）。
    private struct PickTableLayout {
        var metricWidths: [CGFloat]
        var spacing: CGFloat
        var nameWidth: CGFloat
    }

    /// 指标列的实测布局（表头与所有数据行共用同一份，谁也不许自己算）。
    ///
    /// 口径（内容实测 ×1.35+4、富余先填**等宽间隙**到 32pt 封顶、剩余按比例摊回列内）
    /// 的唯一实现是 `ColumnLayout` —— 本函数只负责"哪些列参与实测、哪些写死、几段间隙"，
    /// 不再自带一份分配算法（2026-10-27 B1：原先这里、`SharedDataTable.columnWidths`、
    /// 指标筛选各写一份，同一个 App 里三种列宽行为）。
    private func pickTableLayout(all: [ScanPick], available: CGFloat) -> PickTableLayout {
        let cols = WatchColumn.scanResultColumns
        let bases = cols.map { c in
            ColumnLayout.baseWidth(title: c.title, cells: all.map { c.text(pick: $0) })
        }
        // 名称列同样按内容定宽（下限放得下"徽章 + 交易所前缀"的长名，上限 170）：
        // 写死 110 时"国科军工"（50pt）右侧白摊 60pt，是整行最宽的一段空隙。
        let name = ColumnLayout.baseWidth(title: "名称", cells: all.map { $0.nameDash },
                                          minWidth: ResultsTableMetrics.nameMinWidth,
                                          maxWidth: 170, bold: true)
        let fixed = ResultsTableMetrics.scoreWidth + ResultsTableMetrics.roundWidth
            + ResultsTableMetrics.tailWidth
        // 间隙段数 = 分数|名称 · 名称|指标1 · 指标之间(n−1) · 指标n|三轮分 · 三轮分|尾部
        let (widths, spacing) = ColumnLayout.distribute(
            bases: bases, available: available - fixed - name,
            gapCount: CGFloat(cols.count) + 3)
        return PickTableLayout(metricWidths: widths, spacing: spacing, nameWidth: name)
    }

    /// `storedTier` = 这批 picks **落库时**被分到的档位（1/2/3）。
    ///
    /// ⚠ 必须一路传到分数格：分组本来就是按落库 tier 分的，
    ///   若颜色改按"当前生效门槛"重算，就会出现「二档候选卡里 58/53 分画成回避绿」
    ///   —— 同一行里"它属于二档"与"按今天的尺子它不够"互相打脸（设计文档 M6，
    ///   老板 2026-10-22 拍板：颜色与分组同源，都读落库 tier）。
    private func pickSection(_ title: String, picks: [ScanPick], storedTier: Int,
                             dimmed: Bool = false,
                             subtitle: String? = nil,
                             layout: PickTableLayout) -> some View {
        Card(title, subtitle: subtitle ?? ("\(picks.count)只" + (dimmed ? " · 仅观察" : ""))) {
            if picks.isEmpty {
                // ⚠ 文案用「无记录」不用「无」：走到这里说明引擎跑过了（有报告、有分组），
                //   这是"真的没有"，不是"没生成/没抓到"。
                Text(dimmed ? "无（未达观察线）" : "无记录").font(.callout).foregroundStyle(.secondary)
            } else {
                // ⚠ 表头 / 分隔线 / 行列表**必须自己收进一个 `spacing: 0` 的栈**：
                //   `Card` 的内容是一个 `VStack(spacing: 12)`，这三样作为散着的兄弟视图会被塞进
                //   12pt 的缝 —— 实测表头与它自己的分隔线之间多 12pt、分隔线与首行之间再多 12pt，
                //   于是首行的 30pt 行高被撑成 42pt、文字贴在下沿（老板 2026-10-26 报
                //   「标题没居中、内容靠下」）。共享表 `SharedDataTable` 本来就是紧栈，这里同口径。
                VStack(spacing: 0) {
                    // 固定列头（不可编辑）—— 列宽与 `pickRowTail` / `pickNameCell` 同一份定义
                    pickHeader(layout)
                    TableRule()
                    // ⚠ 行列表用 `LazyVStack` 不用 `VStack`：生产库 `picks` 三轮合计可达 1.4 万行
                    //   （slot3 单轮就上万），`VStack` 会在首帧一次性构造全部行视图；
                    //   `LazyVStack` 只构造视口内的行。
                    // ⚠ 外层 `FitScrollView` 根部 `VStack` 不能改成惰性：卡片上的
                    //   `.frame(maxHeight:.infinity)` 在 `LazyVStack` 里不会拉伸，底部留白会暴露
                    //   ⇒ 只把这一段行列表换成惰性，页面骨架不动。
                    LazyVStack(spacing: 0) {
                        // id 用下标（Range<Int> 是标量，避免 foreach_id_payload 把整份 ScanPick
                        // 当 id 哈希）；展开状态仍按业务键 code 判断，不跟下标走。
                        ForEach(picks.indices, id: \.self) { index in
                            let p = picks[index]
                            VStack(spacing: 0) {
                                VStack(spacing: 6) {
                                    // 行本体 = 三段拆开（名称格独立成焦点站，键盘可达）—— 见 `pickRowLine`
                                    pickRowLine(p, storedTier: storedTier, layout: layout)

                                    if expandedCode == p.code {
                                        pickDetail(p)
                                            .motionAwareTransition(.opacity.combined(with: .move(edge: .top)))
                                    }
                                }
                                // 行分隔只留 hairline（斑马纹 2026-10-23 被老板判丑，已删）
                                TableRule()
                            }
                        }
                    }
                }
            }
        }
    }

    /// 行：分三段
    ///
    /// ⚠⚠ 为什么不能整行一个 `Button`：`.focusable()` / `.onKeyPress(.return)` 挂在
    ///   button 的 label 里时**既不进 Tab 循环、也收不到 Return**（实测：AX 聚焦后 Return/Space
    ///   都不弹详情，而**鼠标点击照常弹** —— 断的只有键盘这条路）。整行套 Button 是本页的
    ///   独有形态（复盘/对比/看板/早盘预判四处都没有），所以那四处一直是好的。
    /// ⇒ 拆成三段：分数格 / **名称格（自带 `stockDetailTap`，独立成焦点站）** / 「行其余部分」按钮。
    ///   ⚠ 鼠标手感**逐字不变**：拆之前名称上的 tap 手势本来就赢过行 Button
    ///     ⇒ 点名称=弹详情、点行其余=展开/收起，两条路都没动。
    private func pickRowLine(_ p: ScanPick, storedTier: Int, layout: PickTableLayout) -> some View {
        HStack(spacing: layout.spacing) {
            pickScoreCell(p, storedTier: storedTier)
            pickNameCell(p, width: layout.nameWidth)
            Button {
                withAnimation(reduceMotion ? nil : Mot.expand) {
                    expandedCode = expandedCode == p.code ? nil : p.code
                }
            } label: {
                pickRowTail(p, layout: layout)
            }
            .buttonStyle(.plain)
        }
        .font(TableMetrics.rowFont)
        .frame(height: TableMetrics.rowHeight)
        // ⚠ 必须钉左：行不再靠 `maxWidth:.infinity` 的单元格自己铺满整行，
        //   行宽小于卡宽时 HStack 会被**居中** ⇒ 分数列与表头错开半张卡（实测窄窗口偏 230pt）。
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 分数格（固定 66pt 宽 —— 2026-10-19 由 54 收窄到 46，2026-10-26 随「表头/行同一份对齐口径」放到 66，见 `pickRowTail` 的宽度预算）
    private func pickScoreCell(_ p: ScanPick, storedTier: Int) -> some View {
        // 被均线规则锁档的标的，分数列显示**原始分**而不是压制后的 49。
        // 否则三档里"原始分 78 的票"与"原始分 33 的票"长得完全一样，档位不再表示质量。
        // 注意：档位归属仍按压制后分数（选股结果不变），此处只改呈现。
        let locked = p.tierLockApplied
        let shownScore = locked ? p.scoreRawValue : p.scoreValue
        return ScoreBadge(score: Int(shownScore), tier1: store.tier1Min, tier2: store.tier2Min,
                          storedTier: storedTier, suppressed: locked)
            .frame(width: ResultsTableMetrics.scoreWidth, alignment: .leading)
            .help(locked
                  ? "均线未多头排列 → 按纪律归入三档。此处显示原始分 \(Int(shownScore))，非质量不足"
                  : "")
    }

    /// 名称格（宽度由 `pickTableLayout` 给，下限 110 = 名称列基准宽）：点击弹详情 + 右键菜单（三种复制粒度）。
    /// ⚠ 这一格**必须与「行其余部分」平级**（不是按钮的 label）—— 键盘可达性靠的就是这一点。
    private func pickNameCell(_ p: ScanPick, width: CGFloat) -> some View {
        let code = p.code
        return Text(p.nameDash)
            .bold()
            .lineLimit(1)
            .contentShape(Rectangle())
            .stockDetailTap(code: code, name: p.nameDash)
            // ⚠ 110（2026-10-19 由 124 收窄，见 `pickRowTail` 的宽度预算）：仍放得下
            //   「创 SZ300221」这类"徽章 + 交易所前缀"的长名（约 108pt）；
            //   `lineLimit(1)` 会截断、不会换行。
            .frame(width: width, alignment: .leading)
            // 右键菜单：代码 / 代码+名称 / 摘要三种复制粒度（高频"复制去别处查"场景）
            .contextMenu {
                Button {
                    copyText(code, feedback: "已复制代码 \(code)")
                } label: {
                    Label("复制代码 \(code)", systemImage: "doc.on.doc")
                }
                Button {
                    copyText("\(code) \(p.nameDash)", feedback: "已复制代码与名称")
                } label: {
                    Label("复制代码+名称", systemImage: "doc.on.doc.fill")
                }
                Button {
                    let score = String(format: "%.0f", p.scoreValue)
                    let pct = p.changePctOrNil.map { String(format: "%+.2f%%", $0) } ?? "-"
                    copyText("\(code) \(p.nameDash)｜评分\(score) 涨跌\(pct)",
                             feedback: "已复制摘要")
                } label: {
                    Label("复制一行摘要", systemImage: "list.clipboard")
                }
            }
    }

    /// 「行其余部分」：指标列 / 三轮分 / ⚠ / 展开箭头 —— 这一块才是"展开/收起"按钮的 label。
    ///
    /// ⚠⚠ **总宽必须 ≤ 卡片内容宽**，否则右侧 ⚠ / 箭头被挤出卡片（2026-10-19 老板报的就是这个）。
    ///   指标列宽度不再手写：全部来自 `pickTableLayout`（按内容实测 + 实测卡宽摊剩余），
    ///   固定列仍是 `ResultsTableMetrics` 那四枚。
    ///   最小窗口 1120 ⇒ 卡片内容实测宽 **892pt**；指标列只拿"内容 × 1.35"（约 280pt），
    ///   固定列 分数 66 + 三轮分 88 + 尾部 32 + 名称 110 ⇒ 富余全部进 8 段相等间隙（各 ~39pt）。
    ///   ⚠ 定值沿革：2026-10-19 由「54 / 124 / spacing 8 / 表头占位 52」压到「46 / 110 / spacing 6 / 44」，
    ///     2026-10-26 上午分数列 46→66、尾部占位 44→`tailWidth`、余量均分给指标列；
    ///     当天下午老板否掉"均分"（4 字的「量比」与 7 字的「成交额」一样宽 ⇒ 列内全是空白、
    ///     最后一列与三轮分几乎贴上），改成现在的**按内容定宽 + 间隙拉匀 + 内容居中**。
    private func pickRowTail(_ p: ScanPick, layout: PickTableLayout) -> some View {
        let code = p.code
        return HStack(spacing: layout.spacing) {
            // 指标列：**按自选列表那套字段**（`WatchColumn`）渲染，
            // 列宽读 `pickTableLayout` 的内容实测 ⇒ 三张卡共用同一套列边界。
            // ⚠ 涨跌额 / 成交量**有意不在其中**（`picks` 表没存；且涨跌额不许自算）——
            //   见 `WatchColumn.scanResultColumns` 的说明。
            // ⚠ 内容与表头**都居中**：右对齐时短数字贴着列右边界，与表头之间出现空洞，
            //   看起来就像"列没对齐"（老板 2026-10-26 点名要中间对齐）。
            ForEach(Array(WatchColumn.scanResultColumns.enumerated()), id: \.offset) { i, c in
                Text(c.text(pick: p))
                    .monospacedDigit()
                    .foregroundStyle(c.color(pick: p))
                    .frame(width: layout.metricWidths[i], alignment: .center)
            }
            // 三轮分（`picks` 表快照）：这只票在第 1/2/3 轮各是多少分，缺席的轮显示 —
            threeRoundScores(code)
                .frame(width: ResultsTableMetrics.roundWidth, alignment: .trailing)
            // 尾部图标区**定宽**（与表头占位同一枚常量 `tailWidth`）：
            // 警告图标只在"大盘偏弱"时出现，若让它自由撑宽，同一列的右边界会随数据跳动
            // （实测表头与数据行的三轮分列因此错开 15~29pt）。
            HStack(spacing: 6) {
                if p.marketWeak {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Sem.warn)
                        .help("大盘偏弱环境")
                }
                Image(systemName: "chevron.down")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expandedCode == code ? 180 : 0))
            }
            .frame(width: ResultsTableMetrics.tailWidth, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }

    /// 「三轮分」列：这只票在各轮分别多少分（`picks` 表快照 —— 固定值，不会变）。
    ///
    /// ⚠ 缺席的轮显示 `—` 而**不是 `0`** —— "那轮没这只票"与"那轮 0 分"是两件事
    ///   （`0` 在本项目是**有意义的值**）。
    /// ⚠ 当前轮加粗：列表是按轮次 tab 看的，加粗让"我正在看哪一轮"一眼可辨。
    @ViewBuilder
    private func threeRoundScores(_ code: String) -> some View {
        let map = store.roundScores[code] ?? [:]
        let firstSlot = RoundPlan.slots.first ?? 1
        // ⚠ **每个数字必须固定宽度**：若让文本自适应宽度，`—`（窄）与 `108`（宽）
        //   会把同一轮的分数在各行之间推来推去，**竖着看是歪的**。
        //   ⇒ 数字固定 24pt、分隔符固定 8pt、`spacing: 0` ⇒ 三列在所有行里严格竖直对齐。
        HStack(spacing: 0) {
            ForEach(RoundPlan.slots, id: \.self) { s in
                if s > firstSlot {
                    Text("·").foregroundStyle(.quaternary).frame(width: 8)
                }
                Group {
                    if let v = map[s] {
                        Text(String(format: "%.0f", v))
                            // 加粗"当前这一轮"：停在第四格（三轮对比）时 `leg.slot` 为 nil ⇒ 谁也不加粗
                            .fontWeight(s == leg.slot ? .bold : .regular)
                            .foregroundStyle(s == leg.slot ? .primary : .secondary)
                    } else {
                        Text("—").foregroundStyle(.quaternary)
                    }
                }
                .frame(width: 24)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .help("第 \(RoundPlan.slots.map(String.init).joined(separator: " / ")) 轮的分数（落库快照）；— 表示那轮没有这只票")
    }

    /// 列头（**固定，不可编辑**）。
    ///
    /// ⚠ 列宽与数据行**同源**（同一个 `PickTableLayout` 实例）；宽度本身不在这里量 ——
    ///   表头是内容驱动的一行，量它会在窗口缩小时把卡片反向撑宽（见 `roundDetail` 的注释）。
    private func pickHeader(_ layout: PickTableLayout) -> some View {
        HStack(spacing: layout.spacing) {
            Text("分数").frame(width: ResultsTableMetrics.scoreWidth, alignment: .leading)
            Text("名称").frame(width: layout.nameWidth, alignment: .leading)
            ForEach(Array(WatchColumn.scanResultColumns.enumerated()), id: \.offset) { i, c in
                Text(c.title).frame(width: layout.metricWidths[i], alignment: .center)
            }
            Text("三轮分").frame(width: ResultsTableMetrics.roundWidth, alignment: .trailing)
            // 与数据行尾部图标区同一枚常量 ⇒ 右边界必然对齐（以前这里手写 44，
            // 而行内实际图标只有 ~30，两轮之间错 14pt）
            Color.clear.frame(width: ResultsTableMetrics.tailWidth)
        }
        .font(TableMetrics.headerFont)
        .foregroundStyle(TableMetrics.headerColor)
        .frame(height: TableMetrics.headerHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pickDetail(_ p: ScanPick) -> some View {
        let di = p.deepInfo
        let ic = di.intraday
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Text("MA5 \(StockFmt.price(di.ma5, code: p.code))")
                Text("MA10 \(StockFmt.price(di.ma10, code: p.code))")
                Text("MA20 \(StockFmt.price(di.ma20, code: p.code))")
                Text(di.maPass ? "多头排列" : "非多头")
                    .foregroundStyle(di.maPass ? Sem.up : .secondary)
                Text("连涨\(di.consecUp)天")
                Text("5日累计 \(String(format: "%.1f", di.cum5d ?? 0))%")
            }
            trendStateRow(p)
            HStack(spacing: 16) {
                Text("距低点 \(String(format: "%.1f", di.distFromLow))%")
                Text("距高点 \(String(format: "%.1f", di.distFromHigh))%")
                // gain_ratio 的语义是「冲高回落保留度」(收盘涨幅÷盘中最大涨幅，同昨收基准, 0~1)，
                // 不是收益率 —— 旧标签「收益率」会让人按错误方向调参
                Text("保留度 \(String(format: "%.2f", di.gainRatio ?? 0))")
                Text("影体比 \(String(format: "%.2f", di.shadowBodyRatio ?? 0))")
                Text("量倍 \(String(format: "%.2f", di.volMult5d ?? 0))")
            }
            if !ic.isEmptyObject {
                HStack(spacing: 16) {
                    Text("尾盘量能 \(String(format: "%.2f", ic.tailVolRatio))x")
                    Text("尾盘拉升 \(String(format: "%.2f", ic.tailGainPct))%")
                    Text("收盘强度 \(String(format: "%.2f", ic.closePosition))")
                    Text(ic.tailNewHigh ? "尾盘创新高" : "尾盘未创新高")
                        .foregroundStyle(ic.tailNewHigh ? Sem.up : .secondary)
                    if let ht = ic.dayHighTimeOrNil {
                        Text("高点 \(ht)（陈旧\(String(format: "%.2f", ic.highAgeRatio)))）")
                    }
                }
            }
            if !p.scoreDetails.isEmpty {
                Text("加分：" + p.scoreDetails.joined(separator: " ｜ "))
                    .font(.caption).foregroundStyle(Sem.up)
            }
            if !p.penaltyDetails.isEmpty {
                Text("扣分：" + p.penaltyDetails.joined(separator: " ｜ "))
                    .font(.caption).foregroundStyle(Sem.down)
            }
            // P1 ⑥：K 线数据质量告警。**只在 sparse 时出现**（正常不占位）；
            // 文案唯一来源是 Core 的 `DataQuality.warningText`，这里不另写一份。
            if let dq = p.deepInfo.dataQualityOrNil, dq.isSparse {
                let core = DataQuality(bars: dq.bars, spanDays: dq.spanDays,
                                       maxGapDays: dq.maxGapDays, level: dq.level)
                if let warn = core.warningText {
                    Label(warn, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Sem.warn)
                }
            }
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.sunken, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 趋势状态 / 锁档信心（P1 A1+A2）

    /// 趋势状态 + 锁档信心。
    ///
    /// **为什么需要**：上面那行只有「多头排列 / 非多头」二值 —— 看不出被锁档的那批票里
    /// 哪些是「上升途中回踩被误伤」、哪些是「趋势确已走坏」。这正是 A1+A2 补的信息：
    /// 分数与档位**一个都没变**，只是把"被锁的原因"显示出来，供人工复核。
    ///
    /// ⚠ 文案与配色只写在 UI 层（Core 只出档位字符串 —— Core 不许 import SwiftUI）。
    /// ⚠ 老数据（P1 之前落库）没有这两个键 → **整行不显示**，不猜、不占位。
    @ViewBuilder
    private func trendStateRow(_ p: ScanPick) -> some View {
        if let state = p.deepInfo.trendStateOrNil {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Text("趋势").foregroundStyle(.secondary)
                    Text(Self.trendLabel(state)).foregroundStyle(Self.trendColor(state))
                }
                // 锁档信心只在**真的被锁**时有意义（Core 侧未锁时给 "none"）
                if p.tierLockApplied,
                   let conf = p.deepInfo.lockConfidenceOrNil, conf != "none" {
                    HStack(spacing: 4) {
                        Text("锁档").foregroundStyle(.secondary)
                        Text(Self.lockLabel(conf)).foregroundStyle(Self.lockColor(conf))
                    }
                }
            }
            .help("趋势状态：多头排列 / 多头走弱 / 回踩MA20 / 空头趋势 / 数据不足\n"
                  + "锁档信心：均线未多头会被压进三档；「疑似钝化误伤」指上升途中的回踩，建议复核")
        }
    }

    private static func trendLabel(_ s: String) -> String {
        switch s {
        case "BULL_ALIGNED": return "多头排列"
        case "BULL_WEAKENING": return "多头走弱"
        case "MA_PULLBACK": return "回踩MA20"
        case "BEAR_TREND": return "空头趋势"
        case "INSUFFICIENT": return "数据不足"
        default: return s          // 未知取值原样显示，不吞掉
        }
    }

    /// A 股口径：红=多、绿=空（与上方「多头排列」用 `Sem.up` 一致）
    private static func trendColor(_ s: String) -> Color {
        switch s {
        case "BULL_ALIGNED": return Sem.up
        case "BULL_WEAKENING": return Sem.warn
        case "MA_PULLBACK": return Sem.info
        case "BEAR_TREND": return Sem.down
        default: return .secondary
        }
    }

    private static func lockLabel(_ c: String) -> String {
        switch c {
        case "high": return "趋势已走坏"
        case "likely_blunt": return "疑似钝化误伤（回踩）"
        case "unknown": return "数据不足"
        default: return c
        }
    }

    private static func lockColor(_ c: String) -> Color {
        switch c {
        case "high": return Sem.down
        case "likely_blunt": return Sem.warn
        default: return .secondary
        }
    }
}

// MARK: - SwiftUI Preview
// ⚠ 预览读**真实开发库**（`Store.shared`），仅置 `previewMode` 抑制网络拉取；
//   空库时正好看"无轮次"空态。预览进程独立，不写生产数据。
#Preview("选股结果（真实库 · 禁网络）") {
    Store.shared.previewMode = true
    return ResultsView()
        .frame(width: 900, height: 640)
}

