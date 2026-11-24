import Foundation
import Observation
import SelectedCore

/// 参数中心编辑器的纯状态机与差异/校验逻辑（供 `ParamEditor` 与 `SelectedAppTests` 共用）。
///
/// 从 SwiftUI `@State` 抽离的原因：
///   `jsonBinding` / `nullBinding` 触发 `recomputeDiff()`、`cum_5d_low` 停用→启用缺失必填字段拦截、
///   `.timePair` 非法值阻断保存、写库失败保留草稿与版本名等行为需要在测试目标里直接回归验证。
@MainActor
@Observable
final class ParamEditorState {
    /// 编辑值存储：普通项 key=item key；num_pair 拆成 "<key>#0"/"<key>#1"
    var values: [String: String] = [:]
    var bools: [String: Bool] = [:]
    @ObservationIgnored var initValues: [String: String] = [:]
    @ObservationIgnored var initBools: [String: Bool] = [:]

    /// 结构化 JSON 值（`ParamTableSpecs` 覆盖的那些参数）。
    /// 不复用 `values[key]`（JSON 文本）：结构化编辑器若走“解析→编辑→序列化回文本”，
    /// 每次改动都要往返一次，而且键顺序一变就会产生假 diff。这里直接持有解析后的对象，
    /// `computeDiff` 对它做深比较。
    /// 只有 `ParamTableSpecs.has(key)` 的键会进这里；其余 json 参数仍走文本路径。
    var jsonValues: [String: Any] = [:]
    @ObservationIgnored var initJsonValues: [String: Any] = [:]

    /// 被显式停用（保存为 `null`）的结构化 JSON 参数（`optional == true` 的项，
    /// 如 `cum_5d_low`）。停用不清空 `jsonValues` 里的值，重新启用即恢复。
    var jsonNulls: Set<String> = []
    @ObservationIgnored var initJsonNulls: Set<String> = []

    @ObservationIgnored var itemMeta: [String: (type: String, step: Double)] = [:]

    var versionName = ""
    /// 默认不激活（2026-10-16 审查 B6）：原先默认 `true`，而底部主按钮带
    /// `.keyboardShortcut(.defaultAction)` ⇒ 想“存个草稿试试”的人按一次回车，
    /// 下一轮扫描就直接用这套新参数跑实盘了。另存为草稿是高频动作、
    /// “存完立刻切实盘口径”是低频动作，默认值必须跟着高频走。
    var activateAfterSave = false
    /// 勾了“保存后激活”时的二次确认（改实盘口径 = 与“激活版本”同量级的动作）
    var pendingActivateSave = false

    /// 参数搜索（参数已近百项，靠滚动逐组找太慢）
    var query = ""

    /// `diff` 与 `invalidKeys` 用存储 + 变化时重算：做成计算属性会让 footer
    /// 每次渲染都算 4 遍全量遍历（每项含 trim + 查表 + parseValue）。
    var diff: [String: Any] = [:]
    var invalidKeys: [String] = []

    /// 保存/放弃后的本地重建计数
    var localReload = 0

    init() {}

    // MARK: - 写入并同步重算 diff

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    /// 计算步进结果（用 `Decimal` 按 `step` 有效小数位运算，避免 `Double` 二进制误差长尾如 `0.30000000000000004`）
    static func steppedValue(current: String, type: String, step: Double, dir: Int) -> String? {
        guard step.isFinite else { return nil }
        let curRaw = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let curDec = Decimal(string: curRaw, locale: posixLocale), curDec.isFinite else { return nil }
        let stepStr = String(step)
        guard let stepDec = Decimal(string: stepStr, locale: posixLocale), stepDec.isFinite else { return nil }

        var next = curDec + stepDec * Decimal(dir)
        let lo = Decimal(-100_000)
        let hi = Decimal(100_000)
        if next < lo { next = lo }
        if next > hi { next = hi }

        if type == "int" {
            var rounded = Decimal()
            NSDecimalRound(&rounded, &next, 0, .plain)
            if rounded == 0 { rounded = 0 }
            return NSDecimalString(&rounded, posixLocale)
        } else {
            let scale = max(fractionDigits(curRaw), fractionDigits(stepStr))
            var rounded = Decimal()
            NSDecimalRound(&rounded, &next, scale, .plain)
            if rounded == 0 { rounded = 0 }
            return NSDecimalString(&rounded, posixLocale)
        }
    }

    func stepValue(forKey key: String, dir: Int) {
        guard let meta = itemMeta[key],
              let next = Self.steppedValue(current: values[key] ?? "", type: meta.type, step: meta.step, dir: dir)
        else { return }
        setValue(next, forKey: key)
    }

    private static func fractionDigits(_ text: String) -> Int {
        guard let dot = text.firstIndex(of: ".") else { return 0 }
        let frac = text[text.index(after: dot)...].prefix { $0.isASCII && $0.isNumber }
        // `Double(1.0).description` 会产出 `"1.0"`，步长为整值时不凭空拉高小数位
        if frac.allSatisfy({ $0 == "0" }) { return 0 }
        return frac.count
    }

