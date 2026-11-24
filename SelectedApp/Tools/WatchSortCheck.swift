import Foundation
@testable import SelectedCore

// MARK: - 自选/持仓表头排序自检
//
// 覆盖（口径全部来自 `SelectedCore/WatchSort.swift` 头部那三条）：
//   ① 升序 / 降序 的值序正确
//   ② **nil 恒沉底**，且升序降序都在最后（不许伪装成"最小值"跑到最前）
//   ③ 同值必须**稳定**（保持原顺序）—— 自选页每 5s 轮询刷新，不稳定就会自己跳行
//   ④ "没判过"的得分（score=0 且无 action）与"判了 0 分"同形 ⇒ 前者沉底
//   ⑤ 成本价/持仓量为 0（库里未填折成 0，不是 nil）⇒ 沉底，不参与"最小成本"
//   ⑥ 回本% 只在**确实亏着**时有值 ⇒ 盈利的行在"回本%"列沉底（与显示「—」一致）
//   ⑦ 排序值与显示值**同一个算式**（`HoldingMetrics`）：盈亏率排序值 == 屏幕上的百分数
//   ⑧ 三态循环 升 → 降 → 取消；点别的列直接从那列的升序开始
//   ⑨ 没排序时**原样返回**（行序 = 库里加入顺序，不许被稳定排序悄悄改写）

private var failures = 0

private func check(_ ok: Bool, _ desc: String) {
    if ok { return }
    failures += 1
    print("  ❌ \(desc)")
}

/// 构造库行（字段缺省 = 库里"没填"的样子）
private func row(_ code: String, action: String = "", score: Int = 0,
                 cost: Double = 0, shares: Double = 0, holding: Bool = false) -> WatchItemRow {
    WatchItemRow(JSONValue([
        "code": code, "name": "股" + code, "group_id": 1,
        "is_holding": holding ? 1 : 0,
        "cost_price": cost, "shares": shares,
        "action": action, "score": score,
    ]))
}

private func quote(_ code: String, price: Double, change: Double = 0, changePct: Double = 0,
                   turnoverRate: Double? = nil, amplitude: Double? = nil,
                   volumeRatio: Double? = nil, volume: Double = 0, turnover: Double = 0) -> StockQuote {
    StockQuote(market: "sh", code: code, name: "股" + code, currentPrice: price,
               previousClose: price, openPrice: price, highPrice: price, lowPrice: price,
               volume: volume, turnover: turnover, change: change, changePercent: changePct,
               turnoverRate: turnoverRate, peRatio: nil, marketCap: nil,
               circulationMarketCap: nil, amplitude: amplitude, volumeRatio: volumeRatio,
               pbRatio: nil, limitUp: nil, limitDown: nil)
}

/// 视图侧的取数方式（自检与真页面走同一条路）
private func sortRows(_ rows: [WatchItemRow], _ key: WatchSortKey, ascending: Bool,
                      quotes: [String: StockQuote]) -> [String] {
    WatchSort.sorted(rows, by: key, ascending: ascending) { ($0, quotes[$0.code]) }.map(\.code)
}

