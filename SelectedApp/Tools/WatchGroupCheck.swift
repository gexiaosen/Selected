import Foundation
@testable import SelectedCore

/// 「复制到分组」的分组归属自检（Swift 侧）
///
/// **为什么是自检**：归属表 `watch_group_members` 是 **Swift-only** 的 ——
/// `copy` / `moveWithin` 这两个动作没有另一侧实现可比。
/// 而"一只股票可以同时在多个分组"正是它的核心不变量 ⇒ 必须有自己的断言。
///
/// 跑法：`SELECTED_DATA_DIR=<空目录> WatchGroupCheck`
/// 库由 `DBBootstrap.ensureReady()` **现造**（与真实 App 同构）；
///   **必须给一个空目录**，否则上一轮的残留数据会污染断言。
@main
struct WatchGroupCheck {
    static var failures = 0

    static func check(_ cond: Bool, _ what: String) {
        if cond { print("   ✅ \(what)") }
        else { print("   ❌ \(what)"); failures += 1 }
    }

    /// 断言某只票的归属**恰好**是给定的集合（报错时把两边都打出来，能一眼看出差在哪）。
    static func checkGroups(_ ws: WatchStore, _ code: String, _ want: [Int], _ what: String) {
        let got = ws.groups(of: code)
        if got == want.sorted() { print("   ✅ \(what)（\(got)）") }
        else {
            print("   ❌ \(what)：期望 \(want.sorted())，实际 \(got)")
            failures += 1
        }
    }

    /// 该票在 `watchlist` 里的**主分组**（`group_id` 列）—— 应为归属里最小的那个。
    static func primaryGroup(_ ws: WatchStore, _ code: String) -> Int? {
        ws.watchItems()
            .first { ($0["code"] as? String) == code }
            .flatMap { ($0["group_id"] as? NSNumber)?.intValue }
    }

