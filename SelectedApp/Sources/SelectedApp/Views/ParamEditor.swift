import SwiftUI
import AppKit
import SelectedCore

// MARK: - 参数编辑器（参数中心页内全宽视图）
//
// 编辑引擎：值缓存 / 会话 diff / 校验 / 保存。
//   ① 顶部常驻「未保存 / 与激活版本差异 (n)」条（diff 是 `ParamVersionDiff` 纯函数，
//      比对已落库的目标状态 vs 激活版本，不含本次会话编辑）；
//   ② 域内容由页面壳左导航驱动（`domain`），域内 tunable 项置顶为「重点」、
//      其余进「更多」折叠。
//
// ⚠ schema 由本视图自己持有（@State）：读全局 `store.paramSchema` 会让
//   「编辑指定版本」永久替换全局基线 → 之后另存出的新版本参数错误
//   （写坏参数，比崩溃更危险）。

/// 参数中心页的单域编辑器
struct ParamEditor: View {
    private let store = Store.shared

    /// 编辑指定版本（nil = 当前激活版本）
    var editVersion: String?
    /// 当前显示的域（页面壳左导航驱动；切换域**不**重建编辑值——状态跨域共享）
    var domain: ParamDomain
    /// 外部写完成信号（激活/删除版本后页面壳 +1）→ 重建基线
    var reloadToken: Int = 0
    /// 保存完成后回调（页面壳借此退出「编辑指定版本」态）
    var onSaved: () -> Void = {}
    /// 顶栏「返回激活版本」回调（页面壳清空指定版本目标）
    var onExitTarget: () -> Void = {}

    @State private var editor = ParamEditorState()
    /// 本编辑器自己持有的 schema（理由见文件头 ⚠）
    @State private var schema: JSONValue?
    /// 「与激活版本差异」列表（已落库状态比对，不含会话编辑）
    @State private var versionDiff: [ParamDiffEntry] = []
    @State private var showDiffPopover = false
    /// 「更多」折叠展开态（域内无 tunable 项时不折叠，见 `domainContent`）
    @State private var moreExpanded = false

    private var groups: [JSONValue] { schema?["groups"].array ?? [] }

    /// 重建基线的触发键（目标切换 / 外部写 / 本地保存后）
    private var targetKey: String {
        "\(editVersion ?? "")|\(reloadToken)|\(editor.localReload)"
    }

    private var activeVersionName: String {
        store.paramVersions.first { $0.isActive }?.name ?? "—"
    }

    // MARK: 加载

    private func loadAll() {
        guard let target = store.paramsSnapshot(version: editVersion) else {
            schema = JSONValue(["groups": [Any]()])
            return
        }
        schema = JSONValue(["groups": ParamSchema.shared.schemaPayload(target)])
        if let active = store.paramsSnapshot(version: nil) {
            versionDiff = ParamVersionDiff.diff(old: active, new: target)
        }
    }

