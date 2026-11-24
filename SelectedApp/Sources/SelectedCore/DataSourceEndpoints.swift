import Foundation

/// 数据源端点 **唯一出处**。
///
/// URL / token / Referer 常量若散在各数据源文件里，腾讯/东财任一 WAF 调整或 host 轮换
/// 就要逐文件搜索修改并重打包。收敛到这里后**只改这一处**。
///
/// 规则：数据源层一律从这里取值，不再在各自文件里写 URL 字面量；
/// 各 Source 的 `host` / `referer` 仍保留为本地静态常量（`host + path` 拼接不动），
/// 只是赋值来源改为本枚举 —— 把"改动面"与"使用面"解耦。
enum DataSourceEndpoints {

    // MARK: - 代码形状校验（所有"把代码拼进 URL / 文件名"的取数入口先过这里）
    //
    // ⚠ 为什么必须严格 ASCII（2026-10-16 审查 B4）：
    //   `Character.isNumber` 认全角 `１２３４`、也认阿拉伯-印度数字 `٠١٢`；
    //   界面侧的"像代码"判据用的就是它，而 `Store.addWatchByCode` 把用户粘贴的原串
    //   一路传到取数层。这类字符进 `URL(string:)` 会被拒（返回 nil ⇒ 静默空数据），
    //   更坏的是含 `&` / `,` / `=` 的原串会**往腾讯的 `q=` 里追加参数**，
    //   改变请求语义而不报任何错。项目里已有的严格写法见 `LhbSource.isDate`
    //   （`omittingEmptySubsequences: false` + `isASCII`）—— 这里把它推广到代码。
    /// 5 或 6 位纯 ASCII 数字（5 位 = 港股，6 位 = A 股 / 场内基金）
    static func isQuoteCode(_ s: String) -> Bool {
        (s.count == 5 || s.count == 6) && s.allSatisfy { $0.isASCII && $0.isNumber }
    }
    /// 6 位纯 ASCII 数字（A 股 / 场内基金）
    static func isSixDigitCode(_ s: String) -> Bool {
        s.count == 6 && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    // MARK: - 腾讯

    /// 实时行情（单只/批量）：`q=` 后接代码（逗号分隔），GBK 编码
    static let tencentQuotes = "https://qt.gtimg.cn/q="
    /// 前复权 K 线（日/周/月，`newfqkline`）
    static let tencentKLine = "https://proxy.finance.qq.com/ifzqgtimg/appstock/app/newfqkline/get"
    /// 分时（腾讯**镜像**）。
    /// ⚠ `https://web.ifzq.gtimg.cn/appstock/app/minute/query` 已被腾讯 WAF 整条路径拦截
    ///   （HTTP 501 + waf.tencent.com 跳转页，2026-10-21 实测），与当年 K 线是同一个坑。
    ///   `proxy.finance.qq.com` 是同一份数据、同一 JSON 格式。
    static let tencentMinute = "https://proxy.finance.qq.com/ifzqgtimg/appstock/app/minute/query"
    /// 分时备用 host（同数据同格式；主镜像不可用时切换）
    static let tencentMinuteAlt = "https://ifzq.gtimg.cn/appstock/app/minute/query"
    /// 分时 K 线请求的 Referer（实测无它腾讯可能返回空）
    static let tencentKLineReferer = "https://gu.qq.com"

    // MARK: - 新浪

    /// K 线 JSONP 基址（后面接 `var%20_…/` 与 `CN_MarketDataService.getKLineData?…`）
    static let sinaKLine = "https://quotes.sina.cn/cn/api/jsonp_v2.php/"
    /// 证券/指数列表 JSONP（`vip.stock.finance.sina.com.cn`）
    static let sinaList = "https://vip.stock.finance.sina.com.cn/quotes_service/api/json_v2.php/"
    /// 新浪行情域（资金流等按 host 拼路径时用）
    static let sinaHost = "https://vip.stock.finance.sina.com.cn"
    /// 新浪资金流 Referer
    static let sinaFinanceReferer = "https://finance.sina.com.cn"

    // MARK: - 东方财富

    /// 排行/行业/基本面（`/api/qt/clist/get` 等）
    static let eastmoneyPush2 = "https://push2.eastmoney.com"
    /// 历史 K 线（`/api/qt/stock/kline/get`）
    static let eastmoneyPush2His = "https://push2his.eastmoney.com"
    /// 涨停池（`/getTopicZTPool`）
    static let eastmoneyPush2Ex = "https://push2ex.eastmoney.com"
    /// 分时 1 分钟趋势（腾讯分时不可用时的**跨源兜底**）
    static let eastmoneyMinute = "https://push2his.eastmoney.com/api/qt/stock/trends2/get"
    /// 龙虎榜/席位（`/api/data/v1/get`）
    static let eastmoneyDataCenter = "https://datacenter-web.eastmoney.com"
    /// 东财网页端用的公开 token（`ut`）。它是**固定值**、公开网页端的值，**不是用户凭证**；
    /// 换值只改这里。
    static let eastmoneyUT = "7eea3edcaed734bea9cbfc24409ed989"

    /// 东财**延时行情**子域（实为同一套实时快照接口）。
    /// ⚠ 2026-10-30 实测：`push2` 与 `push2delay` 对本机出口**间歇性空回包**（curl 52），
    ///   而同族的 `push2delay2` 稳定 200（27ms）—— 所以行情池把它排在第一位。
    static let eastmoneyPush2Delay = "https://push2delay.eastmoney.com"
    static let eastmoneyPush2Delay2 = "https://push2delay2.eastmoney.com"
    /// 东财编号行情主机（爱盯盘同款兜底链；同一份数据、同一套字段）
    static let eastmoneyPush2Numbered = [
        "https://1.push2.eastmoney.com",
        "https://7.push2.eastmoney.com",
        "https://21.push2.eastmoney.com",
        "https://28.push2.eastmoney.com",
    ]

    // MARK: - 新浪（行情池第二源）

    /// 新浪实时行情：`list=` 后接代码（逗号分隔），GBK 编码。
    /// ⚠ **必须带 Referer**：不带直接 403（2026-10-30 实测 9 字节拒绝页）。
    static let sinaHQ = "https://hq.sinajs.cn/list="
    static let sinaHQReferer = "https://finance.sina.com.cn"
    /// 东财通用 Referer（quote 域有防盗链；带上更稳）
    static let eastmoneyReferer = "https://quote.eastmoney.com/"
    /// 龙虎榜 Referer（data 域）
    static let eastmoneyDataCenterReferer = "https://data.eastmoney.com/"

    // MARK: - 深圳证券交易所（官方交易日历）

    /// 按月返回每个自然日是否交易日：`?month=yyyy-MM` → `data[].jyrq` + `jybz`（`"1"`=交易日）。
    /// 2026-11-02 实测 HTTP 200 / 1.3KB / 0.17s，**无需 cookie、无需 Referer 白名单**，
    /// 且**含未来日**（当月整月日历一次给全）—— 这正是"靠上证行情猜今天开不开盘"猜不出的部分。
    static let szseCalendarMonth = "https://www.szse.cn/api/report/exchange/onepersistenthour/monthList"

    // MARK: - 同花顺（K 线兜底）

    /// 日 K 线 JSONP：`hs_{6位代码}/01/last.js`（`01`=日线；实测 `02/30/60` 是别的周期/口径，
    /// `03/04/100` 直接 404 → 本项目的周K/月K **不走这条**）。
    static let thsKLine = "https://d.10jqka.com.cn/v6/line/"
    static let thsReferer = "https://d.10jqka.com.cn/"

    // MARK: - 腾讯（分笔成交）

    /// 逐笔/分笔成交：`?appn=detail&action=data&c={fullCode}&p={页码}`。
    /// 与 `qt.gtimg.cn` 同族但**是另一个 host**，实测 200 / 0.15s / 2.8KB（单页约 150 笔）。
    static let tencentDetail = "https://stock.gtimg.cn/data/index.php"
}
