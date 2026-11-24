import Foundation

/// 板块行情的**盘中刷新策略**（纯函数，可单测）。
///
/// ## ⚠ 09:00–16:00 **不是**交易时段 —— 别和 `AlertWindow.sessionRanges` 混用
/// 全项目唯一的交易时段定义是 `AlertWindow.sessionRanges = [570...690, 780...900]`
/// （09:30–11:30 / 13:00–15:00）。本窗口**刻意更宽**，理由：
///   · **09:00 起**：集合竞价阶段东财的板块聚合已经有值（用户开盘前就想看）；
///   · **15:00–16:00**：收盘后源还在更新定稿值（`BoardHeatJob` 的 15:10 定稿任务就在这段里）。
/// ⇒ 两者**语义不同**（"什么时候能交易" vs "什么时候有板块数据可取"），因此各自一份定义，
///   各自写清口径；**不要**为了让两边一致去改任何一份（那是把两个概念混成一个）。
public enum BoardRefresh {

    /// 盘中刷新窗口：09:00 起、**16:00 起停**（含午休 —— 快照与是否连续竞价无关）
    /// ⚠ 区间是**闭区间**：`540...959` 表示"09:00 刷到 15:59，16:00 整不再刷"。
    public static let windowMinuteRanges: [ClosedRange<Int>] = [540...959]

    /// App 在前台时的刷新间隔（5 分钟）
    public static let activeInterval: TimeInterval = 300
    /// App 不在前台时的间隔（15 分钟）—— 没人看的时候没必要每 5 分钟打扰源；
    /// 与 `AlertMonitor.pollInterval` 同一取向（不活跃降频）。
    public static let idleInterval: TimeInterval = 900

    /// 某分钟是否在刷新窗口内（`minuteOfDay` = 0..1439）
    public static func inWindow(minuteOfDay m: Int) -> Bool {
        windowMinuteRanges.contains { $0.contains(m) }
    }

    /// 下一轮该等多久；`nil` = 窗口外（不轮询）。
    public static func nextInterval(minuteOfDay: Int, appActive: Bool) -> TimeInterval? {
        guard inWindow(minuteOfDay: minuteOfDay) else { return nil }
        return appActive ? activeInterval : idleInterval
    }
}
