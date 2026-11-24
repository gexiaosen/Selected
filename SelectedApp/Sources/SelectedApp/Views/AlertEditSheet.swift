import SwiftUI
import SelectedCore

/// 提醒编辑弹窗的目标（`Identifiable` 供 `.sheet(item:)`）
struct AlertEditTarget: Identifiable {
    let code: String
    let name: String
    var id: String { code }
}

// MARK: - 「修改提醒」弹窗（自选列表铃铛图标打开）
//
// 布局与参数编辑器统一：头部 → 内容 → 底部操作栏。
// 6 行规则：价格上涨到 / 价格下跌到 / 当日涨额达 / 当日跌额达 / 当日涨幅达 / 当日跌幅达，
// 每行各带「单次 / 每日重复」，底部是取消 + 确认。
//
// ⚠ 行序与文案全由 `AlertKind.allCases` / 各属性决定，本文件不自带
//   "哪种类型该怎么显示"的判断 —— 本地留一份族别判断，新增一族就会判错。
//   族别相关的四件事（`placeholder` / `defaultRepeat` / `unitSuffix` / 文案）都在 Core。
//
// ⚠ 草稿态，确认才落库：弹窗内不写库，取消必须能完整回退。
//   故不要在这里加 `onChange` 自动保存（挂载即触发的循环）。
// ⚠ 校验失败 → 行内红字 + 不关闭（不静默丢弃、不静默截断）。
// ⚠ 提醒**只来自这里手动填写的规则**：引擎的止盈/止损价位仅在头部做只读参考 + 一键填入，
//   不会自行弹通知（0.6.10 起）。
struct AlertEditSheet: View {

    let code: String
    let name: String

    private let store = Store.shared
    @Environment(\.dismiss) private var dismiss

    /// 六行的输入文本（多值逗号分隔）
    @State private var texts: [AlertKind: String]
    /// 六行的重复方式
    @State private var repeats: [AlertKind: AlertRepeat]
    /// 校验错误（按行；确认时填，改动即清）
    @State private var errors: [AlertKind: String] = [:]
    /// 提醒时间窗
    @State private var window: AlertWindow

