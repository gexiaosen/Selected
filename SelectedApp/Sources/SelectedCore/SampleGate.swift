import Foundation

/// 样本门槛 —— 「样本不足时**不出结论**」的统一判据。
///
/// **为什么做成结构化判据**：调优会给出"最优候选参数"，但结论可信度完全取决于评估池里
/// 有多少只**带标签的样本**。池子只有 7 只时，"这个候选比基线好 3 分"是噪声不是发现 ——
/// 只给一句 `warning` 文案而结论照样摆着，用户看到的就是"调优推荐"。
/// UI 据本判据把结论区换成「样本不足，不出结论」。
///
/// **口径**：`samples` 是"真正参与结论的样本数"，不同调用方含义不同 ——
/// 调优是评估池标的数（`pool_size`），复盘是纪律口径的样本数
/// （`four_layer_winrate.disciplined.total`）。
///
/// 阈值 30 与 `PhaseTune` 的 `<30` 告警**同源**（同一份判据，不再各写一遍）。
public enum SampleGate {

    /// 默认阈值（只）。低于它 → 不出结论
    public static let defaultThreshold = 30

    /// 写进结果 JSON 的那三个键
    public static func json(samples: Int, threshold: Int = defaultThreshold) -> [String: Any] {
        ["sufficient": samples >= threshold, "samples": samples, "threshold": threshold]
    }

    /// 结论是否可信
    public static func sufficient(samples: Int, threshold: Int = defaultThreshold) -> Bool {
        samples >= threshold
    }

    /// 面向用户的说明（UI 与日志共用一份，避免两处措辞漂移）。
    /// 样本充足时返回空串（调用方据此不显示该提示）。
    public static func message(samples: Int, threshold: Int = defaultThreshold) -> String {
        if sufficient(samples: samples, threshold: threshold) { return "" }
        return "样本不足：仅 \(samples) 只（门槛 \(threshold) 只），不出结论 —— 继续积累复盘数据后再调优。"
    }
}
