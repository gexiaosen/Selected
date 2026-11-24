import XCTest
@testable import SelectedCore

/// ``RoundPlan`` 作为"几轮、各叫什么"的唯一来源。
///
/// ⚠ 为什么钉这条（2026-10-16 审查 B8-1）：轮次槽位与标签原先在 Core 里
/// 有 **8 份独立写法**（4 处 `[1,2,3]` + 4 份 `14:00/14:30/14:50`）。
/// 加第 4 轮时它们不会编译报错，而是静默产出错误结论：
/// `slots.count >= expectedSlots.count` 恒假 ⇒ 所有信号都被判"未持续验证"，
/// 或 `resolveSlot` 返回一个没有标签的槽位（落库 `slot_label` 空串）。
/// 收成一个来源之后，剩下的风险是"某个消费方又偷偷绕过它"，这几条断言守的就是这个。
final class RoundPlanTests: XCTestCase {

    func testSlotsAndLabelsAgree() {
        XCTAssertEqual(RoundPlan.slots, [1, 2, 3])
        XCTAssertEqual(Set(RoundPlan.labels.keys), Set(RoundPlan.slots),
                       "每个槽位都必须有标签；多出来的键说明轮次改了没同步")
        XCTAssertEqual(RoundPlan.count, RoundPlan.slots.count)
    }

    /// 公开入口拿到的必须就是 `RoundPlan` 本身（别名不能被"顺手改回字面量"）
    /// （第三个别名 `PhaseOps.slotLabels` 随「源系统导入」一起删除，2026-10-27）
    func testConsumersShareOneSource() {
        XCTAssertEqual(SignalClassifier.expectedSlots, RoundPlan.slots)
        XCTAssertEqual(ScanRunner.slotLabels, RoundPlan.labels)
    }

    /// `resolveSlot` 的三个出口标签 = `RoundPlan.labels`
    func testResolveSlotLabelsComeFromRoundPlan() {
        // 边界 14:15 / 14:40（当日分钟数）
        func labelAt(_ minute: Int) -> String {
            let day = ChinaTime.calendar.date(from: DateComponents(year: 2026, month: 1, day: 15,
                                                                   hour: minute / 60, minute: minute % 60))!
            return Screener.resolveSlot(now: day, bounds: [855, 880]).label
        }
        XCTAssertEqual(labelAt(14 * 60), RoundPlan.label(of: 1))
        XCTAssertEqual(labelAt(14 * 60 + 20), RoundPlan.label(of: 2))
        XCTAssertEqual(labelAt(14 * 60 + 45), RoundPlan.label(of: 3))
    }

    /// 缺轮判定：按 `slots` 顺序返回，未知槽位不会混进来
    func testMissingKeepsPlanOrder() {
        XCTAssertEqual(RoundPlan.missing([2]), [1, 3])
        XCTAssertEqual(RoundPlan.missing([1, 2, 3]), [])
    }

    /// 任务键 / 默认时刻同样出自 `plan` 这一张表（第二片收的就是这两处）
    func testKeysAndTimesDeriveFromPlan() {
        XCTAssertEqual(RoundPlan.roundKeys, ["round1", "round2", "round3"])
        XCTAssertEqual(RoundPlan.roundKeys, RoundPlan.slots.map(RoundPlan.roundKey))
        XCTAssertEqual(RoundPlan.plan.map { $0.hour * 60 + $0.minute }, [840, 870, 890],
                       "默认时刻 14:00 / 14:30 / 14:50 —— 这张真值表改了，调度默认、标签、边界一起跟着变")
    }

    /// ⚠ 这几条钉的是**用户看得见的字**：轮次派生不能顺手把「三轮」改成「3 轮」、
    /// 把「第一轮」改成「第 1 轮」。改轮数时文案要跟着变，但**轮数不变时必须逐字相同**。
    func testDerivedTextIsByteIdenticalToTheOldLiterals() {
        XCTAssertEqual(RoundPlan.cn(1), "一")
        XCTAssertEqual(RoundPlan.cn(3), "三")
        XCTAssertEqual(RoundPlan.cn(11), "11", "超出汉字表要回落阿拉伯数字，不能越界崩溃")
        XCTAssertEqual(RoundPlan.cn(-1), "-1")
        XCTAssertEqual(RoundPlan.ordinal(1), "第一轮")
        XCTAssertEqual(RoundPlan.ordinal(3), "第三轮")
        XCTAssertEqual(RoundPlan.label(of: 1), "14:00")
        XCTAssertEqual(RoundPlan.label(of: 3), "14:50")
        XCTAssertEqual(RoundPlan.label(of: 9), "", "未知槽位 → 空串（与原 slotLabels[x] ?? \"\" 一致）")
    }

