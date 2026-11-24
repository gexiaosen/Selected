import Foundation

// ⚠ 本文件是**自动生成的数据源**，但生成之后它就是**单一事实来源**：
//   · 改库结构 / 参数元数据 → 改这里 → 跑 `SelectedApp/Tools/export_schema.swift`
//     重新生成 `engine/params/{db_schema_export,param_schema_export}.json`
//   · `swift test` 的 `SchemaExportTests` 会断言"重新生成的结果与仓内文件逐字节相同"
//
// ⚠ 键序 = 插入序（Python dict 保序）⇒ 必须用 `[(String, PyVal)]`，不能换成字典。

public enum SchemaExportData {

    /// `engine/params/db_schema_export.json`（建表脚本 + 增量迁移 + 版本水位）
    public static let dbSchema: PyVal = .obj([
        ("schema_version", .int(15)),
        ("schema_sql", .str(
            "\n"
            + "CREATE TABLE IF NOT EXISTS meta(\n"
            + "  key TEXT PRIMARY KEY, value TEXT\n"
            + ");\n"
            + "\n"
            + "-- 交易日与大盘环境\n"
            + "CREATE TABLE IF NOT EXISTS trading_days(\n"
            + "  date TEXT PRIMARY KEY,\n"
            + "  is_trading INTEGER,\n"
            + "  sh_price REAL, sh_change_pct REAL, sh_amplitude REAL,\n"
            + "  up_count INTEGER, down_count INTEGER, flat_count INTEGER,\n"
            + "  sh_ok INTEGER, ratio_ok INTEGER,\n"
            + "  sh_3d_trend TEXT, sh_consecutive_decline INTEGER, sh_3d_decline_count INTEGER,\n"
            + "  sh_d1 REAL, sh_d2 REAL,\n"
            + "  updated_at TEXT\n"
            + ");\n"
            + "\n"
            + "-- 轮次扫描\n"
            + "CREATE TABLE IF NOT EXISTS scan_rounds(\n"
            + "  id INTEGER PRIMARY KEY AUTOINCREMENT,\n"
            + "  date TEXT NOT NULL, slot INTEGER NOT NULL, slot_label TEXT,\n"
            + "  run_time TEXT NOT NULL,\n"
            + "  screener_version TEXT, param_version TEXT,\n"
            + "  total_scanned INTEGER, after_hard_filter INTEGER, after_profile_filter INTEGER,\n"
            + "  after_form_filter INTEGER, excluded_count INTEGER, final_count INTEGER,\n"
            + "  tier1_count INTEGER, tier2_count INTEGER,\n"
            + "  market_env_json TEXT, result_json TEXT,\n"
            + "  status TEXT DEFAULT 'ok',\n"
            + "  UNIQUE(date, slot, run_time)\n"
            + ");\n"
            + "CREATE INDEX IF NOT EXISTS idx_rounds_date ON scan_rounds(date, slot);\n"
            + "\n"
            + "-- 入档标的明细（一/二/三档）\n"
            + "CREATE TABLE IF NOT EXISTS picks(\n"
            + "  id INTEGER PRIMARY KEY AUTOINCREMENT,\n"
            + "  round_id INTEGER NOT NULL REFERENCES scan_rounds(id),\n"
            + "  date TEXT, slot INTEGER,\n"
            + "  code TEXT, name TEXT, tier INTEGER, score REAL,\n"
            + "  -- C 项（2026-09-16）：score 是**参与档位判定**的分数（可能被均线规则压制），\n"
            + "  -- score_raw 是压制前的真实分，ma_qualified/tier_lock_applied 记录资格与是否被压制。\n"
            + "  -- 三者一起才能让\"78 分被锁进三档\"与\"33 分本来就在三档\"在库里可区分。\n"
            + "  score_raw REAL, ma_qualified INTEGER, tier_lock_applied INTEGER DEFAULT 0,\n"
            + "  price REAL, change_pct REAL, volume_ratio REAL, turnover REAL,\n"
            + "  amplitude REAL, amount REAL, avg_price REAL,\n"
            + "  deep_info_json TEXT, score_details_json TEXT, penalty_details_json TEXT,\n"
            + "  market_weak INTEGER DEFAULT 0\n"
            + ");\n"
            + "CREATE INDEX IF NOT EXISTS idx_picks_round ON picks(round_id);\n"
            + "CREATE INDEX IF NOT EXISTS idx_picks_date ON picks(date, code);\n"
            + "\n"
            + "-- 深度排除名单\n"
            + "CREATE TABLE IF NOT EXISTS excluded_stocks(\n"
            + "  id INTEGER PRIMARY KEY AUTOINCREMENT,\n"
            + "  round_id INTEGER NOT NULL REFERENCES scan_rounds(id),\n"
            + "  date TEXT, slot INTEGER, code TEXT, name TEXT, reason TEXT\n"
            + ");\n"
            + "\n"
            + "-- ETF 推荐\n"
            + "CREATE TABLE IF NOT EXISTS etf_picks(\n"
            + "  id INTEGER PRIMARY KEY AUTOINCREMENT,\n"
            + "  round_id INTEGER NOT NULL REFERENCES scan_rounds(id),\n"
            + "  date TEXT, slot INTEGER,\n"
            + "  code TEXT, name TEXT, price REAL, change_pct REAL,\n"
            + "  volume_ratio REAL, turnover REAL, amount REAL\n"
            + ");\n"
            + "\n"
            + "-- 三轮信号分类（每交易日汇总一次）\n"
            + "CREATE TABLE IF NOT EXISTS signal_classes(\n"
            + "  date TEXT NOT NULL, code TEXT NOT NULL,\n"
            + "  name TEXT, signal_type TEXT,  -- strongest/consensus/pulse\n"
            + "  scores_json TEXT, trend TEXT,\n"
            + "  PRIMARY KEY(date, code)\n"
            + ");\n"
            + "\n"
            + "-- 阶段一：早盘预判\n"
            + "CREATE TABLE IF NOT EXISTS predicts(\n"
            + "  date TEXT PRIMARY KEY,       -- 预判执行日（T+1）\n"
            + "  sel_date TEXT NOT NULL,      -- 选股日（T）\n"
            + "  predict_time TEXT,\n"
            + "  market_env_json TEXT,\n"
            + "  stocks_json TEXT,\n"
            + "  is_empty_day INTEGER DEFAULT 0,\n"
            + "  report_md TEXT,\n"
            + "  updated_at TEXT\n"
            + ");\n"
            + "\n"
            + "-- 阶段二：盘中验证\n"
            + "CREATE TABLE IF NOT EXISTS verifies(\n"
            + "  sel_date TEXT PRIMARY KEY,\n"
            + "  verify_time TEXT,\n"
            + "  stats_json TEXT,      -- 总体/持续/脉冲分组胜率\n"
            + "  detail_json TEXT,     -- 逐标的明细\n"
            + "  deviation_json TEXT,  -- 预判偏离清单\n"
            + "  is_empty_day INTEGER DEFAULT 0,  -- 空仓日标记（无入档信号，无标的可验证）\n"
            + "  updated_at TEXT\n"
            + ");\n"
            + "\n"
            + "-- 阶段三：收盘复盘\n"
            + "CREATE TABLE IF NOT EXISTS reviews(\n"
            + "  sel_date TEXT PRIMARY KEY,\n"
            + "  review_time TEXT,\n"
            + "  four_layer_json TEXT,   -- 四层胜率\n"
            + "  accuracy_json TEXT,     -- 准确度汇总\n"
            + "  stocks_json TEXT,       -- 逐标的（四层分项+tp_profits+skipped）\n"
            + "  is_empty_day INTEGER DEFAULT 0,\n"
            + "  report_md TEXT,\n"
            + "  updated_at TEXT\n"
            + ");\n"
            + "\n"
            + "-- 阶段四：三天迭代\n"
            + "CREATE TABLE IF NOT EXISTS iterate_reports(\n"
            + "  id INTEGER PRIMARY KEY AUTOINCREMENT,\n"
            + "  trigger_date TEXT UNIQUE,\n"
            + "  is_empty_day_report INTEGER DEFAULT 0,\n"
            + "  counter INTEGER,\n"
            + "  insights_json TEXT,\n"
            + "  empty_trend_json TEXT,\n"
            + "  report_md TEXT,\n"
            + "  created_at TEXT\n"
            + ");\n"
            + "\n"
            + "-- 三轮对比完整报告（供 Swift 直读层毫秒级加载）\n"
            + "CREATE TABLE IF NOT EXISTS compare_reports(\n"
            + "  date TEXT PRIMARY KEY,\n"
            + "  json TEXT NOT NULL,\n"
            + "  updated_at TEXT\n"
            + ");\n"
            + "\n"
            + "-- 次日结果台账（F13）：**所有已评分标的**（含三档）的统一口径次日表现。\n"
            + "-- 存在理由：predicts/reviews 只覆盖 tier1+tier2，导致 tuner._build_pool 存在\n"
            + "-- 幸存者偏差 —— 调优器只能\"在已选中的标的里重新排序\"，永远看不到三档标的的真实结果。\n"
            + "-- 本表用**统一政策**（次日 09:30-11:30 窗口，目标 +discipline_target_pct%）为全部已评分\n"
            + "-- 标的打标签，让评分层参数第一次可以在\"全部候选\"上评估。\n"
            + "CREATE TABLE IF NOT EXISTS stock_outcomes(\n"
            + "  sel_date TEXT NOT NULL, code TEXT NOT NULL,\n"
            + "  name TEXT, tier INTEGER,\n"
            + "  open_pct REAL,                 -- 次日开盘涨幅（L1 跳空口径）\n"
            + "  disc_profit REAL, disc_win INTEGER, disc_hit INTEGER, disc_hit_time TEXT,\n"
            + "  window_profit REAL, close_profit REAL, high_profit REAL,\n"
            + "  target_pct REAL, window_start TEXT, window_end TEXT,\n"
            + "  skipped INTEGER DEFAULT 0,\n"
            + "  updated_at TEXT,\n"
            + "  PRIMARY KEY(sel_date, code)\n"
            + ");\n"
            + "CREATE INDEX IF NOT EXISTS idx_outcomes_date ON stock_outcomes(sel_date);\n"
            + "\n"
            + "-- 参数版本（F11）\n"
            + "CREATE TABLE IF NOT EXISTS param_versions(\n"
            + "  name TEXT PRIMARY KEY,\n"
            + "  params_json TEXT NOT NULL,\n"
            + "  is_builtin INTEGER DEFAULT 0,\n"
            + "  note TEXT DEFAULT '',\n"
            + "  created_at INTEGER\n"
            + ");\n"
            + "\n"
            + "-- 计数器（迭代计数器等，修复 D4）\n"
            + "CREATE TABLE IF NOT EXISTS counters(\n"
            + "  key TEXT PRIMARY KEY, value TEXT\n"
            + ");\n"
            + "\n"
            + "-- 数据源事件日志（F9 可观测）\n"
            + "CREATE TABLE IF NOT EXISTS data_source_logs(\n"
            + "  id INTEGER PRIMARY KEY AUTOINCREMENT,\n"
            + "  ts TEXT, source TEXT, event TEXT, detail TEXT\n"
            + ");\n"
            + "CREATE INDEX IF NOT EXISTS idx_dsl_ts ON data_source_logs(ts);\n"
            + "\n"
            + "-- 自选分组（watch 模块）；id=1 为默认组（首次初始化自动创建）\n"
            + "CREATE TABLE IF NOT EXISTS watch_groups(\n"
            + "  id INTEGER PRIMARY KEY AUTOINCREMENT,\n"
            + "  name TEXT NOT NULL UNIQUE,\n"
            + "  created_at TEXT NOT NULL\n"
            + ");\n"
            + "\n"
            + "-- 自选股列表（watch 模块）；is_holding/cost_price/shares 为用户手动持仓（仅 UI 盈亏显示，\n"
            + "-- 与引擎信号生命周期独立）\n"
            + "CREATE TABLE IF NOT EXISTS watchlist(\n"
            + "  code TEXT PRIMARY KEY,\n"
            + "  name TEXT,\n"
            + "  added_at TEXT NOT NULL,\n"
            + "  group_id INTEGER DEFAULT 1,\n"
            + "  is_holding INTEGER DEFAULT 0,\n"
            + "  cost_price REAL,\n"
            + "  shares REAL\n"
            + ");\n"
            + "\n"
            + "-- 自选股每日判定历史（三层判定：市场灯/打分/持仓状态机）\n"
            + "CREATE TABLE IF NOT EXISTS watch_judgments(\n"
            + "  id INTEGER PRIMARY KEY AUTOINCREMENT,\n"
            + "  date TEXT NOT NULL,\n"
            + "  code TEXT NOT NULL,\n"
            + "  name TEXT,\n"
            + "  action TEXT NOT NULL,\n"
            + "  score INTEGER,\n"
            + "  details_json TEXT,\n"
            + "  target_price REAL, stop_loss_price REAL, baseline_price REAL,\n"
            + "  sell_window TEXT, position_advice TEXT, risk_level TEXT,\n"
            + "  market_light TEXT,\n"
            + "  created_at TEXT NOT NULL,\n"
            + "  UNIQUE(date, code)\n"
            + ");\n"
            + "CREATE INDEX IF NOT EXISTS idx_wj_code ON watch_judgments(code, date);\n"
            + "\n"
            + "-- 证券主列表缓存（F14，2026-09-18 从 data/cache/stock_list.json 迁库）\n"
            + "-- 为什么入库：它是唯一\"跨进程共享（引擎写、Swift 读）+ 两端各写一份\"的缓存文件，\n"
            + "-- 原子写 / .tmp / 损坏回落逻辑要在两处维护；入库后单一事实来源，且可按 code 索引。\n"
            + "-- cache_date：整表替换式写入（刷新即 DELETE + INSERT），故同批行的日期必然一致。\n"
            + "CREATE TABLE IF NOT EXISTS securities(\n"
            + "  code TEXT PRIMARY KEY,\n"
            + "  name TEXT,\n"
            + "  market INTEGER,\n"
            + "  cache_date TEXT\n"
            + ");\n"
            + "\n"
            + "-- 场内基金列表缓存（ETF/LOF/封闭式；自选页「搜索添加」按名称模糊匹配用）\n"
            + "-- 为什么独立成表：`securities` 是**选股扫描的 A 股票池**，混入场内基金会让扫描器\n"
            + "-- 去给基金打分（错误池子）。基金只用于自选页搜索/加自选，与扫描链路完全隔离。\n"
            + "-- kind：etf / lof / close（来源节点），便于按类型筛选与排障。\n"
            + "CREATE TABLE IF NOT EXISTS funds(\n"
            + "  code TEXT PRIMARY KEY,\n"
            + "  name TEXT,\n"
            + "  market INTEGER,\n"
            + "  kind TEXT,\n"
            + "  cache_date TEXT\n"
            + ");\n"
            + "\n"
            + "-- 港股列表缓存（自选页「搜索添加」按名称模糊匹配港股用；2026-09-20）\n"
            + "-- 为什么独立成表：港股是**另一个市场的股票**，与场内基金（market/kind 语义）和 A 股\n"
            + "-- 扫描池都不同源；只服务自选页搜索/加自选（行情走腾讯 hk 前缀）。\n"
            + "CREATE TABLE IF NOT EXISTS hk_list(\n"
            + "  code TEXT PRIMARY KEY,\n"
            + "  name TEXT,\n"
            + "  cache_date TEXT\n"
            + ");\n"
            + "")),
        ("migration_sql", .arr([
            .str("ALTER TABLE watchlist ADD COLUMN group_id INTEGER DEFAULT 1"),
            .str("ALTER TABLE watchlist ADD COLUMN is_holding INTEGER DEFAULT 0"),
            .str("ALTER TABLE watchlist ADD COLUMN cost_price REAL"),
            .str("ALTER TABLE watchlist ADD COLUMN shares REAL"),
            .str("ALTER TABLE predicts ADD COLUMN overall_json TEXT"),
            .str("ALTER TABLE reviews ADD COLUMN insights_json TEXT"),
            .str("ALTER TABLE reviews ADD COLUMN reference_json TEXT"),
            .str("ALTER TABLE verifies ADD COLUMN warnings_json TEXT"),
            .str("ALTER TABLE verifies ADD COLUMN is_empty_day INTEGER DEFAULT 0"),
            .str("ALTER TABLE iterate_reports ADD COLUMN four_layer_avg_json TEXT"),
            .str("ALTER TABLE picks ADD COLUMN score_raw REAL"),
            .str("ALTER TABLE picks ADD COLUMN ma_qualified INTEGER"),
            .str("ALTER TABLE picks ADD COLUMN tier_lock_applied INTEGER DEFAULT 0"),
            .str("ALTER TABLE trading_days ADD COLUMN flat_count INTEGER DEFAULT 0"),
            // 个股参数覆盖已删除（2026-10-15）：日扫描本就不读覆盖，覆盖只服务个股调优，
            // 而个股调优一并下线。DROP 幂等，老库启动即清。
            .str("DROP TABLE IF EXISTS stock_param_overrides")
        ]))
    ])

