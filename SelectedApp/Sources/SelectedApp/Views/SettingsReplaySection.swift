import SwiftUI
import SelectedCore

// MARK: - 历史回放

/// 「历史回放」卡片：把调优样本从 `iterate.tune_pool_days`（默认 120 个交易日）
/// 扩到几年，并让「引入任何新评分项之前」能在历史上先验证有效性。
///
/// ## ⚠⚠ 口径：这是**收盘价回测**，不是尾盘重放
/// live 的选股价是 14:00/14:30/14:50 的**盘中价**，而分时数据**不可回溯**
/// （新浪 5 分钟线只覆盖最近约 5 个交易日）。所以回放只能用**收盘价**，
/// 连量比也只能是**全日**量比。回放样本与实盘样本**口径不同** ——
/// 调优器默认不混用（`reviews.scan_mode` + `iterate.include_replay`）。
///
/// 卡片里把这件事写在最上面，因为**它是这个功能的天花板，不是实现缺陷**：
/// 用户看到"回放样本比实盘样本好看/难看"时必须知道两边不可直接比。
extension SettingsView {

    var replayCard: some View {
        Card("历史回放", subtitle: "把选股样本扩到几年 —— 收盘价口径，与实盘口径不同") {
            VStack(alignment: .leading, spacing: 10) {
                caliberNote
                cacheStatus
                rangePicker
                actionRow
                progressArea
                resultArea
            }
        }
    }

    // MARK: 口径说明（**放在最上面**）

