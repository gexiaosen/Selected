import XCTest
@testable import SelectedCore

/// 参数体系的**兼容性契约**。
///
/// `validate` 的"可选"语义是「**键存在但值为 null** 才放行」，**键缺失一律报错**。
/// 于是任何新增的 schema 项都会让**全部存量参数版本**（库里已存的 JSON 没有这个键）
/// 立刻变成非法 —— 保存、调优、重放全线报错。
///
/// 决策（见 `docs/specs/README.md`）：
/// 新增**只影响新逻辑**的参数走「工厂参数 + 读取处回落默认值」，**不声明为 schema 项**。
///
/// 本文件把这条契约变成可执行断言 —— 以后谁改 `validate` 的语义，或想把工厂参数
/// 提成 schema 项，都会在这里被拦住并被迫做一次显式决策。
final class ParamSchemaContractTests: XCTestCase {

    private var items: [ParamSchema.Item] { ParamSchema.shared.allItems }

    override func setUpWithError() throws {
        // 读不到 → **失败**（不是 `XCTSkip`）：口径与 `EntityTestSupport.FixtureMissing` 一致
        // —— 该 JSON 已纳入版本管理且是随包资源，"读不到"说明仓库不完整 / 打包漏资源
        try EntityTestSupport.requireParamSchema()
        // schema 项过少同样是"元数据不完整"，不是"当前环境不具备" —— 不许静默跳过，
        // 否则本文件的兼容性契约会在坏环境里整批不跑而仍报全绿
        XCTAssertGreaterThan(items.count, 10,
                             "schema 项只有 \(items.count) 条 —— 元数据不完整（不允许伪装成全绿）")
    }

    /// 把点路径键展开成嵌套字典（`validate`/`hasKey` 按 `.` 逐层下钻）
    private func nested(_ key: String, _ value: Any) -> [String: Any] {
        let parts = key.split(separator: ".").map(String.init)
        guard let last = parts.last else { return [:] }
        var node: [String: Any] = [last: value]
        for p in parts.dropLast().reversed() { node = [p: node] }
        return node
    }

    // MARK: - 元数据自身

    func testSchemaItemsAreWellFormed() {
        XCTAssertFalse(items.isEmpty)
        for it in items {
            XCTAssertFalse(it.key.isEmpty, "存在空 key 的 schema 项")
            XCTAssertFalse(it.label.isEmpty, "\(it.key) 缺 label")
            XCTAssertFalse(it.type.isEmpty, "\(it.key) 缺 type")
        }
        XCTAssertEqual(Set(items.map(\.key)).count, items.count, "schema 项 key 必须唯一")
        XCTAssertFalse(ParamSchema.shared.defaultActive.isEmpty, "缺 default_active")
    }

    // MARK: - 契约①：键缺失一律报错（**含 optional**）

    /// 这是整条约束的根：`optional` 不是"可以没有"，而是"可以显式为 null"。
    /// 断言「空 dict 会为**每一项**报缺失」——正是新增 schema 项会打断存量版本的原因。
    func testAbsentKeyIsReportedForEveryItemIncludingOptional() {
        let errors = ParamSchema.shared.validate([:])
        let joined = errors.joined(separator: "\n")
        for it in items {
            XCTAssertTrue(joined.contains(it.key),
                          "空参数应报出 \(it.key) 缺失（optional=\(it.optional)）")
        }
        XCTAssertEqual(errors.count, items.count,
                       "空 dict 下只应有 \(items.count) 条「缺失参数」，实得 \(errors.count) 条：\n\(joined)")
    }

    // MARK: - 契约②：显式 null 只对 optional 放行