    // MARK: 布局

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if groups.isEmpty {
                VStack(spacing: 8) {
                    ProgressView("加载参数…")
                    Button("重新加载") { editor.localReload += 1 }
                        .btnSecondary()
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                form
            }
            Divider()
            footer
        }
        .task(id: targetKey) { loadAll() }
        .onChange(of: schema) { _, _ in editor.buildEdits(from: groups) }
        .dismissKeyboardOnOutsideTap()
    }

    /// 顶部常驻条：编辑目标 + 未保存提示 + 与激活版本差异
    private var topBar: some View {
        HStack(spacing: 8) {
            Label(editVersion != nil ? "正在编辑版本 \(editVersion ?? "")"
                                     : "正在编辑激活版本 \(activeVersionName)",
                  systemImage: "slider.horizontal.3")
                .font(.callout)
                .foregroundStyle(editVersion != nil ? Sem.info : Color.secondary)
            Spacer()
            if editVersion != nil {
                Button("返回激活版本") { onExitTarget() }
                    .btnSecondary()
                    .controlSize(.small)
            }
            if !editor.invalidKeys.isEmpty {
                Text("\(editor.invalidKeys.count) 项输入无效").font(.caption).foregroundStyle(Sem.up)
            } else if editor.diffCount > 0 {
                Text("\(editor.diffCount) 项未保存").font(.caption).foregroundStyle(Sem.warn)
            }
            Button("与激活版本差异 (\(versionDiff.count))") { showDiffPopover = true }
                .btnSecondary()
                .controlSize(.small)
                .popover(isPresented: $showDiffPopover, arrowEdge: .bottom) { diffPopover }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var diffPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("与激活版本差异（\(versionDiff.count)）")
                .font(.caption.bold())
                .padding(10)
            Divider()
            if versionDiff.isEmpty {
                Text("与激活版本一致")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        // id 用点路径键（唯一；`\.self` 会序列化 entry 的 Any 值）
                        ForEach(versionDiff, id: \.key) { e in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.label).font(.caption)
                                HStack(spacing: 4) {
                                    Text(e.oldText)
                                        .font(AppFont.numeric(AppFont.detailSmall)).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Image(systemName: "arrow.right")
                                        .font(AppFont.micro).foregroundStyle(.tertiary)
                                    Text(e.newText)
                                        .font(AppFont.numeric(AppFont.detailSmall))
                                        .lineLimit(1)
                                }
                                Text(e.key)
                                    .font(AppFont.monoSmall).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .frame(width: 360, height: 320)
            }
        }
    }

    // MARK: 表单（搜索 + 当前域内容）

    private var trimmedQuery: String {
        editor.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索本域参数（中文名 / 键名，如 量比、volume_ratio）", text: $editor.query)
                .textFieldStyle(.plain)
            if !trimmedQuery.isEmpty {
                Text("\(matchCount) 项").font(.caption).foregroundStyle(.secondary)
                Button { editor.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var form: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    domainContent
                }
                .padding(14)
            }
        }
    }

    /// 当前域的分组（schema 组 → 域映射见 `ParamDomain`），再按搜索词过滤
    private var domainGroups: [JSONValue] {
        let q = trimmedQuery
        let inDomain = groups.filter { ParamDomain.domain(forGroupKey: $0.paramGroupKey) == domain }
        guard !q.isEmpty else { return inDomain }
        return inDomain.compactMap { g -> JSONValue? in
            let titleHit = (g["title"].string ?? "").lowercased().contains(q)
                || (g["group"].string ?? "").lowercased().contains(q)
            let items = g["items"].array
            let hit = titleHit ? items : items.filter { it in
                (it["label"].string ?? "").lowercased().contains(q)
                    || (it["key"].string ?? "").lowercased().contains(q)
            }
            if hit.isEmpty { return nil }
            var dict = g.dictAny
            dict["items"] = hit.map { $0.raw }
            return JSONValue(dict)
        }
    }

    private var matchCount: Int {
        domainGroups.reduce(0) { $0 + $1["items"].array.count }
    }

    /// 取分组内 tunable 状态匹配的子集（空则 nil）
    private func subset(_ g: JSONValue, tunable: Bool) -> JSONValue? {
        let items = g["items"].array.filter { ($0["tunable"].bool == true) == tunable }
        guard !items.isEmpty else { return nil }
        var dict = g.dictAny
        dict["items"] = items.map { $0.raw }
        return JSONValue(dict)
    }

    /// 域内容：重点（tunable）置顶，其余「更多」折叠；
    /// 域内**没有** tunable 项时不折叠（否则整域被藏进「更多」，比旧版更看不见）。
    @ViewBuilder
    private var domainContent: some View {
        let focus = domainGroups.compactMap { subset($0, tunable: true) }
        let rest = domainGroups.compactMap { subset($0, tunable: false) }
        let restCount = rest.reduce(0) { $0 + $1["items"].array.count }
        if focus.isEmpty && rest.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.title3).foregroundStyle(.secondary)
                Text("本域没有匹配「\(trimmedQuery)」的参数")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else {
            if !focus.isEmpty {
                Text("重点（可调优）")
                    .font(.caption.bold())
                    .foregroundStyle(Sem.tailEnhance)
                ForEach(focus, id: \.paramGroupKey) { section($0) }
            }
            if focus.isEmpty {
                ForEach(rest, id: \.paramGroupKey) { section($0) }
            } else if !rest.isEmpty {
                DisclosureGroup(isExpanded: $moreExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(rest, id: \.paramGroupKey) { section($0) }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("更多（\(restCount)）")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Tok.sunken, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func section(_ g: JSONValue) -> some View {
        ParamGroupSection(group: g, values: editor.values, bools: editor.bools,
                          itemMeta: editor.itemMeta, binding: binding, boolBinding: boolBinding,
                          jsonBinding: jsonBinding, nullBinding: nullBinding,
                          requiredSubKeys: { ParamSchema.shared.requiredSubKeys($0) })
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 12) {
            TextField("新版本名称（如 param-1014）", text: $editor.versionName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 230)
            Toggle("保存后激活", isOn: $editor.activateAfterSave)
                .font(.caption)
                .toggleStyle(.checkbox)
            Spacer()
            Text(editor.saveHint)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("放弃修改") { editor.localReload += 1 }
                .btnSecondary()
                .disabled(editor.diffCount == 0 && editor.invalidKeys.isEmpty)
            Button { save() } label: {
                // 文案跟着"会不会切实盘口径"变（审查 B6）：勾上激活时按钮必须说清"并激活"
                Label(editor.activateAfterSave ? "保存并激活" : "保存为新版本", systemImage: "checkmark")
            }
            .keyboardShortcut(.defaultAction)
            .btnPrimary()
            .disabled(!editor.canSave)
            .confirmationDialog(
                "保存后会立即用这套参数跑后续扫描？",
                isPresented: $editor.pendingActivateSave,
                titleVisibility: .visible) {
                Button("保存并激活", role: .destructive) { performSave() }
                Button("只保存不激活") { editor.activateAfterSave = false; performSave() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("激活版本会改变档位门槛、阈值表与纪律窗口等打分口径；"
                     + "已落库的历史样本仍按其当时的版本解释，不会重算。")
            }
        }
        .padding(12)
    }

    private func save() {
        // 勾了"保存后激活" ⇒ 先确认（这一步改的是实盘口径，不是草稿）
        if editor.activateAfterSave {
            editor.pendingActivateSave = true
            return
        }
        performSave()
    }

    private func performSave() {
        let ok = editor.performSave { name, diff, activate in
            store.saveGlobalParams(name: name, diff: diff, activate: activate)
        }
        if ok { onSaved() }
    }

    // MARK: 绑定

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { self.editor.values[key] ?? "" }, set: { self.editor.setValue($0, forKey: key) })
    }

    private func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { self.editor.bools[key] ?? false }, set: { self.editor.setBool($0, forKey: key) })
    }

    /// 结构化 JSON 值的绑定（`ParamTableSpecs` 覆盖的参数用）
    private func jsonBinding(_ key: String) -> Binding<[String: Any]> {
        Binding(get: { self.editor.jsonValues[key] as? [String: Any] ?? [:] },
                set: { self.editor.setJSONValue($0, forKey: key) })
    }

    /// 「停用本项」开关的绑定（保存为显式 `null`）
    private func nullBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { self.editor.jsonNulls.contains(key) },
                set: { self.editor.setJSONNull($0, forKey: key) })
    }
}

