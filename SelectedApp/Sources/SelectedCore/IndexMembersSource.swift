import Foundation

/// 指数成份（沪深300 / 中证500 / 上证50）。
///
/// 数据源：新浪 `Market_Center.getHQNodeData` 的 `node=` 参数（板块 / 指数成份），
/// 与证券列表同一接口。节点对照：`hs300`→沪深300、`zhishu_000905`→中证500、
/// `zhishu_000016`→上证50（`num` 被服务端强制回落 100，需分页）。
///
/// ⚠ 两个"看着对其实错"的节点名，失败方式**都是静默的**：
/// `zhishu_000300` 返回**空数组**（与"没有成份"不可区分）；`hs_s` 返回**指数本身**。
/// → 节点名必须是**常量**（不许拼字符串），且每次抓取做**数量下界断言**（`Index.minCount`）。
///
/// ⚠ 这是**展示**用的身份标记，不进筛选。
public enum IndexMembers {

    /// 一个被跟踪的指数
    public struct Index: Equatable, Sendable {
        /// 落库标识（也是界面上的键）
        public let code: String
        /// 显示名
        public let name: String
        /// 新浪 `node=` 参数。⚠ **必须实测过**（见类型注释里那两个反例）
        public let node: String
        /// 数量下界：抓回来的成份数低于它 → 判为**抓取失败**，不写库。
        ///
        /// 为什么不写"数量相等"：指数会调仓（每半年），且停牌/退市会让数量短暂少几只。
        /// 下界留足余量，只拦住"整批拿不到 / 拿错了节点"这类**数量级**的错误。
        public let minCount: Int
    }

    /// 跟踪的指数清单（**唯一事实来源**）
    public static let indices: [Index] = [
        Index(code: "hs300", name: "沪深300", node: "hs300", minCount: 250),
        Index(code: "zz500", name: "中证500", node: "zhishu_000905", minCount: 400),
        Index(code: "sz50", name: "上证50", node: "zhishu_000016", minCount: 40),
    ]

    public static func index(_ code: String) -> Index? {
        indices.first { $0.code == code }
    }

    /// 成份里的一条
    public struct Member: Equatable, Sendable {
        public let code: String
        public let name: String
    }
}

/// 抓取 + **纯解析**（分开是为了让解析可离线单测）。
public enum IndexMembersSource {

    /// 分页上限。实测最大 500 只 / 每页 100 → 5 页；给到 10 页留足余量。
    /// ⚠ 与 `DataSources.sinaListMaxPages`（90）不同：那是全市场 A 股（5000+），这是指数成份。
    static let maxPages = 10
    static let pageSize = 100

    /// 拼一页的 URL。⚠ `node` 必须来自 `IndexMembers.indices`（不要在这里拼字符串）
    public static func url(node: String, page: Int) -> String {
        DataSourceEndpoints.sinaList
            + "Market_Center.getHQNodeData?page=\(page)&num=\(pageSize)"
            + "&sort=symbol&asc=1&node=\(node)&symbol=&_s_r_a=page"
    }

    /// **纯决策**：这次抓回来的数量够不够格覆盖库里的旧数据（可单测）。
    ///
    /// 抽成独立函数是为了让"拦不拦"这件事**可离线断言** ——
    /// `refresh` 本身要触网，没法在单测里跑。
    ///
    /// - Returns: `(是否接受, 拒绝原因)`
    public static func acceptance(count: Int, index: IndexMembers.Index) -> (ok: Bool, reason: String?) {
        if count >= index.minCount { return (true, nil) }
        return (false, "抓到 \(count) 只 < 下界 \(index.minCount)")
    }

    /// 纯解析：新浪响应体 → 成份（按 code 升序、去重）。    ///
    /// **全有或全无**：整体不是数组 → `[]`（与 `parseSinaKline` 同一条纪律 ——
    /// 半截数据比没有数据更危险，会被当成"完整的一份成份表"）。
    /// 单行缺 `code` → 跳过该行（新浪偶有 `code` 为 `None` 的行，与证券列表同源问题）。
    public static func parse(_ text: String) -> [IndexMembers.Member] {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stripped.hasPrefix("["),
              let data = stripped.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        var seen = Set<String>()
        var out: [IndexMembers.Member] = []
        for r in rows {
            let code = (r["code"] as? String) ?? ""
            guard !code.isEmpty, code.allSatisfy({ $0.isASCII && $0.isNumber }), seen.insert(code).inserted else {
                continue
            }
            out.append(IndexMembers.Member(code: code, name: (r["name"] as? String) ?? ""))
        }
        return out.sorted { $0.code < $1.code }
    }

    /// 抓一个指数的全部成份。
    ///
    /// - Returns: 成份列表。**抓取失败与"真的是空"都返回 `[]`** ——
    ///   所以调用方（`IndexMembersStore.refresh`）**必须**用 `Index.minCount` 判一次，
    ///   不能拿 `[]` 直接覆盖库里的好数据。
    public static func fetch(_ index: IndexMembers.Index) -> [IndexMembers.Member] {
        var collected: [IndexMembers.Member] = []
        var page = 1
        while page <= maxPages {
            let text = DataSources.httpGet(url(node: index.node, page: page),
                                           referer: "https://finance.sina.com.cn", retries: 1)
            // ⚠ 分页之间必须过全局限速（2026-10-16 审查 B4）：原先整个循环一次都没有节流，
            //   最多 `maxPages` 页连发打新浪。
            DataSources.throttleAfterNetwork()
            let stripped = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // 首页就失败 / 不是数组 → 整个抓取失败（返回空，交给下界断言拦住）
            if text == nil || !stripped.hasPrefix("[") {
                if page == 1 {
                    // ⚠ 不写响应体原文（审查 B4）：见 `DataSourcesLists` 里同一改动的说明
                    //   —— 代理门户/半截 HTML 的前 80 字节会被写进 `data_source_logs`
                    //   并在诊断页与系统通知里出现。改记长度与首字符。
                    DataSources.logDataSource("sina", "index_members_error",
                                              "\(index.name) 首页无数据（响应 "
                                              + "\((text ?? "").count) 字节，首字符 "
                                              + (stripped.isEmpty ? "无" : String(stripped.prefix(1))) + "）")

                }
                break
            }
            let rows = parse(stripped)
            if rows.isEmpty { break }        // 已翻到末页
            collected.append(contentsOf: rows)
            page += 1
        }
        // 分页之间可能重复（调仓临界点），整体再去重一次
        var seen = Set<String>()
        return collected.filter { seen.insert($0.code).inserted }
            .sorted { $0.code < $1.code }
    }
}
