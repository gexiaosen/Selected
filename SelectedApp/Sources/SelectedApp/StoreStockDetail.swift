import Foundation
import Observation
import SelectedCore

/// 个股详情页的**数据聚合层**。
///
/// ## 为什么需要它
/// 详情页的多类信息（指数成份 / 行业 / 上市日期 / 基本面 / 龙虎榜 / 涨停池 / 资金流…）
/// 若各挂独立 `.task` 分别调 Core 的 `@MainActor` Store，就是主线程串行多次 SQLite 查询，
/// 且同一只票的信息分次查、**没有任何复用**。
/// 做法与 `Store` 的既有约定一致：**一次查完 → 收进一个 `@Observable` → View 只读不查**
/// （视图 body 里逐行查库就是主线程同步 I/O）。
///
/// ## 边界（刻意不做的事）
/// · **不改变查哪些数据、查到什么口径** —— 只是从「多次串行往返」变成「1 次」；
/// · **不合并 K 线 / 分时 / 预测**（那三个各有自己的重载语义：`loadChart` 受
///   `period` + `reloadToken` 影响、`loadIntraday` 有轮询、`loadForecast` 依赖
///   `loadChart` 的结果），仍留在各自 extension；
/// · **不引入后台线程** —— Core 的这些 Store 是 `@MainActor`，要真搬到后台得先
///   把它们改成 `Sendable` 的独立读取，那是另一件事。本类只做「串行 → 单次」。
@Observable
@MainActor
final class StockDetailStore {

    // MARK: 一次性加载的静态档案（打开详情时查一次，之后不变）

    /// 所属指数徽章（`IndexMembersStore.indicesOf` → 名称）
    var indexBadges: [String] = []
    /// 基本面（`FundamentalStore.fundamentals`）
    var stockFundamentals: Fundamental.Item?

    /// 是否已加载过（避免 `code` 相同但视图重建时重复查）
    private(set) var loadedCode: String?

    // MARK: 加载控制

    /// 本次加载的代号（用于丢弃过期的回填结果）
    private var loadToken: Int = 0

    /// 一次查完「静态档案」那一组（后台线程自建独立只读连接，不阻塞主线程）。
    ///
    /// ⚠ 逐项 `try?` 不可用：这些 Store 的方法**不是** throwing（它们内部
    ///自己 `?? nil` 兜底），所以直接调、`nil` 即"没数据"。
    ///
    /// - Parameter code: 股票代码。
    func loadProfile(code: String) async {
        guard !code.isEmpty else { return }
        loadToken += 1
        let token = loadToken

        let (badges, fundamentals) = await Task.detached(priority: .userInitiated) {
            let reader = SQLiteReader.makeIndependent()
            defer { reader.invalidate() }
            // 指数成份：季度级变化，打开时查一次即可
            let badges = IndexMembersStore.indicesOf(code: code, reader: reader)
                .compactMap { IndexMembers.index($0)?.name }
            let fundamentals = FundamentalStore.fundamentals(of: code, reader: reader)
            return (badges, fundamentals)
        }.value

        guard !Task.isCancelled, token == loadToken else { return }
        indexBadges = badges
        stockFundamentals = fundamentals
        loadedCode = code
    }

    /// 切换股票时清空（`.id(target.code)` 换股票时走这条路）。
    func reset() {
        loadToken += 1          // 让在途的旧结果失效
        indexBadges = []
        stockFundamentals = nil
        loadedCode = nil
    }

    /// 是否已有该 code 的档案（View 用来决定要不要显示骨架）
    func hasProfile(for code: String) -> Bool { loadedCode == code }
}