    /// `engine/params/param_schema_export.json`（参数元数据 / 工厂默认 / 出厂版本表）
    public static let paramSchema: PyVal = .obj([
        ("schema_groups", .arr([
            .obj([
                ("group", .str("hard_filter")),
                ("title", .str("硬性过滤（第一层）")),
                ("items", .arr([
                    .obj([
                        ("key", .str("hard_filter.price_min")),
                        ("label", .str("最低价格")),
                        ("type", .str("float")),
                        ("default", .double(3.0)),
                        ("note", .str("低于该价格的股票不参与")),
                        ("tunable", .bool(false)),
                        ("min", .double(0.5)),
                        ("max", .double(20.0)),
                        ("step", .double(0.5)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("hard_filter.price_max")),
                        ("label", .str("最高价格")),
                        ("type", .str("float")),
                        ("default", .double(105.0)),
                        ("note", .str("高于该价格的股票不参与")),
                        ("tunable", .bool(false)),
                        ("min", .double(20.0)),
                        ("max", .double(300.0)),
                        ("step", .double(5.0)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("hard_filter.change_pct_loose")),
                        ("label", .str("宽松涨幅区间(%)")),
                        ("type", .str("num_list")),
                        ("default", .arr([
                            .double(1.0),
                            .double(6.0)
                        ])),
                        ("note", .str("硬过滤的涨幅带 [下限, 上限]，必须恰好两项（原实现硬解包2项，多一项会崩）")),
                        ("tunable", .bool(true)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .int(2)),
                        ("max_len", .int(2)),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("hard_filter.exclude_st_pattern")),
                        ("label", .str("ST/退市排除正则")),
                        ("type", .str("str")),
                        ("default", .str("ST|\\*ST|^S|退")),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("hard_filter.exclude_bse_prefix")),
                        ("label", .str("北交所代码前缀")),
                        ("type", .str("str")),
                        ("default", .str("92")),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ])
                ]))
            ]),
            .obj([
                ("group", .str("profile_filter")),
                ("title", .str("稳健画像（第二层）")),
                ("items", .arr([
                    .obj([
                        ("key", .str("profile_filter.change_pct")),
                        ("label", .str("涨幅区间(%)")),
                        ("type", .str("num_pair")),
                        ("default", .arr([
                            .double(1.8),
                            .double(5.2)
                        ])),
                        ("note", .str("当日涨幅落在该区间才入画像")),
                        ("tunable", .bool(true)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("profile_filter.volume_ratio")),
                        ("label", .str("量比区间")),
                        ("type", .str("num_pair")),
                        ("default", .arr([
                            .double(1.9),
                            .double(4.2)
                        ])),
                        ("note", .str("")),
                        ("tunable", .bool(true)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("profile_filter.turnover")),
                        ("label", .str("换手率区间(%)")),
                        ("type", .str("num_pair")),
                        ("default", .arr([
                            .double(4.2),
                            .double(10.5)
                        ])),
                        ("note", .str("")),
                        ("tunable", .bool(true)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("profile_filter.amplitude_max")),
                        ("label", .str("振幅上限(%)")),
                        ("type", .str("float")),
                        ("default", .double(13.0)),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .double(6.0)),
                        ("max", .double(20.0)),
                        ("step", .double(0.5)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("profile_filter.price_ge_avg")),
                        ("label", .str("收盘价≥均价")),
                        ("type", .str("bool")),
                        ("default", .bool(true)),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ])
                ]))
            ]),
            .obj([
                ("group", .str("form_filter")),
                ("title", .str("形态过滤（第四层）")),
                ("items", .arr([
                    .obj([
                        ("key", .str("form_filter.upper_shadow_ratio")),
                        ("label", .str("上影线容忍比")),
                        ("type", .str("float")),
                        ("default", .double(0.8)),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .double(0.2)),
                        ("max", .double(1.5)),
                        ("step", .double(0.05)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("form_filter.close_high_ratio")),
                        ("label", .str("收盘高位比")),
                        ("type", .str("float")),
                        ("default", .double(0.95)),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .double(0.6)),
                        ("max", .double(1.0)),
                        ("step", .double(0.01)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("form_filter.body_ratio_min")),
                        ("label", .str("实体占比下限")),
                        ("type", .str("float")),
                        ("default", .double(0.4)),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .double(0.1)),
                        ("max", .double(0.9)),
                        ("step", .double(0.05)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("form_filter.pass_threshold")),
                        ("label", .str("形态通过阈值(项)")),
                        ("type", .str("int")),
                        ("default", .int(2)),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .int(1)),
                        ("max", .int(3)),
                        ("step", .int(1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ])
                ]))
            ]),
            .obj([
                ("group", .str("deep_filter")),
                ("title", .str("深度技术（K线计算）")),
                ("items", .arr([
                    .obj([
                        ("key", .str("deep_filter.kline_days")),
                        ("label", .str("K线取样天数")),
                        ("type", .str("int")),
                        ("default", .int(65)),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .int(30)),
                        ("max", .int(120)),
                        ("step", .int(5)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("deep_filter.vol_avg_days")),
                        ("label", .str("分均量天数")),
                        ("type", .str("int")),
                        ("default", .int(5)),
                        ("note", .str("「5日均量倍数」所用的均量窗口（已接入计算）")),
                        ("tunable", .bool(false)),
                        ("min", .int(3)),
                        ("max", .int(10)),
                        ("step", .int(1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("deep_filter.vol_mult_normalize")),
                        ("label", .str("量能折算全日口径")),
                        ("type", .str("bool")),
                        ("default", .bool(true)),
                        ("note", .str("盘中当日量只走了部分交易时间，开启后按已交易分钟数折算到全日，否则 14:00 轮会系统性低估放量、且三轮口径不一致")),
                        ("tunable", .bool(false)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("deep_filter.ma20_slope_lookback")),
                        ("label", .str("MA20斜率回看")),
                        ("type", .str("int")),
                        ("default", .int(5)),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .int(3)),
                        ("max", .int(10)),
                        ("step", .int(1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ])
                ]))
            ]),
            .obj([
                ("group", .str("exclusion")),
                ("title", .str("深度排除规则")),
                ("items", .arr([
                    .obj([
                        ("key", .str("exclusion.deep_trend_threshold")),
                        ("label", .str("深跌排除阈值(%)")),
                        ("type", .str("float")),
                        ("default", .double(-30.0)),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .double(-60.0)),
                        ("max", .double(-10.0)),
                        ("step", .double(5.0)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("exclusion.pulse_gain_ratio")),
                        ("label", .str("脉冲排除·冲高回落保留度")),
                        ("type", .str("float")),
                        ("default", .double(0.6)),
                        ("note", .str("(收盘-昨收)÷(最高-昨收)，分子分母同为昨收基准；1=收在最高，0=涨幅全回吐。低于该值且影体比超限 → 判为脉冲假信号排除")),
                        ("tunable", .bool(true)),
                        ("min", .double(0.0)),
                        ("max", .double(1.0)),
                        ("step", .double(0.05)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("exclusion.pulse_shadow_body")),
                        ("label", .str("脉冲排除·影体比")),
                        ("type", .str("float")),
                        ("default", .double(0.5)),
                        ("note", .str("")),
                        ("tunable", .bool(true)),
                        ("min", .double(0.0)),
                        ("max", .double(2.0)),
                        ("step", .double(0.05)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("exclusion.market_change_threshold")),
                        ("label", .str("大盘弱市跌幅阈值(%)")),
                        ("type", .str("float")),
                        ("default", .double(-1.5)),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .double(-4.0)),
                        ("max", .double(-0.5)),
                        ("step", .double(0.1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("exclusion.market_ratio_threshold")),
                        ("label", .str("弱市涨跌比阈值")),
                        ("type", .str("float")),
                        ("default", .double(0.8)),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .double(0.3)),
                        ("max", .double(1.5)),
                        ("step", .double(0.1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("exclusion.market_decline_lookback")),
                        ("label", .str("连跌判定回看(日)")),
                        ("type", .str("int")),
                        ("default", .int(3)),
                        ("note", .str("回看多少个已完成交易日统计尾部连跌；≥3 才能判定连跌2日（已接入计算）")),
                        ("tunable", .bool(false)),
                        ("min", .int(3)),
                        ("max", .int(8)),
                        ("step", .int(1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ])
                ]))
            ]),
            .obj([
                ("group", .str("scoring_bonus")),
                ("title", .str("评分 · 加分项")),
                ("items", .arr([
                    .obj([
                        ("key", .str("scoring.bonus.ma_bullish")),
                        ("label", .str("均线多头排列")),
                        ("type", .str("int")),
                        ("default", .int(20)),
                        ("note", .str("")),
                        ("tunable", .bool(true)),
                        ("min", .int(0)),
                        ("max", .int(50)),
                        ("step", .int(1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.bonus.vol_mult_high")),
                        ("label", .str("放量≥1.28倍加分")),
                        ("type", .str("num_pair")),
                        ("default", .arr([
                            .double(1.28),
                            .int(20)
                        ])),
                        ("note", .str("[量比倍数, 加分]")),
                        ("tunable", .bool(true)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.bonus.vol_mult_mid")),
                        ("label", .str("放量1.0~1.28倍加分")),
                        ("type", .str("num_pair")),
                        ("default", .arr([
                            .double(1.0),
                            .int(10)
                        ])),
                        ("note", .str("")),
                        ("tunable", .bool(true)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.bonus.consec_up")),
                        ("label", .str("连涨加分表")),
                        ("type", .str("json")),
                        ("default", .obj([
                            ("le1", .int(15)),
                            ("le2", .int(10)),
                            ("le3", .int(5)),
                            ("gt3", .int(0))
                        ])),
                        ("note", .str("键名即阈值：le1=连涨≤1天, gt3=连涨>3天。**改表即生效**（含 gt3）")),
                        ("tunable", .bool(false)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.bonus.cum_5d")),
                        ("label", .str("5日累计涨幅加分表")),
                        ("type", .str("json")),
                        ("default", .obj([
                            ("le8", .int(15)),
                            ("le12", .int(10)),
                            ("le15", .int(5)),
                            ("gt15", .int(0))
                        ])),
                        ("note", .str("键名即阈值：le8=累计≤8%…… gt15=累计>15%。**改表即生效**（含 gt15）")),
                        ("tunable", .bool(false)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.bonus.dist_low")),
                        ("label", .str("距低点距离加分表")),
                        ("type", .str("json")),
                        ("default", .obj([
                            ("le15", .int(10)),
                            ("le25", .int(5)),
                            ("gt25", .int(0))
                        ])),
                        ("note", .str("键名即阈值。**改表即生效**（含 gt25）")),
                        ("tunable", .bool(false)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.bonus.dist_high")),
                        ("label", .str("距高点距离加分表")),
                        ("type", .str("json")),
                        ("default", .obj([
                            ("le_neg5", .int(5)),
                            ("gt_neg5", .int(0))
                        ])),
                        ("note", .str("_neg 表示负值：le_neg5=距高点≤-5%。**改表即生效**（含 gt_neg5）")),
                        ("tunable", .bool(false)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.bonus.form_full")),
                        ("label", .str("形态全满足")),
                        ("type", .str("int")),
                        ("default", .int(10)),
                        ("note", .str("")),
                        ("tunable", .bool(true)),
                        ("min", .int(0)),
                        ("max", .int(30)),
                        ("step", .int(1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.bonus.form_pass")),
                        ("label", .str("形态部分满足")),
                        ("type", .str("int")),
                        ("default", .int(5)),
                        ("note", .str("")),
                        ("tunable", .bool(true)),
                        ("min", .int(0)),
                        ("max", .int(20)),
                        ("step", .int(1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.bonus.market_ok_ok")),
                        ("label", .str("大盘强+涨跌比健康")),
                        ("type", .str("int")),
                        ("default", .int(5)),
                        ("note", .str("")),
                        ("tunable", .bool(true)),
                        ("min", .int(0)),
                        ("max", .int(20)),
                        ("step", .int(1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.bonus.market_ok_only")),
                        ("label", .str("大盘强（弱涨跌比）")),
                        ("type", .str("int")),
                        ("default", .int(3)),
                        ("note", .str("")),
                        ("tunable", .bool(true)),
                        ("min", .int(0)),
                        ("max", .int(15)),
                        ("step", .int(1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.bonus.ma20_slope_up")),
                        ("label", .str("MA20 向上")),
                        ("type", .str("int")),
                        ("default", .int(5)),
                        ("note", .str("")),
                        ("tunable", .bool(true)),
                        ("min", .int(0)),
                        ("max", .int(20)),
                        ("step", .int(1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ])
                ]))
            ]),
            .obj([
                ("group", .str("scoring_penalty")),
                ("title", .str("评分 · 扣分项")),
                ("items", .arr([
                    .obj([
                        ("key", .str("scoring.penalty.prev_1d")),
                        ("label", .str("前日涨幅扣分表")),
                        ("type", .str("json")),
                        ("default", .obj([
                            ("gt7", .int(-10)),
                            ("gt5", .int(-5))
                        ])),
                        ("note", .str("键名即阈值：gt7=前日涨>7%。**改表即生效**（原实现阈值 7/5 写死在代码里）")),
                        ("tunable", .bool(false)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.penalty.ma_deviation")),
                        ("label", .str("乖离率扣分表")),
                        ("type", .str("json")),
                        ("default", .obj([
                            ("lt2", .int(0)),
                            ("le5", .int(-5)),
                            ("gt5", .int(-10))
                        ])),
                        ("note", .str("键名即阈值：lt2=偏离<2% 不扣分。**改表即生效**")),
                        ("tunable", .bool(false)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.penalty.stagnation")),
                        ("label", .str("滞涨判定扣分")),
                        ("type", .str("json")),
                        ("default", .obj([
                            ("vol_ratio_min", .double(2.0)),
                            ("gain_ratio", .double(0.6)),
                            ("score", .int(-5))
                        ])),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.penalty.long_shadow")),
                        ("label", .str("长上影判定扣分")),
                        ("type", .str("json")),
                        ("default", .obj([
                            ("vol_ratio_min", .double(2.0)),
                            ("shadow_body", .double(0.5)),
                            ("score", .int(-5))
                        ])),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.penalty.vol_shrink")),
                        ("label", .str("缩量扣分")),
                        ("type", .str("json")),
                        ("default", .obj([
                            ("threshold", .double(1.0)),
                            ("score", .int(-5))
                        ])),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.penalty.cum_5d_low")),
                        ("label", .str("5日累计过低扣分")),
                        ("type", .str("json")),
                        ("default", .obj([
                            ("threshold", .double(3.0)),
                            ("score", .int(-5))
                        ])),
                        ("note", .str("阈值表；**显式填 null 表示本版本停用该扣分**（classic 基线早于该参数，补值会改变其历史行为）。停用不是缺失：留空不会阻断保存（2026-09-17 修复）")),
                        ("tunable", .bool(false)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(true))
                    ])
                ]))
            ]),
            .obj([
                ("group", .str("scoring_intraday")),
                ("title", .str("评分 · 尾盘分时结构")),
                ("items", .arr([
                    .obj([
                        ("key", .str("scoring.intraday.enabled")),
                        ("label", .str("启用尾盘分时")),
                        ("type", .str("bool")),
                        ("default", .bool(true)),
                        ("note", .str("需要 5 分钟线；开启后整轮会增加约 3-9s（仅对形态通过后的候选拉取）")),
                        ("tunable", .bool(false)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.intraday.tail_window_min")),
                        ("label", .str("尾盘窗口(分钟)")),
                        ("type", .str("int")),
                        ("default", .int(30)),
                        ("note", .str("取「已交易时段的最后 N 分钟」，与第几轮无关，保证三轮可比")),
                        ("tunable", .bool(true)),
                        ("min", .int(15)),
                        ("max", .int(60)),
                        ("step", .int(5)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.intraday.min_bars")),
                        ("label", .str("最少5分钟根数")),
                        ("type", .str("int")),
                        ("default", .int(20)),
                        ("note", .str("当日 5 分钟线不足该根数则本维度整体放弃（不猜）")),
                        ("tunable", .bool(false)),
                        ("min", .int(6)),
                        ("max", .int(48)),
                        ("step", .int(2)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.intraday.tail_gain_min")),
                        ("label", .str("尾盘拉升下限(%)")),
                        ("type", .str("float")),
                        ("default", .double(0.3)),
                        ("note", .str("尾盘区间涨跌幅（首根收盘→末根收盘）")),
                        ("tunable", .bool(true)),
                        ("min", .double(-1.0)),
                        ("max", .double(3.0)),
                        ("step", .double(0.1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.intraday.tail_gain_score")),
                        ("label", .str("尾盘拉升加分")),
                        ("type", .str("int")),
                        ("default", .int(8)),
                        ("note", .str("标定支持：≥0.3% 组 L3 期望 -0.627 vs <0.3% 的 -0.855（方向正确）")),
                        ("tunable", .bool(true)),
                        ("min", .int(0)),
                        ("max", .int(25)),
                        ("step", .int(1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.intraday.close_position_min")),
                        ("label", .str("收盘强度分位下限")),
                        ("type", .str("float")),
                        ("default", .double(0.9)),
                        ("note", .str("收盘价在当日[最低,最高]中的分位，1.0=收在最高")),
                        ("tunable", .bool(true)),
                        ("min", .double(0.5)),
                        ("max", .double(1.0)),
                        ("step", .double(0.02)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.intraday.close_position_score")),
                        ("label", .str("收盘强度加分")),
                        ("type", .str("int")),
                        ("default", .int(15)),
                        ("note", .str("标定显示这是**最强且单调**的维度：≥0.9 组 L3 期望 -0.427、平均跳空 +0.121%；≥0.97 组 -0.317 / 跳空 +0.737% → 权重由 8 提到 15")),
                        ("tunable", .bool(true)),
                        ("min", .int(0)),
                        ("max", .int(30)),
                        ("step", .int(1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.intraday.tail_new_high_score")),
                        ("label", .str("尾盘创日内新高加分")),
                        ("type", .str("int")),
                        ("default", .int(10)),
                        ("note", .str("标定支持：创新高组平均跳空 -0.048% vs 未创新高 -0.46%（原实现漏了这项加分）")),
                        ("tunable", .bool(true)),
                        ("min", .int(0)),
                        ("max", .int(25)),
                        ("step", .int(1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.intraday.high_age_max")),
                        ("label", .str("高点陈旧度上限")),
                        ("type", .str("float")),
                        ("default", .double(0.85)),
                        ("note", .str("(已交易时长-高点出现时的时长)÷已交易时长。标定显示阈值 0.85 比 0.75 更精准（≥0.85→-0.869 vs <0.85→-0.684）。注意：不要改用「高点是否在早盘」——早盘天然占已交易时长约58%，那是时间权重不是信号")),
                        ("tunable", .bool(true)),
                        ("min", .double(0.3)),
                        ("max", .double(1.0)),
                        ("step", .double(0.05)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.intraday.stale_high_penalty")),
                        ("label", .str("高点陈旧扣分")),
                        ("type", .str("int")),
                        ("default", .int(-8)),
                        ("note", .str("")),
                        ("tunable", .bool(true)),
                        ("min", .int(-25)),
                        ("max", .int(0)),
                        ("step", .int(1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ])
                ]))
            ]),
            .obj([
                ("group", .str("budget")),
                ("title", .str("性能预算（防跑飞）")),
                ("items", .arr([
                    .obj([
                        ("key", .str("budget.deep_budget_sec")),
                        ("label", .str("深挖耗时上限(秒)")),
                        ("type", .str("float")),
                        ("default", .double(120.0)),
                        ("note", .str("候选深挖阶段（日K+5分钟线）的耗时上限；0=不限。触发后按「形态分→量比」优先级保留较好的，其余不评分并在日志留痕")),
                        ("tunable", .bool(false)),
                        ("min", .int(0)),
                        ("max", .int(600)),
                        ("step", .int(10)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("budget.max_deep_candidates")),
                        ("label", .str("深挖候选上限(只)")),
                        ("type", .str("int")),
                        ("default", .int(0)),
                        ("note", .str("0=不限。与耗时上限任一先到即停；未触发时对结果零影响")),
                        ("tunable", .bool(false)),
                        ("min", .int(0)),
                        ("max", .int(2000)),
                        ("step", .int(20)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ])
                ]))
            ]),
            .obj([
                ("group", .str("tiers")),
                ("title", .str("档位与锁档")),
                ("items", .arr([
                    .obj([
                        ("key", .str("scoring.tiers.tier1_min")),
                        ("label", .str("一档门槛(分)")),
                        ("type", .str("int")),
                        ("default", .int(70)),
                        ("note", .str("")),
                        ("tunable", .bool(true)),
                        ("min", .int(55)),
                        ("max", .int(95)),
                        ("step", .int(1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.tiers.tier2_min")),
                        ("label", .str("二档门槛(分)")),
                        ("type", .str("int")),
                        ("default", .int(50)),
                        ("note", .str("")),
                        ("tunable", .bool(true)),
                        ("min", .int(35)),
                        ("max", .int(75)),
                        ("step", .int(1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.tier_lock.enabled")),
                        ("label", .str("均线降档锁启用")),
                        ("type", .str("bool")),
                        ("default", .bool(true)),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("scoring.tier_lock.max_score")),
                        ("label", .str("非多头最高分")),
                        ("type", .str("int")),
                        ("default", .int(69)),
                        ("note", .str("均线非多头时分数封顶（低于一档门槛则强制三档）")),
                        ("tunable", .bool(true)),
                        ("min", .int(0)),
                        ("max", .int(100)),
                        ("step", .int(1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ])
                ]))
            ]),
            .obj([
                ("group", .str("etf")),
                ("title", .str("ETF 推荐")),
                ("items", .arr([
                    .obj([
                        ("key", .str("etf.change_pct_min")),
                        ("label", .str("涨幅下限(%)")),
                        ("type", .str("float")),
                        ("default", .double(0.5)),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .double(0.0)),
                        ("max", .double(3.0)),
                        ("step", .double(0.1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("etf.volume_ratio_min")),
                        ("label", .str("量比下限")),
                        ("type", .str("float")),
                        ("default", .double(1.0)),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .double(0.5)),
                        ("max", .double(3.0)),
                        ("step", .double(0.1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("etf.top_n")),
                        ("label", .str("推荐数量")),
                        ("type", .str("int")),
                        ("default", .int(8)),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .int(1)),
                        ("max", .int(20)),
                        ("step", .int(1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("etf.codes")),
                        ("label", .str("ETF 池(逗号分隔代码)")),
                        ("type", .str("str_list")),
                        ("default", .null),
                        ("note", .str("用逗号分隔，如 159915,510300")),
                        ("tunable", .bool(false)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ])
                ]))
            ]),
            .obj([
                ("group", .str("predict")),
                ("title", .str("预判策略")),
                ("items", .arr([
                    .obj([
                        ("key", .str("predict_rules.red_decline_days")),
                        ("label", .str("红灯连跌天数")),
                        ("type", .str("int")),
                        ("default", .int(2)),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .int(1)),
                        ("max", .int(5)),
                        ("step", .int(1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("predict_rules.yellow_open_threshold")),
                        ("label", .str("黄灯开盘阈值(%)")),
                        ("type", .str("float")),
                        ("default", .double(-0.5)),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .double(-3.0)),
                        ("max", .double(0.0)),
                        ("step", .double(0.1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("predict_rules.strategies")),
                        ("label", .str("策略表(JSON)")),
                        ("type", .str("json")),
                        ("default", .null),
                        ("note", .str("5 种策略的卖出窗口/目标/止损/风险/仓位/文案，JSON 对象")),
                        ("tunable", .bool(false)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("predict_rules.regime_thresholds")),
                        ("label", .str("大盘状态门槛浮动")),
                        ("type", .str("json")),
                        ("default", .null),
                        ("note", .str("五种大盘状态对目标价/止损价/自选打分线的**浮动量**（target_adj/stop_adj 是百分点、score_adj 是分；**负 = 降门槛**）。灯级判定不受它影响；`crash` 分支不偏移（仓位建议是空仓，调它没意义）")),
                        ("tunable", .bool(false)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ])
                ]))
            ]),
            .obj([
                ("group", .str("iterate")),
                ("title", .str("迭代与风控阈值")),
                ("items", .arr([
                    .obj([
                        ("key", .str("iterate.trigger_interval")),
                        ("label", .str("迭代触发间隔(有效日)")),
                        ("type", .str("int")),
                        ("default", .int(3)),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .int(1)),
                        ("max", .int(10)),
                        ("step", .int(1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("iterate.empty_trend_days")),
                        ("label", .str("空仓趋势统计天数")),
                        ("type", .str("int")),
                        ("default", .int(10)),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .int(3)),
                        ("max", .int(30)),
                        ("step", .int(1)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("iterate.warning_pct")),
                        ("label", .str("空仓告警线(%)")),
                        ("type", .str("float")),
                        ("default", .int(80)),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .int(30)),
                        ("max", .int(100)),
                        ("step", .int(5)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("iterate.notice_pct")),
                        ("label", .str("空仓提示线(%)")),
                        ("type", .str("float")),
                        ("default", .int(50)),
                        ("note", .str("")),
                        ("tunable", .bool(false)),
                        ("min", .int(20)),
                        ("max", .int(90)),
                        ("step", .int(5)),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ]),
                    .obj([
                        ("key", .str("iterate.thresholds")),
                        ("label", .str("阈值表(JSON)")),
                        ("type", .str("json")),
                        ("default", .null),
                        ("note", .str("含窗口/收盘/高点偏差、胜率线、晨午比、纪律目标幅度(discipline_target_pct)、平均收益封顶(avg_profit_cap) 等")),
                        ("tunable", .bool(false)),
                        ("min", .null),
                        ("max", .null),
                        ("step", .null),
                        ("min_len", .null),
                        ("max_len", .null),
                        ("optional", .bool(false))
                    ])
                ]))
            ])
        ])),
        ("required_json_keys", .obj([
            ("scoring.bonus.consec_up", .arr([
                .str("le1"),
                .str("le2"),
                .str("le3"),
                .str("gt3")
            ])),
            ("scoring.bonus.cum_5d", .arr([
                .str("le8"),
                .str("le12"),
                .str("le15"),
                .str("gt15")
            ])),
            ("scoring.bonus.dist_low", .arr([
                .str("le15"),
                .str("le25"),
                .str("gt25")
            ])),
            ("scoring.bonus.dist_high", .arr([
                .str("le_neg5"),
                .str("gt_neg5")
            ])),
            ("scoring.penalty.prev_1d", .arr([
                .str("gt7"),
                .str("gt5")
            ])),
            ("scoring.penalty.ma_deviation", .arr([
                .str("lt2"),
                .str("le5"),
                .str("gt5")
            ])),
            ("scoring.penalty.stagnation", .arr([
                .str("vol_ratio_min"),
                .str("gain_ratio"),
                .str("score")
            ])),
            ("scoring.penalty.long_shadow", .arr([
                .str("vol_ratio_min"),
                .str("shadow_body"),
                .str("score")
            ])),
            ("scoring.penalty.vol_shrink", .arr([
                .str("threshold"),
                .str("score")
            ])),
            ("predict_rules.strategies", .arr([
                .str("up_consensus"),
                .str("up_pulse"),
                .str("down_consensus"),
                .str("down_pulse"),
                .str("crash")
            ])),
            ("predict_rules.regime_thresholds", .arr([
                .str("BULL_TREND"),
                .str("BULL_CORRECTION"),
                .str("BEAR_TREND"),
                .str("PANIC"),
                .str("RECOVERY")
            ])),
            ("iterate.thresholds", .arr([
                .str("discipline_target_pct"),
                .str("discipline_window")
            ]))
        ])),
        ("factory_params", .obj([
            ("hard_filter", .obj([
                ("price_min", .double(3.0)),
                ("price_max", .double(105.0)),
                ("amplitude_max", .double(15.0)),
                ("change_pct_min", .double(-7.0)),
                ("change_pct_loose", .arr([
                    .double(1.0),
                    .double(6.0)
                ])),
                ("exclude_st_pattern", .str("ST|\\*ST|^S|退")),
                ("exclude_bse_prefix", .str("92")),
                ("one_word_board_pct", .double(9.0))
            ])),
            ("profile_filter", .obj([
                ("change_pct", .arr([
                    .double(1.8),
                    .double(5.2)
                ])),
                ("volume_ratio", .arr([
                    .double(1.9),
                    .double(4.2)
                ])),
                ("turnover", .arr([
                    .double(4.2),
                    .double(10.5)
                ])),
                ("amplitude_max", .double(13.0)),
                ("price_ge_avg", .bool(true))
            ])),
            ("risk_filter", .obj([
                ("volume_ratio_hard_max", .double(6.8)),
                ("turnover_hard_max", .double(17.5))
            ])),
            ("form_filter", .obj([
                ("upper_shadow_ratio", .double(0.8)),
                ("close_high_ratio", .double(0.95)),
                ("body_ratio_min", .double(0.4)),
                ("pass_threshold", .int(2))
            ])),
            ("deep_filter", .obj([
                ("kline_days", .int(65)),
                ("vol_avg_days", .int(5)),
                ("ma20_slope_lookback", .int(5)),
                ("vol_mult_normalize", .bool(true))
            ])),
            ("exclusion", .obj([
                ("deep_trend_threshold", .double(-30.0)),
                ("pulse_gain_ratio", .double(0.6)),
                ("pulse_shadow_body", .double(0.5)),
                ("market_change_threshold", .double(-1.5)),
                ("market_ratio_threshold", .double(0.8)),
                ("market_decline_lookback", .int(3))
            ])),
            ("scoring", .obj([
                ("bonus", .obj([
                    ("ma_bullish", .int(20)),
                    ("vol_mult_high", .arr([
                        .double(1.28),
                        .int(20)
                    ])),
                    ("vol_mult_mid", .arr([
                        .double(1.0),
                        .int(10)
                    ])),
                    ("consec_up", .obj([
                        ("le1", .int(15)),
                        ("le2", .int(10)),
                        ("le3", .int(5)),
                        ("gt3", .int(0))
                    ])),
                    ("cum_5d", .obj([
                        ("le8", .int(15)),
                        ("le12", .int(10)),
                        ("le15", .int(5)),
                        ("gt15", .int(0))
                    ])),
                    ("dist_low", .obj([
                        ("le15", .int(10)),
                        ("le25", .int(5)),
                        ("gt25", .int(0))
                    ])),
                    ("dist_high", .obj([
                        ("le_neg5", .int(5)),
                        ("gt_neg5", .int(0))
                    ])),
                    ("form_full", .int(10)),
                    ("form_pass", .int(5)),
                    ("market_ok_ok", .int(5)),
                    ("market_ok_only", .int(3)),
                    ("ma20_slope_up", .int(5))
                ])),
                ("penalty", .obj([
                    ("prev_1d", .obj([
                        ("gt7", .int(-10)),
                        ("gt5", .int(-5))
                    ])),
                    ("ma_deviation", .obj([
                        ("lt2", .int(0)),
                        ("le5", .int(-5)),
                        ("gt5", .int(-10))
                    ])),
                    ("stagnation", .obj([
                        ("vol_ratio_min", .double(2.0)),
                        ("gain_ratio", .double(0.6)),
                        ("score", .int(-5))
                    ])),
                    ("long_shadow", .obj([
                        ("vol_ratio_min", .double(2.0)),
                        ("shadow_body", .double(0.5)),
                        ("score", .int(-5))
                    ])),
                    ("vol_shrink", .obj([
                        ("threshold", .double(1.0)),
                        ("score", .int(-5))
                    ])),
                    ("cum_5d_low", .obj([
                        ("threshold", .double(3.0)),
                        ("score", .int(-5))
                    ]))
                ])),
                ("tier_lock", .obj([
                    ("enabled", .bool(true)),
                    ("max_score", .int(69))
                ])),
                ("tiers", .obj([
                    ("tier1_min", .int(70)),
                    ("tier2_min", .int(50))
                ])),
                ("intraday", .obj([
                    ("enabled", .bool(true)),
                    ("tail_window_min", .int(30)),
                    ("min_bars", .int(20)),
                    ("tail_vol_ratio_min", .double(1.5)),
                    ("tail_vol_ratio_score", .int(0)),
                    ("tail_gain_min", .double(0.3)),
                    ("tail_gain_score", .int(8)),
                    ("close_position_min", .double(0.9)),
                    ("close_position_score", .int(15)),
                    ("tail_new_high_score", .int(10)),
                    ("high_age_max", .double(0.85)),
                    ("stale_high_penalty", .int(-8))
                ])),
                ("patterns", .obj([
                    ("enabled", .bool(false)),
                    ("bullish_score", .int(6)),
                    ("bearish_score", .int(-6)),
                    ("neutral_score", .int(0)),
                    ("cap", .int(12))
                ]))
            ])),
            ("etf", .obj([
                ("change_pct_min", .double(0.5)),
                ("volume_ratio_min", .double(1.0)),
                ("top_n", .int(8)),
                ("codes", .arr([
                    .str("159915"),
                    .str("510300"),
                    .str("510500"),
                    .str("159919"),
                    .str("512100"),
                    .str("159922"),
                    .str("510050"),
                    .str("159949"),
                    .str("512660"),
                    .str("512480"),
                    .str("159992"),
                    .str("512010"),
                    .str("512170"),
                    .str("159881"),
                    .str("588000"),
                    .str("159869"),
                    .str("560250"),
                    .str("159667"),
                    .str("562500"),
                    .str("159995"),
                    .str("515790"),
                    .str("516160"),
                    .str("515050"),
                    .str("512690"),
                    .str("512800"),
                    .str("159766"),
                    .str("515170"),
                    .str("512680"),
                    .str("515710"),
                    .str("159825"),
                    .str("512980"),
                    .str("515030"),
                    .str("562000"),
                    .str("159605"),
                    .str("513100"),
                    .str("513500"),
                    .str("159941"),
                    .str("510880"),
                    .str("512880"),
                    .str("515180"),
                    .str("159989"),
                    .str("513050")
                ]))
            ])),
            ("rounds", .obj([
                ("slots", .arr([
                    .str("14:00"),
                    .str("14:30"),
                    .str("14:50")
                ])),
                ("boundaries", .arr([
                    .str("14:15"),
                    .str("14:40")
                ]))
            ])),
            ("budget", .obj([
                ("deep_budget_sec", .double(120.0)),
                ("max_deep_candidates", .int(0))
            ])),
            ("phases", .obj([
                ("predict", .str("09:30")),
                ("verify", .str("10:00")),
                ("review", .str("15:05")),
                ("iterate", .str("15:30"))
            ])),
            ("predict_rules", .obj([
                ("red_decline_days", .int(2)),
                ("yellow_open_threshold", .double(-0.5)),
                ("regime_thresholds", .obj([
                    ("BULL_TREND", .obj([
                        ("target_adj", .double(0.0)),
                        ("stop_adj", .double(0.0)),
                        ("score_adj", .double(0.0))
                    ])),
                    ("BULL_CORRECTION", .obj([
                        ("target_adj", .double(-1.0)),
                        ("stop_adj", .double(0.5)),
                        ("score_adj", .double(-3.0))
                    ])),
                    ("BEAR_TREND", .obj([
                        ("target_adj", .double(1.0)),
                        ("stop_adj", .double(-0.5)),
                        ("score_adj", .double(5.0))
                    ])),
                    ("PANIC", .obj([
                        ("target_adj", .double(2.0)),
                        ("stop_adj", .double(-1.0)),
                        ("score_adj", .double(10.0))
                    ])),
                    ("RECOVERY", .obj([
                        ("target_adj", .double(-0.5)),
                        ("stop_adj", .double(0.0)),
                        ("score_adj", .double(-2.0))
                    ]))
                ])),
                ("strategies", .obj([
                    ("up_consensus", .obj([
                        ("window", .arr([
                            .str("10:30"),
                            .str("11:30")
                        ])),
                        ("target_pct", .double(2.0)),
                        ("stop_pct", .double(-2.0)),
                        ("risk", .str("低")),
                        ("position", .str("正常仓位")),
                        ("direction", .str("上午强，10:30-11:30冲高"))
                    ])),
                    ("up_pulse", .obj([
                        ("window", .arr([
                            .str("10:00"),
                            .str("10:30")
                        ])),
                        ("target_pct", .double(2.0)),
                        ("stop_pct", .double(-2.0)),
                        ("risk", .str("中")),
                        ("position", .str("半仓")),
                        ("direction", .str("短冲高，见好就收"))
                    ])),
                    ("down_consensus", .obj([
                        ("window", .arr([
                            .str("14:30"),
                            .str("15:00")
                        ])),
                        ("target_pct", .double(1.0)),
                        ("stop_pct", .double(-1.5)),
                        ("risk", .str("中")),
                        ("position", .str("半仓")),
                        ("direction", .str("午后修复，尾盘卖出"))
                    ])),
                    ("down_pulse", .obj([
                        ("window", .arr([
                            .str("09:30"),
                            .str("10:00")
                        ])),
                        ("target_pct", .double(1.0)),
                        ("stop_pct", .double(-1.5)),
                        ("risk", .str("高")),
                        ("position", .str("轻仓")),
                        ("direction", .str("低开反弹，尽快离场"))
                    ])),
                    ("crash", .obj([
                        ("window", .arr([
                            .str("--"),
                            .str("--")
                        ])),
                        ("target_pct", .double(0.0)),
                        ("stop_pct", .double(0.0)),
                        ("risk", .str("极高")),
                        ("position", .str("空仓观望")),
                        ("direction", .str("暴跌日不操作"))
                    ]))
                ]))
            ])),
            ("iterate", .obj([
                ("trigger_interval", .int(3)),
                ("empty_trend_days", .int(10)),
                ("warning_pct", .int(80)),
                ("notice_pct", .int(50)),
                ("tune_pool_days", .int(120)),
                ("include_replay", .bool(false)),
                ("thresholds", .obj([
                    ("window_vs_snap", .int(10)),
                    ("window_vs_close", .int(10)),
                    ("high_vs_window", .int(15)),
                    ("low_winrate", .int(40)),
                    ("low_high_winrate", .int(50)),
                    ("group_market", .int(20)),
                    ("group_signal", .int(15)),
                    ("morning_ratio", .double(0.6)),
                    ("afternoon_ratio", .double(0.6)),
                    ("discipline_target_pct", .double(1.5)),
                    ("discipline_window", .arr([
                        .str("09:30"),
                        .str("11:30")
                    ])),
                    ("avg_profit_cap", .double(10.0))
                ]))
            ]))
        ])),
        ("builtin_versions", .obj([
            ("默认", .str("classic_2026_7_16.json")),
            ("backtest", .str("backtest_v1_1_0.json")),
            ("backtest-1.2.0", .str("backtest_v1_2_0.json")),
            ("backtest-1.3.0", .str("backtest_v1_3_0.json")),
            ("backtest-strict", .str("backtest_strict.json"))
        ])),
        ("builtin_order", .arr([
            .str("默认"),
            .str("backtest"),
            .str("backtest-1.2.0"),
            .str("backtest-1.3.0"),
            .str("backtest-strict")
        ])),
        ("default_active", .str("backtest-1.3.0")),
        ("protected_versions", .arr([
            .str("默认")
        ])),
        ("deleted_builtins_key", .str("params_deleted_builtins")),
        ("superseded_defaults", .obj([
            ("backtest", .str("backtest-1.3.0")),
            ("backtest-1.2.0", .str("backtest-1.3.0"))
        ])),
        ("migration_flag_key", .str("param_default_migrated"))
    ])
}
