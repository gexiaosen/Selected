import Foundation

// MARK: - 个股实时行情（腾讯 qt.gtimg.cn）
// 市场覆盖 sh/sz/bj（北交所）+ hk（港股）

public struct StockQuote: Equatable, Sendable {
    public let market: String        // "sh" / "sz" / "bj" / "hk"
    public let code: String          // 纯数字代码
    public let name: String
    public let currentPrice: Double
    public let previousClose: Double
    public let openPrice: Double
    public let highPrice: Double
    public let lowPrice: Double
    public let volume: Double        // 手
    public let turnover: Double      // 万元
    public let change: Double
    public let changePercent: Double
    public let turnoverRate: Double? // 换手率
    public let peRatio: Double?      // 市盈率
    public let marketCap: Double?    // 总市值（亿）
    public let circulationMarketCap: Double? // 流通市值（亿）
    public let amplitude: Double?    // 振幅
    public let volumeRatio: Double?  // 量比
    public let pbRatio: Double?      // 市净率
    /// 涨停价 / 跌停价（腾讯 f[47] / f[48]，**板块相关**：主板 ±10% / 创业板·科创板 ±20% /
    /// 北交所 ±30% / ST 实测 ±10%）。
    ///
    /// ⚠ 指数的这两个字段是 **-1**（哨兵值）→ 消费方必须先判 `> 0`。
    /// ⚠ 港股留空（布局不同位）。
    public let limitUp: Double?
    public let limitDown: Double?
    /// 行情时间戳（该笔快照的源侧时间）。
    ///
    /// 用途：接口池的"新鲜度"打分 —— 同一时刻两个源一个回 15:00 一个回 14:57，
    /// 光看请求延迟分不出来。拿不到时间戳的源留 `nil`（不参与新鲜度比较）。
    public let quoteTime: Date?

    /// 带市场前缀的完整代码（sh600519 / sz000001）
    public var fullCode: String { "\(market)\(code)" }
    /// 上涨（红）；A股红涨绿跌
    public var isRising: Bool { change >= 0 }

    /// 显式 public init：历史日K回填 / 调试快照需要在 Core 外构造行情快照。
    /// 实盘解析仍走 `StockQuotes.parse`，两者字段同一套。
    public init(market: String, code: String, name: String, currentPrice: Double,
                previousClose: Double, openPrice: Double, highPrice: Double, lowPrice: Double,
                volume: Double, turnover: Double, change: Double, changePercent: Double,
                turnoverRate: Double?, peRatio: Double?, marketCap: Double?,
                circulationMarketCap: Double?, amplitude: Double?, volumeRatio: Double?,
                pbRatio: Double?, limitUp: Double?, limitDown: Double?,
                quoteTime: Date? = nil) {
        self.market = market
        self.code = code
        self.name = name
        self.currentPrice = currentPrice
        self.previousClose = previousClose
        self.openPrice = openPrice
        self.highPrice = highPrice
        self.lowPrice = lowPrice
        self.volume = volume
        self.turnover = turnover
        self.change = change
        self.changePercent = changePercent
        self.turnoverRate = turnoverRate
        self.peRatio = peRatio
        self.marketCap = marketCap
        self.circulationMarketCap = circulationMarketCap
        self.amplitude = amplitude
        self.volumeRatio = volumeRatio
        self.pbRatio = pbRatio
        self.limitUp = limitUp
        self.limitDown = limitDown
        self.quoteTime = quoteTime
    }
}

public enum StockQuotes {
    /// 批量取数已全部迁到 `QuoteAPI`（接口池：腾讯 / 东财 / 新浪，运行时选最优）。
    /// 本类型只保留**纯解析**与代码口径 —— 这样解析口径可离线单测，网络永远不在这里。

    /// 批量响应文本 → 完整 symbol（`sh000001`）→ quote
    ///
    /// 多行 `v_XXnnnnnn="..."` 逐行解析。**纯函数**（不触网），供自检离线锁定解析口径。
    /// ⚠ 必须认全 sh/sz/bj/hk 四种前缀：漏一种，对应市场的行会被整行跳过
    ///   —— 表现为"自选里这些标的永远没有实时价"。
    public static func parseBatchFullKeys(_ text: String) -> [String: StockQuote] {
        var result: [String: StockQuote] = [:]
        for line in text.components(separatedBy: "\n") {
            guard let key = symbolKey(of: line),
                  marketPrefixes.contains(String(key.prefix(2))),
                  let q = parse(rawString: line, market: String(key.prefix(2))) else { continue }
            result[key] = q
        }
        return result
    }