    func setValue(_ value: String, forKey key: String) {
        values[key] = value
        recomputeDiff()
    }

    func setBool(_ value: Bool, forKey key: String) {
        bools[key] = value
        recomputeDiff()
    }

    func setJSONValue(_ value: [String: Any], forKey key: String) {
        jsonValues[key] = value
        recomputeDiff()
    }

    func setJSONNull(_ disabled: Bool, forKey key: String) {
        if disabled {
            jsonNulls.insert(key)
        } else {
            jsonNulls.remove(key)
        }
        recomputeDiff()
    }

    var diffCount: Int { diff.count }

    var saveHint: String {
        if !invalidKeys.isEmpty { return "\(invalidKeys.count) 项输入无效" }
        let base = diffCount == 0 ? "无变更" : "\(diffCount) 项变更"
        // 勾了激活就把后果写在旁边（审查 B6）：不靠颜色、只用文字，
        // 免得只在 hover 里才看得见
        return activateAfterSave ? "\(base) · 将立即用于后续扫描" : base
    }

    var canSave: Bool {
        invalidKeys.isEmpty && diffCount > 0 && !versionName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @discardableResult
    func performSave(using saver: (String, [String: Any], Bool) -> Bool) -> Bool {
        pendingActivateSave = false
        let ok = saver(versionName.trimmingCharacters(in: .whitespaces), diff, activateAfterSave)
        guard ok else { return false }
        versionName = ""
        // 参数写入是同步收口（`runParamWriteValue` 落库 + `refreshParams` 都在主线程跑完），
        // 保存成功后重建基线即可看到新状态；写入失败则保留当前草稿与版本名。
        localReload += 1
        return true
    }

    // MARK: - 基线构建

    func buildEdits(from groups: [JSONValue]) {
        var v: [String: String] = [:], b: [String: Bool] = [:]
        var meta: [String: (type: String, step: Double)] = [:]
        var iv: [String: String] = [:], ib: [String: Bool] = [:]
        var jv: [String: Any] = [:], ijv: [String: Any] = [:]
        var jn: Set<String> = [], ijn: Set<String> = []
        for g in groups {
            for it in g["items"].array {
                let key = it["key"].string ?? ""
                let type = it["type"].string ?? "str"
                meta[key] = (type, it["step"].double ?? 1)
                let val = it["value"]
                switch type {
                case "bool":
                    let bb = val.bool ?? false
                    b[key] = bb; ib[key] = bb; v[key] = ""; iv[key] = ""
                case "num_pair":
                    let pair = (val.raw as? [Any] ?? []).map { String(describing: $0) }
                    let a = pair.count > 0 ? pair[0] : ""
                    let c = pair.count > 1 ? pair[1] : ""
                    v[key + "#0"] = a; iv[key + "#0"] = a
                    v[key + "#1"] = c; iv[key + "#1"] = c
                    v[key] = ""; iv[key] = ""
                default:
                    v[key] = encodeValue(it["value"], type: type)
                    iv[key] = v[key]
                    // 结构化 JSON：值仍是对象时收进结构化状态。
                    // 显式 null（如 classic 的 cum_5d_low「本版本停用」）在停用集登记。
                    if type == "json" {
                        if let obj = val.raw as? [String: Any] {
                            jv[key] = obj; ijv[key] = obj
                        } else if val.raw is NSNull {
                            jn.insert(key); ijn.insert(key)
                        }
                    }
                }
            }
        }
        values = v; initValues = iv
        bools = b; initBools = ib
        jsonValues = jv; initJsonValues = ijv
        jsonNulls = jn; initJsonNulls = ijn
        itemMeta = meta
        query = ""
        // 基线刚换过 → 立刻重算一次
        recomputeDiff()
    }

    func encodeValue(_ val: JSONValue, type: String) -> String {
        if let s = val.string, type == "str" { return s }
        if let arr = val.raw as? [Any] {
            return arr.map { String(describing: $0) }.joined(separator: ",")
        }
        if let obj = val.raw as? [String: Any], type == "json" {
            return prettyJSON(obj) ?? String(describing: obj)
        }
        if let n = val.raw as? NSNumber {
            return type == "int" ? String(n.intValue) : String(n.doubleValue)
        }
        return val.string ?? ""
    }

    /// 结构化 JSON 的深比较（不受键顺序影响）。
    /// 不用 `String(describing:)`：字典的 description 不保证键顺序（同 `JSONValue.Hashable` 的坑）。
    static func deepEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let x?, let y?):
            return NSDictionary(dictionary: x as? [String: Any] ?? [:])
                .isEqual(to: y as? [String: Any] ?? [:])
        default: return false
        }
    }

    private func prettyJSON(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 解析编辑值 → 类型化对象；nil 表示解析失败
    func parseValue(_ raw: String, type: String) -> Any? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "int":
            guard let d = Int(s) else { return nil }
            return d
        case "float":
            guard let d = Double(s), d.isFinite else { return nil }
            return d
        case "num_pair":
            let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2,
                  let a = Double(parts[0]), a.isFinite,
                  let b = Double(parts[1]), b.isFinite else { return nil }
            return [a, b]
        case "num_list":
            let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let nums = parts.compactMap { Double($0) }
            guard !parts.isEmpty, nums.count == parts.count, nums.allSatisfy(\.isFinite) else { return nil }
            return nums
        case "str_list":
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case "json":
            guard !s.isEmpty, let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
            return obj
        default:
            return s
        }
    }

    // MARK: - diff 计算

    func recomputeDiff() {
        diff = computeDiff()
        invalidKeys = computeInvalidKeys()
    }

    /// 编辑后与初始值的差异表（点路径 → 新值）；解析失败项计入 invalidKeys
    func computeDiff() -> [String: Any] {
        var d: [String: Any] = [:]
        for (key, cur) in values {
            if key.hasSuffix("#1") { continue }
            let raw = cur.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.hasSuffix("#0") {
                let baseKey = String(key.dropLast(2))
                guard let meta = itemMeta[baseKey], meta.type == "num_pair" else { continue }
                let pair = [raw, (values[baseKey + "#1"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)]
                let joined = pair.joined(separator: ",")
                let initJoined = [(initValues[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                  (initValues[baseKey + "#1"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)]
                    .joined(separator: ",")
                if joined == initJoined { continue }
                if let parsed = parseValue(joined, type: "num_pair") as? [Double] {
                    if let initParsed = parseValue(initJoined, type: "num_pair") as? [Double],
                       parsed == initParsed {
                        continue
                    }
                    d[baseKey] = parsed
                }
                continue
            }
            guard let meta = itemMeta[key] else { continue }
            // 结构化 JSON：只有当结构化值真的被改过才接管，否则继续走下面的文本路径。
            if meta.type == "json", ParamTableSpecs.has(key) {
                let wasNull = initJsonNulls.contains(key)
                let isNull = jsonNulls.contains(key)
                if isNull != wasNull {
                    // 停用 ↔ 启用：写显式 null / 写回对象（未填字段时传空字典交由形状校验提示）
                    d[key] = isNull ? NSNull() : (jsonValues[key] ?? [String: Any]())
                    continue
                }
                if !isNull, let cur = jsonValues[key],
                   !Self.deepEqual(cur, initJsonValues[key]) {
                    d[key] = cur
                    continue
                }
                continue
            }
            let initRaw = (initValues[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw == initRaw { continue }
            if let parsed = parseValue(raw, type: meta.type) {
                if meta.type == "float", let curD = parsed as? Double,
                   let initD = parseValue(initRaw, type: "float") as? Double, curD == initD {
                    continue
                }
                if meta.type == "int", let curI = parsed as? Int,
                   let initI = parseValue(initRaw, type: "int") as? Int, curI == initI {
                    continue
                }
                d[key] = parsed
            }
        }
        for (key, cur) in bools {
            guard let meta = itemMeta[key], meta.type == "bool" else { continue }
            if let initB = initBools[key], cur != initB {
                d[key] = cur
            }
        }
        return d
    }

    /// 解析失败的项（diff 中被跳过）
    func computeInvalidKeys() -> [String] {
        var bad: [String] = []
        for (key, e) in values {
            let raw = e.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.hasSuffix("#0") {
                let baseKey = String(key.dropLast(2))
                guard let meta = itemMeta[baseKey], meta.type == "num_pair" else { continue }
                let joined = [raw, (values[baseKey + "#1"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)].joined(separator: ",")
                guard let parsed = parseValue(joined, type: "num_pair") else {
                    bad.append(baseKey); continue
                }
                // 区间倒挂要在编辑时就标出来（2026-10-16 审查 B6）：
                // `ParamSchema.validate` 保存时会拒（所以数据不会被写坏），
                // 但只在校验返回后才看得见 —— 而“下限 > 上限”的画像区间
                // 在实际打分里等于把所有候选一次清空，值得当场标出来。
                // （扫描侧另有 `Screener.profileRangeProblem` 兜底，双保险。）
                let pair = parsed as? [Any] ?? []
                if pair.count == 2, let a = Num.doubleOrNil(pair[0]), let b = Num.doubleOrNil(pair[1]),
                   a > b {
                    bad.append("\(baseKey)（区间倒挂：\(PyJSON.numStr(a)) > \(PyJSON.numStr(b))）")
                }
                continue
            }
            guard let meta = itemMeta[key], meta.type != "bool" else { continue }
            if meta.type == "json", ParamTableSpecs.has(key) {
                if jsonNulls.contains(key) { continue }   // 停用态没有形状可查
                let cur = jsonValues[key] ?? [String: Any]()
                if initJsonNulls.contains(key) || !Self.deepEqual(cur, initJsonValues[key]) {
                    if let why = ParamTableSpecs.problem(key, value: cur) {
                        bad.append("\(key)（\(why)）")
                    }
                }
                continue
            }
            let initRaw = (initValues[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw == initRaw { continue }
            if parseValue(raw, type: meta.type) == nil { bad.append(key) }
        }
        return bad
    }
}
