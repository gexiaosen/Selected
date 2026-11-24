import SwiftUI
import UserNotifications
import SelectedCore

// MARK: - 自选提醒

/// 「提醒」卡片：全局开关 + 通知授权状态 + 已配置规则一览。
///
/// ## 为什么要有这张卡
/// 提醒的**设置入口**在自选列表每只票后面的铃铛上（就近、与标的绑定，这是对的），
/// 但那样留了两个洞：
///   ① 想知道"我到底配了哪些提醒"要逐只票点过去 —— 自选几十只票时基本不可用；
///   ② 系统没允许通知时，`Notifier.send` 直接 return，提醒**静默不响**
///      —— 自选页的铃铛照样是"已设置"的样子，看不出任何异常。
/// 这张卡就是这两个洞的统一出口。
///
/// ## 与自选页铃铛的分工
/// · 铃铛 = **单只票**的编辑入口（弹 `AlertEditSheet`）
/// · 本卡 = **全局**视角（一览 / 总闸 / 通知授权）+ 从这里也能进单只票的编辑
extension SettingsView {

    var alertsCard: some View {
        Card("提醒", subtitle: "在自选列表点每只票名称后面的铃铛设置；这里看全部并统一控制") {
            VStack(alignment: .leading, spacing: 10) {
                notifyRow
                Divider()
                pauseRow
                Divider()
                skippedNoQuoteBanner
                HStack(spacing: 8) {
                    Text("已配置提醒").font(.callout.bold())
                    Text("\(store.alertRulesByCode.count) 只")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("刷新") { store.loadAlerts() }
                        .btnSecondary()
                        .controlSize(.small)
                }
                rulesListBody
            }
        }
        // 每次进设置页向系统查一次授权状态（用户可能刚在系统设置里改过）
        .task {
            // ⚠ **先把数据读进缓存再查授权**：`rulesList` 读的是 `store.alertRulesByCode` /
            //   `store.watchItems`（内存快照），而快照不一定已被自选页填过 —— 设置窗口是独立 scene，
            //   第一次只开设置不进自选 ⇒ 快照全空 ⇒ 一览显示"还没有配置任何提醒"。
            //   ⇒ 进这张卡就自己加载（`loadWatch` 内部含 `loadAlerts`，名称/规则/时间窗一次读齐）。
            store.loadWatch()
            await refreshNotifyStatus()
        }
    }

    // MARK: 通知授权