    /// 一行响应的完整代码键：`v_sh600519="1~…"` → `sh600519`。
    /// 认不出 / 前缀不认 / 数字位缺失 → nil。
    static func symbolKey(of line: String) -> String? {
        guard let v = line.range(of: "v_") else { return nil }
        let rest = line[v.upperBound...]
        guard let eq = rest.firstIndex(of: "=") else { return nil }
        let key = String(rest[..<eq]).lowercased()
        let digits = String(key.dropFirst(2))
        guard key.count > 2, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return key
    }

    /// 一行响应引号内的 `~` 分隔字段数组（行情、五档、分笔共用同一份切分口径）。
    static func quotedFields(of line: String) -> [String]? {
        guard let start = line.range(of: "\""),
              let end = line[start.upperBound...].range(of: "\"") else { return nil }
        return String(line[start.upperBound..<end.lowerBound]).components(separatedBy: "~")
    }

    /// 批量响应文本 → code(纯数字) → quote（自选列表口径）
    public static func parseBatch(_ text: String) -> [String: StockQuote] {
        var result: [String: StockQuote] = [:]
        for (full, quote) in parseBatchFullKeys(text) {
            result[Self.digits(full)] = quote
        }
        return result
    }

    /// 拆分已带的市场前缀与代码本体（统一只走一轮 lowercased + prefix 扫描）
    private static func splitMarketPrefix(_ code: String) -> (prefix: String?, body: String) {
        let lowered = code.lowercased()
        for p in marketPrefixes where lowered.hasPrefix(p) {
            return (p, String(lowered.dropFirst(2)))
        }
        return (nil, code)
    }

    /// 按代码推断市场前缀（A 股规则 + 北交所 920 号段 + 港股 5 位码）
    public static func inferMarket(code: String) -> String {
        // 输入已带前缀（sh600276/sz000001/bj430047/hk00700）→ 直接用，别再拼一次
        let (existing, d) = splitMarketPrefix(code)
        if let existing { return existing }
        // 港股：5 位数字 —— A 股与场内基金都是 6 位，长度即可判别（必须先于首位规则，
        // 否则 00700/09988 会被判成深市 sz00700）
        if d.count == 5 { return "hk" }
        // 北交所新号段 920xxx（必须先于 "9" → 沪市 的旧规则，900xxx 才是沪 B 股）
        if d.hasPrefix("920") { return "bj" }
        guard let first = d.first else { return "sh" }
        switch first {
        case "6", "9": return "sh"                       // 沪市：600/601/603/605/688、B股 900
        case "0", "1", "2", "3": return "sz"             // 深市：000/001/002/003/300/301
        case "4", "8": return "bj"                       // 北交所：430/83x/87x/88x
        default: return "sh"
        }
    }

    /// 行情接口支持的市场前缀（批量解析与全代码拼接共用）
    public static let marketPrefixes = ["sh", "sz", "bj", "hk"]

    /// 去掉市场前缀后的数字代码（sh600519 → 600519；hk00700 → 00700）
    public static func digits(_ code: String) -> String {
        splitMarketPrefix(code).body
    }

    /// 场内基金代码（沪：50/51/52/56/58；深：15/16/18）—— 与 funds 表口径一致
    public static func isFundCode(_ code: String) -> Bool {
        let d = digits(code)
        guard d.count == 6 else { return false }
        return ["50", "51", "52", "56", "58", "15", "16", "18"].contains(String(d.prefix(2)))
    }

    /// 统一成带市场前缀的完整代码（供 K 线等需要 fullCode 的接口用）
    public static func fullCode(_ code: String) -> String {
        let d = digits(code)
        return inferMarket(code: code) + d
    }

    // MARK: - 市场标识（徽章 + 交易所前缀 + 展示代码）

    /// 一只标的的市场展示信息
    public struct MarketInfo {
        /// 徽章单字：科/创/沪/深/北/基/港；"" = 不加徽章（未识别）
        public let tag: String
        /// 交易所前缀（大写）：SH/SZ/BJ/HK
        public let prefix: String
        /// 展示用完整代码：SZ300221 / SH510300 / BJ920819 / HK00700
        public let display: String
    }

