import XCTest
@testable import SelectedCore

/// `ScheduleCatalog`（任务注册表）的回归锁。
///
/// ## 为什么要有这个文件（2026-10-16 审查 B8-2 第一片）
/// 这张表是从**两份手写表**里抽出来的：`ScheduleTimes.defaults`（key/label/时刻，设置页用）
/// 与 `Scheduler.taskTemplates`（id/label/args/notifyTitle，通知文案用）。
/// 抽取本身不改任何对外可见的东西 ⇒ 那么"没改坏"就必须有东西钉住，否则一次"顺手整理"
/// 就能悄悄把某个任务的出厂时刻挪 10 分钟、或把通知标题写错 —— 两者都不会编译报错。
///
/// ⚠ 下面这些期望值是**手抄的旧字符串**，这是刻意的：唯一来源已经变成注册表，
///   而测试要钉的就是"抽表前后逐字相同"。改了注册表**应当**让这里变红，逼改的人确认。
final class ScheduleCatalogTests: XCTestCase {

    func testIdsAreUnique() {
        let ids = ScheduleCatalog.ids
        XCTAssertEqual(Set(ids).count, ids.count, "任务 id 重复会让状态字典互相覆盖")
    }

    func testLabelsAreNonEmpty() {
        for t in ScheduleCatalog.tasks {
            XCTAssertFalse(t.label.isEmpty, "\(t.id) 的展示名是空的 —— 设置页会出现一格空白")
        }
    }

    /// 注册表必须覆盖**所有轮次键**（漏一轮 = 那一轮根本不排，且无报错）
    func testCoversEveryRound() {
        for k in RoundPlan.roundKeys {
            XCTAssertNotNil(ScheduleCatalog.task(k), "注册表里没有 \(k) —— 加轮次时这里要一起登记")
        }
    }

    /// **出厂时刻升序**：`ScheduleTimes.defaults` 直接拿本表当默认表，
    /// 而设置页的稳定排序假定"声明序 ≈ 时间序"（同刻靠声明序定先后）。
    /// ⚠ 末轮与 `watch` 默认**同为 14:50** —— 这条断言同时钉住"末轮排在 watch 前面"，
    ///   换过来会让这两格在设置页反复换位，用户以为自己的设置被改了。
    func testDeclaredInAscendingTimeOrder() {
        let mins = ScheduleCatalog.tasks.map(\.minuteOfDay)
        XCTAssertEqual(mins, mins.sorted(), "注册表声明序必须是出厂时刻升序")
        if let lastRound = RoundPlan.slots.last,
           let ri = ScheduleCatalog.tasks.firstIndex(where: { $0.id == RoundPlan.roundKey(lastRound) }),
           let wi = ScheduleCatalog.tasks.firstIndex(where: { $0.id == "watch" }) {
            XCTAssertEqual(ScheduleCatalog.tasks[ri].minuteOfDay, ScheduleCatalog.tasks[wi].minuteOfDay,
                           "末轮与全量判定默认同刻（自选判定用的就是那一轮行情）")
            XCTAssertLessThan(ri, wi, "同刻时末轮必须排在 watch 之前（稳定排序的并列次序）")
        }
    }

    /// 通知标题 = label + 后缀。这些串是抽表时的**基线**（从 `git show HEAD:Scheduler.swift`
    /// 的旧表逐条抄回，不是照抄新实现 —— 照抄的话本条会"自己证明自己没错"：
    /// 第一版就是这样漏掉了 `iterate`）。
    ///
    /// ⚠ 13 条与旧表逐字相同；唯一**故意**不同的是 `iterate`：旧串「迭代报告就绪」比
    ///   `label + 后缀` 少两字，2026-10-16 经用户确认统一成派生形态 ⇒「三天迭代报告就绪」。
    ///   改这里任何一条前先分清：是"注册表写错了"，还是"用户看得见的字要变"。
    func testNotifyTitlesFollowTheSingleDerivation() {
        let expected: [String: String] = [
            "predict": "早盘预判就绪",
            "verify": "盘中验证完成",
            "round1": "第一轮选股完成",
            "round2": "第二轮选股完成",
            "round3": "第三轮选股完成",
            "compare": "三轮对比报告就绪",
            "review": "收盘复盘完成",
            "fundflow": "资金流向已入库",
            "watch": "全量判定完成",
            "iterate": "三天迭代报告就绪",
            "lhb": "龙虎榜已入库",
            "limitup": "涨停统计已入库",
            "boardheat": "板块热度已入库",
            "indsnap": "指标快照已入库",
        ]
        for (id, title) in expected {
            XCTAssertEqual(ScheduleCatalog.task(id)?.notifyTitle, title,
                           "\(id) 的完成通知标题变了（后缀含义见 NotifySuffix 注释）")
        }
        // 反向：注册表里不许有**没被钉住**的任务 —— 新增任务时必须同时在这里登记
        XCTAssertEqual(Set(ScheduleCatalog.ids), Set(expected.keys),
                       "注册表与这张标题期望表的任务集合不一致")
    }

