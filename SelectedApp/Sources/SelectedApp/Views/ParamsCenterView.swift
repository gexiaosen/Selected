import SwiftUI
import SelectedCore

// MARK: - 参数中心（侧栏独立页）
//
// A 域选股参数的唯一入口（单一入口纪律：两处入口必然漂移）。
//
// ## 版面
// ```
// 版本卡：参数版本列表（激活 / 编辑此版本 / 删除）
// 编辑区：左域导航（`ParamDomain` 5 个 schema 域 + 参数调优）＋ 右单域编辑器
//         （`ParamEditor`：重点置顶 + 更多折叠 + 未保存条 + 与激活版本差异；
//           调优域右栏是 `TunePanelView`——保存的新版本当场就在上方版本卡里）
// ```
//
// ## 域模型
// 这里只管 A 选股参数（进打分/过滤链的）；B 指标筛选参数（screen 阈值 /
// 指标周期 / 超买超卖线）不进打分、不进选股版本列表，在「指标筛选」页齿轮里调
// （`IndicatorSettingsSheet`）。
//
// ⚠ 间距按设置页规范：页面级卡片间 14、页内边距 16、卡内首层 10。

struct ParamsCenterView: View {
    private let store = Store.shared

    /// 当前域（左导航驱动；默认打分规则 —— tunable 最密集、最常调）
    @State private var domain: ParamDomain = .scoring
    /// 编辑目标：指定版本（nil = 当前激活版本）
    @State private var editVersion: String?
    /// 外部写完成信号（激活/删除版本）→ 编辑器重建基线
    @State private var reloadToken = 0
    /// 待确认删除的参数版本名（空 = 无待确认）
    @State private var confirmDeleteVersion = ""
    /// 待确认**激活**的参数版本名（空 = 无待确认）
    @State private var confirmActivateVersion = ""

    /// 正在编辑描述的版本名（nil = 无 popover 打开）
    @State private var noteEditName: String?
    /// 描述编辑草稿（popover 里的 TextField 绑定）
    @State private var noteDraft = ""
    /// 待确认「恢复出厂设置」
    @State private var confirmRestoreFactory = false
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 与其余页同一套页栏：更新时间 + 主操作（参数与日期无关，故不挂 DateChip）。
            // ⚠ 页栏同时承载库级错误横幅（`PageActionBar` 内部读 `Store.bannerError`），
            //   原先只有出错时才出现一条空页栏，正常态页面直接顶到红绿灯下，与九页不一致。
            PageActionBar {
                // 刷新是辅助动作：本页的主操作在编辑器底部（保存为新版本）。
                ActionBarButton(title: "刷新", secondary: true, isBusy: store.busy.contains("param"),
                                helpText: "重新读取参数版本与当前参数") {
                    store.refreshParams()
                }
            }
            VStack(spacing: 14) {
                versionCard
                editorCard.frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { store.refreshParams() }
    }

    // MARK: 版本卡