    /// 市场标识的**单一实现**（自选列表、搜索结果、详情页共用）：
    /// 徽章判定与行情用的市场前缀必须同源，否则会出现"徽章写科创、行情按深市取"这类矛盾。
    public static func marketInfo(_ code: String) -> MarketInfo {
        let d = digits(code)
        let prefix = inferMarket(code: code).uppercased()
        // 港股：hk 前缀或 5 位数字（A 股/场内基金都是 6 位）
        if prefix == "HK" {
            return MarketInfo(tag: "港", prefix: "HK", display: "HK" + d)
        }
        var tag = ""
        if isFundCode(d) {
            tag = "基"                                       // 基金优先：50/51/58 等不参与板块判定
        } else {
            switch String(d.prefix(3)) {
            case "688", "689": tag = "科"                     // 科创板（689 = CDR/存托凭证）
            case "300", "301": tag = "创"                     // 创业板
            case "600", "601", "603", "605", "900": tag = "沪" // 沪主板 + 沪 B 股
            case "000", "001", "002", "003", "200": tag = "深" // 深主板/中小板 + 深 B 股
            case "920": tag = "北"                            // 北交所新号段
            default:
                // 北交所：430 / 83x / 87x / 88x（首位 4 或 8）
                if let f = d.first, f == "4" || f == "8" { tag = "北" }
            }
        }
        return MarketInfo(tag: tag, prefix: prefix, display: prefix + d)
    }

    /// 徽章单字的含义（悬浮提示用）
    public static func marketTagHelp(_ tag: String) -> String {
        switch tag {
        case "科": return "科创板"
        case "创": return "创业板"
        case "沪": return "上海证券交易所"
        case "深": return "深圳证券交易所"
        case "北": return "北京证券交易所"
        case "基": return "场内基金（ETF/LOF/封闭式）"
        case "港": return "香港交易所"
        default: return ""
        }
    }

    /// 腾讯响应解析：v_sh600519="1~贵州茅台~600519~1460.00~..."
    public static func parse(rawString: String, market: String) -> StockQuote? {
        guard let f = quotedFields(of: rawString),
              f.count >= 40,
              let price = Double(f[3]), price > 0,
              let preClose = Double(f[4]) else { return nil }
        // 港股字段布局与 A 股不同（实测 hk00700/hk01276 逐位核对）：
        //   f38 换手率位置上恒为 0、f46 是英文名（不是 PB）、f49 是 52 周低（不是量比）
        //   —— 这三项港股一律留空（宁缺勿错）；振幅 f43 / 市值 f44-45 / PE f39 同位可用
        let isHK = market == "hk"

        return StockQuote(
            market: market,
            code: f[2],
            name: f[1],
            currentPrice: price,
            previousClose: preClose,
            openPrice: Double(f[5]) ?? 0,
            highPrice: Double(f[33]) ?? 0,
            lowPrice: Double(f[34]) ?? 0,
            volume: Double(f[6]) ?? 0,
            // ⚠ 腾讯 f[37] 的单位按市场而变：A股/基金是**万元**，港股是**元**
            //   （实测 hk00700 f37=8,540,915,574，与东财 f6 完全一致）。
            //   统一折成"万元"再进模型，否则港股成交额会大 1 万倍。
            turnover: isHK ? (Double(f[37]) ?? 0) / 1_0000 : (Double(f[37]) ?? 0),
            change: Double(f[31]) ?? 0,
            changePercent: Double(f[32]) ?? 0,
            turnoverRate: isHK ? nil : Double(f[38]),
            peRatio: Double(f[39]),
            // 腾讯接口字段索引：
            //   f[43]=振幅%  f[44]=**流通市值**(亿)  f[45]=**总市值**(亿)
            //   f[46]=市净率PB  f[47]=涨停价  f[48]=跌停价  f[49]=量比
            // ⚠ 44/45 不能互换：判据是**流通市值必然 ≤ 总市值**
            //   （有限售股的票上差异很大，如北交所中诚咨询：流通 3.05亿 vs 总 14.21亿）。
            //   互换的后果：详情页两格显示互换；
            //   `ChipDistribution.estimateFloatShares` 拿流通市值反推流通股本时会**偏大**。
            marketCap: f.count > 45 ? Double(f[45]) : nil,
            circulationMarketCap: f.count > 44 ? Double(f[44]) : nil,
            amplitude: f.count > 43 ? Double(f[43]) : nil,
            volumeRatio: isHK ? nil : (f.count > 49 ? Double(f[49]) : nil),
            pbRatio: isHK ? nil : (f.count > 46 ? Double(f[46]) : nil),
            // 涨跌停价（供「涨跌停异动」判定用）。
            // ⚠ 用它而不是"跌幅>9.5%"：档位是**板块相关**的 ——
            //   主板 ±10% / 创业板·科创板 ±20% / 北交所 ±30% / ST ±10%。
            // ⚠ 指数的这两个字段是 **-1**（哨兵值，不是价格）→ 消费方必须先判 `> 0`，
            //   否则 `price >= -1` 恒真，**每一条指数都会被判成"涨停"**。
            // ⚠ 港股同样留空：实测 hk 的 f47/f48 是 52 周高附近的值，不是涨跌停。
            limitUp: isHK ? nil : (f.count > 47 ? Double(f[47]) : nil),
            limitDown: isHK ? nil : (f.count > 48 ? Double(f[48]) : nil),
            quoteTime: parseQuoteTime(f.count > 30 ? f[30] : "")
        )
    }