// MARK: - 分组小节

private struct ParamGroupSection: View {
    let group: JSONValue
    let values: [String: String]
    let bools: [String: Bool]
    let itemMeta: [String: (type: String, step: Double)]
    let binding: (String) -> Binding<String>
    let boolBinding: (String) -> Binding<Bool>
    let jsonBinding: (String) -> Binding<[String: Any]>
    let nullBinding: (String) -> Binding<Bool>
    let requiredSubKeys: (String) -> [String]

    /// 标签列统一宽度：定宽后同域内所有控件左缘对齐（`maxWidth: .infinity` 会让控件起点参差）
    private static let labelWidth: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group["title"].string ?? group["group"].string ?? "")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            ForEach(group["items"].array, id: \.paramItemKey) { it in
                itemRow(it)
            }
        }
        .padding(10)
        .background(Tok.sunken, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func itemRow(_ it: JSONValue) -> some View {
        let key = it["key"].string ?? ""
        let type = it["type"].string ?? "str"
        if type == "json" {
            // 结构化编辑器（阈值表 / 命名字段 / 表格）横向占宽 → 上下排：标签行在上，控件占满剩余宽度
            VStack(alignment: .leading, spacing: 6) {
                labelRow(it, key: key)
                control(it, type: type)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 5)
        } else {
            HStack(alignment: .center, spacing: 8) {
                labelCell(it, key: key)
                Spacer(minLength: 8)
                control(it, type: type)
            }
            .padding(.vertical, 3)
        }
    }

    /// json 行的顶部标签行（标签 + 可调优胶囊，占满宽度）
    private func labelRow(_ it: JSONValue, key: String) -> some View {
        HStack(spacing: 8) {
            labelCell(it, key: key)
            Spacer()
        }
    }

    private func labelCell(_ it: JSONValue, key: String) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(it["label"].string ?? key).font(.callout)
                if let note = it["note"].string, !note.isEmpty {
                    Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if it["tunable"].bool == true {
                Text("可调优")
                    .font(.caption2.bold())
                    .foregroundStyle(Sem.tailEnhance)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Tok.tint(Sem.tailEnhance), in: Capsule())
            }
        }
        .frame(width: Self.labelWidth, alignment: .leading)
    }

    @ViewBuilder
    private func control(_ it: JSONValue, type: String) -> some View {
        let key = it["key"].string ?? ""
        switch type {
        case "int", "float":
            HStack(spacing: 4) {
                TextField("", text: binding(key))
                    .textFieldStyle(.roundedBorder).frame(width: 88)
                    .font(AppFont.numeric(.callout))
                    .multilineTextAlignment(.trailing)
                Button { step(key, dir: -1) } label: { Image(systemName: "chevron.down").font(.caption2) }
                    .buttonStyle(.borderless)
                Button { step(key, dir: 1) } label: { Image(systemName: "chevron.up").font(.caption2) }
                    .buttonStyle(.borderless)
            }
        case "bool":
            Toggle("", isOn: boolBinding(key)).labelsHidden()
        case "num_pair":
            HStack(spacing: 4) {
                TextField("下限", text: binding(key + "#0"))
                    .textFieldStyle(.roundedBorder).frame(width: 74)
                    .font(AppFont.numeric(.callout))
                    .multilineTextAlignment(.trailing)
                Text("~").font(.caption).foregroundStyle(.secondary)
                TextField("上限", text: binding(key + "#1"))
                    .textFieldStyle(.roundedBorder).frame(width: 74)
                    .font(AppFont.numeric(.callout))
                    .multilineTextAlignment(.trailing)
            }
        case "json":
            // 配了结构化 specs 的走对应控件；没配的仍走裸 JSON 文本框。
            //
            // ⚠ 内层 switch **故意穷尽**（不带 `default:`）：将来给 `Shape` 加一种形状时，
            //   这里会**编译报错**而不是静默退回文本框。外层的 else 只覆盖
            //   "schema 里有、但 specs 没配"的 json 参数 —— 那种情况由
            //   `ParamTableSpecsTests.testSpecsCoverEveryJSONParamExactly` 报红。
            if let shape = ParamTableSpecs.shape(key) {
                switch shape {
                case .thresholdTable(let unit, let sign):
                    ParamThresholdTableEditor(unit: unit, sign: sign,
                                              lockedKeys: Set(requiredSubKeys(key)),
                                              value: jsonBinding(key))
                case .namedFields(let fields):
                    ParamNamedFieldsEditor(fields: fields,
                                           canDisable: it["optional"].bool == true,
                                           value: jsonBinding(key),
                                           disabled: nullBinding(key))
                case .table(let rows, let columns):
                    ParamTableEditor(rows: rows, columns: columns, value: jsonBinding(key))
                }
            } else {
                TextEditor(text: binding(key))
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 84)
                    .frame(maxWidth: 360)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            }
        default: // str / num_list / str_list
            TextField("", text: binding(key))
                .textFieldStyle(.roundedBorder).frame(width: 200)
                .font(AppFont.numeric(.callout))
                .multilineTextAlignment(.trailing)
        }
    }

    private func step(_ key: String, dir: Int) {
        guard let meta = itemMeta[key],
              let next = ParamEditorState.steppedValue(
                current: binding(key).wrappedValue,
                type: meta.type,
                step: meta.step,
                dir: dir)
        else { return }
        binding(key).wrappedValue = next
    }
}