    private var versionCard: some View {
        Card("参数版本", subtitle: "激活版本用于选股与调优；修改另存为新版本，可随时回退") {
            VStack(alignment: .leading, spacing: 6) {
                if store.paramVersions.isEmpty {
                    Text("无参数版本").font(.callout).foregroundStyle(.secondary)
                } else {
                    // ⚠ id 用版本名：`\.self` 会序列化整个参数版本字典做身份判定
                    ForEach(store.paramVersions, id: \.name) { v in
                        versionRow(v)
                    }
                }
                // 恢复出厂：版本列表为空时也要显示（删光了出厂版本正是最需要恢复的时候）
                Divider()
                HStack(spacing: 8) {
                    Text("版本落库后即为你的数据，启动不再覆盖；点描述文字可改说明")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("恢复出厂设置") { confirmRestoreFactory = true }
                        // 覆盖出厂版本 + 还原描述都不可撤销，按破坏性角色显示（红字描边），
                        // 不再与普通次操作同色；二次确认仍由 confirmationDialog 承担。
                        .btnDanger()
                        .disabled(store.busy.contains("param"))
                        .help("用随包默认文件覆盖一次出厂版本（自定义版本不受影响）")
                        .confirmationDialog(
                            "恢复出厂设置",
                            isPresented: $confirmRestoreFactory,
                            titleVisibility: .visible) {
                            Button("恢复", role: .destructive) { store.restoreFactoryParams() }
                            Button("取消", role: .cancel) { }
                        } message: {
                            // ⚠ 单一字面量（无 `+` 拼接）→ 走 LocalizedStringKey，`**` 正常解析
                            Text("出厂版本将被**随包默认覆盖一次**，你改过的描述也会还原；自定义版本不受影响。")
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func versionRow(_ v: ParamVersionRow) -> some View {
        let isActive = v.isActive
        // 可删性只跟随引擎裁决（`ParamStore.listVersions()` 的 `deletable`）。
        // ⚠ 不在这里重新推导规则：引擎改了规则，界面这份推导就会与引擎打架
        //   （「规则改了、界面仍显示不可删」）。
        let deletable = v.deletable
        let vName = v.name
        HStack(alignment: .center, spacing: 8) {
            // 描述钉一行（尾部截断）：长 note 换行会把行高撑到三倍、
            // 短 note 又让文字与行尾图标之间空一大段 —— 单行 + 占满中段后行高恒齐。
            // 点击描述打开 popover 编辑（出厂/用户版本一视同仁：落库后都是用户数据）。
            VStack(alignment: .leading, spacing: 2) {
                Text(vName).bold()
                Button {
                    noteDraft = v.note
                    noteEditName = vName
                } label: {
                    Text(v.noteDash)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .help("点击编辑描述")
                .popover(isPresented: Binding(
                    get: { noteEditName == vName },
                    set: { if !$0 { noteEditName = nil } }),
                         arrowEdge: .trailing) {
                    noteEditor(name: vName)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 状态与动作融合成行尾一个图标：实心绿 = 已激活（只读），
            // 空心灰 = 点击激活（与编辑/删除同为 btnIcon，行尾三枚同尺寸对齐）。
            // ⚠ 激活行**不挂 `.disabled`** —— borderless 禁用会把绿对勾一起洗灰，
            //   状态反而看不见；误触由 action 里的 `!isActive` 守卫挡下。
            Button {
                // ⚠ 激活必须确认（2026-10-16 审查 B6）：这一枚图标按下去改的是
                //   **下一轮的打分口径**（档位门槛、阈值表、纪律窗口…），
                //   后果与"删版本"同量级、却比删除更难发现 ——
                //   激活前后界面只差一个实心/空心绿圈，误点一次就按另一套参数出票，
                //   事后无从追溯"今天为什么是这批"。旁边的删除**有**确认，激活没有，
                //   这条不对称本身就是缺陷。
                if !isActive { confirmActivateVersion = vName }
            } label: {
                Image(systemName: isActive ? "checkmark.circle.fill" : "checkmark.circle")
                    .foregroundStyle(isActive ? AnyShapeStyle(Sem.down) : AnyShapeStyle(Tok.dim))
            }
            .btnIcon()
            .disabled(!isActive && store.busy.contains("param"))
            .help(isActive ? "当前激活版本" : "激活此版本（会改变后续扫描的打分口径）")
            .alert(
                "是否确认激活「\(confirmActivateVersion)」参数？",
                isPresented: Binding(
                    get: { !confirmActivateVersion.isEmpty },
                    set: { if !$0 { confirmActivateVersion = "" } })) {
                Button("激活", role: .destructive) {
                    store.activateParam(confirmActivateVersion)
                    confirmActivateVersion = ""
                    reloadToken += 1
                }
                Button("取消", role: .cancel) { confirmActivateVersion = "" }
            } message: {
                Text(activateWarningText(confirmActivateVersion))
            }

            Button {
                // 编辑此版本 = 切编辑器目标（激活版本走 nil 基线，语义相同）
                editVersion = isActive ? nil : vName
                if domain == .tune { domain = .scoring }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .btnIcon()
            .help("编辑此版本参数")

            Button {
                // ⚠ 必须确认：删版本不可恢复
                confirmDeleteVersion = vName
            } label: {
                Image(systemName: "trash")
            }
            // 删除 = 破坏性 → 红色图标按钮；不可删时靠 `.disabled` 变灰
            .btnIcon(Sem.up)
            .disabled(!deletable)
            .alert(
                // 文案排版：问句当标题、后果当正文（标题一句话问完、正文只说后果）。
                "是否确认删除「\(confirmDeleteVersion)」参数？",
                isPresented: Binding(
                    get: { !confirmDeleteVersion.isEmpty },
                    set: { if !$0 { confirmDeleteVersion = "" } })) {
                Button("删除", role: .destructive) {
                    store.deleteParam(confirmDeleteVersion)
                    confirmDeleteVersion = ""
                    reloadToken += 1
                }
                Button("取消", role: .cancel) { confirmDeleteVersion = "" }
            } message: {
                // ⚠ 这一句是**单一字面量**（无 `+` 拼接）→ 走 `LocalizedStringKey`，`**` 会被正常解析
                Text("删除后**不可恢复**。")
            }
            .help(deletable ? "删除版本"
                            : (isActive ? "当前激活版本不可删（先切到其他版本）" : "经典默认版本不可删"))
        }
        .font(.callout)
        .padding(.vertical, 2)
    }

    /// 描述编辑 popover 内容（独立函数：塞进 versionRow 的三元/修饰符链会让编译器超时）
    ///
    /// ⚠ 多行 + 420pt 宽：描述常有七八十字（单行 260pt 装不下半句就被截断），
    ///   `axis: .vertical` + `lineLimit(2...6)` 让全文一眼可见可编辑。
    /// ⚠ 不挂 `.onSubmit`：保存已由 `.defaultAction`（回车）承担，两条都挂会写两次。
    private func noteEditor(name: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("编辑「\(name)」描述").font(.callout).bold()
            TextField("这一版是干什么的…", text: $noteDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($noteFocused)
                .lineLimit(2...6)
                .onAppear { noteFocused = true }
            HStack {
                Spacer()
                Button("取消") { noteEditName = nil }
                    .btnSecondary()
                    .keyboardShortcut(.cancelAction)
                Button("保存") { saveNote(name) }
                    .btnPrimary()
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.busy.contains("param"))
            }
        }
        .padding(12)
        .frame(width: 420)
    }

    private func saveNote(_ name: String) {
        if store.setParamNote(name: name, note: noteDraft) {
            noteEditName = nil
        }
    }

    // MARK: 编辑区（左域导航 + 右单域）

    private var editorCard: some View {
        Card {
            HStack(spacing: 0) {
                domainNav.frame(width: 150)
                Divider()
                Group {
                    if domain == .tune {
                        TunePanelView()
                    } else {
                        ParamEditor(editVersion: editVersion, domain: domain,
                                    reloadToken: reloadToken,
                                    onSaved: {
                                        // 保存成功后回到"编辑激活版本"态（失败时不触发回调，保留当前编辑目标与草稿）
                                        editVersion = nil
                                    },
                                    onExitTarget: { editVersion = nil })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// 域导航（`ParamDomain` 单一来源；图标在此映射，Core 不放 UI 资产）
    private var domainNav: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ParamDomain.allCases) { d in
                domainRow(d)
            }
            Spacer()
        }
        .padding(8)
    }

    /// 单行拆成独立函数：整段塞在 `ForEach` 闭包里会让编译器超时
    /// （"unable to type-check this expression in reasonable time"，三元套 `AnyShapeStyle` 是元凶）
    private func domainRow(_ d: ParamDomain) -> some View {
        let selected = domain == d
        return Button {
            domain = d
        } label: {
            HStack(spacing: 8) {
                Image(systemName: navIcon(d)).frame(width: 16)
                Text(d.title).font(.callout)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Sem.info : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? AnyShapeStyle(Tok.chip) : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func navIcon(_ d: ParamDomain) -> String {
        switch d {
        case .scoring: return "number"
        case .filter: return "line.3.horizontal.decrease.circle"
        case .tierBudget: return "scalemass"
        case .predict: return "sunrise"
        case .iterate: return "arrow.triangle.2.circlepath"
        case .tune: return "wand.and.stars"
        }
    }

    /// 激活确认框的正文：与当前激活版本的**实际差异**（2026-10-16 审查 B6）。
    ///
    /// ⚠ 为什么要它：激活一枚图标按下去改的是后续扫描与预判的打分口径，
    ///   而原界面唯一的提示是"绿圈从空心变实心"—— 误点后既看不到改了什么，
    ///   事后也无从解释"今天为什么是这批票"。这里把差异提前摊开，
    ///   让"确认"这件事真的有信息可确认（而不是又一个点了就过的弹窗）。
    ///   差异数据复用现成的 `ParamVersionDiff`（编辑器里那份），不另起一套口径。
    private func activateWarningText(_ target: String) -> String {
        guard !target.isEmpty else { return "" }
        let activeName = ParamStore.shared.activeName()
        let cur = ParamStore.shared.activeParams() ?? [:]
        let next = ParamStore.shared.versionParams(target) ?? [:]
        let entries = ParamVersionDiff.diff(old: cur, new: next)
        var lines: [String] = ["激活会立即改变后续扫描与预判的打分口径。"]
        if target == activeName {
            lines.append("目标就是当前激活版本「\(activeName)」，实际不会改变任何参数。")
        } else if entries.isEmpty {
            lines.append("与当前激活版本「\(activeName)」相比：参数值无差异。")
        } else {
            let head = entries.prefix(3)
                .map { "\($0.label) \($0.oldText) → \($0.newText)" }
                .joined(separator: "；")
            lines.append("与当前激活版本「\(activeName)」相比有 \(entries.count) 项差异：\(head)")
            if entries.count > 3 {
                lines.append("（其余 \(entries.count - 3) 项请到参数编辑器查看）")
            }
        }
        lines.append("已落库的历史样本仍按其当时的参数版本解释，不会重算。")

        return lines.joined(separator: "\n")
    }
}

