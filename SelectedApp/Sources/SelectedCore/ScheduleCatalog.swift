import Foundation

/// **可调度任务的注册表**：有哪些任务、各叫什么、出厂默认几点、完成通知怎么收尾。
///
/// ## 为什么要有这个文件（2026-10-16 审查 B8-2 第一片）
/// 「有哪些任务、各叫什么」原先在 App 层写了**两份完整表**：
/// · `ScheduleTimes.defaults`（key / label / hour / minute —— 设置页显示的那份）
/// · `Scheduler.taskTemplates`（id / label / args / notifyTitle —— 通知文案用的那一份）
/// 两份都写 label ⇒ 漂了不报错：设置页显示「资金流向」、失败通知里写「资金流」，
/// 用户看到的同一个任务两个名字。
///
/// ⚠ 更要命的是**并集靠手写对齐**：`rebuildTasks` 用 `times.time(of: t.id) ?? return nil`
///   丢弃查不到时刻的模板 ⇒ 往 `taskTemplates` 加了任务、忘了在 `ScheduleTimes` 注册，
///   结果是**这个任务永远不排、界面上连一格圆点都没有**，且没有任何报错。
///   反过来（注册了但没模板）也一样静默。
///
/// ## 收成一处之后的分工
/// · 本文件 = **唯一真值**（id / label / 默认时刻 / 通知后缀 / 展示顺序）
/// · `ScheduleTimes` = 只管「用户改过的时刻」（存 UserDefaults）
/// · `Scheduler` = 只管执行分派，**不再持有任何任务表**
///   （漏登记会走到「任务 \(id) 没有原生实现」那条**显式失败**，不会静默）
public enum ScheduleCatalog {

    /// 完成通知标题的**后缀**（与 `label` 拼成整句：「收盘复盘」+「完成」）。
    ///
    /// ⚠ 四类后缀各有含义，不是随意措辞，**不许收敛成一种**：
    /// · `done` 当日**计算**跑完（盘中验证 / 轮次扫描 / 收盘复盘 / 全量判定）
    /// · `stored` 收盘后**抓取类**已落库（资金流 / 龙虎榜 / 涨停 / 板块 / 指标快照）
    /// · `report` 产出的是**可翻阅的报告**（三轮对比 / 三天迭代）
    /// · `ready` 结果在页面上**等着看**（早盘预判）
    /// 合并会抹掉「数据现在在哪一步」这条用户真正要的信息。
    public enum NotifySuffix: String, Sendable {
        case done = "完成"
        case stored = "已入库"
        case report = "报告就绪"
        case ready = "就绪"
    }

    public struct Task: Sendable, Equatable {
        public let id: String
        public let label: String
        /// **出厂**默认时刻（用户可在设置页改；实际时刻以 `ScheduleTimes` 为准）
        public let hour: Int
        public let minute: Int
        public let suffix: NotifySuffix

        /// 完成通知标题 = `label` + 后缀（**唯一出口，没有例外**）。
        ///
        /// ⚠ 历史上 `iterate` 写的是「迭代报告就绪」，比 `label + 后缀` 少两字；
        ///   2026-10-16 经用户确认统一成派生形态 ⇒ 现在是「三天迭代报告就绪」。
        ///   以后要偏离这条，就得先回答"为什么不统一措辞"，而不是悄悄加一个覆写字段。
        public var notifyTitle: String { label + suffix.rawValue }

        /// 当日分钟数（比较先后用）
        public var minuteOfDay: Int { hour * 60 + minute }

        public init(id: String, label: String, hour: Int, minute: Int, suffix: NotifySuffix) {
            self.id = id
            self.label = label
            self.hour = hour
            self.minute = minute
            self.suffix = suffix
        }
    }

    /// 轮次任务（由 `RoundPlan` 派生，不逐轮手写）
    private static var roundTasks: [Task] {
        RoundPlan.plan.map {
            .init(id: RoundPlan.roundKey($0.num),
                  label: "第\(RoundPlan.cn($0.num))轮选股",
                  hour: $0.hour, minute: $0.minute, suffix: .done)
        }
    }