@main
struct WatchSortCheck {
    static func main() {
        // ---- ① ② ③ 现价：值序 / nil 沉底 / 同值稳定 ----
        let rows: [WatchItemRow] = [row("A"), row("B"), row("C"), row("D"), row("E")]
        let quotes: [String: StockQuote] = [
            "A": quote("A", price: 30), "B": quote("B", price: 10),
            "C": quote("C", price: 20), "D": quote("D", price: 10),   // 与 B 同值
            // E 无行情 ⇒ nil
        ]
        check(sortRows(rows, .price, ascending: true, quotes: quotes) == ["B", "D", "C", "A", "E"],
              "现价升序错（应 10,10,20,30,nil 且同值保持原序）："
              + sortRows(rows, .price, ascending: true, quotes: quotes).joined(separator: ","))
        check(sortRows(rows, .price, ascending: false, quotes: quotes) == ["A", "C", "B", "D", "E"],
              "现价降序错（nil 必须仍在最后，不随方向翻到最前）："
              + sortRows(rows, .price, ascending: false, quotes: quotes).joined(separator: ","))

        // ---- ④ 得分：没判过的 0 分不许混进"最低分" ----
        let scored: [WatchItemRow] = [row("A", action: "买入", score: 0), row("B"),
                                      row("C", action: "持有", score: 55), row("D", action: "观察", score: 20)]
        // A 是"判过且 0 分"（该排在最前），B 是"没判过"（该沉底）—— 两枚在库里同为 score=0
        check(sortRows(scored, .score, ascending: true, quotes: [:]) == ["A", "D", "C", "B"],
              "得分升序错（判过的按分排，没判过的沉底）："
              + sortRows(scored, .score, ascending: true, quotes: [:]).joined(separator: ","))

        // ---- ⑤ 成本价/持仓量：库里未填是 0，不是最小值 ----
        let costs: [WatchItemRow] = [row("A", cost: 12.5, shares: 100, holding: true),
                                     row("B", cost: 0, shares: 100, holding: true),
                                     row("C", cost: 8.2, shares: 0, holding: true)]
        check(sortRows(costs, .costPrice, ascending: true, quotes: [:]) == ["C", "A", "B"],
              "成本价升序错（未填成本=0 的必须沉底）："
              + sortRows(costs, .costPrice, ascending: true, quotes: [:]).joined(separator: ","))
        check(sortRows(costs, .shares, ascending: false, quotes: [:]) == ["A", "B", "C"],
              "持仓量降序错（未填=0 的必须沉底）："
              + sortRows(costs, .shares, ascending: false, quotes: [:]).joined(separator: ","))

        // ---- ⑥ 回本% 只在亏损时有值 + ⑦ 与显示同一份算式 ----
        let hq: [String: StockQuote] = ["A": quote("A", price: 10), "B": quote("B", price: 12)]
        let hold: [WatchItemRow] = [row("A", cost: 12, shares: 100, holding: true),   // 亏 → 回本 +20%
                                    row("B", cost: 10, shares: 100, holding: true)]   // 赚 → 无回本
        check(sortRows(hold, .recovery, ascending: true, quotes: hq) == ["A", "B"],
              "回本% 错（盈利的行该列无值，必须沉底）："
              + sortRows(hold, .recovery, ascending: true, quotes: hq).joined(separator: ","))
        let m = HoldingMetrics(cost: 12, shares: 100, price: 10)
        check(abs(m.pnlPct - (-16.666_666_666)) < 1e-6 && abs((m.recovery ?? 0) - 20) < 1e-6,
              "HoldingMetrics 口径漂了（盈亏率/回本% 与视图算式对不上）：pnlPct=\(m.pnlPct) rec=\(String(describing: m.recovery))")
        check(WatchSort.value(row: hold[0], live: hq["A"], key: .pnlPct) == m.pnlPct,
              "排序读的盈亏率与 `HoldingMetrics` 不是同一个值")

        // ---- ⑧ 三态循环 ----
        check(WatchSortState.next(nil, .price) == WatchSortState(key: .price, ascending: true),
              "第一下必须是升序（老板原话：点击表头进行升序）")
        check(WatchSortState.next(WatchSortState(key: .price, ascending: true), .price)
                == WatchSortState(key: .price, ascending: false), "升序再点该转倒序")
        check(WatchSortState.next(WatchSortState(key: .price, ascending: false), .price) == nil,
              "倒序再点该取消")
        check(WatchSortState.next(WatchSortState(key: .price, ascending: false), .score)
                == WatchSortState(key: .score, ascending: true), "换列该从那列的升序重新开始")

        // ---- ⑨ 没排序时原样 ----
        let plain = sortRows(rows, .price, ascending: true, quotes: [:])
        check(plain == ["A", "B", "C", "D", "E"],
              "全 nil 时不许改写行序（稳定排序的兜底）：" + plain.joined(separator: ","))

        // ---- 可排集合不许悄悄长大：判定/名称没有排序键 ----
        check(WatchSortKey.allCases.count == 15,
              "排序键数量变了（现 15：现价+得分+7 行情+5 持仓专有）⇒ 同步核对视图侧 sortKey 与文档")

        if failures == 0 {
            print("✅ 自选/持仓表头排序自检通过")
            exit(0)
        }
        print("❌ 排序自检 \(failures) 项失败")
        exit(1)
    }
}