    /// 轮次任务键的判据是集合，不是前缀 —— `hasPrefix("round")` 会把不相干的键也认成轮次
    func testIsRoundUsesThePlanNotAPrefix() {
        XCTAssertTrue(RoundPlan.isRound(key: "round1"))
        XCTAssertTrue(RoundPlan.isRound(key: "round3"))
        XCTAssertFalse(RoundPlan.isRound(key: "round4"), "不在 plan 里的轮次不是合法任务键")
        XCTAssertFalse(RoundPlan.isRound(key: "rounds"))
        XCTAssertFalse(RoundPlan.isRound(key: "compare"))
    }

    /// `slots` 必须是 `1...count` 连续升序：`roundKey`（按 num 寻址）与
    /// `resolved(atOrdinal:)`（按下标寻址）两套出口必须等价，
    /// 否则"第三轮"和 `round3` 可能指到不同的轮。
    func testPlanIsContiguousAscendingFromOne() {
        XCTAssertEqual(RoundPlan.slots, Array(1...RoundPlan.count))
        XCTAssertEqual(RoundPlan.plan.map(\.num), RoundPlan.slots)
    }

    // MARK: 源码层防线：`Sources/` 里不许再出现 `"roundN"` 字面量

    /// ⚠ 这条是"收成单一来源"之后**必须**配的一条 —— 否则收敛只是姿态，
    ///   下一处 `case "round4"` 会悄悄长回来，而悬空键的后果**全是静默的**：
    ///   · `ScheduleTimes.clock("round9")` → `"—"`（文案里的时刻凭空变成破折号）
    ///   · `RoundPlan.isRound(key: "round9")` → false（通知点了不跳转 / 扫描分支根本不进）
    ///   · `entries` 里没这个 key → `update(key:)` 直接 `return nil`（改了个不存在的任务，还报"成功"）
    ///
    ///   B8-1 第二片收完之后，`Sources/` 里已经**一处都不剩**（注释里的举例不算 —— 扫之前先剥注释），
    ///   所以判据从"不许出现 plan 之外的键"收紧成"**一处都不许写**"：
    ///   要轮次键就 `RoundPlan.roundKey(_:)` / `roundKeys`，别的手都进不来。
    ///
    ///   ⚠ **空转防护走自证**，不靠"Sources 里必须扫到点东西"（那与"已经清零"的真实状态冲突）。
    ///   拿**本测试文件自己的文本**当已知有命中的样本反扫：扫不出来 = 正则或剥注释漂了，
    ///   此时第②步的"零命中"就是假绿 —— 先让第①步报红。
    func testNoRoundKeyLiteralsInSources() throws {
        // ① 扫描器自证（本文件 `testIsRoundUsesThePlanNotAPrefix` 里有 3 处真实字面量）
        let selfText = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        let mine = roundKeyLiterals(in: selfText)
        XCTAssertGreaterThanOrEqual(mine.count, 3,
                                    "扫描器在**已知有 `\"roundN\"` 的本文件**上只扫到 \(mine.count) 处 → "
                                    + "正则/剥注释漂了，下面的零命中断言会是假绿")

        // ② 真判据
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()   // .../Tests
            .deletingLastPathComponent()                               // .../SelectedApp
            .appendingPathComponent("Sources", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sources.path) else {
            return XCTFail("源码根目录不存在：\(sources.path)（路径漂了 → 本条会静默失效）")
        }
        let files = walkSwift(sources)
        XCTAssertGreaterThan(files.count, 50,
                             "只扫到 \(files.count) 个 .swift —— 目录结构漂了，本条已空转")
        var hits: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for h in roundKeyLiterals(in: text) {
                hits.append("\(file.lastPathComponent)  \(h)")
            }
        }
        XCTAssertTrue(hits.isEmpty,
                      "`Sources/` 里又写死了轮次键（应改走 `RoundPlan.roundKey` / `roundKeys`）：\n"
                      + hits.joined(separator: "\n"))
    }

    /// 剥注释后扫 `"roundN"` 字面量，返回命中内容（含引号，便于肉眼定位）
    private func roundKeyLiterals(in text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "\"round[0-9]+\"")
        var out: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = stripComment(raw)
            for m in pattern.matches(in: line, range: NSRange(location: 0, length: line.utf16.count)) {
                out.append((line as NSString).substring(with: m.range))
            }
        }
        return out
    }

    /// 递归收集 `Sources/` 下的 `.swift`（跳过隐藏/派生目录）
    private func walkSwift(_ dir: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return en.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    /// 去掉行内注释（只认"整行注释"与"代码后跟 `//`"两种；`https://` 里的 `//` 前面是 `:`，不切）
    private func stripComment(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { return "" }
        var idx = line.startIndex
        while let r = line.range(of: "//", range: idx..<line.endIndex) {
            let before = line.index(before: r.lowerBound)
            if line[before] != ":" { return String(line[..<r.lowerBound]) }
            idx = r.upperBound
        }
        return line
    }
}
