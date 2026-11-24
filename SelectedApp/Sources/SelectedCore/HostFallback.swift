import Foundation

/// **同族 host 降级链**。
///
/// ## 为什么需要（真实请求验过的证据）
/// 逐个 host 连打 3 次（带完整 UA + Referer）：
///
/// | host | 路径 | 结果 |
/// |---|---|---|
/// | `push2.eastmoney.com` | `/api/qt/clist/get` | **HTTP 000（连接失败）×3** |
/// | `push2ex.eastmoney.com` | `/api/qt/clist/get` | HTTP 404 ×3（**该路径在 push2ex 上不存在**） |
/// | `push2ex.eastmoney.com` | `/getTopicZTPool` | **HTTP 200** ✅ |
/// | `datacenter-web.eastmoney.com` | 根 | HTTP 200 ✅
///
/// ⇒ `push2` 可能整体不可用，而它承担**基本面**（`FundamentalSource`）与
/// **板块热度**（`BoardHeatSource`）两个数据集 —— 源一挂，这两个功能静默返回空。
///
/// ## 本类型解决什么
/// 给出**一组候选 host**，按序尝试，第一个拿到**非空响应**的胜出。
/// **刻意只做同族降级**（`push2` → `push2ex`），不做跨源降级
/// （东财 → 新浪）—— 跨源的字段口径不同，换过去要重写映射，
/// 那是「另一个源」而不是「一个源的备用地址」，出错时反而更难判断。
///
/// ## 为什么不是「只加个 fallback host 常量」
/// 因为**同族内不同路径的可用性也不同**（`push2ex` 上 `getTopicZTPool` 有、
/// `clist` 没有）⇒ 降级必须由**调用方按路径自己声明候选**，
/// 不能在端点层做一个"全局替换"。
public enum HostFallback {

    /// 一次尝试的结果。
    public struct Attempt {
        /// 胜出的 host（`nil` = 全部候选都失败）。
        public let host: String?
        /// 全部候选的失败描述（`host → 原因`），用于**留痕**。
        public let tried: [(host: String, reason: String)]
        /// 走了几个候选才成功（1 = 首选就成；n = 第 n 个才成；= count 则全败）。
        public let attemptCount: Int
    }

    /// 按候选顺序尝试，第一个 `probe` 返回**非 nil** 的胜出。
    ///
    /// - Parameters:
    ///   - candidates: 候选 host，**首选在前**（通常是当前代码里写死的那个）。
    ///   - probe: 对某个 host 发起请求并返回结果；**返回 nil 表示"这个 host 不行，换下一个"**
    ///            （抛错与返回 nil 等价，都换下一个 —— 调用点通常已经 `try?` 了）。
    /// - Returns: 胜出的 host 与全部尝试记录。
    ///
    /// ⚠ **只探测"能不能拿到数据"，不探测"数据对不对"** ——
    ///   跨 host 的解析口径本应一致（同族），若解析失败那是代码问题不是 host 问题，
    ///   在这里重试只会掩盖它。
    public static func firstWorking(
        candidates: [String],
        probe: (String) async throws -> Data?
    ) async -> Attempt {
        var tried: [(host: String, reason: String)] = []
        for (i, host) in candidates.enumerated() {
            do {
                if let data = try await probe(host), !data.isEmpty {
                    return Attempt(host: host, tried: tried, attemptCount: i + 1)
                }
                tried.append((host, "空响应"))
            } catch {
                tried.append((host, String(describing: error)))
            }
        }
        return Attempt(host: nil, tried: tried, attemptCount: candidates.count)
    }

    /// 把尝试记录拼成一条适合写 `data_source_logs.detail` 的字符串。
    ///
    /// ⚠ **刻意写全部候选的结果**（而不只是最后一个）—— 数据源故障时
    /// 「几个 host 各自怎么失败的」是定位问题的第一手信息，只留最后一条等于把这个信息扔掉。
    public static func describe(_ a: Attempt) -> String {
        let detail = a.tried.map { "\($0.host) → \($0.reason)" }.joined(separator: "；")
        guard a.host == nil else {
            return "降级成功（第 \(a.attemptCount) 个 host：\(a.host!)，此前 \(detail)）"
        }
        return "全部候选 host 均失败（\(detail)）"
    }
}
