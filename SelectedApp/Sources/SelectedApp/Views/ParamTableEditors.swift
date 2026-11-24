import SwiftUI
import AppKit
import SelectedCore

// MARK: - 结构化参数编辑器（参数中心里 json 类型参数的自定义控件）
//
// 形状由 `ParamTableSpecs.Shape` 决定。**未配 specs 的 json 参数仍走裸 JSON 文本框** ——
// 覆盖性由 `ParamTableSpecsTests` 钉住，不会静默退回。
//
// 为什么控件是「提交时机可控」而不是「每敲一键就提交」：
// 形状 A 改阈值会**改键名**（`le1` → `le2`），若逐键提交，行的身份在输入过程中
// 反复变化（视图重建 / 焦点丢失）。所以阈值与分值都在**回车或失焦**时提交。

// MARK: - 通用小控件

/// 回车 / 失焦时提交的文本框。
///
/// ⚠ 故意**不监听 `text` 的变化**：`onAppear` 里初始化文本会触发 `onChange`，
/// 于是一挂载就用初值"提交"一次（`value` 被写回同一份数据 → 触发重绘 → 再提交…）。
private struct CommitField: View {
    let initial: String
    var width: CGFloat = 56
    var placeholder: String = ""
    let onCommit: (String) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: width)
            .focused($focused)
            .onSubmit { onCommit(text) }
            .onChange(of: focused) { _, nowFocused in
                if !nowFocused { onCommit(text) }
            }
            .onAppear { text = initial }
            .onChange(of: initial) { _, v in if !focused { text = v } }
    }
}

/// 数值 → 紧凑文本（整数不写小数点，与 `Screener.thresholdKey` 的写法一致）
private func compactNum(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(v)
}

/// `NSNumber` 会桥接 `Bool`，显式排除 —— 与 `JSONValue` 的取值语义一致
private func asDouble(_ v: Any?) -> Double? {
    guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    return n.doubleValue
}

// MARK: - 形状 A：阈值→分值表（档位行编辑器）

/// 键名由 `(比较符, 阈值)` 拼出（`Screener.thresholdKey`）—— 改阈值就是改键名。
/// 每档一行：比较符下拉 / 阈值 / 分值（裸 JSON 文本框会让用户手写键名，体验倒挂）。
///
/// ⚠ 必填档位（`ParamSchema.requiredSubKeys`）阈值只读、不可删：
///   `REQUIRED_JSON_KEYS` 固化的是默认值的键名，删掉或改键名会让 `validate`
///   报「缺少子键」而保存被拒。新增的档位没有这个约束，可自由调整。
struct ParamThresholdTableEditor: View {
    let unit: String
    let sign: ParamTableSpecs.Sign
    /// 引擎约定的必填子键（不可删、阈值只读）
    let lockedKeys: Set<String>
    @Binding var value: [String: Any]

    /// 行 = Core 里的纯逻辑结果 + 给 SwiftUI 用的 `id`
    private struct Row: Identifiable {
        let id: String          // 键名
        let op: String
        let threshold: Double
        let score: Double

        init(_ r: ParamThresholdTableOps.Row) {
            id = r.key; op = r.op; threshold = r.threshold; score = r.score
        }
    }

    private static let ops = ["<=", "<", ">=", ">"]

    private static func opSymbol(_ op: String) -> String {
        switch op {
        case "<=": return "≤"
        case "<":  return "<"
        case ">=": return "≥"
        case ">":  return ">"
        default:   return op
        }
    }

