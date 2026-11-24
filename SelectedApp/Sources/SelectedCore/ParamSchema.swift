import Foundation

/// 参数元数据与校验。
///
/// 元数据**不在 Swift 里手抄**：单一事实来源是随包 JSON
/// （`engine/params/param_schema_export.json`），本类读它，实现：
///   · getValue / hasKey（点路径取值，区分「显式 null」与「键缺失」）
///   · applyDiff（diff 深合并到基线）
///   · validate（类型 / 范围 / 区间倒挂 / 长度 / 嵌套必填子键 + 跨参数一致性）
///   · schemaPayload（UI 表单：分组 + 项 + 当前值）
///
/// ⚠ 两处**有意**跳过检查而不是崩溃：`crossChecks` 里区间元素非数值时、
///   `setValue` 的中间节点非字典时。
final public class ParamSchema: @unchecked Sendable {
    public static let shared = ParamSchema()

    /// 参数项元数据（`ParamSchema.allItems` 的元素；App 层参数编辑器直接读它，
    /// 故类型与成员都需要 `public`）
    public struct Item {
        /// 元数据原始字典（原样保留：schema 新增字段会自动流到 schemaPayload）
        public let raw: [String: Any]
        public var key: String { raw["key"] as? String ?? "" }
        public var label: String { raw["label"] as? String ?? "" }
        public var type: String { raw["type"] as? String ?? "" }
        public var tunable: Bool { raw["tunable"] as? Bool ?? false }
        public var optional: Bool { raw["optional"] as? Bool ?? false }
        public var minValue: Any? { Self.nonNull(raw["min"]) }
        public var maxValue: Any? { Self.nonNull(raw["max"]) }
        public var minLen: Any? { Self.nonNull(raw["min_len"]) }
        public var maxLen: Any? { Self.nonNull(raw["max_len"]) }

        /// JSON null 与「键缺失」统一折成 nil
        public static func nonNull(_ v: Any?) -> Any? {
            guard let v = v, !(v is NSNull) else { return nil }
            return v
        }
    }

    /// 参数分组（`ParamSchema.groups` 的元素）
    public struct Group {
        public let raw: [String: Any]
        public let items: [Item]
    }

    private let lock = NSLock()
    private var cached: [String: Any]?
    private var loadTried = false

    private init() {}

    // MARK: - 元数据定位与加载

    /// 随包资源定位：Bundle 资源目录 → 开发模式（cwd 上溯 3 层）。
    /// 与 SQLiteReader/ParamStore 的数据目录解析是两件事：这里找的是**只读资源**。
    public static func resourceCandidates(_ relative: String) -> [String] {
        var out: [String] = []
        if let r = Bundle.main.resourceURL {
            out.append(r.appendingPathComponent(relative).path)
        }
        var base = FileManager.default.currentDirectoryPath
        for _ in 0..<3 {
            out.append(base + "/" + relative)
            base = (base as NSString).deletingLastPathComponent
        }
        return out
    }

    /// 元数据文件（SELECTED_PARAM_SCHEMA 环境变量可覆盖）
    public static func metadataPath() -> String? {
        if let env = ProcessInfo.processInfo.environment["SELECTED_PARAM_SCHEMA"],
           FileManager.default.fileExists(atPath: env) {
            return env
        }
        return resourceCandidates("engine/params/param_schema_export.json")
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    private func load() -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        if loadTried { return cached }
        loadTried = true
        guard let path = Self.metadataPath(),
              let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        cached = obj
        return obj
    }

    /// 元数据可用性：不可用（未随包/损坏）时调用方必须**拒绝保存并报错**（无回落）
    public var isAvailable: Bool { load() != nil }

    public var groups: [Group] {
        guard let raw = load()?["schema_groups"] as? [[String: Any]] else { return [] }
        return raw.map { g in
            Group(raw: g, items: (g["items"] as? [[String: Any]] ?? []).map { Item(raw: $0) })
        }
    }