    func testExplicitNullIsAcceptedOnlyForOptionalItems() throws {
        let optionals = items.filter(\.optional)
        let requireds = items.filter { !$0.optional }
        XCTAssertFalse(optionals.isEmpty, "一个 optional 项都没有 —— 契约②无法验证，请检查元数据")
        XCTAssertFalse(requireds.isEmpty, "一个必填项都没有 —— 契约②无法验证，请检查元数据")

        for it in optionals {
            let errors = ParamSchema.shared.validate(nested(it.key, NSNull()))
            XCTAssertFalse(errors.contains { $0.contains("缺失参数") && $0.contains(it.key) },
                           "optional 项 \(it.key) 的显式 null 应被放行，实得：\(errors)")
        }
        for it in requireds {
            let errors = ParamSchema.shared.validate(nested(it.key, NSNull()))
            XCTAssertTrue(errors.contains { $0.contains("缺失参数") && $0.contains(it.key) },
                          "必填项 \(it.key) 的显式 null 仍应报缺失，实得：\(errors)")
        }
    }

    /// `hasKey` 是「显式 null」与「压根没写」的唯一区分点，它必须认 null。
    func testHasKeyDistinguishesExplicitNullFromAbsent() {
        let withNull = nested("a.b", NSNull())
        XCTAssertTrue(ParamSchema.hasKey(withNull, "a.b"))
        XCTAssertFalse(ParamSchema.hasKey(withNull, "a.c"))
        XCTAssertFalse(ParamSchema.hasKey([:], "a.b"))
        // getValue 则把 null 折成 nil —— 两者配合才实现 optional 语义
        XCTAssertNil(ParamSchema.getValue(withNull, "a.b"))
        XCTAssertNil(ParamSchema.getValue([:], "a.b"))
    }

    // MARK: - 契约③：未声明的键不参与校验（工厂参数的安全前提）

    /// 工厂参数（如 `iterate.tune_pool_days`）**不是 schema 项**，所以既不会被要求、
    /// 也不会因为存在而报错 —— 这正是"加参数不打断存量版本"能成立的原因。
    func testUndeclaredKeysAreIgnoredByValidation() {
        let declared = Set(items.map(\.key))
        let probe = "__not_a_schema_item__"
        XCTAssertFalse(declared.contains(probe))
        let withProbe = nested(probe, 1)
        XCTAssertEqual(ParamSchema.shared.validate(withProbe).count, items.count,
                       "未声明键不应改变错误条数（它应当被完全忽略）")
    }

    // MARK: - 决策的可执行快照

    /// `iterate.tune_pool_days` 在**工厂参数**里存在（默认 120），且**刻意不声明**为 schema 项。
    /// 若哪天有人把它提成 schema 项，上面「契约①」的语义会让存量版本全部非法 ——
    /// 这条断言会把那次改动标出来，迫使改的人先更新 design 文档与兼容方案。
    func testTunePoolDaysIsFactoryParamNotSchemaItem() throws {
        let iterate = try XCTUnwrap(ParamSchema.shared.factoryParams["iterate"] as? [String: Any],
                                    "工厂参数缺 iterate 段")
        XCTAssertEqual(iterate["tune_pool_days"] as? Int, 120,
                       "工厂默认窗口应为 120 个交易日（读取处也回落 120，两处必须一致）")
        XCTAssertFalse(items.contains { $0.key == "iterate.tune_pool_days" },
                       "tune_pool_days 刻意不是 schema 项（见 design 文档）；"
                       + "若确要提成 schema 项，请先给存量版本补值再删掉本断言")
    }

    /// `iterate.include_replay` 同款 —— 在工厂参数里、
    /// **默认 false**、且**刻意不声明**为 schema 项。
    ///
    /// 默认值这一条是有牙齿的：`false` 是「调优池只用 live 样本」的唯一开关。
    /// 若它变成 `true`，回放样本（**收盘价口径**）会与 live 样本（**尾盘盘中口径**）
    /// 混进同一个池，得到的"最优参数"是两种口径的平均，而界面上看不出池里混了什么。
    func testIncludeReplayIsFactoryParamDefaultingToLiveOnly() throws {
        let iterate = try XCTUnwrap(ParamSchema.shared.factoryParams["iterate"] as? [String: Any],
                                    "工厂参数缺 iterate 段")
        XCTAssertEqual(iterate["include_replay"] as? Bool, false,
                       "工厂默认必须是 false（只用 live）；读取处也回落 false，两处必须一致")
        XCTAssertFalse(items.contains { $0.key == "iterate.include_replay" },
                       "include_replay 刻意不是 schema 项（同 tune_pool_days）；"
                       + "若确要提成 schema 项，请先给存量版本补值再删掉本断言")
    }

