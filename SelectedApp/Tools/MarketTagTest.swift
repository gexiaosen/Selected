import Foundation
@testable import SelectedCore

/// 市场标识与多市场行情解析自检 —— 徽章/前缀 + 港股/北交所行情
///
/// 纯离线（行情解析用**实录原文**，不触网）。锁两件事：
///   1. `StockQuotes.marketInfo` 的徽章与交易所前缀 —— 单一实现，防"两处判断漂移"
///      （徽章写"科"、行情按深市取这类矛盾必须编译期就暴露不了、运行期也被本自检拦住）
///   2. 市场前缀推断与腾讯行情解析 —— 港股字段布局与 A 股不同（必须按市场分支留空三项）；
///      批量解析必须认全 sh/sz/bj/hk（北交所/港股曾被整行跳过 → 自选里永远没有实时价）
@main
struct MarketTagTest {
    private static var failures = 0

    static func main() {
        print("== market-tag ==")
        badgeTable()
        marketPrefix()
        codeHelpers()
        quoteParse()
        volumeFormat()

        print(failures == 0 ? "✅ market-tag：全部断言通过" : "❌ market-tag：\(failures) 项断言失败")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 1) 徽章 + 展示代码（表格驱动：改规则必须同步改这里）

    private static func badgeTable() {
        let cases: [(code: String, tag: String, display: String)] = [
            ("688981", "科", "SH688981"),   // 中芯国际
            ("689009", "科", "SH689009"),   // 九号公司（CDR）
            ("300221", "创", "SZ300221"),
            ("301029", "创", "SZ301029"),
            // 沪市单字是「**沪**」（与「深」对称）
            ("600519", "沪", "SH600519"),
            ("605499", "沪", "SH605499"),
            ("900901", "沪", "SH900901"),   // 沪 B 股
            ("000001", "深", "SZ000001"),
            ("002594", "深", "SZ002594"),
            ("200011", "深", "SZ200011"),   // 深 B 股
            ("430047", "北", "BJ430047"),
            ("831305", "北", "BJ831305"),
            ("920819", "北", "BJ920819"),   // 北交所新号段（旧规则 9→沪，会错取行情）
            ("510300", "基", "SH510300"),   // 沪 ETF
            ("588000", "基", "SH588000"),   // 科创 50 ETF（基金优先于"科"）
            ("159915", "基", "SZ159915"),   // 深 ETF
            ("160105", "基", "SZ160105"),   // 深 LOF
            ("00700", "港", "HK00700"),
            ("01276", "港", "HK01276"),
            ("hk00700", "港", "HK00700"),   // 带前缀输入也要归一
            ("123456", "", "SZ123456"),     // 未识别（可转债等）：不加徽章，前缀按推断兜底
        ]
        for c in cases {
            let info = StockQuotes.marketInfo(c.code)
            check(info.tag == c.tag && info.display == c.display,
                  "\(c.code) → 「\(c.tag)」\(c.display)（实际「\(info.tag)」\(info.display)）")
        }
    }

    // MARK: - 2) 行情市场前缀推断（含两条防回归边界）

    private static func marketPrefix() {
        let cases: [(code: String, market: String)] = [
            ("600519", "sh"), ("900901", "sh"),
            ("000001", "sz"), ("300750", "sz"), ("200011", "sz"),
            ("430047", "bj"), ("831305", "bj"),
            ("920819", "bj"),                 // 920 号段 → 北交所
            ("00700", "hk"), ("09988", "hk"),
            ("000001", "sz"),                 // 关键：6 位深市代码不得被判成港股
            ("sh600519", "sh"), ("bj430047", "bj"), ("hk00700", "hk"),
        ]
        for c in cases where StockQuotes.inferMarket(code: c.code) != c.market {
            check(false, "inferMarket(\(c.code)) 应为 \(c.market)，实际 \(StockQuotes.inferMarket(code: c.code))")
        }
        check(true, "inferMarket：\(cases.count) 例全通过")
    }

    // MARK: - 3) 代码归一（digits / fullCode）