    private var notifyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: notifyStatus == true ? "bell.badge.fill" : "bell.slash")
                .foregroundStyle(notifyStatus == true ? AnyShapeStyle(Sem.warn)
                                                      : AnyShapeStyle(Tok.dim))
            VStack(alignment: .leading, spacing: 2) {
                Text("系统通知").font(.callout.bold())
                // ⚠ 这里是 `String` → `Text` 走 verbatim 重载，**不解析 Markdown**
                //   （星号会原样显示）。要粗体得用字符串字面量 —— 见 SettingsReplaySection 的同类说明。
                Text(notifyHint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(notifyLabel)
                .font(.caption.bold())
                .foregroundStyle(notifyStatus == true ? AnyShapeStyle(Sem.down)
                                                      : AnyShapeStyle(Sem.up))
            Button("重新检测") { Task { await refreshNotifyStatus() } }
                .btnSecondary()
            // ⚠ 测试通知：授权状态只说明"系统允许了"，**不代表这条链路真的正常** ——
            //   实测反例：bundle 签名因 xattr 失效时，通知照弹、只是**左侧应用图标变成占位方块**
            //   （见 `build_app.sh` 安装段的长注释）。
            //   这类问题**只有真弹一条、真看一眼才知道**，所以给一个一键自检的入口。
            Button("发一条测试") {
                Notifier.shared.send(
                    title: "通知自检",
                    body: "能看到这条、且左侧显示应用图标，说明通知链路正常。",
                    identifier: "selected.notify.selfcheck")
            }
            .btnSecondary()
            .disabled(notifyStatus != true)
            .help(notifyStatus == true
                  ? "立即发一条系统通知，确认能弹出来（含左侧应用图标）"
                  : "系统未允许通知 → 先在「系统设置 → 通知」里打开，再点「重新检测」")
        }
    }

    private var notifyLabel: String {
        switch notifyStatus {
        case .some(true):  return "已开启"
        case .some(false): return "未开启"
        case .none:        return "检测中…"
        }
    }

    private var notifyHint: String {
        switch notifyStatus {
        case .some(true):
            return "提醒会以系统通知弹出；App 不在前台也会弹（先落库再投递，所以不会重复）"
        case .some(false):
            var hint = "系统里没有允许通知 → 提醒会静默不响（不报错、铃铛照样显示已设置）。"
                     + "去「系统设置 → 通知 → Selected」打开后点「重新检测」"
            // ⚠ 把"已经丢了几条"说出来：否则用户只看到"没响"，
            //   无从判断是"没触发"还是"触发了但被拦下"—— 这两件事的处置完全不同。
            if notifySuppressedCount > 0 {
                // ⚠ 这里**不能用 `**`**：整句是 `+` 拼接出来的 `String` → `Text` 走 verbatim 重载、
                //   不解析 Markdown（星号会原样显示给用户）。要强调用「」。
                hint += "。⚠ 本次运行已有「\(notifySuppressedCount) 条」提醒因此未能送达"
            }
            return hint
        case .none:
            return "正在向系统查询授权状态…"
        }
    }

    /// 向系统查**当前**授权状态。
    ///
    /// ⚠ 不读 `Notifier.isAuthorized`：那个只记下**启动时那次请求**的结果，
    ///   用户中途去系统设置里关掉通知，它仍然是 `true` → 卡片显示"已开启"而提醒其实不响。
    ///   `notificationSettings()` 每次都问系统，这才是唯一的事实来源。
    /// ⚠ `.notDetermined` 归到"未开启"：App 启动时已经请求过授权
    ///   （`SelectedApp.applicationDidFinishLaunching` → `Notifier.requestAuth()`），
    ///   走到这里还是 notDetermined 说明用户没理会那个弹窗 —— 那就等于没开。
    private func refreshNotifyStatus() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        switch s.authorizationStatus {
        case .authorized, .provisional, .ephemeral: notifyStatus = true
        default: notifyStatus = false
        }
        // ⚠ 一并取"因未开启而未能送达的条数"：这些通知不能**静默消失**，
        //   否则用户看到"提醒没响"却查不到任何原因。
        notifySuppressedCount = Notifier.shared.suppressedCount
        // ⚠ 一并取「因缺行情未判定」的条数
        notifySkippedNoQuote = Notifier.shared.skippedNoQuote
    }

    // MARK: 总闸

    private var pauseRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: $alertsPaused) {
                Text("暂停全部提醒").font(.callout.bold())
            }
            .toggleStyle(.switch)
            Text(alertsPaused
                 ? "已暂停：所有提醒都不弹（自选页的价格列照常刷新）。"
                   + "暂停期间不写触发状态 → 恢复后当天仍会提醒"
                 : "总闸 —— 打开后所有提醒都不弹（自选页的价格列照常刷新）；"
                   + "引擎的止盈/止损价位仅作参考，不会自动提醒")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 提醒一览

    /// 「因缺行情未判定」的横幅。
    ///
    /// ⚠ 为什么**独立于授权状态**那一段（`notifyStatusHint`）：
    ///   那一段只在「系统没给通知权限」时出现，而这一个是**网络/数据源**问题 ——
    ///   两者同时发生时只显示授权提示，用户会以为"开了通知就好了"，而真正的原因是断网。
    ///   ⇒ 分开显示，各自指向自己的处置。
    @ViewBuilder
    private var skippedNoQuoteBanner: some View {
        if notifySkippedNoQuote > 0 {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(Sem.warn)
                VStack(alignment: .leading, spacing: 2) {
                    Text("最近一轮有「\(notifySkippedNoQuote) 只」已配提醒的票没拿到行情，未做判定")
                        .font(.caption)
                    Text("这不影响自选页的价格显示（会保留上一轮的），但这些票这一轮的提醒不会弹。"
                         + "若是持续出现，去「数据源诊断」看是哪个源在失败。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            // ⚠ 底色走 Tok 的语义色出口（`theme_tint` 护栏盯着"彩底不许裸透明度"）
            .background(Tok.tint(Sem.warn, .block), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// 已配置的规则（按 code 升序）。
    ///
    /// ⚠ `id: \.code` 用**稳定标量键**。用 `\.element` 会走 `JSONValue` 的整份哈希
    ///   —— 那正是设置页卡顿的成因（`foreach_id_payload` 护栏盯着这条）。
    /// ⚠ 名称/时间窗都从 `store` 的**内存快照**取，不在 `body` 里查库：
    ///   逐行 `AlertStore.window(code:)` 就是主线程同步 I/O（每行一次 SQLite 查询）。
    @ViewBuilder
    private var rulesListBody: some View {
        let rules = store.alertRulesByCode
        let codes = rules.keys.sorted()
        // ⚠ 必须写成**表达式**：`@ViewBuilder` 里不许出现 `for` 循环语句。
        let names = Dictionary(store.watchItems.map { ($0.code, $0.displayName) },
                               uniquingKeysWith: { a, _ in a })

        if codes.isEmpty {
            Text("还没有配置任何提醒 —— 去自选列表，点每只票名称后面的铃铛")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(codes, id: \.self) { code in
                    alertRow(code: code,
                             name: names[code] ?? "",
                             rules: rules[code] ?? [],
                             window: store.alertWindowsByCode[code] ?? .anytime)
                    if code != codes.last {
                        Divider().padding(.leading, 22)
                    }
                }
            }
        }
    }

    private func alertRow(code: String, name: String,
                          rules: [AlertRule], window: AlertWindow) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bell.fill")
                .foregroundStyle(Sem.warn)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name.isEmpty ? code : "\(code) \(name)").bold()
                    Text(window.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(rulesSummary(rules))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("编辑") { alertEdit = AlertEditTarget(code: code, name: name) }
                .btnSecondary()
        }
        .font(.callout)
    }

    /// 规则 → 一行摘要。
    ///
    /// 按 `AlertKind.allCases` 的**固定顺序**拼（不是按库里读出来的顺序）——
    /// 库里的顺序是 `ORDER BY kind` 的文本序，与界面上的行序（截图那四行）不一致，
    /// 直接用它会让摘要看起来是乱序的。
    private func rulesSummary(_ rules: [AlertRule]) -> String {
        var parts: [String] = []
        for kind in AlertKind.allCases {
            let ts = rules.filter { $0.kind == kind }
            guard !ts.isEmpty else { continue }
            // 单位后缀由**族别**给（价格无后缀 / 涨跌额「 元」/ 百分比「%」）。
            // ⚠ 价格类与百分比类的输出有单测钉住 —— 不能写成"给所有类型都加后缀"，
            //   那会静默改掉价格类的显示。
            let values = ts.map { String(format: "%.2f", $0.threshold) + kind.unitSuffix }
            // 同一种 kind 的重复方式在弹窗里是**一个**下拉 → 同一 kind 内必然一致
            let suffix = ts.first?.repeatMode == .once ? "（单次）" : ""
            parts.append("\(kind.title) \(values.joined(separator: ","))\(suffix)")
        }
        return parts.joined(separator: " · ")
    }
}
