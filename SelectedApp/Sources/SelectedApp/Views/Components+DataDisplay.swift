import SwiftUI
import SelectedCore
import ThinkingOrbs

// MARK: - 空态（原生 ContentUnavailableView）

struct EmptyStateView: View {
    let icon: String
    let title: String
    var hint: String?
    /// 压缩占位高度（字号不变，只减空白）：同页多空态时避免整页超出需要滚动
    var compact: Bool = false
    /// 空态里的动作（可选）：让用户不必回到页栏找按钮
    var actionTitle: String?
    var actionDisabled: Bool = false
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            if let hint {
                Text(hint)
            }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    // 空态动作是次操作：页栏才是本页唯一主操作
                    .btnSecondary()
                    .disabled(actionDisabled)
            }
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 90 : 180)
    }
}

// MARK: - 零轴 delta 条（共用）

/// 0 轴居中的有符号涨跌条（审查 #16：compare 逐轮行情标尺 / tune 候选综合分 delta
/// 两处手搓的色、高、量程各异，收敛成这一个组件）。
/// 中间是 0 轴基线，正值向右、负值向左；长度按 `fullScale`（半宽对应的量级）比例收缩、
/// 超限截断。两侧颜色由调用方给 —— 行情标尺是"红涨绿跌"、分数 delta 是"绿=提升/灰=持平"，
/// 语义不同，组件不写死。
struct ZeroAxisDeltaBar: View {
    let value: Double
    /// "条打满半宽"对应的量级（超出按比例截断）
    let fullScale: Double
    var height: CGFloat = 12
    var barHeight: CGFloat = 5
    var positiveColor: Color
    var negativeColor: Color
    var baselineColor: Color = Tok.skeleton
    /// 最小可见长度（非零 delta 再小也留一截；`value == 0` 不画条）
    var minBarLength: CGFloat = 2
    /// 端头留白（打满时条尖与基线端点之间的气口）
    var endInset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let usable = max(half - endInset, 1)
            let ratio = abs(value) / max(fullScale, 0.0001)
            let len = ratio > 0 ? max(min(ratio, 1) * usable, minBarLength) : 0
            ZStack {
                Rectangle().fill(baselineColor).frame(width: 1, height: height)
                if len > 0 {
                    Capsule()
                        .fill(value >= 0 ? positiveColor : negativeColor)
                        .frame(width: CGFloat(len), height: barHeight)
                        .offset(x: value >= 0 ? len / 2 : -len / 2)
                }
            }
            .frame(width: geo.size.width, height: height)
        }
        .frame(height: height)
    }
}

/// 行内错误/预警横幅（原生拼装：系统 Symbol + 语义色 + 圆角表面）
/// 「图标 + 主文 + 可选补充说明」两段式，排版走系统字号层级；表面色走 Tok.tint（theme_source 护栏）。
struct ErrorView: View {
    let message: String
    var hint: String? = nil
    /// 下一步动作（可选）——与 `EmptyStateView` 的 action 同构。
    /// 有动作可点却不给，等于把"怎么办"推回让用户自己找页栏按钮。
    var actionTitle: String? = nil
    var actionDisabled: Bool = false
    var action: (() -> Void)? = nil