    /// `PhaseTune` 池过滤的三条分支 —— **第三条是"静默失效"的解法**，必须钉住。
    func testPoolLiveOnlyClauseHasThreeDistinctBranches() {
        let live = PhaseTune.liveOnlyClause(includeReplay: false, hasColumn: true)
        XCTAssertTrue(live.contains("scan_mode='live'"), "默认（只用 live）必须真的筛：\(live)")
        XCTAssertTrue(live.hasPrefix(" AND "), "片段要能直接拼进 WHERE 子句：\(live)")

        XCTAssertEqual(PhaseTune.liveOnlyClause(includeReplay: true, hasColumn: true), "",
                       "显式开启 include_replay → 不筛")

        // 列不存在 → **不筛**。若这里返回过滤片段，`PhaseStore.query` 会把
        //   `no such column: scan_mode` 静默吞成 `[]` → 池变空 → 调优报"历史评估池为空"，
        //   看起来像"你还没跑过扫描"。而"列不存在"等价于"库里不可能有回放样本"
        //   （回放的标记写入同样需要这一列），所以不筛就是正确行为。
        XCTAssertEqual(PhaseTune.liveOnlyClause(includeReplay: false, hasColumn: false), "",
                       "列不存在时必须不筛（否则池会静默变空）")
    }

    // MARK: - 「永不生效」参数的可执行快照

    /// 7 个「外层兜底」参数不在 schema（值仍在，只是不进参数中心）
    private static let removedFromSchema = [
        "hard_filter.amplitude_max",
        "hard_filter.change_pct_min",
        "hard_filter.one_word_board_pct",
        "risk_filter.volume_ratio_hard_max",
        "risk_filter.turnover_hard_max",
        "scoring.intraday.tail_vol_ratio_min",
        "scoring.intraday.tail_vol_ratio_score",
    ]

    private static let shippedParamFiles = [
        "classic_2026_7_16", "backtest_v1_1_0", "backtest_v1_2_0",
        "backtest_v1_3_0", "backtest_strict",
    ]

    /// 按点路径取值（`a.b.c`）
    private static func value(_ root: [String: Any], _ key: String) -> Any? {
        var cur: Any = root
        for p in key.split(separator: ".").map(String.init) {
            guard let d = cur as? [String: Any], let next = d[p] else { return nil }
            cur = next
        }
        return cur
    }

    /// 这 7 个键**不在 schema 里**，但**必须**留在工厂参数与每个出厂 JSON 里。
    ///
    /// 不是可选的：`Screener.hardFilter` 用 `numPy(hf["amplitude_max"]) ?? 0` 取值 ——
    /// 键一消失，`amp > 0` 会把**几乎全部候选排除**（整轮静默选不出票）；
    /// `tail_vol_ratio_score` 更是 `?? 12`，键一消失所有尾盘票**凭空 +12 分**。
    /// 两类都**不报错**，只能靠断言拦（宽松的一侧不报错）。
    ///
    /// 见 `docs/specs/README.md`。
    func testRemovedParamsAreFactoryOnlyNotSchemaItems() throws {
        for key in Self.removedFromSchema {
            XCTAssertFalse(items.contains { $0.key == key },
                           "\(key) 又回到参数中心了（应走 spec 里的迁移路径）")
            XCTAssertNotNil(Self.value(ParamSchema.shared.factoryParams, key),
                            "工厂参数缺 \(key) —— 新库拿不到值，引擎会静默走 `?? 0` / `?? 12`")
        }
        for name in Self.shippedParamFiles {
            let json = try EntityTestSupport.fixture("engine/params/\(name).json")
            let raw = (json.raw as? [String: Any]) ?? [:]
            for key in Self.removedFromSchema {
                XCTAssertNotNil(Self.value(raw, key),
                                "\(name).json 缺 \(key)（Python 会 KeyError / Swift 会静默出错）")
            }
        }
    }