    /// 钉住「标题只有一条派生规则」：任何任务只要 `label + suffix` 拼不出自己的标题，
    /// 就说明有人想加特例 —— 那是措辞决定，应当先摆到台面上，而不是悄悄加字段。
    func testNotifyTitleHasNoPerTaskExceptions() {
        for t in ScheduleCatalog.tasks {
            XCTAssertEqual(t.notifyTitle, t.label + t.suffix.rawValue,
                           "\(t.id) 的通知标题不再等于 label + 后缀（覆写通道已拆）")
        }
    }

    /// 出厂默认时刻（B8-2 抽表前后逐项核对过；改任何一个都要先回答"排它后面那个会不会抢 runningTask"）
    func testDefaultTimes() {
        let got = Dictionary(uniqueKeysWithValues: ScheduleCatalog.tasks.map { ($0.id, $0.minuteOfDay) })
        let want: [String: Int] = [
            "predict": 570,      // 09:30
            "verify": 600,       // 10:00
            "round1": 840,       // 14:00（与 RoundPlan 同源）
            "round2": 870,       // 14:30
            "round3": 890,       // 14:50
            "watch": 890,        // 14:50 —— 与末轮同刻，靠稳定排序定先后
            "compare": 902,      // 15:02
            "review": 905,       // 15:05
            "boardheat": 910,    // 15:10
            "limitup": 915,      // 15:15
            "indsnap": 925,      // 15:25
            "iterate": 930,      // 15:30
            "fundflow": 965,     // 16:05（实测发布时刻 16:02~16:04，120s×3 预算要从 16:05 起算）
            "lhb": 1050,         // 17:30 —— 交易所发布延迟的估计值
        ]
        XCTAssertEqual(got, want)
    }

    /// `RoundPlan` 的轮次时刻改动必须**同时**反映到注册表（那几行是从 plan 派生的，不该漂移）
    func testRoundTimesFollowRoundPlan() {
        for slot in RoundPlan.plan {
            let t = ScheduleCatalog.task(RoundPlan.roundKey(slot.num))
            XCTAssertEqual(t?.hour, slot.hour)
            XCTAssertEqual(t?.minute, slot.minute)
            XCTAssertEqual(t?.suffix, .done)
        }
    }

    // MARK: 展示顺序（调度圆点行）

    /// `displayOrder` 必须是注册表的**全排列**（不重不漏）。
    /// ⚠ 漏一个的表现：那个任务注册了、`execute` 也认得，却**永远不排、界面上连一格圆点都没有**；
    ///   原先那份实现靠 `compactMap` 静默丢弃 ⇒ 这正是 B8-2 要拆掉的坑，所以把它做成断言。
    func testDisplayOrderCoversEveryTaskExactlyOnce() {
        XCTAssertEqual(Set(ScheduleCatalog.displayOrder), Set(ScheduleCatalog.ids),
                       "展示顺序表与注册表的任务集合不一致")
        XCTAssertEqual(ScheduleCatalog.displayOrder.count, ScheduleCatalog.ids.count,
                       "展示顺序表里有重复 id")
        XCTAssertEqual(ScheduleCatalog.tasksInDisplayOrder.count, ScheduleCatalog.tasks.count,
                       "有任务在 displayOrder 里找不到对应注册行（被 compactMap 丢了）")
    }

    /// 圆点行 / 菜单栏「调度任务」是**当时间线读的** ⇒ 展示顺序必须时刻单调不减。
    /// ⚠ 这里断言的是**不变式**而不是某份写死的名单：名单式断言每调一次出厂时刻都要跟着改，
    ///   迟早又漂一回（2026-11-05 资金流 16:00→16:05 时，旧名单正就是这么把 16:05 留在 14:50 前头）。
    func testDisplayOrderIsChronological() {
        let mins = ScheduleCatalog.tasksInDisplayOrder.map(\.minuteOfDay)
        XCTAssertEqual(mins, mins.sorted(), "展示顺序不是时刻升序（圆点行会读成乱序时间线）")
    }

    /// 同刻两项（`round3` 与 `watch` 都是 14:50）的先后**必须稳定**：
    /// 表现是这两格反复换位，用户以为自己的设置被改了 ⇒ 靠 `tasks` 原序兜底，不靠字典序。
    func testSameMinuteTieIsStable() {
        let ids = ScheduleCatalog.displayOrder
        guard let r = ids.firstIndex(of: "round3"), let w = ids.firstIndex(of: "watch") else {
            return XCTFail("round3 / watch 不在展示顺序里")
        }
        XCTAssertEqual(ScheduleCatalog.task("round3")?.minuteOfDay,
                       ScheduleCatalog.task("watch")?.minuteOfDay, "前提变了：两者不再同刻，本断言该删")
        XCTAssertLessThan(r, w, "14:50 这两格换位了（稳定排序被破坏）")
    }
}