    /// 排序 / 解析 / 键名拼接全部在 `ParamThresholdTableOps`（纯逻辑，可单测）——
    /// 视图只负责画。见那个文件顶部对"为什么抽到 Core"的说明。
    private var rows: [Row] { ParamThresholdTableOps.rows(value).map(Row.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows) { rowView($0) }
            addButton
            if !lockedKeys.isEmpty { lockHint }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 行

    @ViewBuilder
    private func rowView(_ r: Row) -> some View {
        let locked = lockedKeys.contains(r.id)
        HStack(spacing: 5) {
            if locked {
                // 必填档位：比较符只读（改它 = 改键名 = validate 报缺失）
                Text(Self.opSymbol(r.op))
                    .font(.caption.bold()).foregroundStyle(.secondary)
                    .frame(width: 30)
            } else {
                Picker("", selection: Binding(get: { r.op }, set: { setOp(r, to: $0) })) {
                    ForEach(Self.ops, id: \.self) { Text(Self.opSymbol($0)).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 52)
            }

            if locked {
                Text(compactNum(r.threshold))
                    .font(.caption.monospacedDigit())
                    .frame(width: 56, alignment: .trailing)
            } else {
                CommitField(initial: compactNum(r.threshold)) { setThreshold(r, to: $0) }
            }

            if !unit.isEmpty {
                Text(unit).font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .leading)
            }
            Text("→").font(.caption2).foregroundStyle(Tok.dim)

            CommitField(initial: compactNum(r.score), placeholder: scoreHint) { setScore(r, to: $0) }
            Text("分").font(.caption2).foregroundStyle(.secondary)

            Spacer(minLength: 2)

            if locked {
                Image(systemName: "lock.fill")
                    .font(AppFont.micro)
                    .foregroundStyle(Tok.dim)
                    .frame(width: 18)
                    .help("引擎约定的必填档位：可改分值，不能改阈值或删除")
            } else {
                Button { removeRow(r) } label: {
                    Image(systemName: "xmark").font(AppFont.micro)
                }
                .buttonStyle(.borderless)
                .help("删除这一档")
                .frame(width: 18)
            }
        }
    }

    private var scoreHint: String {
        switch sign {
        case .bonus:   return "+"
        case .penalty: return "−"
        case .any:     return ""
        }
    }

    private var addButton: some View {
        Button { addRow() } label: {
            Label("添加一档", systemImage: "plus").font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Sem.brand)
        .help("新增一档（默认加在现有档位之外，可再调整）")
    }

    private var lockHint: some View {
        Text("带 \(Image(systemName: "lock.fill")) 的是引擎约定的必填档位：可改分值，"
             + "不能改阈值或删除（改了会让参数校验报「缺少子键」）")
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 编辑

    /// 换键名：冲突（同比较符同阈值已存在）时**拒绝并提示**，不静默覆盖
    private func replace(_ r: Row, withKey newKey: String?) {
        guard let newKey else { return }
        guard let updated = ParamThresholdTableOps.replacingKey(value, from: r.id, to: newKey)
        else { NSSound.beep(); return }
        value = updated
    }

    private func setOp(_ r: Row, to op: String) {
        replace(r, withKey: Screener.thresholdKey(op: op, threshold: r.threshold))
    }

    private func setThreshold(_ r: Row, to text: String) {
        guard let t = Double(text.trimmingCharacters(in: .whitespaces)) else { return }
        replace(r, withKey: Screener.thresholdKey(op: r.op, threshold: t))
    }

    private func setScore(_ r: Row, to text: String) {
        guard let s = Double(text.trimmingCharacters(in: .whitespaces)) else { return }
        var v = value
        v[r.id] = s
        value = v
    }

    private func removeRow(_ r: Row) {
        var v = value
        v.removeValue(forKey: r.id)
        value = v
    }

    /// 新增一档：默认落在现有档位之外（`>` 取更大阈值），避免与现有键冲突
    private func addRow() {
        guard let result = ParamThresholdTableOps.addingRow(value) else { return }
        value = result.table
    }
}

/// 时间区间对（`["HH:mm", "HH:mm"]` 或暴跌日 `["--", "--"]`）。
///
/// ⚠ 不能拆成两个独立 `CommitField` 各自捕获渲染时的 `a` / `b`：
///   先改开始再改结束时，第二个框的闭包仍持有渲染前的旧 `a`，一失焦就把开始时间覆盖回去。
///   这里由同一个控件持有实时 `(startText, endText)`，提交时总是读取双框当前文本并同步校验。
@MainActor
private struct TimePairField: View {
    let initialStart: String
    let initialEnd: String
    let width: CGFloat
    let onCommit: ([String]) -> Void

    @State private var startText: String = ""
    @State private var endText: String = ""
    @FocusState private var focusedField: Slot?

    private enum Slot: Hashable { case start, end }

    private var halfWidth: CGFloat { max(52, (width - 14) / 2) }
    private var initialKey: String { "\(initialStart)\u{0}\(initialEnd)" }

    private var currentProblem: String? {
        ParamTableSpecs.timePairProblem(start: startText, end: endText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                TextField("09:30", text: $startText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: halfWidth)
                    .focused($focusedField, equals: .start)
                    .onSubmit { commit() }
                    .overlay {
                        if currentProblem != nil {
                            RoundedRectangle(cornerRadius: 5).stroke(Sem.up, lineWidth: 1)
                        }
                    }
                Text("–").font(.caption2).foregroundStyle(Tok.dim)
                TextField("15:00", text: $endText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: halfWidth)
                    .focused($focusedField, equals: .end)
                    .onSubmit { commit() }
                    .overlay {
                        if currentProblem != nil {
                            RoundedRectangle(cornerRadius: 5).stroke(Sem.up, lineWidth: 1)
                        }
                    }
            }
            if let problem = currentProblem {
                Text(problem)
                    .font(AppFont.detailSmall)
                    .foregroundStyle(Sem.up)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            startText = initialStart
            endText = initialEnd
        }
        .onChange(of: initialKey) { _, _ in
            if focusedField != .start { startText = initialStart }
            if focusedField != .end { endText = initialEnd }
        }
        .onChange(of: focusedField) { oldValue, _ in
            // 任一格失焦即提交实时双框（非法状态也会写入以便 ParamEditor 标红禁用保存；
            // 先改 start 再切去改 end 不会丢失 start）。
            if oldValue != nil {
                commit()
            }
        }
    }

    private func commit() {
        let s = startText.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = endText.trimmingCharacters(in: .whitespacesAndNewlines)
        startText = s
        endText = e
        if s == initialStart && e == initialEnd { return }
        onCommit([s, e])
    }
}

// MARK: - 通用字段控件（形状 B / C 复用）

/// 按 `FieldKind` 渲染一个子键的输入控件。提交时机同 `CommitField`（回车 / 失焦）。
///
/// `@MainActor` 是必须的：`onCommit` 是个 escaping 闭包，会被再捕获进 `CommitField`
/// 的闭包里。非隔离函数里传它会触发 Swift 6 的
/// 「sending value of non-Sendable type ... risks causing data races」。
/// 这本来就是 UI 代码，标 `@MainActor` 是它真实的隔离域。
@MainActor
@ViewBuilder
func paramFieldControl(kind: ParamTableSpecs.FieldKind,
                       initial: Any?,
                       width: CGFloat,
                       onCommit: @escaping (Any) -> Void) -> some View {
    switch kind {
    case .number, .percent:
        CommitField(initial: asDouble(initial).map(compactNum) ?? "", width: width) { text in
            guard let v = Double(text.trimmingCharacters(in: .whitespaces)) else { return }
            onCommit(v)
        }

    case .timePair:
        let pair = (initial as? [Any]) ?? []
        let a = pair.count > 0 ? String(describing: pair[0]) : ""
        let b = pair.count > 1 ? String(describing: pair[1]) : ""
        TimePairField(initialStart: a, initialEnd: b, width: width) { onCommit($0) }

    case .choice(let options):
        Picker("", selection: Binding(
            get: { (initial as? String) ?? options.first ?? "" },
            set: { onCommit($0) })) {
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden().pickerStyle(.menu).frame(width: width)

    case .text:
        CommitField(initial: (initial as? String) ?? "", width: width) { onCommit($0) }
    }
}

// MARK: - 形状 B：参数化判据（键名固定 + 中文标签）

/// 键是固定字段名（`vol_ratio_min` / `gain_ratio` / `score` …），不是"阈值→分值"，
/// 所以不能增删行，只能改值。
///
/// `canDisable` 为真时（schema 里 `optional == true`，如 `cum_5d_low`）多一个
/// **「停用本项」**开关 —— 对应"显式 `null` = 本版本停用该扣分"。
/// 停用**不清空**已填的值，重新启用即恢复。
struct ParamNamedFieldsEditor: View {
    let fields: [ParamTableSpecs.Field]
    let canDisable: Bool
    @Binding var value: [String: Any]
    @Binding var disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if disabled {
                HStack(spacing: 8) {
                    Text("本项已停用（保存为 null）")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("启用") { disabled = false }
                        .buttonStyle(.borderless).font(.caption).foregroundStyle(Sem.brand)
                    Spacer(minLength: 0)
                }
            } else {
                ForEach(fields, id: \.key) { f in
                    HStack(spacing: 6) {
                        Text(f.label)
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 116, alignment: .trailing)
                        paramFieldControl(kind: f.kind, initial: value[f.key],
                                          width: f.kind == .timePair ? 130 : 84) { v in
                            value[f.key] = v
                        }
                        if !f.unit.isEmpty {
                            Text(f.unit).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .help(f.note.isEmpty ? f.key : f.note)
                }
                if canDisable {
                    Button("停用本项") { disabled = true }
                        .buttonStyle(.borderless).font(.caption2).foregroundStyle(.secondary)
                        .padding(.leading, 122)
                        .help("保存为显式 null —— 本版本停用该扣分，不清空已填的值")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


// MARK: - 形状 C：行 × 列（预判策略表）

/// 5 个策略 × 6 个字段（窗口 / 目标价 / 止损价 / 风险 / 仓位 / 操作提示）。
///
/// ⚠ **逐行分块**而不是横向表格：参数 sheet 只有 580pt 宽，6 列横排每列只剩 ~80pt，
/// 「操作提示」会被挤成一条缝。分块后每个字段都有正常宽度，5 行 × ~90pt 靠表单滚动。
///
/// `risk` / `position` 走**下拉**（枚举固定，防手滑写错）；`direction` 是自由文案 ——
/// 这三个字段**都被引擎消费**（→ `predict_direction` / `risk_level` / `position_advice`），
/// 所以它们是参数而不是展示文案，只是不该让人手写 JSON。
struct ParamTableEditor: View {
    let rows: [ParamTableSpecs.Row]
    let columns: [ParamTableSpecs.Column]
    @Binding var value: [String: Any]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.key) { rowCard($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowCard(_ r: ParamTableSpecs.Row) -> some View {
        let row = (value[r.key] as? [String: Any]) ?? [:]
        return VStack(alignment: .leading, spacing: 3) {
            Text(r.label).font(.caption.bold()).foregroundStyle(.primary)
            ForEach(columns, id: \.key) { c in
                HStack(spacing: 6) {
                    Text(c.label)
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .trailing)
                    paramFieldControl(kind: c.kind, initial: row[c.key], width: c.width) { v in
                        var updated = (value[r.key] as? [String: Any]) ?? [:]
                        updated[c.key] = v
                        value[r.key] = updated
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(8)
        .background(Tok.row, in: RoundedRectangle(cornerRadius: 8))
    }
}
