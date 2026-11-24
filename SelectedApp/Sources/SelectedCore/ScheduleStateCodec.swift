import Foundation

// MARK: - 调度状态的持久化编解码（纯逻辑，可单测）
//
// 为什么单独抽出来：
// "写进去了"和"读回来了"是两件事 —— 编解码任一侧漏一个字段都是静默 bug
// （如 `lastFailureAt` 没读回 → 重启后已失败的任务永不重试，而 UI 仍显示"等待重试"），
// 若都在 `@MainActor` 的 `Scheduler` 里则没有任何测试能碰到。
// 把编解码抽成纯函数后，往返一致性可以直接断言：
// 每个字段都要 `encode → decode` 后与原文相等 —— 少读一个字段就会红。

/// `[String: TaskRuntimeState]` ↔ JSON 友好字典
public enum ScheduleStateCodec {

    // MARK: - 单条

    public static func encode(_ s: TaskRuntimeState) -> [String: Any] {
        var d: [String: Any] = ["status": s.status.rawValue, "attempts": s.attempts]
        if let f = s.lastFailureAt { d["lastFailureAt"] = f.timeIntervalSince1970 }
        if let m = s.message { d["message"] = m }
        if let c = s.changedAt { d["changedAt"] = c.timeIntervalSince1970 }
        return d
    }

    public static func decode(_ d: [String: Any]) -> TaskRuntimeState? {
        guard let raw = d["status"] as? String,
              let status = ScheduleStatus(rawValue: raw) else { return nil }
        return TaskRuntimeState(
            status: status,
            attempts: d["attempts"] as? Int ?? 0,
            // 存时间戳而非 Date：UserDefaults / plist 的 Date 往返依赖编码，
            // 存 Double 更稳且便于比较
            lastFailureAt: (d["lastFailureAt"] as? Double).map { Date(timeIntervalSince1970: $0) },
            message: d["message"] as? String,
            changedAt: (d["changedAt"] as? Double).map { Date(timeIntervalSince1970: $0) })
    }

    // MARK: - 整表

    public static func encodeAll(_ states: [String: TaskRuntimeState]) -> [String: Any] {
        states.mapValues(encode)
    }

    /// 单条解不出来就丢弃那一条（不整体失败）：脏数据不该让整个调度状态表读不回来
    public static func decodeAll(_ payload: [String: Any]) -> [String: TaskRuntimeState] {
        var out: [String: TaskRuntimeState] = [:]
        for (k, v) in payload {
            guard let d = v as? [String: Any], let st = decode(d) else { continue }
            out[k] = st
        }
        return out
    }

    public static func toJSON(_ states: [String: TaskRuntimeState]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: encodeAll(states)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// 返回 `nil` 表示"没有可用存档"（区别于"存档为空表"）
    public static func fromJSON(_ json: String?) -> [String: TaskRuntimeState]? {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return decodeAll(obj)
    }

    // MARK: - 旧版本迁移（两套旧键 → 新状态表）

    /// 旧版本把状态分成两处：`completedTasks_<date>`（已完成 id 列表）与
    /// `retryState_<date>`（retryCounts / failedCounts / failureMessages / lastFailureAt）。
    /// 升级当天若不迁移，**同一天已经跑过的任务会被重跑一遍**。
    public static func migrateLegacy(completed: [String],
                                     retryCounts: [String: Int],
                                     failureMessages: [String: String],
                                     lastFailureAt: [String: Double],
                                     now: Date = Date()) -> [String: TaskRuntimeState] {
        var out: [String: TaskRuntimeState] = [:]
        for id in completed {
            out[id] = TaskRuntimeState(status: .done, attempts: 1, changedAt: now)
        }
        for (id, n) in retryCounts where out[id] == nil {
            out[id] = TaskRuntimeState(
                status: .failed, attempts: n,
                lastFailureAt: lastFailureAt[id].map { Date(timeIntervalSince1970: $0) },
                message: failureMessages[id], changedAt: now)
        }
        return out
    }
}