    init(message: String, hint: String? = nil,
         actionTitle: String? = nil, actionDisabled: Bool = false,
         action: (() -> Void)? = nil) {
        self.message = message
        self.hint = hint
        self.actionTitle = actionTitle
        self.actionDisabled = actionDisabled
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Sem.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // 动作是次操作（页栏才是本页唯一主操作），与 `EmptyStateView` 同一档
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .btnSecondary()
                    .disabled(actionDisabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.tint(Sem.warn, .block), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// **上次运行失败**横幅：错误 + 下一步（重试）+ 口径说明（屏上仍是哪一批数据）。
///
/// ⚠ 与 `PageActionBar` 那条持久红条**不是一回事**，别合并：
///   那条只给库级故障（判据 `Store.bannerError` 内含 `ToastPolicy.allowsBanner` 白名单），
///   会跨日期、跨页面持续可见；这一条挂在**发起该动作的那一页**，归属由 `lastErrorKey`
///   决定，同一动作再跑成功时 `Store` 自己清空（`if lastErrorKey == key { lastError = nil }`）。
/// ⚠ 为什么必须有：toast 是瞬时事件（error 档"点别处即走"），而 `staleWhileBusy` 之后
///   页面**保留旧数据**——失败提示一消失，屏上就只剩一份看起来像新鲜的旧数字。
///   这一条补的就是那段静默期。
/// ⚠ `busy` 期间不显示：那时页栏的「第N轮扫描中 · mm:ss」徽章在场，两条并存互相打架。
struct RunFailureBanner: View {
    private let store = Store.shared
    /// `Store.busy` / `lastErrorKey` 的键（"round" / "compare" / "review" …）
    let key: String
    /// 口径说明：告诉用户此刻屏上显示的是什么（时间戳由本组件补，不在调用点各写一份）
    let staleNote: String
    var retryTitle: String = "重试"
    let retry: () -> Void

    /// 与页栏「更新 hh:mm:ss」同源的加载时刻（`Store.lastRefreshAt`），不另算一套口径。
    private static let stampFmt = ChinaTime.formatter("HH:mm:ss")
    private var stamp: String { store.lastRefreshAt.map { Self.stampFmt.string(from: $0) } ?? "--:--:--" }

    var body: some View {
        if let msg = store.lastError, store.lastErrorKey == key, !store.busy.contains(key) {
            ErrorView(message: msg, hint: "\(staleNote) · 数据加载于 \(stamp)",
                      actionTitle: retryTitle, action: retry)
        }
    }
}

// MARK: - 长任务等待指示（点阵动效）
//
// ⚠ 白名单：只用于「不确定型长任务」原来的转圈图标位。**不许**用于 ——
//   · 骨架屏位（那是"即将出现"，不是"在忙"，项目约定见 StockDetailSheet）
//   · 有百分比的确定性进度
//   · 静态的"待运行 / 等生成"空态
//   清单与理由见 docs/specs/README.md。
//
// 动效只承担"在忙"，**不承担状态语义**：语义色（Sem.info / Sem.warn）、文案、
// 耗时提示一律由调用方保留原样 —— 所以这里不做任何配色，上游墨点自己跟随明暗外观。
// ⚠ 本项目不做读屏无障碍：**别"顺手加回"** accessibilityHidden(true)。

/// 页面级等待：点阵动效 + 文案（居中，撑满可用高度）
struct LoadingView: View {
    var text: String = "加载中…"
    /// 动效语义：扫描/检索 → `.searching`；推演 → `.solving`；汇总 → `.composing`；网络拉取 → `.connecting`
    var design: OrbDesign = .working

    var body: some View {
        HStack(spacing: 10) {
            ThinkingOrb(design, size: .small)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 90)
    }
}

/// 内联等待指示（胶囊 / 列表行 / 工具条）：只有动效，不含文案
struct ThinkingDot: View {
    var design: OrbDesign
    /// 上游 `.small`（20pt 设计）按此尺寸绘制；与 caption 同行取 13，与 callout 同行取 15~16
    var diameter: CGFloat = 15

    var body: some View {
        ThinkingOrb(design, size: .small, diameter: diameter)
    }
}

// MARK: - KV 行

struct KVRow: View {
    let key: String
    let value: String
    var valueColor: Color = .primary
    /// 宽卡里把 key/value 拉得太开时，给整行一个上限（nil = 撑满可用宽）。
    /// 宽松的 HStack 里用不到；复盘/历史的整页卡用它收敛关联距离。
    var maxWidth: CGFloat? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(valueColor).monospacedDigit()
        }
        .font(.callout)
        .frame(maxWidth: maxWidth, alignment: .leading)
    }
}

// MARK: - 环境灯推导
//
// 判定规则（"连续下跌 → 红；sh_ok 非真 → 黄；否则绿"）已下沉到
// `SelectedCore.MarketEnv.lightLevel` —— 那里可以单测，也不必再持有 `JSONValue`。
// 这里只负责"档位 → 文案 + 配色"（配色属 UI 层，Core 不许 import SwiftUI）。

/// ⚠ 文案与颜色都走 `Sem` 的单一来源（`Sem.lightText` / `Sem.light`），不在此就地写。
func envLight(_ env: MarketEnv?) -> (String, Color) {
    guard let env else { return ("未知", .gray) }
    return (Sem.lightText(env.lightLevel), Sem.light(env.lightLevel))
}

// MARK: - 指标格（"值 + 标签"小格）

/// 「指标格」的统一形态：**mono semibold 值 + detailSmall 次级标签**。
///
/// ## ⚠ 参数是"各处形态差异的并集"，不是新设计
///
/// boxed / spacing / trailing 只是让不同调用点共用一份实现。
/// ⇒ 真要"统一观感"（例如把间距统一、把底统一加上）**是另一件事** ——
///   那属于设计改动，得单独评审 + 人工看明暗两档。
///
/// ⚠ `CompareView.statCellText` / `statCellPnl`
///   是**另一种形态**（标签在上、值在下），**不在本组**。
struct MetricCell: View {
    let label: String
    let value: String
    /// 值的前景色（`nil` = 默认前景）。资金流卡用它表达正负方向。
    var valueColor: Color?
    /// 值后面追加的小字（筹码卡的「+N%」缺口）。
    var trailing: String?
    /// 是否带 `Tok.sunken` 底与内边距
    var boxed: Bool = false
    /// 值与标签的间距
    var spacing: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            HStack(spacing: 4) {
                Text(value)
                    .font(AppFont.mono.weight(.semibold))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(valueColor ?? Color.primary)
                if let t = trailing {
                    Text(t)
                        .font(AppFont.detailSmall).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Text(label).font(AppFont.detailSmall).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, boxed ? 10 : 0)
        .padding(.vertical, boxed ? 7 : 0)
        .background(boxed ? Tok.sunken : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 统一表格（表头与数据行共享列宽定义，改列宽只改一处）

/// 表格列定义：表头与数据行共用，宽度/对齐只在此定义一次
struct TableColumnSpec: Identifiable {
    let id: String
    let title: String
    var width: CGFloat?
    var alignment: Alignment = .center

    init(_ title: String, width: CGFloat? = nil, alignment: Alignment = .center) {
        self.id = title
        self.title = title
        self.width = width
        self.alignment = alignment
    }
}

/// 数据单元格：按列定义统一应用宽度与对齐（表头/数据行使用同一列定义即可列对齐）
extension View {
    func tableCell(_ column: TableColumnSpec) -> some View {
        self
            .frame(width: column.width, alignment: column.alignment)
            .frame(maxWidth: column.width == nil ? .infinity : nil, alignment: column.alignment)
    }
}

/// 表头行
struct DataTableHeader: View {
    let columns: [TableColumnSpec]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(columns) { col in
                Text(col.title)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .tableCell(col)
            }
        }
    }
}

/// 统一表格容器：表头 + 分割线 + 数据行（行内容由调用方按列渲染）
struct DataTable<Row, RowID: Hashable, RowContent: View>: View {
    let columns: [TableColumnSpec]
    let rows: [Row]
    let rowID: KeyPath<Row, RowID>
    var rowSpacing: CGFloat = 3
    let rowContent: (Row, [TableColumnSpec]) -> RowContent

    init(_ columns: [TableColumnSpec],
         rows: [Row],
         rowID: KeyPath<Row, RowID>,
         rowSpacing: CGFloat = 3,
         @ViewBuilder rowContent: @escaping (Row, [TableColumnSpec]) -> RowContent) {
        self.columns = columns
        self.rows = rows
        self.rowID = rowID
        self.rowSpacing = rowSpacing
        self.rowContent = rowContent
    }

    var body: some View {
        VStack(spacing: rowSpacing) {
            DataTableHeader(columns: columns)
            Divider()
            ForEach(rows, id: rowID) { row in
                rowContent(row, columns)
            }
        }
    }
}