    private static func codeHelpers() {
        check(StockQuotes.digits("sh600519") == "600519", "digits(sh600519) = 600519")
        check(StockQuotes.digits("hk00700") == "00700", "digits(hk00700) = 00700")
        check(StockQuotes.fullCode("510300") == "sh510300", "fullCode(510300) = sh510300")
        check(StockQuotes.fullCode("00700") == "hk00700", "fullCode(00700) = hk00700")
        check(StockQuotes.fullCode("920819") == "bj920819", "fullCode(920819) = bj920819")
        check(StockQuotes.isFundCode("510300") && StockQuotes.isFundCode("159915")
              && !StockQuotes.isFundCode("123456") && !StockQuotes.isFundCode("00700"),
              "isFundCode：场内基金 true / 可转债与港股 false")
    }

    // MARK: - 4) 腾讯行情解析（实录原文，离线）

    /// 收盘后 `qt.gtimg.cn/q=sh600519,hk00700,bj920819` 的实际响应
    private static let rawBatch = #"""
    v_sh600519="1~贵州茅台~600519~1257.12~1266.98~1262.99~24891~12061~12829~1257.12~8~1257.11~2~1257.08~1~1257.06~2~1257.05~2~1257.13~1~1257.24~2~1257.28~1~1258.00~16~1258.28~1~~20260918161436~-9.86~-0.78~1265.88~1256.10~1257.12/24891/3135849108~24891~313585~0.20~19.30~~1265.88~1256.10~0.77~15715.03~15715.03~6.25~1393.68~1140.28~1.14~-6~1259.84~17.65~19.09~~~0.08~313584.9108~527.9904~42~   A~GP-A~-6.82~-1.41~4.14~32.41~27.30~1539.98~1151.01~-5.48~-1.23~7.57~1250081601~1250081601~-16.67~-8.89~1250081601~~~-11.22~-0.42~~CNY~0~___D__F__N~1257.00~102~";
    v_hk00700="100~腾讯控股~00700~419.000~426.000~428.000~28796138.0~0~0~419.000~0~0~0~0~0~0~0~0~0~419.000~0~0~0~0~0~0~0~0~0~28796138.0~2026/09/18 16:08:32~-7.000~-1.64~430.400~419.000~419.000~28796138.0~12180786280.956~0~15.31~~0~0~2.68~38108.4103~38108.4103~TENCENT~1.27~677.700~411.000~1.85~-25.88~0~0~0~0~0~14.05~2.93~0.32~100~-29.43~-2.19~GP~20.41~11.00~-5.37~-8.32~-0.57~9095085993.00~9095085993.00~14.50~5.313~423.001~-29.78~HKD~1~50";
    v_bj920819="62~颖泰生物~920819~3.02~3.03~3.05~56372~29940~26431~3.02~612~3.01~2069~3.00~1306~2.99~650~2.98~440~3.03~1745~3.04~830~3.05~481~3.06~1019~3.07~2148~~20260918153443~-0.01~-0.33~3.08~3.01~3.02/56372/17108707~56372~1710.87~0.47~-13.89~~3.08~3.01~2.31~36.59~37.02~0.78~3.93~2.13~0.70~-1146~3.03~323.86~-14.41~~~~1710.8707~0.0000~0~ ~GP~-21.96~-7.65~0.00~-5.60~-2.44~4.55~2.52~-6.50~1.00~13.11~1211625000~1225800000~-10.14~-24.50~1211625000~~~-32.74~0.33~~CNY~4~NBFND~0.00~0";
    """#

    private static func quoteParse() {
        let batch = StockQuotes.parseBatch(rawBatch)
        check(batch.count == 3 && Set(batch.keys) == ["600519", "00700", "920819"],
              "批量解析认全 sh/hk/bj 三行（实际 \(batch.keys.sorted())）")

        // A 股：字段全量可用
        if let sh = batch["600519"] {
            check(sh.name == "贵州茅台" && sh.market == "sh", "A股：名称/市场 = 贵州茅台/sh")
            check(approx(sh.currentPrice, 1257.12) && approx(sh.previousClose, 1266.98)
                  && approx(sh.highPrice, 1265.88) && approx(sh.lowPrice, 1256.10),
                  "A股：现价/昨收/最高/最低")
            check(approx(sh.change, -9.86) && approx(sh.changePercent, -0.78), "A股：涨跌/涨跌幅")
            check(sh.volumeRatio != nil && sh.pbRatio != nil && sh.turnoverRate != nil,
                  "A股：量比/市净率/换手率有值")
            // 估值字段必须有断言 —— 没有的话 44/45 写反也能活下来。
            // 茅台流通=总，所以它区分不出来，得靠下面 920819 那条。
            check(approx(sh.peRatio ?? -1, 19.30) && approx(sh.pbRatio ?? -1, 6.25),
                  "A股：市盈率 f39=19.30 / 市净率 f46=6.25")
            check(approx(sh.limitUp ?? -1, 1393.68) && approx(sh.limitDown ?? -1, 1140.28),
                  "A股：涨停价 f47=1393.68 / 跌停价 f48=1140.28")
        } else {
            check(false, "A股：解析缺失 600519")
        }

        // 港股：同位字段可用；量比/市净率/换手率**必须留空**（腾讯港股布局不同位）
        if let hk = batch["00700"] {
            check(hk.name == "腾讯控股" && hk.market == "hk", "港股：名称/市场 = 腾讯控股/hk")
            check(approx(hk.currentPrice, 419) && approx(hk.previousClose, 426)
                  && approx(hk.highPrice, 430.4) && approx(hk.lowPrice, 419),
                  "港股：现价/昨收/最高/最低")
            check(approx(hk.change, -7) && approx(hk.changePercent, -1.64), "港股：涨跌/涨跌幅")
            check(approx(hk.amplitude ?? -1, 2.68), "港股：振幅 f43 同位可用")
            check(hk.turnoverRate == nil && hk.volumeRatio == nil && hk.pbRatio == nil,
                  "港股：换手率/量比/市净率留空（宁缺勿错）")
            // 港股 f47/f48 实测是 1.27 / 677.70（52 周高附近），**不是涨跌停**
            check(hk.limitUp == nil && hk.limitDown == nil,
                  "港股：涨跌停价留空（同位是别的字段，宁缺勿错）")
        } else {
            check(false, "港股：解析缺失 00700")
        }

        // 北交所：字段布局与 A 股一致（含量比/市净率）
        if let bj = batch["920819"] {
            check(bj.name == "颖泰生物" && bj.market == "bj", "北交所：名称/市场 = 颖泰生物/bj")
            check(approx(bj.currentPrice, 3.02) && approx(bj.change, -0.01)
                  && approx(bj.changePercent, -0.33), "北交所：现价/涨跌/涨跌幅")
            check(approx(bj.volumeRatio ?? -1, 0.70) && approx(bj.pbRatio ?? -1, 0.78),
                  "北交所：量比/市净率有值")
            // 这条是 44/45 写反的**判别性断言**：颖泰生物有少量限售股，
            //   流通(36.59) ≠ 总(37.02)。写反时两者会互换 → 这条立刻红。
            //   （茅台/恒瑞/平安都流通≈总，拿它们"交叉验证"是**分辨不出来**的。）
            check(approx(bj.circulationMarketCap ?? -1, 36.59)
                  && approx(bj.marketCap ?? -1, 37.02),
                  "北交所：流通市值 f44=36.59 < 总市值 f45=37.02（写反即红）")
            check(approx(bj.limitUp ?? -1, 3.93) && approx(bj.limitDown ?? -1, 2.13),
                  "北交所：涨停价 3.93 / 跌停价 2.13")
        } else {
            check(false, "北交所：解析缺失 920819")
        }

        // 结构不变量：**流通市值 ≤ 总市值**（流通股 ≤ 总股本）。
        //   这条不需要任何个股知识，也不怕夹具换样本 —— 是 44/45 顺序的通用护栏。
        for (code, q) in batch {
            guard let f = q.circulationMarketCap, let t = q.marketCap, f > 0, t > 0 else { continue }
            check(f <= t, "\(code)：流通市值(\(f)) ≤ 总市值(\(t))")
        }
    }

    // MARK: - 5) 成交量格式（K 线副图右轴刻度与图例：X万 / X亿）

    private static func volumeFormat() {
        check(StockFmt.volumeCompact(21619) == "2.16万", "21619 → 2.16万（原样输出是 21619.00）")
        check(StockFmt.volumeCompact(14823) == "1.48万", "14823 → 1.48万")
        check(StockFmt.volumeCompact(123_456_789) == "1.23亿", "过亿 → 亿档")
        check(StockFmt.volumeCompact(8600) == "8600", "不足 1 万：整数原值")
        check(StockFmt.volume(21619) == "2.16万手", "表内口径（volume）保留「手」后缀，与刻度区分")
    }

    // MARK: - 工具

    private static func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }

    private static func check(_ cond: Bool, _ msg: String) {
        print(cond ? "   ✅ \(msg)" : "   ❌ \(msg)")
        if !cond { failures += 1 }
    }
}