    /// 腾讯 `quote_time` 有两种形状（实测）：
    ///   · A 股/指数：`yyyyMMddHHmmss`（`20261030161455`）
    ///   · 港股：`yyyy/MM/dd HH:mm:ss`（`2026/10/30 16:08:14`）
    /// 形状不对返回 nil（不猜时间）。
    static let quoteTimeFormatter = ChinaTime.formatter("yyyyMMddHHmmss")
    static let quoteTimeSlashFormatter = ChinaTime.formatter("yyyy/MM/dd HH:mm:ss")

    public static func parseQuoteTime(_ raw: String) -> Date? {
        if raw.count == 14, raw.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return quoteTimeFormatter.date(from: raw)
        }
        if raw.contains("/") {
            return quoteTimeSlashFormatter.date(from: raw)
        }
        return nil
    }
}

// MARK: - 数值格式化（A 股口径，从 StockWatch 移植精简）

public enum StockFmt {
    /// 成交量（单位：手）
    public static func volume(_ v: Double) -> String {
        if v >= 1_0000_0000 { return String(format: "%.2f亿手", v / 1_0000_0000) }
        if v >= 1_0000 { return String(format: "%.2f万手", v / 1_0000) }
        return String(format: "%.0f手", v)
    }

    /// 成交量紧凑格式（**不带单位后缀**；K 线副图右轴刻度与图例用）。
    ///
    /// 原样输出（`21619.00`）既占宽又难读，改成 X万 / X亿。
    /// 不带"手/股"后缀是刻意的：A 股与港股成交量单位不同（手 / 股），
    /// 刻度上写单位反而会错，单位由图例语境表达。
    public static func volumeCompact(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1_0000_0000 { return String(format: "%.2f亿", v / 1_0000_0000) }
        if a >= 1_0000 { return String(format: "%.2f万", v / 1_0000) }
        return String(format: "%.0f", v)
    }

    /// 指标数值紧凑格式（指标筛选结果表用：`|v| ≥ 1亿` 缩为亿、`|v| ≥ 1万` 缩为万，其余 2 位小数）。
    ///
    /// 与 `volumeCompact` 同属 1万/1亿 分档（此前 `IndicatorScreenerView` 误写 `100_0000` 缩放 100 倍），
    /// 差异是 `< 1万` 保留两位小数（如 RSI 24.35 / CMF 0.12），且支持可空值。
    public static func compact(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        let a = abs(v)
        if a >= 1_0000_0000 { return String(format: "%.2f亿", v / 1_0000_0000) }
        if a >= 1_0000 { return String(format: "%.2f万", v / 1_0000) }
        return String(format: "%.2f", v)
    }

    /// 成交额（输入单位：万元，腾讯接口 f[37]）
    public static func turnover(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1_0000 { return String(format: "%.2f亿", v / 1_0000) }   // ≥1亿（=10000万元）
        return String(format: "%.2f万", v)                                   // <1亿，直接万元
    }

    /// 百分比指标（振幅/换手率等）
    public static func percent(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.2f%%", v)
    }

    /// 市值（亿元）
    public static func marketCap(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.2f亿", v)
    }

    /// 可空数值
    public static func num(_ v: Double?, digits: Int = 2) -> String {
        guard let v else { return "—" }
        return String(format: "%.\(digits)f", v)
    }

    // MARK: - 价格（**按标的定档**：场内基金 3 位，其余 2 位）

    /// 价格小数位：场内基金 **3 位**，股票/指数 **2 位**。
    ///
    /// ⚠ 为什么必须分档（2026-10-29 他实测反馈"基金只显示 2 位小数"）：
    ///   ETF/LOF 的净值与行情本来就是 3 位（`159915` 实测现价 `3.406`、
    ///   生产库里的成本价 `159338 = 1.249`），写死 `%.2f` 会把 `1.052` 打成 `1.05` ——
    ///   不是"少看一位小数"，是**把两个不同的价格显示成同一个**。
    ///   上面 `costPrice` 早就为同一个坑改成 3 位了，行情价这条一直漏着。
    /// ⚠ 精度**不在这里丢**：解析链路一路保留原始 `Double`（`DataSourcesQuotes` 明写
    ///   "其余保持原始 double"），所以只需要在**出口**按档出数，不需要动任何取数代码。
    public static func priceDigits(code: String) -> Int {
        StockQuotes.isFundCode(code) ? 3 : 2
    }