    init(code: String, name: String) {
        self.code = code
        self.name = name
        // ⚠ 不在构造期查库：init 只建空/默认态，`.task` 里异步加载填充
        //   （构造期同步读 `watch_alerts` 会压在 sheet 呈现的 critical path 上）。
        _texts = State(initialValue: [:])
        _repeats = State(initialValue: Dictionary(uniqueKeysWithValues:
            AlertKind.allCases.map { ($0, $0.defaultRepeat) }))
        _window = State(initialValue: .anytime)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(AlertKind.allCases, id: \.self) { kind in
                        ruleRow(kind)
                    }
                    sameScaleNote
                    windowRow
                    engineRef
                }
                .padding(14)
            }
            Divider()
            footer
        }
        // ⚠ 6 行规则后内容高度约 515–540pt —— 高度设小了内容会滚动，用户看不到底部行
        //   （界面不报错、不崩，只是"少了两个选项"）。
        //   ⚠ 这个数字只能靠真开一次确认：`swift build` 与回归测试验不了"有没有被截断/要滚动"。
        //   长期可改成自适应高度，但那需要能真看一次界面才敢动。
        .frame(width: 480, height: 540)
        // 构造期不查库（见 init）→ 呈现后异步加载当前规则与时间窗（草稿态不变）。
        // ⚠ 读 `Store` 的缓存（`alertRulesByCode` / `alertWindowsByCode`），不直接调 `AlertStore`：
        //   View 里逐行调它就是主线程同步 I/O（每行一次 SQLite 查询）。
        .task {
            // ⚠ 若缓存还没填（用户从没进过设置页的提醒一览），先补一次再读，
            //   避免出现"打开编辑弹窗但缓存是空的 ⇒ 规则显示成默认值"这种静默错误。
            if store.alertRulesByCode.isEmpty || store.alertWindowsByCode.isEmpty {
                store.loadAlerts()
            }
            let rules = store.alertRulesByCode[code] ?? []
            var t: [AlertKind: String] = [:]
            var r: [AlertKind: AlertRepeat] = [:]
            for kind in AlertKind.allCases {
                let mine = rules.filter { $0.kind == kind }
                t[kind] = AlertInput.format(mine.map(\.threshold),
                                digits: StockFmt.priceDigits(code: code))
                // ⚠ 默认值也走 Core（`AlertKind.defaultRepeat`）——本文件不自带"哪种类型默认怎么重复"
                //   的判断，否则就是第二份口径。
                r[kind] = mine.first?.repeatMode ?? kind.defaultRepeat
            }
            texts = t
            repeats = r
            // ⚠ 缓存里没这只票（没配过时间窗）⇒ 回落 .anytime；
            //   不能在这里换口径，否则「未配置」与「配置为全天」会变成两回事。
            window = store.alertWindowsByCode[code] ?? .anytime
        }
    }

    // MARK: 头部：股票信息

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge")
                    .foregroundStyle(Sem.warn)
                Text("修改提醒").font(.headline)
            }
            Text("\(name) (\(StockQuotes.fullCode(code).uppercased()))")
                .font(.callout.bold())
            quoteLine
        }
        .frame(maxWidth: .infinity)
        .padding(14)
    }

    @ViewBuilder
    private var quoteLine: some View {
        if let q = store.liveQuotes[code] {
            HStack(spacing: 8) {
                Text(StockFmt.price(q.currentPrice, code: code))
                Text(StockFmt.signedPrice(q.change, code: code))
                Text(String(format: "%+.2f%%", q.changePercent))
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(Sem.pnl(q.changePercent))
        } else {
            Text("暂无实时行情（打开自选页后自动获取）")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 六行规则

    private func ruleRow(_ kind: AlertKind) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(kind.title)
                    .font(.callout)
                    .frame(width: 88, alignment: .trailing)
                // 占位符按族别给（价格 `如 5.20` / 涨跌额 `如 0.50,1.00` / 百分比 `如 1.00,3.00,5.00`）
                TextField(kind.placeholder, text: textBinding(kind))
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospacedDigit())
                    .onChange(of: texts[kind] ?? "") { _, _ in
                        // 内容变了（含「填入引擎价」那条路径）→ 清掉这一行的旧错误，
                        // 不要让用户改完还看着红字。
                        // ⚠ 只改 `errors` 不改 `texts`，不会自激（反过来就会）
                        if errors[kind] != nil { errors[kind] = nil }
                    }
                Picker("", selection: repeatBinding(kind)) {
                    ForEach(AlertRepeat.allCases, id: \.self) { r in
                        Text(r.title).tag(r)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 104)
            }
            if let e = errors[kind] {
                Text(e)
                    .font(.caption2)
                    .foregroundStyle(Sem.up)
                    .padding(.leading, 96)
            }
        }
    }

    private func textBinding(_ kind: AlertKind) -> Binding<String> {
        Binding(get: { texts[kind] ?? "" }, set: { texts[kind] = $0 })
    }

    private func repeatBinding(_ kind: AlertKind) -> Binding<AlertRepeat> {
        Binding(get: { repeats[kind] ?? kind.defaultRepeat },
                set: { repeats[kind] = $0 })
    }

    // MARK: 涨额 / 涨幅同源提示

    /// ⚠ 口径提示（惯例「口径写在界面上」）：同一只票同一天，涨跌额与涨跌幅是同一个事实的两种刻度，
    /// 不是两份独立证据。用户可能两个都设，不拦，但必须让他知道两条会在同一刻各响一条 ——
    /// 否则他会以为是两个独立的信号在互相印证。
    private var sameScaleNote: some View {
        Text("涨额与涨幅是同一个数的两种刻度（1 元 = 多少% 取决于昨收）——"
             + "同一只票两个都设，若刚好对上会在同一刻各响一条")
            .font(.caption).foregroundStyle(.secondary)
            .padding(.leading, 96)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 提醒时间

    private var windowRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("提醒时间")
                    .font(.callout)
                    .frame(width: 88, alignment: .trailing)
                Picker("", selection: $window) {
                    ForEach(AlertWindow.allCases, id: \.self) { w in
                        Text(w.title).tag(w)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 140)
                Spacer(minLength: 0)
            }
            // 「口径写在界面上」：窗口与交易日的关系必须让用户看得见
            Text("三种时间都只在交易日评估 —— 否则「每日重复」会在周末拿周五收盘价重复提醒")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 96)
        }
    }

    // MARK: 引擎参考（只读 + 一键填入）

    /// 引擎的止盈 / 止损锚点。只读参考：来自最近一次判定（`watch_judgments`），
    /// 由引擎每日重算，**不会自动提醒**；要提醒请填入下方任一规则并确认。
    @ViewBuilder
    private var engineRef: some View {
        let j = store.watchJudgments.first { $0.code == code }
        let target = j?.targetPrice ?? 0
        let stop = j?.stopLossPrice ?? 0
        if target > 0 || stop > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text("引擎参考（来自最近一次判定，每日重算；仅参考，不会自动提醒 —— 要提醒请填入下方并确认）")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if target > 0 {
                        Button("填入目标价 \(fmt(target))") { texts[.upPrice] = fmt(target) }
                    }
                    if stop > 0 {
                        Button("填入止损价 \(fmt(stop))") { texts[.downPrice] = fmt(stop) }
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .buttonStyle(.link)
            }
            .padding(.top, 4)
        }
    }

    // MARK: 底部操作栏

    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .btnSecondary()
                Button("确认") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .btnPrimary()
            }
            Text("提示：多个值可以用英文逗号（,）隔开，中文逗号也认；留空 = 取消该条")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    // MARK: 确认

    /// 逐行解析 → 任一非法就**行内报错并不关闭**（不静默丢弃、不静默截断）。
    private func confirm() {
        var parsed: [AlertKind: [Double]] = [:]
        var found: [AlertKind: String] = [:]
        for kind in AlertKind.allCases {
            switch AlertInput.parse(texts[kind] ?? "", kind: kind) {
            case .empty:
                parsed[kind] = []
            case .ok(let values):
                parsed[kind] = values
            case .invalid(let why):
                found[kind] = "\(kind.title)：\(why)"
            }
        }
        guard found.isEmpty else {
            errors = found
            return
        }

        // 一个阈值一行（各自带本行的重复方式）—— 阶梯提醒靠这个成立：
        // 「涨幅达 5%」响过之后「涨幅达 7%」还能响
        var drafts: [AlertDraft] = []
        for kind in AlertKind.allCases {
            let repeatMode = repeats[kind] ?? kind.defaultRepeat
            for v in parsed[kind] ?? [] {
                drafts.append(AlertDraft(kind: kind, threshold: v, repeatMode: repeatMode))
            }
        }

        let empty = drafts.isEmpty
        store.saveAlerts(code: code, drafts: drafts, window: window,
                         successMessage: empty ? "已取消该股提醒" : "提醒已保存（\(drafts.count) 条）")
        dismiss()
    }

    /// 提醒阈值都是**价格档** ⇒ 小数位跟着标的走（基金 3 位，见 `StockFmt.priceDigits`）
    private func fmt(_ v: Double) -> String { StockFmt.price(v, code: code) }
}