    static func main() {
        if let e = DBBootstrap.ensureReady() {
            print("❌ ensureReady 失败：\(e)")
            exit(2)
        }
        let ws = WatchStore.shared

        // ── 准备：默认组 + 两个新分组 + 一只票 ──
        _ = try? ws.groupAdd(name: "甲组")
        _ = try? ws.groupAdd(name: "乙组")
        let gids = ws.groupRows().compactMap { ($0["id"] as? NSNumber)?.intValue }
        guard gids.count >= 3 else {
            print("❌ 分组没建起来（只有 \(gids)）")
            exit(2)
        }
        let def = gids[0], a = gids[1], b = gids[2]
        print("分组：默认=\(def) 甲=\(a) 乙=\(b)")

        _ = try? ws.add(code: "600000", name: "浦发银行", group: def)
        checkGroups(ws, "600000", [def], "① add 之后归属 = {默认组}")

        // ── ② copyTo：加一份归属，原来那份保留 ──
        _ = try? ws.copyTo(code: "600000", group: a)
        checkGroups(ws, "600000", [def, a], "② copyTo 甲组 → 同时在默认组与甲组")

        // ── ③ 主分组仍是最小的那个 ──
        check(primaryGroup(ws, "600000") == min(def, a),
              "③ 主分组 = 归属里最小的（`watchlist.group_id`，对账读这列）")

        // ── ④从**默认组**移动 = 只加不减（默认组是"所有分组去重总量"）──
        _ = try? ws.moveWithin(code: "600000", from: def, to: b)
        checkGroups(ws, "600000", [def, a, b], "④ moveWithin(默认→乙)：默认组**不移出**、甲组保留")

        // ── ④b 从**非默认组**移动 = 正常组内操作（旧语义不变）──
        _ = try? ws.moveWithin(code: "600000", from: a, to: b)
        checkGroups(ws, "600000", [def, b], "④b moveWithin(甲→乙)：甲组移出、乙组去重")

        // ── ⑤ 幂等：from == to 不改动 ──
        _ = try? ws.moveWithin(code: "600000", from: b, to: b)
        checkGroups(ws, "600000", [def, b], "⑤ moveWithin(from == to) 幂等")

        // ── ⑥迁移**不能**把多归属重置回单归属 ──
        //   这是最容易写错的一条：`backfillWatchGroupMembers` 的 `NOT EXISTS` 条件
        //   一旦漏掉，每次启动都会把用户"复制"出来的分组**静默清掉**（表现为"复制了但没了"）。
        if let e = DBBootstrap.ensureReady() {
            print("❌ 第二次 ensureReady 失败：\(e)")
            exit(2)
        }
        checkGroups(ws, "600000", [def, b], "⑥ 重跑 ensureReady 后多归属仍在（迁移不重置）")

        // ── ⑦ remove：归属一起清（否则重新加进来会带着幽灵归属）──
        _ = try? ws.remove(code: "600000")
        checkGroups(ws, "600000", [], "⑦ remove 之后归属清空")

        // ── ⑧ groupDelete：多归属的票**不该**被删，单归属的才删 ──
        _ = try? ws.add(code: "600519", name: "贵州茅台", group: def)
        _ = try? ws.copyTo(code: "600519", group: a)
        _ = try? ws.add(code: "000001", name: "平安银行", group: a)   // 只在甲组
        _ = try? ws.groupDelete(id: a)
        let codes = Set(ws.watchItems().compactMap { $0["code"] as? String })
        check(codes.contains("600519"), "⑧a 多归属的票在删组后**仍在自选**")
        checkGroups(ws, "600519", [def], "⑧b 它只失去甲组那一条归属")
        check(!codes.contains("000001"), "⑧c 只属于甲组的票被一并删除")

        // ── ⑨ 删组后主分组回落到剩下的那个 ──
        check(primaryGroup(ws, "600519") == def, "⑨ 主分组回落到默认组")

        // ── ⑩ 删组 A（A < B 且不含默认组）：多分组同步主归属，独属票级联清提醒 ──
        _ = try? ws.groupAdd(name: "丙组")
        _ = try? ws.groupAdd(name: "丁组")
        let allGroups = ws.groupRows()
        let cOpt = allGroups.first { ($0["name"] as? String) == "丙组" }.flatMap { ($0["id"] as? NSNumber)?.intValue }
        let dOpt = allGroups.first { ($0["name"] as? String) == "丁组" }.flatMap { ($0["id"] as? NSNumber)?.intValue }
        guard let c = cOpt, let d = dOpt, c < d else {
            print("❌ 无法定位 丙组/丁组：\(allGroups)")
            exit(2)
        }
        _ = try? ws.add(code: "601318", name: "中国平安", group: c)
        _ = try? ws.copyTo(code: "601318", group: d)
        _ = try? ws.add(code: "000002", name: "万科A", group: c)
        _ = try? AlertStore.save(
            code: "601318",
            drafts: [AlertDraft(kind: .upPrice, threshold: 50.0, repeatMode: .daily)],
            window: .open,
            at: "2026-11-12 09:30:00")
        _ = try? AlertStore.save(
            code: "000002",
            drafts: [AlertDraft(kind: .downPrice, threshold: 8.5, repeatMode: .once)],
            window: .open,
            at: "2026-11-12 09:30:00")
        check(primaryGroup(ws, "601318") == c, "⑩a 删除前 601318 主分组 = 较小非默认组 丙(\(c))")
        let delErr = (try? ws.groupDelete(id: c)) ?? "error"
        check(delErr.isEmpty, "⑩b groupDelete(丙) 成功")
        checkGroups(ws, "601318", [d], "⑩c 601318 归属仅剩 丁(\(d))")
        check(primaryGroup(ws, "601318") == d, "⑩d 删较小主组后 watchlist.group_id 同步迁至 丁(\(d))")
        check(AlertStore.rules(code: "601318").count == 1, "⑩e 多分组成员留存时提醒规则保留")
        let codesAfter = Set(ws.watchItems().compactMap { $0["code"] as? String })
        check(!codesAfter.contains("000002"), "⑩f 独属丙组的 000002 从 watchlist 删除")
        check(AlertStore.rules(code: "000002").isEmpty, "⑩g 独属丙组的 000002 关联 watch_alerts 同步删除")
        check(AlertStore.windowsByCode()["000002"] == nil, "⑩h 独属丙组的 000002 关联 watch_alert_settings 同步删除")

        // ── ⑪ WatchStore.remove 同事务清提醒 ──
        _ = try? ws.remove(code: "601318")
        check(AlertStore.rules(code: "601318").isEmpty, "⑪a WatchStore.remove 同步清 watch_alerts")
        check(AlertStore.windowsByCode()["601318"] == nil, "⑪b WatchStore.remove 同步清 watch_alert_settings")

        // ── ⑫ DBBootstrap.ensureReady 启动清理孤儿提醒 ──
        _ = try? AlertStore.save(
            code: "999999",
            drafts: [AlertDraft(kind: .upPrice, threshold: 99.0, repeatMode: .once)],
            window: .open,
            at: "2026-11-12 10:00:00")
        check(AlertStore.rules(code: "999999").count == 1, "⑫a 人工构造非自选孤儿提醒规则 1 条")
        check(DBBootstrap.ensureReady() == nil, "⑫b 重跑 ensureReady 成功")
        check(AlertStore.rules(code: "999999").isEmpty, "⑫c ensureReady 清理孤儿 watch_alerts")
        check(AlertStore.windowsByCode()["999999"] == nil, "⑫d ensureReady 清理孤儿 watch_alert_settings")

        print(failures == 0
              ? "✅ 全部通过（分组归属：复制 / 组内移动 / 迁移幂等 / 删组 / 主归属同步 / 提醒清理）"
              : "❌ \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
