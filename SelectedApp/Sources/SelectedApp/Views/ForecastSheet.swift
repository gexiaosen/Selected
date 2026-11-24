import SwiftUI
import SelectedCore

/// 次日高低点区间查询（手动输入任意股票代码）
///
/// **定位说明（界面上也原样展示）**：这是**统计区间估计**，不是预测承诺，更不构成买卖建议。
/// 口径：以该股自身近 N 个交易日的「高/低相对前收偏离」分布为基线，
/// 用近期波动倍数 k 调整后给出次日区间，并附带**逐日滚动回测命中率**说明这套方法当前的水平。
/// 为什么不显示"精确点位"：单日高低点主要由大盘与突发消息决定，给精确数字是误导。
struct ForecastSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let store = Store.shared

    /// 预填代码（从个股详情进来时用）
    var presetCode: String = ""

    @State private var code: String = ""
    @State private var searchSuggestions: [JSONValue] = []
    @State private var result: ForecastResult?
    @State private var errorText: String?
    @State private var loading = false
    @State private var queryTask: Task<Void, Never>?
    @State private var baseDays = 30
    @State private var recentDays = 3
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    inputRow
                    if loading {
                        loadingSkeleton
                    } else if let e = errorText {
                        errorView(e)
                    } else if let r = result {
                        resultView(r)
                    } else {
                        hintView
                    }
                }
                .padding(16)
            }
        }
        .frame(width: SheetMetrics.forecast.width, height: SheetMetrics.forecast.height)
        .onAppear {
            code = presetCode
            codeFocused = true
            if !presetCode.isEmpty { query() }
        }
        .onDisappear {
            queryTask?.cancel()
        }
    }

    // MARK: - 骨架

    private var header: some View {
        HStack {
            Image(systemName: "scope")
                .foregroundStyle(Sem.info)
            Text("次日高低点区间").font(.headline)
            Spacer()
            Button("关闭") { dismiss() }
                .btnSecondary()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var inputRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("输入代码或名称，如 600276 或 茅台", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .focused($codeFocused)
                    .onChange(of: code) { _, _ in searchSuggestions = searchStocks() }
                    .onSubmit { query() }
                Button {
                    query()
                } label: {
                    if loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("查询")
                    }
                }
                .btnPrimary()
                .disabled(loading || code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            // 搜索建议下拉（复用 stockList 名称模糊匹配）
            if !searchSuggestions.isEmpty && codeFocused {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // ⚠ id 用代码：搜索建议每按键换一批，`\.offset` 会把"第 0 条"复用成另一只票
                        //   （动画/高亮错位）
                        ForEach(searchSuggestions.prefix(10), id: \.codeKey) { s in
                            let c = s["code"].string ?? ""
                            let n = s["name"].string ?? ""
                            Button {
                                code = c
                                searchSuggestions = []
                                query()
                            } label: {
                                HStack {
                                    Text(c).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(n).font(.callout)
                                    Spacer()
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 180)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.top, 2)
            }
        }
    }

    /// 名称/代码模糊搜索（与自选页搜索同源，复用 stockList）
    private func searchStocks() -> [JSONValue] {
        let q = code.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        // 纯数字 → 视为代码直接查询，不弹建议
        if q.allSatisfy({ $0.isASCII && $0.isNumber }) { return [] }
        return store.stockList.filter { s in
            (s["code"].string ?? "").contains(q) || (s["name"].string ?? "").contains(q)
        }
    }

    private var loadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 8)
                    .fill(Tok.skeleton)
                    .frame(height: 64)
            }
        }
    }

    private func errorView(_ msg: String) -> some View {
        Card("查询失败") {
            Text(msg).font(.callout).foregroundStyle(Sem.warn)
            Text("常见原因：代码位数不对（需 6 位）、该股停牌/次新股导致历史数据不足。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("重试") { query() }
                    .btnSecondary()
                Text("输入框内可修改代码后重试。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var hintView: some View {
        Card("用法") {
            VStack(alignment: .leading, spacing: 6) {
                Text("输入 6 位代码（可带 sh/sz 前缀）查询次日区间。").font(.callout)
                Text("区间来自该股自身历史波动分布 + 近期波动状态，并附逐日滚动回测命中率。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("⚠ 属统计估计，不是预测承诺；大盘剧烈波动或一字板时区间会失效。")
                    .font(.caption).foregroundStyle(Sem.warn)
            }
        }
    }

    // MARK: - 结果

    private func resultView(_ r: ForecastResult) -> some View {
        let name = r.name
        let base = r.baseClose
        let hiC = r.highCentral
        let hiO = r.highOptimistic
        let loC = r.lowCentral
        let loO = r.lowOptimistic
        // 早退分支（日K不足）没有 baseline/recent/backtest → 实体里是 nil，
        // 这里用 `?? 0` / 可选链取值。
        let bt = r.backtest
        let bl = r.baseline
        let rc = r.recent

        return VStack(alignment: .leading, spacing: 14) {
            // 标的与基准
            HStack(spacing: 8) {
                Text("\(r.code) \(name)").font(.headline)
                Spacer()
                Text("基准日 \(r.asOfDash) · 前收 \(fmt(base))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !r.adjusted {
                Text("⚠ 前复权数据获取失败，已回落不复权口径：除权日可能造成假跳变，区间参考性下降")
                    .font(.caption).foregroundStyle(Sem.warn)
            }

            // 核心：次日区间
            Card("次日区间", subtitle: "锚定前收 \(fmt(base))") {
                HStack(spacing: 0) {
                    rangeCell("高点", central: hiC, edge: hiO, edgeLabel: "上限",
                              color: Sem.up, note: "约 3/4 的交易日日内高点不超过上限")
                    Divider().frame(height: 54)
                    rangeCell("低点", central: loC, edge: loO, edgeLabel: "下限",
                              color: Sem.down, note: "约 2/3 的交易日日内低点不破下限")
                }
                Text("预期振幅 \(fmtPct(r.expectedRangePct))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // 回测
            if let bt, bt.n > 0 {
                Card("历史回测", subtitle: "逐日滚动 n=\(bt.n)") {
                    VStack(alignment: .leading, spacing: 4) {
                        row2("高点 ≤ 上限", pct(bt.highWithinUpper))
                        row2("低点 ≥ 下限", pct(bt.lowAboveLower))
                        row2("高低点同时覆盖", pct(bt.bothCovered))
                        row2("中枢误差中位", "高 \(fmtPct(bt.highMedianErrPct)) / 低 \(fmtPct(bt.lowMedianErrPct))")
                    }
                }
            }

            // 口径明细
            Card("口径明细", subtitle: "基线 \(bl?.days ?? 0) 日 · 近期 \(rc?.days ?? 0) 日") {
                VStack(alignment: .leading, spacing: 4) {
                    row2("平均振幅（基线/近期）",
                         "\(fmtPct(bl?.avgRangePct)) → \(fmtPct(rc?.avgRangePct))")
                    row2("波动倍数 k", "\((rc?.k).map { String(format: "%.2f", $0) } ?? "-")"
                         + (rc?.kClamped == true ? "（已钳位）" : ""))
                    row2("基点分位（高）",
                         "P50 \(fmtPct(bl?.highPct.p50)) / P75 \(fmtPct(bl?.highPct.p75))")
                    row2("基点分位（低）",
                         "P50 \(fmtPct(bl?.lowPct.p50)) / P25 \(fmtPct(bl?.lowPct.p25))")
                    row2("上涨日占比", pct(bl?.closeUpRatio))
                    row2("连续涨跌", "\(rc?.streak ?? 0) 日")
                }
            }

            // 局限（必须展示，不可省）
            Card("局限说明") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(r.caveats.indices, id: \.self) { i in
                        HStack(alignment: .top, spacing: 6) {
                            Text("·").foregroundStyle(.secondary)
                            Text(r.caveats[i])
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func rangeCell(_ title: String, central: Double, edge: Double,
                           edgeLabel: String, color: Color, note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(fmt(central)).font(AppFont.display(26))
                    .monospacedDigit().foregroundStyle(color)
                Text("中枢").font(AppFont.detail).foregroundStyle(.secondary)
            }
            Text("\(edgeLabel) \(fmt(edge))")
                .font(.callout).monospacedDigit().foregroundStyle(color)
            Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 8)
    }

    private func row2(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.caption.monospacedDigit())
        }
    }

    /// 区间上下限与前收都是**价格档** ⇒ 小数位跟着标的走（基金 3 位）
    private func fmt(_ v: Double) -> String { StockFmt.price(v, code: code) }
    private func fmtPct(_ v: Double?) -> String {
        guard let v else { return "-" }
        return String(format: "%+.2f%%", v)
    }
    private func pct(_ v: Double?) -> String {
        guard let v else { return "-" }
        return String(format: "%.0f%%", v * 100)
    }

    // MARK: - 取数（只读查询，不走 runEngine：它与"查看日期"无关，也不该受历史模式限制）

    private func query() {
        let c = code.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return }
        loading = true
        errorText = nil
        result = nil
        let base = baseDays, recent = recentDays
        // 名称：本地证券列表（与引擎 forecast 的取名口径一致；纯代码输入也能显示名称）
        let full = StockQuotes.fullCode(c)
        let name = store.stockList.first {
            $0["code"].string == full || $0["code"].string == c
        }?["name"].string ?? ""
        queryTask?.cancel()
        queryTask = Task {
            // 原生计算（已与 Python 逐字段对账一致）；不回落 CLI
            let out = await ForecastEngine.fetchAndForecast(code: c, name: name,
                                                            baseDays: base, recentDays: recent)
            guard !Task.isCancelled else { return }
            loading = false
            guard let out else {
                errorText = "\(c) 的日K线取数失败（数据源异常或代码无效）"
                return
            }
            if out.status == "insufficient_data" {
                errorText = out.dataError.isEmpty ? "-" : out.dataError
            } else {
                result = out
            }
        }
    }
}