    public var allItems: [Item] { groups.flatMap(\.items) }

    /// 出厂版本名（`save` 必须拒绝覆盖）
    public var builtinNames: Set<String> {
        Set((load()?["builtin_versions"] as? [String: Any] ?? [:]).keys)
    }

    /// 出厂版本名 → 随包文件名（DB 行缺失时的兜底加载）
    public func builtinFile(_ name: String) -> String? {
        (load()?["builtin_versions"] as? [String: Any])?[name] as? String
    }

    /// 出厂版本**插入序**。补种建行时按此顺序插入：`created_at` 同为整秒，
    /// list_versions 的稳定顺序实际由插入序决定（Swift 的 Set 无序，不能直接遍历 builtinNames）。
    public var builtinOrder: [String] {
        (load()?["builtin_order"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// 出厂默认升级映射
    public var supersededDefaults: [String: String] {
        (load()?["superseded_defaults"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
    }

    /// 出厂默认升级的一次性标记键
    public var migrationFlagKey: String { load()?["migration_flag_key"] as? String ?? "" }

    /// 当前出厂默认版本（激活指针缺失时的兜底）
    public var defaultActive: String { load()?["default_active"] as? String ?? "" }

    public var factoryParams: [String: Any] { load()?["factory_params"] as? [String: Any] ?? [:] }

    /// 该 json 参数的**必填子键**（空 = 无约束）。
    ///
    /// 参数中心用它禁用「删除档位」与「改阈值」——
    /// 删掉或改键名会让 `validate` 报「缺少子键」而保存被拒（固化的是**默认值的键名**）。
    public func requiredSubKeys(_ key: String) -> [String] { requiredJSONKeys[key] ?? [] }

    private var requiredJSONKeys: [String: [String]] {
        guard let raw = load()?["required_json_keys"] as? [String: Any] else { return [:] }
        var out: [String: [String]] = [:]
        for (k, v) in raw { out[k] = (v as? [Any])?.compactMap { $0 as? String } ?? [] }
        return out
    }

    // MARK: - 点路径取值

    public static func getValue(_ params: [String: Any], _ path: String) -> Any? {
        var node: Any = params
        for part in path.split(separator: ".").map(String.init) {
            guard let dict = node as? [String: Any], let next = dict[part] else { return nil }
            node = next
        }
        return Item.nonNull(node)
    }

    /// 键路径是否**存在**（值为 null 也算存在）—— 区分「显式停用」与「压根没写」
    public static func hasKey(_ params: [String: Any], _ path: String) -> Bool {
        let parts = path.split(separator: ".").map(String.init)
        guard let last = parts.last else { return false }
        var node: Any = params
        for part in parts.dropLast() {
            guard let dict = node as? [String: Any], let next = dict[part] else { return false }
            node = next
        }
        return (node as? [String: Any])?.keys.contains(last) ?? false
    }

    /// 按点路径写入值。
    ///
    /// ⚠ 中间节点**不是字典**时**保留原值 + 留痕**，不静默清空：
    /// 若退化成空字典覆盖回去，会把原有子树整块抹掉且无任何报错。
    /// 不抛错是因为为一条畸形 diff 崩掉整个 App 比跳过它更糟；
    /// 畸形 diff 是调用方 bug，本该在写入前被 `validate` 拦住。
    private static func setValue(_ node: inout [String: Any], _ parts: [String], _ value: Any) {
        guard let head = parts.first else { return }
        if parts.count == 1 { node[head] = value; return }
        if let existing = node[head], !(existing is [String: Any]) {
            NSLog("[NOTICE] applyDiff：中间节点不是字典（段 %@），已跳过该 diff 以免抹掉原有子树",
                  head)
            return
        }
        var child = node[head] as? [String: Any] ?? [:]
        setValue(&child, Array(parts.dropFirst()), value)
        node[head] = child
    }

    private static func deepCopy(_ v: Any) -> Any {
        if let d = v as? [String: Any] { return d.mapValues { deepCopy($0) } }
        if let a = v as? [Any] { return a.map { deepCopy($0) } }
        return v
    }

    /// diff（点路径→新值）合并到基线
    public func applyDiff(base: [String: Any], diff: [String: Any]) -> [String: Any] {
        var out = Self.deepCopy(base) as? [String: Any] ?? [:]
        for (k, v) in diff {
            let parts = k.split(separator: ".").map(String.init)
            if parts.isEmpty { continue }
            Self.setValue(&out, parts, v)
        }
        return out
    }

    // MARK: - 类型判定与文案格式化

    public static func isNumber(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) != CFBooleanGetTypeID()
    }

    public static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    public static func dbl(_ v: Any) -> Double? { (v as? NSNumber)?.doubleValue }

    /// `str()` 等价（数值/布尔/文本），用于把上下限/倒挂值嵌进错误文案。
    public static func numStr(_ v: Any) -> String { PyJSON.numStr(v) }

    private static func num(_ params: [String: Any], _ key: String) -> Any? {
        guard let v = getValue(params, key), isNumber(v) else { return nil }
        return v
    }

    private static func pair(_ params: [String: Any], _ key: String) -> [Any]? {
        guard let v = getValue(params, key) as? [Any], v.count == 2 else { return nil }
        return v
    }

    private static func isPairOfNumbers(_ v: Any) -> Bool {
        guard let a = v as? [Any], a.count == 2 else { return false }
        return a.allSatisfy { isNumber($0) }
    }

    private static func isNumberList(_ v: Any) -> Bool {
        guard let a = v as? [Any] else { return false }
        return a.allSatisfy { isNumber($0) }
    }

    private static func isStringList(_ v: Any) -> Bool {
        guard let a = v as? [Any] else { return false }
        return a.allSatisfy { $0 is String }
    }

    // MARK: - 校验

    /// **正则类**参数的 key。
    ///
    /// ⚠ 硬编码清单而不是给 schema 加 `isRegex` 字段：schema 字段集合要与
    ///   `param_schema_export.json` 的结构保持一致。这份清单只有一项、且**只在保存参数时**用。
    public static let regexParamKeys = ["hard_filter.exclude_st_pattern"]

    /// 正则类参数**能不能编译**。返回空数组 = 都能编译。
    ///
    /// ## ⚠ 为什么不并进 `validate`
    ///
    /// `validate` 的规则与导出元数据逐条对应，不夹带额外检查；且非法正则在运行时的
    /// 处置是**有意**降级成"永不匹配"并留痕（见 `ScanRunner.regex` 的注释），
    /// 本函数是保存侧的健壮性检查。
    ///
    /// ## 为什么必须挡在**保存时**
    ///
    /// 非法正则一旦存进去，`ScanRunner.regex` 只会写一条
    /// `data_source_logs(source='params', event='invalid_st_pattern')`；
    /// 而 `DataFreshness.specs` **有意排除**了 `params`（"不是数据源"）
    /// ⇒ 那条日志在**数据源自检里根本不显示** ⇒ 用户永远看不到，
    /// 表现只是"今天选出的票变多 / 含 ST"。
    /// 在保存时挡住 = 用户**当场**知道（本项目纪律：要挡就做成校验错误，别只告警）。
    public static func regexParamErrors(_ params: [String: Any]) -> [String] {
        var errors: [String] = []
        for key in regexParamKeys {
            guard let v = Self.getValue(params, key) as? String, !v.isEmpty else { continue }
            if (try? NSRegularExpression(pattern: v)) == nil {
                errors.append("「\(key)」不是合法正则：\(v)"
                              + "（引擎会退化为「永不匹配」→ ST / 退市排除会「静默失效」）")
            }
        }
        return errors
    }

    public func validate(_ params: [String: Any]) -> [String] {
        var errors: [String] = []
        for it in allItems {
            guard let v = Self.getValue(params, it.key) else {
                // 可选参数的**显式 null** = 本版本停用该项，不是缺失 → 放行；
                // 键不存在（拼错/被删）仍按缺失报错。
                if it.optional, Self.hasKey(params, it.key) { continue }
                errors.append("缺失参数 \(it.label)（\(it.key)）")
                continue
            }
            let lo = it.minValue, hi = it.maxValue
            switch it.type {
            case "int", "float":
                if !Self.isNumber(v) {
                    errors.append("\(it.label) 应为\(it.type == "int" ? "整数" : "数值")")
                } else if let lo = lo, let d = Self.dbl(v), let l = Self.dbl(lo), d < l {
                    errors.append("\(it.label) 低于下限 \(Self.numStr(lo))")
                } else if let hi = hi, let d = Self.dbl(v), let h = Self.dbl(hi), d > h {
                    errors.append("\(it.label) 高于上限 \(Self.numStr(hi))")
                }
            case "bool":
                if !Self.isBool(v) { errors.append("\(it.label) 应为布尔") }
            case "num_pair":
                if !Self.isPairOfNumbers(v) {
                    errors.append("\(it.label) 应为两个数值 [下限, 上限]")
                } else if let arr = v as? [Any] {
                    let a = Self.dbl(arr[0]) ?? 0, b = Self.dbl(arr[1]) ?? 0
                    if a > b {
                        errors.append("\(it.label) 区间倒挂：下限 \(Self.numStr(arr[0])) "
                                      + "大于上限 \(Self.numStr(arr[1]))")
                    } else if let lo = lo, let hi = hi,
                              let l = Self.dbl(lo), let h = Self.dbl(hi), a < l || b > h {
                        errors.append("\(it.label) 超出允许范围 [\(Self.numStr(lo)), \(Self.numStr(hi))]")
                    }
                } else {
                    // ⚠ 不变量：isPairOfNumbers 通过 ⟹ 可转数组。else 分支只是防御，
                    //   不用 `as!`（判断漂移即 trap 且不可 catch）
                    errors.append("\(it.label) 校验通过但无法转数组（内部不一致）")
                }
            case "num_list":
                if !Self.isNumberList(v) {
                    errors.append("\(it.label) 应为数值列表")
                } else if let arr = v as? [Any] {
                    let count = Double(arr.count)
                    if let ml = it.minLen, let n = Self.dbl(ml), count < n {
                        errors.append("\(it.label) 至少需要 \(Self.numStr(ml)) 个数值")
                    } else if let ml = it.maxLen, let n = Self.dbl(ml), count > n {
                        errors.append("\(it.label) 最多 \(Self.numStr(ml)) 个数值")
                    }
                } else {
                    errors.append("\(it.label) 校验通过但无法转列表（内部不一致）")
                }
            case "str_list":
                if !Self.isStringList(v) {
                    errors.append("\(it.label) 应为字符串列表")
                } else if let arr = v as? [Any] {
                    if let ml = it.minLen, let n = Self.dbl(ml), Double(arr.count) < n {
                        errors.append("\(it.label) 至少需要 \(Self.numStr(ml)) 项")
                    } else if let ml = it.maxLen, let n = Self.dbl(ml), Double(arr.count) > n {
                        errors.append("\(it.label) 最多 \(Self.numStr(ml)) 项")
                    }
                } else {
                    errors.append("\(it.label) 校验通过但无法转列表（内部不一致）")
                }
            case "str":
                if !(v is String) { errors.append("\(it.label) 应为文本") }
            case "json":
                // 先断言"必须是对象"：值不是字典时不能放行，否则残缺对象落库后
                // `buildStrategy` 静默返回只剩 `strategy_key` 的残缺字典。
                if !(v is [String: Any]) {
                    errors.append("\(it.label) 应为对象（JSON 字典）")
                } else if let dict = v as? [String: Any] {
                    // 嵌套 JSON 的必填子键：只收「被代码直接下标取值」或「代表纪律口径」的键，
                    // 不做通用 JSON Schema（过度设计且容易误伤用户自定义键）
                    for sub in requiredJSONKeys[it.key] ?? [] where dict[sub] == nil {
                        errors.append("\(it.label) 缺少子键 \(sub)（\(it.key).\(sub)）")
                    }
                }
            default:
                break
            }
        }
        errors.append(contentsOf: Self.crossChecks(params))
        return errors
    }

    /// 跨参数一致性（单键范围校验拦不住的那些）
    public static func crossChecks(_ params: [String: Any]) -> [String] {
        var errors: [String] = []
        let tier1 = num(params, "scoring.tiers.tier1_min")
        let tier2 = num(params, "scoring.tiers.tier2_min")
        let lockMax = num(params, "scoring.tier_lock.max_score")

        if let t1 = tier1, let t2 = tier2, let a = dbl(t2), let b = dbl(t1), a >= b {
            errors.append("二档门槛(\(numStr(t2))) 必须低于一档门槛(\(numStr(t1)))，否则二档区间为空")
        }
        if let t1 = tier1, let lm = lockMax, let a = dbl(lm), let b = dbl(t1), a >= b {
            errors.append("均线降档锁上限(\(numStr(lm))) 必须小于一档门槛(\(numStr(t1)))："
                          + "否则均线未多头排列的股票也会被判进一档，绕过「均线多头」纪律")
        }
        // 区间带必须逐层收窄：硬过滤 ⊇ 画像过滤（否则窄的那层永远不起作用，配置形同虚设）
        //
        // ⚠ 用 `change_pct_loose`（硬过滤实际生效的键），不是 `change_pct`（该键不存在，
        // 用它这条校验永不触发）。
        if let h = pair(params, "hard_filter.change_pct_loose"),
           let p = pair(params, "profile_filter.change_pct"),
           let h0 = dbl(h[0]), let h1 = dbl(h[1]), let p0 = dbl(p[0]), let p1 = dbl(p[1]),
           !(h0 <= p0 && h1 >= p1) {
            errors.append("硬过滤涨幅带[\(numStr(h[0])), \(numStr(h[1]))] "
                          + "未包住画像涨幅区间[\(numStr(p[0])), \(numStr(p[1]))]，画像区间会被截断")
        }
        // 逐层收窄：硬过滤涨幅带下限不得低于跌幅下限，
        // 否则跌幅下限会静默截断涨幅带 —— 用户把带下限放宽到 -9% 时会被 -7% 卡住。
        if let h = pair(params, "hard_filter.change_pct_loose"),
           let hl = num(params, "hard_filter.change_pct_min"),
           let h0 = dbl(h[0]), let l = dbl(hl), h0 < l {
            errors.append("硬过滤涨幅带下限(\(numStr(h[0]))%) 低于 跌幅下限(\(numStr(hl))%)，"
                          + "跌幅下限会截断它")
        }
        // 画像区间上限若超过风险硬上限，区间上端永远不可达
        for (pk, hk, label) in Self.riskPairs {
            guard let p = pair(params, pk), let h = num(params, hk),
                  let p1 = dbl(p[1]), let hv = dbl(h) else { continue }
            if p1 > hv {
                errors.append("画像\(label)区间上限(\(numStr(p[1]))) 超过风险硬上限(\(numStr(h)))，上端永远不可达")
            }
        }
        // 逐层收窄：画像振幅上限不得超过硬过滤振幅上限。
        // 这两项都不在参数中心（外层已移出 schema），没有这条规则时，
        // 用户把画像振幅上限调到 16~20 会被隐藏的 15 静默截断、且界面上毫无提示。
        if let pa = num(params, "profile_filter.amplitude_max"),
           let ha = num(params, "hard_filter.amplitude_max"),
           let a = dbl(pa), let b = dbl(ha), a > b {
            errors.append("画像振幅上限(\(numStr(pa))%) 超过 硬过滤振幅上限(\(numStr(ha))%)，"
                          + "上端永远不可达")
        }
        // 红灯连跌天数至少为 1
        if let rd = num(params, "predict_rules.red_decline_days"), let v = dbl(rd), v < 1 {
            errors.append("红灯连跌天数至少为 1")
        }
        return errors
    }

    private static let riskPairs: [(String, String, String)] = [
        ("profile_filter.volume_ratio", "risk_filter.volume_ratio_hard_max", "量比"),
        ("profile_filter.turnover", "risk_filter.turnover_hard_max", "换手率"),
    ]

    // MARK: - UI 表单数据（≡ param_schema.schema_payload）

    public func schemaPayload(_ params: [String: Any]) -> [[String: Any]] {
        groups.map { g in
            var items: [[String: Any]] = []
            for it in g.items {
                var d = it.raw
                let v = Self.getValue(params, it.key)
                // 特殊展示值：str_list 转逗号分隔文本（UI 文本输入），json 保留原样
                if it.type == "str_list", let arr = v as? [Any] {
                    d["value"] = arr.map { Self.numStr($0) }.joined(separator: ",")
                } else {
                    d["value"] = v ?? NSNull()
                }
                items.append(d)
            }
            return ["group": g.raw["group"] ?? NSNull(),
                    "title": g.raw["title"] ?? NSNull(),
                    "items": items]
        }
    }
}

/// 数值/JSON 表示法格式化（参数落库与错误文案都依赖这套形态）
public enum PyJSON {
    /// `str()` 等价：整数保持整数形态、浮点保留 ".0"、布尔输出 True/False。
    ///
    /// ⚠ 必须看 `objCType` 而不是 `NSNumber.description`：
    /// `NSNumber(7.0).description` 是 "7"，而这里要 "7.0"。
    public static func numStr(_ v: Any) -> String {
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "True" : "False" }
            let t = String(cString: n.objCType)
            if t == "d" || t == "f" { return floatStr(n.doubleValue) }
            return String(n.int64Value)
        }
        if let s = v as? String { return s }
        return String(describing: v)
    }

    /// `repr(float)` 等价（整数值保留 ".0"）
    public static func floatStr(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e16 { return String(format: "%.1f", d) }
        return String(d)
    }

    /// `json.dumps(obj, ensure_ascii=False)` 等价。
    ///
    /// ⚠ 不用 `JSONSerialization`：它把 Double 3.0 写成 `3`（整数形态），落库后再读回
    /// 就变成 int —— 参数中心的文案（"振幅上限(15.0)%"）与库内口径都会跟着漂，
    /// 这里显式保留浮点形态。键序按字典序（语义等价）。
    public static func encode(_ v: Any) -> String {
        if let d = v as? [String: Any] {
            let body = d.keys.sorted().map { "\"\(escape($0))\": \(encode(d[$0]!))" }
            return "{" + body.joined(separator: ", ") + "}"
        }
        if let a = v as? [Any] {
            return "[" + a.map { encode($0) }.joined(separator: ", ") + "]"
        }
        if v is NSNull { return "null" }
        if let s = v as? String { return "\"\(escape(s))\"" }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            let t = String(cString: n.objCType)
            if t == "d" || t == "f" {
                // ⚠ 非有限值必须写成 `null`，不能写 `inf` / `nan`（2026-10-16 审查 B2）：
                //   `floatStr(.infinity)` 得到 "inf" —— 那是**非法 JSON**。
                //   而本函数写的是 `*_json` TEXT 列（stocks_json / deep_info_json / …），
                //   一个非有限值就让**整列 payload 读不回来**：
                //   `parseJSON` 解析失败 → `jdict()/jarray()` 返 `[:]`/`[]` →
                //   那一行的分数照常显示、深度信息卡却整块空白，且日志零痕迹。
                let d = n.doubleValue
                return d.isFinite ? floatStr(d) : "null"
            }
            return String(n.int64Value)
        }
        return "\"\(escape(String(describing: v)))\""
    }

    /// 转义：非 ASCII 原样保留（ensure_ascii=False），仅转义 JSON 必需字符
    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 2)
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out
    }
}