    private var caliberNote: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("回放用的是**收盘价**：选股价 = 收盘价、量比 = 全日口径、尾盘分时结构整块跳过")
                .font(.caption)
                .foregroundStyle(Sem.warn)
            Text("原因：分时数据不可回溯（新浪 5 分钟线只覆盖最近约 5 个交易日）。"
                 + "所以回放样本与实盘样本「不可直接比较」，调优器默认只用实盘样本。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 缓存状态

    private var cacheStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("日K缓存").font(.callout.bold())
                Spacer()
                Button("刷新") { store.refreshReplayCache() }
                    .btnSecondary()
            }
            // ⚠ 「读取中」与「缓存为空」是**两件事**：`stats()` 现在是后台读
            //   （全表扫 125 万行，冷缓存 ~1.1 s），读回来之前不能显示"缓存为空" ——
            //   那是错的结论，不是空状态。只有**首次**读（还没有任何结果）才显示占位；
            //   后续刷新保留上一次的数字，避免闪一下。
            if store.replayCache == nil && store.replayCacheLoading {
                Text("正在读取缓存概况…")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let c = store.replayCache, !c.isEmpty {
                HStack(spacing: 12) {
                    Text("\(c.codes) 只 / \(c.bars) 根")
                    Text("\(c.firstDay) ~ \(c.lastDay)")
                    Text("已请求窗口 \(store.replayCoveredCodes) 只")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: store.replayIndexDayCount > 0
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(store.replayIndexDayCount > 0
                                         ? AnyShapeStyle(Sem.down) : AnyShapeStyle(Sem.warn))
                    // ⚠ 这里**不能**用 `**粗体**`：三元表达式产出的是 `String`，
                    //   走的是 `Text(_ verbatim:)` 重载 → 不做 Markdown 解析，
                    //   星号会原样显示出来。要粗体就得用字符串字面量。
                    Text(store.replayIndexDayCount > 0
                         ? "指数日历 \(store.replayIndexDayCount) 个交易日 → 最多可回放这么多天"
                         : "缺指数日K：交易日历拿不到，一天都回放不了（先点「下载日K缓存」）")
                        .font(.caption)
                }
            } else {
                Text("缓存为空 —— 先点下面的「下载日K缓存」")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("首次全市场约 5000 次请求 / 10–20 分钟；可随时取消，已下载的部分不会重下。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 日期区间

    private var rangePicker: some View {
        HStack(spacing: 12) {
            DatePicker("起始", selection: $replayBeg, displayedComponents: .date)
                .datePickerStyle(.compact)
            DatePicker("结束", selection: $replayEnd, displayedComponents: .date)
                .datePickerStyle(.compact)
            // 两个 DatePicker 已经完整表达了区间；右侧再放一条 `2025-10-20 ~ 2026-10-19`
            // 既重复、又和系统日期格式（斜杠）不一致（2026-10-20 审查）。
        }
    }

    private func dayText(_ d: Date) -> String { ChinaTime.day(d) }

    // MARK: 动作

    private var replayDownloading: Bool { store.replayDownloadTotal > 0 }
    private var replayRunning: Bool { store.replayRunningDay != nil }
    private var replayBusy: Bool { replayDownloading || replayRunning }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button("下载日K缓存") {
                store.downloadReplayCache(beg: dayText(replayBeg), end: dayText(replayEnd))
            }
            // 一卡两动作里只有「开始回放」是主操作 —— 实底并列会互相削弱，
            // 下载是回放的前置步骤 → 次操作
            .btnSecondary()
            .disabled(store.busy.contains("replayDownload") || HistoryReplayMode.isBusy)

            Button("开始回放") {
                store.runReplay(beg: dayText(replayBeg), end: dayText(replayEnd))
            }
            .btnPrimary()
            .disabled(store.busy.contains("replay") || HistoryReplayMode.isBusy)

            if replayBusy {
                Button("取消") { store.cancelReplay() }
                    .btnSecondary()
            }
            Spacer()
            // ⚠ 必须确认（2026-10-16 审查 B6）：清的是**一次 10–20 分钟 / ~5000 请求**
            //   下载来的全市场日K，且删完立刻回放不了（交易日历来自这里）。
            //   原先只有一行 `.help`（hover 才看得见），而这一枚还是本行**最右**的按钮，
            //   误点代价 = 网络成果归零 + 要从已被限流的出口 IP 重下。
            Button {
                confirmClearReplayCache = true
            } label: {
                Label("清空缓存", systemImage: "trash")
            }
            // 这是一次 10–20 分钟 / ~5000 请求下载成果的清空；描边红在浅色下太像禁用，
            // 用实底红把破坏性分量说清楚（真正的二次确认仍在 confirmationDialog 里）。
            .btnDangerFilled()
            .disabled(replayBusy || HistoryReplayMode.isBusy)
                .help("日K缓存可随时删掉重下；清空后回放会报「交易日历缺失」")
                .confirmationDialog(
                    "确认清空日K缓存？",
                    isPresented: $confirmClearReplayCache, titleVisibility: .visible) {
                    Button("清空", role: .destructive) { store.clearReplayCache() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("将删除 \(store.replayCache?.bars ?? 0) 根个股日K + "
                         + "\(store.replayCache?.indexBars ?? 0) 根指数日K。"
                         + "重下约需 10–20 分钟（约 5000 次请求），期间不能进行历史回放。"
                         + "此操作不可撤销。")
                }

        }
    }

    // MARK: 进度

    @ViewBuilder
    private var progressArea: some View {
        if replayDownloading {
            let done = store.replayDownloadDone
            let total = max(1, store.replayDownloadTotal)
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: Double(done), total: Double(total))
                Text("下载中 \(done) / \(total) 只").font(.caption.monospacedDigit())
            }
        }
        if let day = store.replayRunningDay {
            let i = store.replayProgressIndex
            let total = max(1, store.replayProgressTotal)
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: Double(i), total: Double(total))
                Text("回放中 \(i) / \(total)：\(day)").font(.caption.monospacedDigit())
            }
        }
    }

    // MARK: 结果

    @ViewBuilder
    private var resultArea: some View {
        if let s = store.replaySummary {
            Text(s)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        if !store.replayResults.isEmpty {
            // ⚠ **这里不放内层竖向 `ScrollView`** —— 它会和页面主 ScrollView 抢同一个竖向滚动手势：
            //   指针落在内层上时页面不滚；到内层边界时两者互相拉扯、界面一直闪。
            //   （`WatchlistView` 那个是**横向**的，轴不同不冲突 —— 竖向嵌套滚动在本页是禁区。）
            //   ⇒ 用「最近 5 天 + 展开/收起」，**滚动一律交给页面**。
            //
            // ⚠ 顺序按 `day` **显式排序**（`yyyy-MM-dd` 字典序 = 时间序），不依赖
            //   `replayResults` 的产出顺序 —— 收起态要的是"最近的"，猜错方向就反了。
            // ⚠ `id: \.day` —— 用**稳定主键**做标识（日期在结果里唯一，且不依赖字典 description 顺序）。
            let ordered = store.replayResults.sorted { $0.day < $1.day }
            let shown = replayExpanded ? ordered : Array(ordered.suffix(5))
            VStack(alignment: .leading, spacing: 2) {
                ForEach(shown, id: \.day) { r in
                    Text(r.oneLine)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(r.ok ? AnyShapeStyle(.secondary)
                                              : AnyShapeStyle(Sem.warn))
                        .textSelection(.enabled)
                }
                if ordered.count > 5 {
                    Button(replayExpanded ? "收起" : "展开全部（\(ordered.count) 天）") {
                        replayExpanded.toggle()
                    }
                    .btnSecondary()
                    .padding(.top, 4)
                }
            }
        }
    }
}