    /// 注册表 —— **按出厂时刻升序**（`ScheduleTimes.defaults` 直接用它，
    /// 而那份表依赖升序 + 稳定排序来处理"两项同刻"，见 `RoundOrder.sortedByMinuteOfDay`）。
    public static let tasks: [Task] = [
        .init(id: "predict", label: "早盘预判", hour: 9, minute: 30, suffix: .ready),
        .init(id: "verify", label: "盘中验证", hour: 10, minute: 0, suffix: .done),
    ] + roundTasks + [
        // ⚠ 与**末轮**同为 14:50（自选判定用的就是那一轮的行情）→ 展示排序必须**稳定**，
        //   否则这两格会反复换位，用户以为自己的设置被改了。
        .init(id: "watch", label: "全量判定", hour: 14, minute: 50, suffix: .done),
        .init(id: "compare", label: "三轮对比", hour: 15, minute: 2, suffix: .report),
        .init(id: "review", label: "收盘复盘", hour: 15, minute: 5, suffix: .done),
        // 板块热度。⚠ 时点选 15:10 —— 板块涨跌在 15:00 收盘时定稿，排在复盘（15:05）之后、
        //   涨停统计（15:15）之前。与涨停统计同理**不需要**等 17:30（那是龙虎榜的交易所发布延迟，
        //   板块行情是行情自身状态）。
        .init(id: "boardheat", label: "板块热度", hour: 15, minute: 10, suffix: .stored),
        // 涨停统计。⚠ 时点选 15:15 —— 涨停在 15:00 收盘时定稿（14:57 后的集合竞价仍可能炸板），
        //   排在复盘（15:05）之后、指标快照（15:25）之前。
        //   **不需要**像龙虎榜那样等 17:30：那个是交易所的**发布延迟**，而涨停池是**行情自身的状态**（盘中就能取到）。
        .init(id: "limitup", label: "涨停统计", hour: 15, minute: 15, suffix: .stored),
        // 指标快照。⚠ 时点选 15:25 —— 输入是「历史K线缓存 + 今日收盘行情」，必须收盘定稿后
        //   （同板块/涨停的收盘语义）；排在复盘（15:05）之后、迭代（15:30）之前，
        //   单任务串行 ⇒ 不与任何任务抢 `runningTask`。
        .init(id: "indsnap", label: "指标快照", hour: 15, minute: 25, suffix: .stored),
        .init(id: "iterate", label: "三天迭代", hour: 15, minute: 30, suffix: .report),
        // 资金流向。⚠ 时点选 **16:05**（15:20 → 16:00 → 16:05，两步都由实测驱动）：
        //   日期闸门要求「锚点股资金流历史的最新 `opendate` == 今天」，而新浪发布这一行的
        //   实测时刻（成功落库时间，三天连续）：**11-03 16:04:09 / 11-04 16:02:05 / 11-05 16:02:19**。
        //   重试预算是 `retryIntervalSeconds=120 × maxAttempts=3` ⇒ 起点 16:00 的三次尝试只到
        //   **16:04** 就打完，11-03 那天成功时刻 16:04:09 —— 差一秒当天就没数据。
        //   起点挪到 16:05 后覆盖 16:05/16:07/16:09，对实测最晚发布点留 5 分钟余量。
        //   ⚠ 25 分钟补跑窗口在这里**不起作用**：窗口管的是"任务还能不能开始"，
        //     而三次尝试在 16:04 就把 `attempts` 耗尽转 `missed`，窗口远没走完。
        //   仍与复盘/迭代不抢 `runningTask`（单任务串行）；`stock_fund_flows` 没有引擎侧消费者
        //   （只有个股详情页读），晚 5 分钟落地不影响任何判定。
        .init(id: "fundflow", label: "资金流向", hour: 16, minute: 5, suffix: .stored),
        // 龙虎榜。⚠ 时点选 17:30 —— 由交易所在收盘后发布，入库时点**晚于行情收盘**，
        //   排在资金流（16:05）后面是为了"先落当日能落的数据"。
        //   ⚠ 17:30 是**估计值**：`LhbJob` 在"今天还没发布"时会**回看最近几个交易日补漏**，
        //   不会因为估早了就永久丢一天；若需要更晚，改这一个数字即可。
        .init(id: "lhb", label: "龙虎榜", hour: 17, minute: 30, suffix: .stored),
    ]

    public static func task(_ id: String) -> Task? { tasks.first { $0.id == id } }

    public static var ids: [String] { tasks.map(\.id) }

    /// 任务的**展示顺序**（调度圆点行按此排列）。
    ///
    /// ⚠ 与 `tasks` 的**出厂时刻升序**刻意不同：圆点行按功能分组排
    ///   （主链 → 收盘抓取 → 判定 → 迭代 → 榜单）—— **已作废**：那份手工表会随时刻调整悄悄漂歪，
    ///   而圆点行 / 菜单栏「调度任务」是**当时间线读的**，一旦不按时刻排就出现
    ///   "16:05 资金流夹在 15:05 复盘与 14:50 全量判定之间"这种读不通的排布
    ///   （2026-11-05 资金流从 16:00 挪到 16:05 时再次暴露）。
    ///
    /// 现在**按时刻派生**（唯一实现 `RoundOrder.sortedByMinuteOfDay`，同刻按 `tasks` 原序稳定排），
    /// 手工表删除 ⇒ 改任何出厂时刻都不需要再动这里，也不可能"忘了动这里"。
    /// ⚠ 同刻的两项（`round3` 与 `watch` 都是 14:50）顺序靠 `tasks` 的数组序兜住 ——
    ///   表现是"这两格反复换位，用户以为自己的设置被改了"，所以必须稳定、不能靠字典序。
    ///
    /// ⚠ 仍是 `tasks` 的**全排列**（不重不漏），由 `ScheduleCatalogTests` 钉死；
    ///   另外那条测试现在断言的是**时刻单调不减**，不是某个写死的名单 ——
    ///   名单式断言每改一次时刻都要跟着改，迟早又漂一回。
    public static var displayOrder: [String] { tasksInDisplayOrder.map(\.id) }

    /// 按时刻升序的任务行（`Scheduler` 与圆点行都用它，App 层不再持有任何任务表）。
    /// ⚠ 这里排的是**展示顺序**；"下一个待跑任务"仍由 `Scheduler.nextPending` 自己按时刻取，
    ///   两者同源但别把数组序当成调度语义。
    public static var tasksInDisplayOrder: [Task] {
        RoundOrder.sortedByMinuteOfDay(tasks, \.minuteOfDay)
    }
}
