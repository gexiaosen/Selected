import SwiftUI
import SelectedCore

// MARK: - 表格统一口径
//
// 只抽「静态列 + 行」的简单表：ETF 推荐等（深度排除名单 2026-11-04 起不再展示）。
// 选股结果（可展开 / 键盘可达）、自选（可编辑列 / 逐行判定）这类交互表保留各自的行实现，
// 但表头字号、表头颜色、分隔线统一走本文件的 `TableMetrics` / `TableRule`，不再各写一套。

enum TableMetrics {
    /// 表头：11pt Medium + 次级色（取代各页的 10pt tertiary）
    static let headerFont = AppFont.detail.weight(.medium)
    static let headerColor = Color.secondary
    /// 普通/数字单元格：12pt
    static let rowFont = AppFont.bodySmall
    static let rowNumericFont = AppFont.numeric(AppFont.bodySmall)
    static let headerHeight: CGFloat = 28
    static let rowHeight: CGFloat = 30
}

struct TableRule: View {
    var body: some View {
        Rectangle()
            .fill(Tok.hairline)
            .frame(height: 1)
    }
}

// MARK: - 列宽：全 App 唯一算法
//
// 2026-10-27（B1 收口）把原先三份实现合成一份。三份各自的历史：
//   · 选股结果 `ResultsView.pickTableLayout` —— 按内容实测 ×1.35+4，富余先填等间隙（老板
//     2026-10-26 定的口径，也是本函数的口径）；
//   · 本文件 `SharedDataTable.columnWidths` —— 声明宽 + 按权重摊富余（弹性列拿 2 倍权重），
//     结果是"一列特别空、其余刚好"；
//   · 指标筛选 / 自选持仓 —— 写死码表，窗口变宽时富余全进最后一列。
//
// 口径（两个方向都不许走偏）：
//   ① 不许"每列 `maxWidth:.infinity` 均分剩余" —— 4 个字符的「量比」与 7 个字符的「成交额」
//      一样宽，列内两侧全是空白，末列还会跟右边那格贴上；
//   ② 也不许把富余一股脑塞进列内 —— 空白只是换了个地方继续存在。
//      **富余优先待在列与列之间，且每段必须一样宽**；间隙封顶（32pt）后才按比例回摊给列。
enum ColumnLayout {
    /// 间隙下限（= 原 `ResultsTableMetrics.columnSpacing`）
    static let minGap: CGFloat = 6
    /// 间隙上限：再宽就把一张表拉成"字之间隔着一段马路"
    static let maxGap: CGFloat = 32
    /// 内容宽 → 列宽的系数与左右呼吸（数字两侧留一点，但不至于列内出空洞）
    static let factor: CGFloat = 1.35
    static let pad: CGFloat = 4
    /// 弹性列的**起算宽**：`SharedDataTable` 的单元格是 View，量不到文字宽度，
    /// 只能按声明起算（真正定宽由 `distribute` 的间隙/回摊决定）。
    static let flexBase: CGFloat = 160

    /// 表头 / 单元格的实测字体（与 `TableMetrics` 同一档字号，别另起一套）
    static let headerNS = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let rowNS = NSFont.systemFont(ofSize: 12)
    static let rowBoldNS = NSFont.boldSystemFont(ofSize: 12)
    /// 微字档（`AppFont.detailSmall` 的 NSFont 孪生）：图表线尾标注之类要**量宽度**时用，
    /// 字号必须和视图里真正用的那支一致，否则量窄了截字、量宽了留白。
    static let microNS = NSFont.systemFont(ofSize: 10)