    /// 价格（现价 / 开高低昨收 / 目标止损 / 收盘价…）：小数位跟着标的走
    public static func price(_ v: Double?, code: String) -> String {
        guard let v else { return "—" }
        return String(format: "%.\(priceDigits(code: code))f", v)
    }

    /// 带符号的价格涨跌额（`0` 显示 `+0.000` / `+0.00`，与 `signedMoney` 同一取向）
    public static func signedPrice(_ v: Double?, code: String) -> String {
        guard let v else { return "—" }
        return (v >= 0 ? "+" : "") + price(v, code: code)
    }

    // MARK: - 持仓相关（成本价 / 金额 / 盈亏）

    /// 成本价：**固定 3 位小数**。
    ///
    /// ⚠ 为什么必须是 3 位：券商端的**摊薄成本**（含手续费/分红摊薄）与 **ETF 净值**
    ///   本来就是 3 位小数（生产库里就有 `159338 = 1.249`、`600276 = 55.879`）。
    ///   用 `%.2f` 会把它显示成 `1.25` / `55.88` —— **用户看到的成本价是错的**。
    public static func costPrice(_ v: Double) -> String {
        String(format: "%.3f", v)
    }

    /// 元金额（持仓成本 / 市值 / 盈亏）：**保留到 0.001 元、去掉尾随零、不做取整**。
    ///
    /// ⚠ 为什么不是 `%.2f`：`金额 = 成本价 × 数量`，而成本价是 3 位（见 `costPrice`）
    ///   ⇒ 金额本身就可能带 3 位小数，用 2 位会**静默丢精度**。
    /// ⚠ 为什么不是 `%.3f`：`55205.8` 会被写成 `55205.800`，三个尾零纯噪声。
    /// ⚠ 唯一还会缩放的档：`|v| ≥ 1 亿` → 亿（个人持仓不会到，留个兜底防列宽炸掉）。
    public static func money(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1_0000_0000 { return String(format: "%.3f亿", v / 1_0000_0000) }
        // 先按 0.001 元归一，避免 1.249 * 44200 = 55205.799999999996 这类浮点尾巴
        let r = (v * 1000).rounded() / 1000
        if r == 0 { return "0" }
        if r == r.rounded() { return String(format: "%.0f", r) }
        var s = String(format: "%.3f", r)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// 带正负号的元金额（盈亏列 / 汇总栏；`0` 显示 `+0`）
    public static func signedMoney(_ v: Double) -> String {
        (v >= 0 ? "+" : "") + money(v)
    }

    // MARK: - 资金流（元 → 亿/万；"+"与"-"是方向，不能省）

    /// 个股资金流（详情页）：亿 2 位 / 万 1 位 / 元 0 位，缺失 → "—"。
    /// 个股净额量级跨度大（几万到几十亿），分档才读得懂。
    public static func signedFlow(_ v: Double?) -> String {
        guard let v else { return "—" }
        let a = abs(v)
        if a >= 1e8 { return String(format: "%+.2f亿", v / 1e8) }
        if a >= 1e4 { return String(format: "%+.1f万", v / 1e4) }
        return String(format: "%+.0f元", v)
    }

    /// 板块主力净流入（板块页表格 + 看板领涨板块卡）：**恒亿 2 位**。
    /// 板块净额几乎都在亿级，恒单位列宽一致、可直接比大小 —— 同一字段两处必须同档。
    public static func signedFlowYi(_ v: Double) -> String {
        String(format: "%+.2f亿", v / 1e8)
    }

    /// 数值 → 文本，**解析回来与原值逐位相同**（编辑框预填专用）。
    ///
    /// ⚠ 预填**不能**用 `%.2f`：成本价可以是 3 位（`1.249`），预填成 `1.25` 之后
    ///   用户只要点一下「保存」，库里的成本价就被**静默改写成 1.25** ——
    ///   此后市值/盈亏全部跟着错，而且**没有任何提示**。这是本函数存在的唯一理由。
    ///   ⚠ 不要"顺手"换成 `String(describing:)`：它对 `0.1 + 0.2` 会输出
    ///   `0.30000000000000004`（17 位噪声），而这里按需增精度、**取第一个能往返的位数**。
    public static func exact(_ v: Double) -> String {
        if !v.isFinite { return "0" }
        if v == v.rounded() && abs(v) < 1e15 { return String(format: "%.0f", v) }
        for digits in 1...17 {
            let s = String(format: "%.\(digits)f", v)
            if Double(s) == v { return s }
        }
        return String(v)
    }
}
