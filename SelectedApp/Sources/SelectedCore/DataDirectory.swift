import Foundation

/// 数据目录解析 —— **全项目唯一实现**。
///
/// 存在的理由：解析逻辑若在各文件各抄一份，细微差异必然出现 —— 最要命的是漏掉
/// 空串过滤（`!env.isEmpty`）：`SELECTED_DATA_DIR=""`（外部脚本误导出空变量、
/// IDE 环境配置留空）时，建库落用户数据目录、读写却拼出根目录路径，
/// 表现就是"页面全空且无报错"的隐形错位。
///
/// 只有一份实现，**必然一致**；要改解析规则也只改这里。
public enum DataDirectory {

    /// 解析规则（优先级）：
    /// 1. 环境变量 `SELECTED_DATA_DIR`（**空串视为未设置**）
    /// 2. 打包模式（App 内带 `engine/params/param_schema_export.json`）→ 用户数据目录
    /// 3. 开发模式（`<cwd>/data/selected.sqlite3` 或 `<cwd>/../data/…` 存在）→ 工程内 `data/`
    /// 4. 兜底 → 用户数据目录
    ///
    /// ⚠ 绝不能在持锁状态下调用本方法（各 Store 的 `open()` 内部会拿自己的 NSLock，
    ///   NSLock 不可重入，会自我死锁）。
    public static func resolve() -> String {
        if let env = ProcessInfo.processInfo.environment["SELECTED_DATA_DIR"], !env.isEmpty {
            return env
        }
        if let r = Bundle.main.resourceURL,
           FileManager.default.fileExists(
               atPath: r.appendingPathComponent("engine/params/param_schema_export.json").path) {
            return NSHomeDirectory() + "/Library/Application Support/Selected"
        }
        // 开发模式探测：直接看盘符，不依赖任何 Store（避免初始化循环依赖）
        let cwd = FileManager.default.currentDirectoryPath
        for base in [cwd, (cwd as NSString).deletingLastPathComponent] {
            if FileManager.default.fileExists(atPath: base + "/data/selected.sqlite3") {
                return base + "/data"
            }
        }
        return NSHomeDirectory() + "/Library/Application Support/Selected"
    }

    /// 数据目录 + 库文件名
    public static var databasePath: String { resolve() + "/selected.sqlite3" }
}

// ⚠ 注意：本文件必须保持**零依赖**（只依赖 Foundation）。
//
// 各测试脚本（`SelectedApp/Tools/*.sh`）为了让测试自包含，只 `swiftc` 编译所需的
// 那几个源文件 —— `DataDirectory.swift` 被加进了这些子集清单，所以它**不能**引用
// 任何 Store 单例（`SQLiteReader` / `PhaseStore` / … 在子集里根本不存在，会直接编译失败）。
// 因此"换库后把所有连接一起失效"这类**跨层编排**不放在这里，而是放在
// `Store.invalidateAllDataConnections()`（Store.swift 只进 App 全量编译，不进任何子集）。