    /// 「逐层收窄」的第 4、5 对：
    /// 涨幅带下限 ≥ 跌幅下限；画像振幅上限 ≤ 硬过滤振幅上限。
    ///
    /// 这两条防的是同一件事：外层参数已**不在参数中心**，若内层可以越过它，
    /// 用户就会遇到"改了没反应"—— 而且界面上连个可调的旋钮都没有了。
    func testLayerNarrowingRulesRejectInnerExceedingOuter() throws {
        let schema = ParamSchema.shared

        // ① 画像振幅上限(18) 超过 硬过滤振幅上限(15) → 报错
        var overAmp = schema.factoryParams
        var pf = (overAmp["profile_filter"] as? [String: Any]) ?? [:]
        pf["amplitude_max"] = 18.0
        overAmp["profile_filter"] = pf
        XCTAssertTrue(schema.validate(overAmp).contains { $0.contains("硬过滤振幅上限") },
                      "画像振幅上限 18 > 硬过滤振幅上限 15，应报「上端永远不可达」")

        // ② 涨幅带下限(-9) 低于 跌幅下限(-7) → 报错
        var lowBand = schema.factoryParams
        var hf = (lowBand["hard_filter"] as? [String: Any]) ?? [:]
        hf["change_pct_loose"] = [-9.0, 6.0]
        lowBand["hard_filter"] = hf
        XCTAssertTrue(schema.validate(lowBand).contains { $0.contains("跌幅下限会截断它") },
                      "涨幅带下限 -9 < 跌幅下限 -7，应报「跌幅下限会截断它」")

        // ③ 出厂参数本身必须零错误（新规则不得误伤既有配置）
        XCTAssertEqual(schema.validate(schema.factoryParams), [],
                       "出厂参数不应被新增的逐层收窄规则误伤")
    }

    // MARK: - 正则类参数的可编译性

    /// 这一条**故意不并进 `validate`**（理由见 `ParamSchema.regexParamErrors`）
    /// —— 它由**保存路径**单独调用。
    func testRegexParamErrorsCatchesInvalidPattern() {
        let schema = ParamSchema.shared
        var p = schema.factoryParams
        var hf = (p["hard_filter"] as? [String: Any]) ?? [:]

        hf["exclude_st_pattern"] = "ST|\\*ST|^S|退"
        p["hard_filter"] = hf
        XCTAssertEqual(ParamSchema.regexParamErrors(p), [], "出厂正则必须合法（不误伤）")

        hf["exclude_st_pattern"] = "ST|*ST"          // 裸 `*` = 非法（量词无主体）
        p["hard_filter"] = hf
        let errs = ParamSchema.regexParamErrors(p)
        XCTAssertEqual(errs.count, 1)
        XCTAssertTrue(errs[0].contains("exclude_st_pattern"), "错误里要点名是哪个参数：\(errs)")
        XCTAssertTrue(errs[0].contains("静默失效"), "还要说清后果（否则用户不知道该不该管）")

        // 空串**不报**：它不是"非法正则"，而是"不排除任何东西"（有意的关闭方式）
        hf["exclude_st_pattern"] = ""
        p["hard_filter"] = hf
        XCTAssertEqual(ParamSchema.regexParamErrors(p), [], "空串 = 有意关闭该项，不算错误")
    }

    /// 与 `validate` 的关系：**后者不会因为正则非法而报错**（这正是要单独查的原因）。
    func testValidateAloneDoesNotCatchInvalidRegex() {
        let schema = ParamSchema.shared
        var p = schema.factoryParams
        var hf = (p["hard_filter"] as? [String: Any]) ?? [:]
        hf["exclude_st_pattern"] = "ST|*ST"
        p["hard_filter"] = hf
        XCTAssertFalse(schema.validate(p).contains { $0.contains("exclude_st_pattern") },
                       "⚠ 如果哪天 validate 也开始报这条，说明它被并进去了 —— 那会红掉 param_schema 对账")
        XCTAssertEqual(ParamSchema.regexParamErrors(p).count, 1, "但单独查必须能查到")
    }
}