    static func measure(_ s: String, _ font: NSFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    /// 一列的**内容基准宽** = max(表头, 所有单元格) × 1.35 + 4，再夹在 [minWidth, maxWidth] 里。
    /// ⚠ 参数名刻意不叫 `min`/`max` —— 那会把 `Swift.min/max` 遮蔽成 CGFloat，函数体里
    ///   的夹取写法当场编译不过（2026-10-27 实测）。
    /// - Parameter bold: 该列单元格是粗体（名称列），实测必须用同一支字体，否则量窄了会截字
    static func baseWidth(title: String, cells: [String], minWidth: CGFloat = 24,
                          maxWidth: CGFloat? = nil, bold: Bool = false) -> CGFloat {
        let cellFont = bold ? rowBoldNS : rowNS
        let widest = cells.map { measure($0, cellFont) }.max() ?? 0
        let measured = Swift.max(widest, measure(title, headerNS)) * factor + pad
        let floored = Swift.max(minWidth, measured)
        return maxWidth.map { Swift.min($0, floored) } ?? floored
    }

    /// 把视口富余分给「间隙 → 列宽」：先等量拉间隙到 `maxGap`，剩下的按比例摊给各列。
    /// - Returns: 每列最终宽度 + 统一间隙。放不下时压间隙（最低 2pt），**不静默错位** ——
    ///   右侧被卡片裁掉是看得见的。
    /// - Parameter gapCount: 间隙**段数**。默认 `列数 − 1`；调用方若还有不参与摊分的
    ///   写死列（分数 / 三轮分 / 行尾箭头），要把那些列之间的缝一并算进来 ——
    ///   段数错了就等于凭空少摊或多摊几段间隙（选股结果是 `指标列数 + 3`）。
    static func distribute(bases: [CGFloat], available: CGFloat,
                           gapCount: CGFloat? = nil) -> (widths: [CGFloat], gap: CGFloat) {
        let gaps = gapCount ?? CGFloat(Swift.max(bases.count - 1, 1))
        let baseSum = Swift.max(bases.reduce(0, +), 1)
        var slack = available - baseSum - minGap * gaps
        if slack < 0 {
            return (bases, Swift.max(2, minGap + slack / gaps))
        }
        // ① 富余先变成相等的间隙
        let gapRoom = Swift.min(slack, (maxGap - minGap) * gaps)
        let gap = minGap + gapRoom / gaps
        slack -= gapRoom
        // ② 间隙封顶后还有富余：按内容比例摊（宽列多拿、窄列少拿，比例恒定）
        let widths = slack > 0 ? bases.map { $0 + slack * $0 / baseSum } : bases
        return (widths, gap)
    }
}

struct DataTableColumn: Identifiable {
    let id: String
    let title: String
    /// nil = 弹性列（吃掉剩余宽度）
    var width: CGFloat?
    var alignment: Alignment
    var isNumeric: Bool

    init(_ id: String, _ title: String, width: CGFloat? = nil,
         alignment: Alignment = .leading, isNumeric: Bool = false) {
        self.id = id
        self.title = title
        self.width = width
        self.alignment = alignment
        self.isNumeric = isNumeric
    }
}

/// 静态数据表：表头 + 每行一条 hairline 分隔线。
///
/// ⚠ **没有斑马纹，也不给开关**（老板 2026-10-23 看完判"很丑"，护栏 `no_zebra` 钉住）：
///   行的分界只由 `TableRule` 那条 1px hairline 给。要加隔行底色得先过他。
/// 用法：列定义固定宽度 / 弹性宽度；单元格内容由调用方给，数字列自动等宽并右对齐。
struct SharedDataTable<Row, Cell: View>: View {
    let columns: [DataTableColumn]
    let rows: [Row]
    let cell: (Row, DataTableColumn) -> Cell
    @State private var hoveredRow: Int?
    /// 表宽实测（间隙与回摊都要它）；列宽算法本身在 `ColumnLayout`
    @State private var tableWidth: CGFloat = 0

    init(columns: [DataTableColumn], rows: [Row],
         @ViewBuilder cell: @escaping (Row, DataTableColumn) -> Cell) {
        self.columns = columns
        self.rows = rows
        self.cell = cell
    }

    /// 列宽 + 间隙：走 `ColumnLayout` 的**唯一算法**（富余先进等宽间隙 ≤32pt，封顶后按比例回摊）。
    /// 原先这里是"弹性列拿 2 倍权重"的另一套 —— 同一个 App 里三种列宽行为，2026-10-27 B1 合并。
    private func layout(for available: CGFloat) -> (widths: [CGFloat], gap: CGFloat) {
        ColumnLayout.distribute(bases: columns.map { $0.width ?? ColumnLayout.flexBase },
                                available: available)
    }

    var body: some View {
        let L = layout(for: max(tableWidth, 600))
        let widths = L.widths
        return VStack(spacing: 0) {
            HStack(spacing: L.gap) {
                ForEach(columns.indices, id: \.self) { i in
                    let c = columns[i]
                    framed(c, width: widths[i]) {
                        Text(c.title)
                            .lineLimit(1)
                    }
                }
            }
            .font(TableMetrics.headerFont)
            .foregroundStyle(TableMetrics.headerColor)
            .frame(height: TableMetrics.headerHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tableWidth = $0 }
            TableRule()

            LazyVStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { i in
                    let row = rows[i]
                    VStack(spacing: 0) {
                        HStack(spacing: L.gap) {
                            ForEach(columns.indices, id: \.self) { j in
                                let c = columns[j]
                                framed(c, width: widths[j]) {
                                    cell(row, c)
                                        .font(c.isNumeric ? TableMetrics.rowNumericFont : TableMetrics.rowFont)
                                }
                            }
                        }
                        .frame(minHeight: TableMetrics.rowHeight)
                        .background(hoveredRow == i ? Tok.row : Color.clear)
                        .onHover { inside in
                            if inside { hoveredRow = i }
                            else if hoveredRow == i { hoveredRow = nil }
                        }
                        if i < rows.count - 1 {
                            TableRule()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func framed<Content: View>(_ c: DataTableColumn, width: CGFloat,
                                       @ViewBuilder content: () -> Content) -> some View {
        content().frame(width: width, alignment: c.alignment)
    }
}
