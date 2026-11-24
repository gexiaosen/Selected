import SwiftUI
import SelectedCore

// MARK: - 参数调优面板（参数中心「参数调优」域的右栏内容）
//
// 历史重放评估 → 回测对比新老差异 → 存为全局新版本。
// 版本卡就在同页上方：保存的新版本当场可见、当场可激活（原先在设置窗口里，
// 调完要退出去参数中心看，闭环断在两个窗口之间）。
//
// ⚠ 独立 struct（不是 `extension ParamsCenterView`）：Swift 的 `@State`
//   不能声明在 extension 里，做成页面壳的 extension 又要放宽 module-internal。

struct TunePanelView: View {
    private let store = Store.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 新版本名（候选展开后的保存行）
    @State private var tuneVersion = ""
    /// 展开的候选下标（nil = 全折叠）
    @State private var expandedCandidate: Int?
    /// 保存后直接激活
    @State private var tuneActivate = true
    /// 调优池是否纳入历史回放样本。**存 UserDefaults**（与 `phases` 同一模式：
    /// 工厂参数 `iterate.include_replay` 是引擎侧默认，实际生效值由这里单独管）。
    /// ⚠ 默认 `false` —— 回放是收盘价口径，混池会让"最优参数"变成两种口径的平均。
    @AppStorage("tuneIncludeReplay") private var tuneIncludeReplay = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("参数调优", systemImage: "wand.and.stars").font(.callout.bold())
                Text("历史实盘重放评估 → 回测对比新老差异 → 存为全局新版本")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }

            if store.tuneRunning {
                HStack(spacing: 10) {
                    ThinkingDot(design: .solving, diameter: 16)
                    Text("正在回放历史标的并搜索更优参数…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            } else if let t = store.tuneReport {
                tuneResult(t)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("对历史选股日已入档标的，按候选参数重算档位并与真实次日表现比对；展开候选可查看新老参数逐标的回测差异，再决定存为全局新版本。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("评估池大小取决于已积累的复盘数据；结果仅作参考，不自动应用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                // 样本池口径开关。
                // ⚠ 默认关（只用实盘样本）：回放样本是**收盘价口径**、实盘是**尾盘盘中口径**，
                //   混池得到的"最优参数"是两种口径的平均，而池里混了什么在界面上看不出来。
                //   与 `phases` 同一模式：工厂参数 `iterate.include_replay` 是引擎侧默认，
                //   实际生效值由这里（UserDefaults）管。
                Toggle("纳入历史回放样本", isOn: $tuneIncludeReplay)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .help("回放样本是收盘价口径（选股价=收盘价、量比=全日），"
                          + "与实盘的尾盘盘中口径不同；混在一起调优，得到的参数是两种口径的平均。"
                          + "开启后结果里会标注「已含回放样本」。")
                if tuneIncludeReplay {
                    Text("⚠️ 含收盘价口径样本")
                        .font(.caption).foregroundStyle(Sem.warn)
                }
                Spacer()
                Button {
                    expandedCandidate = nil
                    store.runTune(includeReplay: tuneIncludeReplay)
                } label: {
                    Label(store.tuneRunning ? "调优中…" : "开始调优", systemImage: "wand.and.stars")
                }
                .btnPrimary()
                .disabled(store.tuneRunning)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: 结果区

    @ViewBuilder
    private func tuneResult(_ t: TuneResult) -> some View {
        let b = t.baseline.metrics
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                KVRow(key: "评估池", value: "\(t.poolSize) 只标的（去重）")
                KVRow(key: "调优维度", value: "\(t.dims.count) 项评分参数")
                // 样本量透明度：样本跨了多少天直接决定结论可信度（只报"多少只标的"看不出时间跨度）
                KVRow(key: "样本跨度",
                      value: t.poolWindowOrNil.map { "\(t.poolDates) 个交易日（\($0)）" }
                          ?? "—")
                KVRow(key: "耗时", value: "\(t.elapsedSec) s")
                // 池的**口径**必须显式说出来。
                // 否则用户看到"池突然变大了"无从解释 —— 而变大可能是因为混进了
                // 收盘价口径的回放样本，与实盘的尾盘口径不可直接比。
                if t.includeReplay {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Sem.warn)
                        Text("已含历史回放样本（收盘价口径）")
                            .font(.caption).foregroundStyle(Sem.warn)
                    }
                } else {
                    Text("样本池：仅实盘（尾盘盘中口径）")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 16) {
                Label("基线", systemImage: "flag").font(.callout.bold())
                Text("综合 \(String(format: "%.1f", b.total))")
                Text("一档 \(b.tier1.n)只 胜率\(String(format: "%.0f", b.tier1.winrate))%")
                Text("均收 \(String(format: "%.2f", b.tier1.avgProfit))%")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.callout)

            let cands = t.candidates
            // 样本门槛：样本不足 → **不出结论** —— 候选列表整段不展示。
            // 只加一句 warning 而结论照样摆着不够：7 个样本上的"比基线好 3 分"是噪声不是发现。
            // 没有判据（旧格式结果）时按老行为走，不擅自把已有结论藏起来。
            let gated = t.sampleGateOrNil != nil && !t.sampleSufficient
            // 样本不足警告（门槛提示优先，措辞由 Core 统一给，避免两处漂移）
            let notice = gated ? t.sampleGateMessage : t.warning
            if !notice.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Sem.warn)
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(Sem.warn)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Tok.tint(Sem.warn, .block), in: RoundedRectangle(cornerRadius: 8))
            }
            if !gated {
                if cands.isEmpty {
                    Text("未产生候选（可尝试导入更多历史数据后重试）")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    // ⚠ `id` **必须用下标，不许用 `\.element`**：
                    // `TuneCandidate` 的 `Hashable` 来自 `JSONValue.hash` =
                    // `hasher.combine(String(describing: raw))` —— 会把**整个候选**
                    // （含 `metrics.per_stock` 与 `backtest.rows` 各数千条）拼成字符串再哈希，
                    // 含回放池时整份结果数 MB，每次 body 求值哈希耗数百 ms（设置页卡顿的来源）。
                    //
                    // 用 `\.offset` 是**安全**的：`cands` 是单份 `tuneReport` 的快照，
                    // 从不原地增删（重新调优时 `runTune` 先把 `tuneReport` 置 nil →
                    // 整段 ForEach 被销毁重建），且本行的语义标识本来就是"候选 N"。
                    // ⚠ 别照抄到"元素会原地增删/重排"的列表上 —— 那里下标会错位（本项目踩过）。
                    ForEach(Array(cands.enumerated()), id: \.offset) { idx, c in
                        candidateRow(c, index: idx, baseline: b)
                    }
                }
            }
            // 加分项同源相关性诊断：**只在真有高相关配对时出现**（正常不占位）。
            // 提示的是"这几项底层特征同源、别当独立证据加总"，
            // 只提示、不自动调权重 —— 故用 warn 色而非 error 色。
            if let corr = t.correlationOrNil, !t.correlationPairs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Label("同源提示", systemImage: "square.stack.3d.up.slash")
                            .font(.callout.bold())
                        Text("\(t.correlationSamples) 个样本 · |ρ|≥\(String(format: "%.1f", corr["threshold"].doubleOrZero))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(t.correlationPairs.indices, id: \.self) { i in
                        let p = t.correlationPairs[i]
                        Text("\(p["a_label"].string ?? "") ↔ \(p["b_label"].string ?? "")"
                             + "　ρ=\(String(format: "%.2f", p["rho"].doubleOrZero))"
                             + "（n=\(p["n"].intOrZero)）")
                            .font(.caption)
                            .foregroundStyle(Sem.warn)
                    }
                    Text(t.correlationNote)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tok.tint(Sem.warn, .block), in: RoundedRectangle(cornerRadius: 8))
            }
            // P2 C-D3：反事实覆盖诊断。**只在真有未并入的淘汰样本时出现**（正常不占位）——
            // 把"结论覆盖了哪一层、漏了多少"从注释里的一句散文变成看得见的数。
            if t.counterfactualOrNil != nil, t.counterfactualExcluded > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Label("覆盖缺口", systemImage: "square.on.square.dashed")
                            .font(.callout.bold())
                        Text("被淘汰样本 \(t.counterfactualExcluded) 条 · 可并入 \(t.counterfactualRescoreable) 条")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(t.counterfactualNote)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tok.chip, in: RoundedRectangle(cornerRadius: 8))
            }
            // P2 C-D2：参数时代诊断。**只在跨了多个版本时出现**（单版本窗口不占位）——
            // 与 policy_warning 同一类：提醒"结论是混合参数时代的"，别与单一版本直接比。
            if t.paramEraCount > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Label("混合参数时代", systemImage: "clock.arrow.circlepath")
                            .font(.callout.bold())
                        Text(t.paramEras.sorted { $0.value > $1.value }
                                .map { "\($0.key)×\($0.value)" }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(t.paramEraWarning)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tok.tint(Sem.warn, .block), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: 候选行

    private func candidateRow(_ c: TuneCandidate, index: Int, baseline: TuneMetrics) -> some View {
        let m = c.metrics
        let delta = m.total - baseline.total
        let expanded = expandedCandidate == index
        let diff = c.diff
        let diffSummaryText = diff.isEmpty ? "与基线一致" : diff.map { k, v in
            // ⚠ 用完整键路径（点分全名），不只取末段 ——
            //  "ac_k" 是"连涨≤1天加分"还是"首板加速加分"无从判断，13 组 71 项里同名末段不止一个
            let valStr: String
            // ⚠ 取 v.raw 再 cast：v 是 JSONValue 包装，直接 as? String/NSNumber 恒失败
            //（编译器亦警告 unrelated cast），那样 diff 摘要会退化为打印结构体
            if let s = v.raw as? String { valStr = s }
            else if let n = v.raw as? NSNumber { valStr = n.stringValue }
            else if let arr = v.raw as? [Any] { valStr = "[\(arr.map { "\($0)" }.joined(separator: ", "))]" }
            else { valStr = "\(v.raw)" }
            return "\(k)→\(valStr)"
        }.joined(separator: "  ")
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : Mot.expand) {
                    expandedCandidate = expanded ? nil : index
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: delta > 0.01 ? "arrow.up.right.circle.fill" : "minus.circle")
                        .foregroundStyle(delta > 0 ? AnyShapeStyle(Sem.down) : AnyShapeStyle(Color.secondary))
                    Text("候选 \(index + 1)").bold()
                    // 基线→候选综合分 delta 条：共用组件（审查 #16），右绿=提升、左灰=持平/下降。
                    // 宽 60 ⇒ 半宽 30、扣 4pt 端头留白可用 26pt；原口径 1 分 = 6pt ⇒ 满幅 ≈ 26/6 分
                    HStack(spacing: 6) {
                        Text("综合 \(String(format: "%.1f", m.total))")
                            .monospacedDigit()
                        ZeroAxisDeltaBar(value: delta, fullScale: 26.0 / 6.0, height: 9,
                                         positiveColor: Sem.downGraph, negativeColor: Tok.stroke,
                                         baselineColor: Tok.stroke, endInset: 4)
                            .frame(width: 60, height: 9)
                    }
                    Text("\(String(format: "%+.1f", delta))").monospacedDigit()
                        .foregroundStyle(delta > 0 ? AnyShapeStyle(Sem.down) : AnyShapeStyle(Color.secondary))
                    Text("一档 \(m.tier1.n) 只 胜率\(String(format: "%.0f", m.tier1.winrate))%")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("均收 \(String(format: "%.2f", m.tier1.avgProfit))%")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(delta > 0 ? "更优" : "参考")
                        .font(.caption.bold())
                        .foregroundStyle(delta > 0 ? Sem.down : .secondary)
                    Image(systemName: "chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // diff 摘要：显示该候选改了哪些参数
            if !diff.isEmpty {
                Text(diffSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if expanded {
                candidateDetail(c)
                    .motionAwareTransition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: 候选展开：回测对比 + 差异明细 + 保存

    @ViewBuilder
    private func candidateDetail(_ c: TuneCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // ① 回测实盘对比（新老参数逐标的差异）
            if c.hasBacktest {
                backtestSection(c.backtest)
            } else {
                Text("该候选与基线无差异，无回测对比")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // ② 参数差异明细
            let diffText = detailDiffText(c.diff)
            if !diffText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("参数差异（\(c.diffCount) 项）")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    Text(diffText)
                        // ⚠ 等宽字号统一写 `.caption.monospaced()`，不用 `.system(.caption, design: .monospaced)`
                        //   手工拼"字号+字体族" —— 两套写法并存会让"字号档位"再也数不清。
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tok.sunken, in: RoundedRectangle(cornerRadius: 8))
                }
            }

            // ③ 保存落点：全局新版本（保存后同页版本卡当场可见）
            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down").foregroundStyle(.secondary)
                Text("保存到：").font(.callout.bold())
                Spacer()
            }
            HStack(spacing: 8) {
                Image(systemName: "globe").foregroundStyle(.secondary)
                TextField("全局新版本名", text: $tuneVersion)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                Toggle("激活", isOn: $tuneActivate)
                    .toggleStyle(.checkbox).font(.caption)
                Button {
                    if store.applyTuneCandidate(versionName: tuneVersion.trimmingCharacters(in: .whitespaces),
                                                diff: c.diffAny, activate: tuneActivate) {
                        expandedCandidate = nil
                    }
                } label: {
                    Label("存为全局版本", systemImage: "globe")
                }
                .btnPrimary()
                .disabled(tuneVersion.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
        }
        .padding(10)
        .background(Tok.sunken, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: 回测对比表

    @ViewBuilder
    private func backtestSection(_ bt: TuneBacktest) -> some View {
        let s = bt.summary
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Label("回测对比（新老参数 · 实盘表现）", systemImage: "arrow.left.arrow.right.circle")
                    .font(.caption.bold())
                Spacer()
                Text("综合 \(String(format: "%.1f", s.old.total)) → \(String(format: "%.1f", s.new.total))")
                Text("\(String(format: "%+.1f", s.totalDelta))")
                    .foregroundStyle(Sem.change(s.totalDelta > 0 ? "good" : "bad"))
                    .monospacedDigit()
                Text("胜率 \(String(format: "%+.0f", s.winrateDelta))%")
                    .foregroundStyle(Sem.change(s.winrateDelta > 0 ? "good" : "bad"))
                    .monospacedDigit()
                Text("好变化 \(s.goodChanges) · 坏变化 \(s.badChanges)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            let rows = bt.rows
            if !rows.isEmpty {
                // 原生 Table（12 行封顶 + 内部滚动）
                let shown = Array(rows.prefix(12))
                let cols = [
                    DataTableColumn("name", "标的"),
                    DataTableColumn("score", "评分（老→新）", width: 108, alignment: .trailing, isNumeric: true),
                    DataTableColumn("tier", "档位", width: 104),
                    DataTableColumn("next", "次日实盘", width: 96, alignment: .trailing, isNumeric: true),
                ]
                SharedDataTable(columns: cols, rows: shown) { r, c in
                    switch c.id {
                    case "name":
                        HStack(spacing: 4) {
                            Text(r.change == "good" ? "▲" : (r.change == "bad" ? "▼" : "·"))
                                .font(AppFont.detailSmall.weight(.bold))
                                .foregroundStyle(Sem.change(r.change))
                                .frame(width: 12)
                            Text("\(r.code) \(r.nameDash)").lineLimit(1)
                        }
                    case "score":
                        Text("\(r.oldScore) → \(r.newScore)").monospacedDigit()
                    case "tier":
                        Text(tierText(r.oldTier) + " → " + tierText(r.newTier))
                    default:
                        if let p = r.profitOrNil {
                            Text("\(String(format: "%+.2f", p))%").foregroundStyle(Color.pnl(p))
                        } else {
                            Text("-").foregroundStyle(.secondary)
                        }
                    }
                }
                if rows.count > 12 {
                    Text("…其余 \(rows.count - 12) 只")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("新老参数下逐标的无档位/评分变化")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func tierText(_ t: Int) -> String {
        t == 1 ? "一档" : (t == 2 ? "二档" : "三档")
    }

    private func detailDiffText(_ diff: [String: JSONValue]) -> String {
        let lines = diff.map { key, val in "\(key) = \(val.stringOrDash)" }.sorted()
        return lines.joined(separator: "\n")
    }
}

// 原生 Table 需要行 Identifiable；TuneBacktestRow 是 JSONEntity
// 包装，以 code 作 id（与原 DataTable 的 rowID: \.code 同口径）。
extension TuneBacktestRow: Identifiable {
    public var id: String { code }
}
