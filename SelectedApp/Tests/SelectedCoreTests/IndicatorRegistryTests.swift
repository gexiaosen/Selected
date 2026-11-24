import Testing
@testable import SelectedCore

/// `IndicatorRegistry` 的契约测试
///
/// 注册表是快照 Job 与筛选页的接口：
/// "漏登记"与"悄悄删指标"都必须是红的，而不是等页面少一张卡才发现。
struct IndicatorRegistryTests {

    /// 已实现指标 id 的**权威清单**（新增/删除指标必须同步这里 + 对应黄金测试）。
    private static let expectedIds: Set<String> = [
        // 趋势
        "ema", "macd", "hma", "kama",
        // 动量
        "rsiWilder", "stochastic", "stochasticRsi", "ppo",
        "awesomeOscillator", "ultimateOscillator",
        // 波动率
        "atrSma", "bollingerBands", "donchianChannel", "keltnerChannel",
        "superTrend", "ulcerIndex",
        // 成交量
        "vwap", "cmf", "emv", "forceIndex", "moneyFlowMultiplier", "moneyFlowVolume",
    ]

    @Test("注册表与权威 id 清单**完全一致**（漏登记或悄悄删除都会红）")
    func coverageMatchesRegistry() {
        let actual = Set(IndicatorRegistry.all.map(\.id))
        let missing = Self.expectedIds.subtracting(actual)
        let extra = actual.subtracting(Self.expectedIds)
        #expect(missing.isEmpty, "已实现但未登记注册表：\(missing.sorted())")
        #expect(extra.isEmpty, "注册表登记了未实现/已删除的指标：\(extra.sorted())")
    }

    @Test("id 全局唯一")
    func idsAreUnique() {
        let ids = IndicatorRegistry.all.map(\.id)
        #expect(Set(ids).count == ids.count, "存在重复 id")
    }

    @Test("每条 meta 字段合法：显示名非空、分类四选一、id 是 lowerCamel 风格")
    func metaFieldsAreValid() {
        for m in IndicatorRegistry.all {
            #expect(!m.displayName.isEmpty, "\(m.id)：显示名为空")
            #expect(IndicatorRegistry.Category.allCases.contains(m.category),
                    "\(m.id)：分类非法")
            #expect(!m.caliber.isEmpty, "\(m.id)：口径说明为空（分裂点必须写明）")
            #expect(m.id.first.map { $0.isLowercase } == true, "\(m.id)：id 须小驼峰开头")
            #expect(m.defaultPeriods.allSatisfy { $0 >= 0 }, "\(m.id)：周期含非法值")
        }
    }

    @Test("四个分类都非空（筛选页分区渲染的前提）")
    func everyCategoryHasMembers() {
        for c in IndicatorRegistry.Category.allCases {
            #expect(!IndicatorRegistry.all.filter { $0.category == c }.isEmpty,
                    "分类 \(c.rawValue) 下没有任何指标")
        }
    }

    @Test("meta(id:) 命中与未命中")
    func lookup() {
        #expect(IndicatorRegistry.meta(id: "macd")?.defaultPeriods == [12, 26, 9])
        #expect(IndicatorRegistry.meta(id: "nope") == nil)
    }

    @Test("快照列名契约：注册表 outputs ↔ Store 列 单一来源、全局唯一、DDL 全覆盖")
    func snapshotColumnsContract() {
        let cols = IndicatorSnapshotStore.columns
        #expect(Set(cols).count == cols.count, "列名撞车（指标 id 或 series 键重复）")
        for m in IndicatorRegistry.all {
            #expect(!m.outputs.isEmpty, "\(m.id)：outputs 为空（快照无列可落）")
            #expect(Set(m.outputs).count == m.outputs.count, "\(m.id)：outputs 内部重复")
            for c in m.columns {
                #expect(cols.contains(c), "\(m.id) 的列 \(c) 不在 Store 白名单")
            }
        }
        let ddl = IndicatorSnapshotStore.createSQL
        for c in cols { #expect(ddl.contains(c), "DDL 缺列 \(c)") }
        // 整数列必须在注册表里有归属（防"白名单里躺着无主列"）
        for c in IndicatorSnapshotStore.integerColumns {
            #expect(IndicatorSnapshotStore.columnOwners[c] != nil, "\(c) 无所属指标")
        }
    }

    @Test("注册表默认周期与实现签名一致（抽查易漂移的三条）")
    func defaultsMatchImplementations() {
        // 用 130 根合成 K 线：改动函数默认周期而没同步注册表时，这些调用会因
        // 预热长度不同而对不齐 → 断言"注册表周期下能出数、少一根不出数"
        let bars = (1...130).map { i in
            IndicatorGoldenSupport.Bar(open: 10, high: 12, low: 9,
                                       close: 10 + Double(i % 7), volume: 1000)
        }
        // BBANDS：中线首值在索引 period−1（20 → 19）
        let bb = VolatilityIndicators.bollingerBands(bars, period: 20)
        #expect(bb.middle[18] == nil && bb.middle[19] != nil)
        // MACD：信号线首值 = slow−1+signal−1 = 33
        let macd = TrendIndicators.macd(bars)
        #expect(macd.signal[32] == nil && macd.signal[33] != nil)
        // CMF：首值在索引 period−1（20 → 19）
        let cmf = VolumeIndicators.cmf(bars, period: 20)
        #expect(cmf[18] == nil && cmf[19] != nil)
    }
}
