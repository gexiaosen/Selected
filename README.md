# Selected — A股尾盘量化选股 Mac 应用

基于实盘验证的「尾盘选股」系统（late-day-stock-picker-2 策略）的完整产品化实现。

三轮对比选股 × 四阶段验证闭环 × 菜单栏常驻自动化。全部业务逻辑为 **Swift 原生实现**，
运行期不依赖任何 Python 进程或解释器。

- **完整功能说明**：见 [docs/功能说明.md](docs/功能说明.md)
- **设计决策依据**：见 [docs/specs/README.md](docs/specs/README.md)（决策台账）
- **版本变更记录**：见 [CHANGELOG.md](CHANGELOG.md)（1.0.0 起仓库历史重建为单提交，旧历史不再随仓库分发）

---

## 下载与安装

从 [Releases](https://github.com/gexiaosen/Selected/releases/latest) 下载
`Selected-v<版本>-arm64.dmg`，打开后把 Selected 拖进「应用程序」。

- **仅 Apple Silicon（arm64）+ macOS 26+**：Intel / Rosetta 不支持。
- **首次打开会被 Gatekeeper 拦**：应用用 Apple Development 证书签名、未走公证，属预期。
  右键点应用 →「打开」，或到「系统设置 › 隐私与安全性」点「仍要打开」。
- **自动更新**：基于 Sparkle（EdDSA 签名的 DMG 通道，不依赖 Apple Developer ID）。
  每天静默检查一次，发现新版只在侧栏齿轮上亮红点、不弹窗；要立即检查走
  应用菜单「Selected › 检查更新…」或「设置 › 关于 › 检查更新…」。
- **签名证书一年一换**：到期后新版本的身份会变，首次启动会重新问一遍文件夹/钥匙串授权；
  旧版本的自动更新检查不受影响。

---

## 快速开始

### 1. 纯本地安全调试运行（不改版本号、不提交 Git、不碰生产库）

开发联调建议使用独立临时目录与仓库外构建目录（避开 FileProvider 扩展属性与生产数据写入）：

```bash
# 方式 A：使用 SwiftPM 构建并以隔离数据目录运行
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # 若系统默认 CLT 找不到工具链时设置
swift build --package-path SelectedApp --disable-sandbox \
  --scratch-path "${TMPDIR:-/tmp}/selected-swift-build"

mkdir -p /tmp/selected-dev-data
SELECTED_DATA_DIR=/tmp/selected-dev-data \
  "${TMPDIR:-/tmp}/selected-swift-build/debug/Selected"

# 方式 B：构建本地 .app 包但完全不改 Info.plist / 不提交 Git / 不推送
bash SelectedApp/build_app.sh debug --no-commit
SELECTED_DATA_DIR=/tmp/selected-dev-data open SelectedApp/dist/Selected.app
```

> 首次启动自动完成建库、Schema 迁移与随包出厂参数注入。
> **前置条件**：
> - **历史回放 / 指标快照**：`history.sqlite3` 初始为空；需在 **设置 › 数据 › 历史回放** 中联网下载全市场日 K 缓存后，指标快照重算（`indsnap`）与历史回放才能工作（首次下载走全局限速，受东财限流约束，建议避开交易高峰）。
> - **系统通知授权**：首次启动后请在 **设置 › 提醒** 完成通知授权，否则每日调度与自定义价格提醒不会弹窗提示。

### 2. 本地打包 / 安装（`build_app.sh`）

```bash
# 完整本地发布流：先跑全量回归闸门 → 递增版本号 → 签名落位 dist/Selected.app →
# 备份生产数据库（scripts/backup_data.sh）→ git add -A && commit → git push origin/main
bash SelectedApp/build_app.sh [--install]

# 仅跳过远端推送（仍会递增版本号并在本地执行 git commit + tag）
bash SelectedApp/build_app.sh --no-push

# 仅本地打包（不改 Info.plist 版本/构建号，不执行 git add/commit/tag/push）
bash SelectedApp/build_app.sh --no-commit

# 只出 DMG（用已经签好名的 dist/Selected.app，布局烘焙见 Resources/DMG/）
bash SelectedApp/Scripts/make-dmg.sh SelectedApp/dist/Selected.app \
  SelectedApp/dist/Selected-v1.0.0-arm64.dmg
```

- **签名身份**：默认自动探测 `Apple Development`（与 MiscKit 复用同一张证书）；也可用
  `SELECTED_SIGN_IDENTITY` 指定。Sparkle.framework 内的 XPC / Updater.app / Autoupdate
  由内到外逐层重签，最后 `codesign --verify --deep --strict` 校验。
- **`--no-commit` vs `--no-push`**：`--no-push` **仍会修改版本号并执行 `git add -A && git commit`**；只是验证打包产物而不希望产生提交时，务必使用 **`--no-commit`**。
- **回归闸门**：`release` 模式打包前先跑 `engine/tests/run_all.sh`；任一测试或护栏失败则立刻终止，不递增版本号、不提交、不推送。`debug` 不跑全量回归闸门。
- **推送失败保护**：推送失败将以非零状态码退出并打印提示（不会自动重试 `git push`），本地提交保留，修复网络或远端权限后手动 `git push` 即可。
- **`--install` 行为**：先退出正在运行的实例再覆盖 `/Applications/Selected.app` 并注册 LaunchServices，**不会自动重启**，装完需手动 `open -a /Applications/Selected.app`。

### 3. 打 tag 发正式版（CI 出包）

推 `v*.*.*` tag 触发 `.github/workflows/release.yml`：

```bash
git tag -a v1.0.0 -m "Selected 1.0.0"
git push origin v1.0.0
```

CI 会：校验 tag 与 `Info.plist` 版本一致、要求构建号大于上一版 → 全量回归 →
导入签名证书并以 `Apple Development` 身份签名（验 designated requirement，退回 ad-hoc 直接失败）
→ 出 app 与 DMG → 用 `SPARKLE_PRIVATE_ED_KEY` 做 EdDSA 签名 → 创建 GitHub Release
（带 DMG、app.zip、更新说明）→ 生成并上传 `appcast.xml` 到 release 资产。

必需的仓库 Secrets：`SELECTED_SIGNING_CERT_P12`、`SELECTED_SIGNING_CERT_PASSWORD`、
`SPARKLE_PRIVATE_ED_KEY`（前两项由 `SelectedApp/Scripts/upload-signing-cert.sh` 导出上传；
Sparkle 私钥在 `~/.config/selected/sparkle_ed25519`，切勿入库）。

### 开发环境

- **macOS 26+**：`Package.swift` 的 `platforms: [.macOS(.v26)]` 与 `Info.plist` 的
  `LSMinimumSystemVersion = 26.0` 是唯一权威 —— **两处必须同步**（护栏 `version_sync` 钉住）。
  漏改 `Info.plist` 的后果不是崩溃，而是老系统上系统**直接拒绝启动**
- **仅 Apple Silicon（arm64）**：不支持 Intel / Rosetta（`build_app.sh` 对非 arm64 硬断言终止）
- **Xcode 26+**（`.macOS(.v26)` 需要 `swift-tools-version:6.2`；CLT 的 SPM manifest 损坏时
  脚本自动回退 Xcode 工具链）
- **不需要任何 Python** —— 运行期与回归都不用
- **中文为唯一界面语言**：无本地化基础设施，所有文案以中文字面量散落于 `Views/`；
  上架/多语言前需整体重构。`Info.plist` 声明 `CFBundleDevelopmentRegion = zh_CN` +
  `CFBundleLocalizations = [zh-Hans]`（系统菜单因此是中文；这两键由护栏 `plist_keys` 连值钉住）
- **SwiftUI Preview**：看板 / 选股结果 / 自选 / 板块热度等关键视图提供 `#Preview`
  （条数以 `grep -rc "#Preview" Sources/` 为准）—— 读**真实开发库**（`Store.shared`）、
  置 `Store.previewMode` 抑制网络拉取。其余视图依赖进程内 Store 未提供，联调走打包

### 环境变量一览

| 变量名 | 适用范围 | 默认值 | 说明 |
|---|---|---|---|
| `SELECTED_DATA_DIR` | App / Core / 脚本 | 正式打包：`~/Library/Application Support/Selected`；开发直跑：`<工程>/data` | 覆盖数据库与 `cache/` 目录（空串视为未设置；单测与调试隔离必用） |
| `SELECTED_FIXTURE_DIR` | Core | 未设置 | 非空时启用离线夹具模式，行情与 K 线改为读取该目录 JSON 且不写缓存 |
| `SELECTED_KLINE_DELAY` | Core | `0.15`（秒） | K 线网络请求节流最小间隔；`<= 0` 关闭节流（仅建议用于夹具/离线测试） |
| `SELECTED_PARAM_SCHEMA` | Core | 随包 `engine/params/param_schema_export.json` | 覆盖选股参数元数据与出厂默认 JSON 路径 |
| `SELECTED_DB_SCHEMA` | Core | 随包 `engine/params/db_schema_export.json` | 覆盖数据库 Schema 导出 JSON 路径 |
| `SELECTED_STOCK_LIST_HTTP` | Core / 自检 | 未设置 | 设为 `off` 时跳过证券/基金/港股列表网络抓取，用于测试离线/降级回退逻辑 |
| `SELECTED_BACKUP_DIR` | 备份与校验脚本 | `../Selected-backups` | 覆盖 `scripts/backup_data.sh` 与 `scripts/verify_backup.sh` 的归档目录 |
| `SELECTED_SWIFT_FLAGS` | 构建脚本 | 空 | 传给 `SelectedApp/build_app.sh` 内部 `swift build` 的额外参数（如 `-Xswiftc -disable-sandbox`） |
| `DEVELOPER_DIR` | 构建 / 回归脚本 | 系统当前激活路径 | 指向 `/Applications/Xcode.app/Contents/Developer`（当 CLT 无法解析 `Package.swift` 时必设） |
| `SELECTED_SNAPSHOT_DIR` | `SelectedApp/Tools/visual_snapshot.sh` | 未设置 | 非空时触发视觉截图输出到指定目录 |
| `SELECTED_SNAPSHOT_DATE` | 视觉截图工具 | 库内最新选股日 | 指定截图使用的选股日期 |
| `SELECTED_SNAPSHOT_CODE` | 视觉截图工具 | 样本默认标的 | 指定详情页截图的股票代码 |
| `SELECTED_SNAPSHOT_TEMPLATE` | 视觉截图工具 | 未设置 | 视觉对比模板路径覆盖 |
| `SELECTED_CALIBRATE_DB` / `SELECTED_CALIBRATE_SPLIT` | `SelectedApp/Tools/param_calibrate_test.sh` | 正式库 / `2026-06-01` | 参数标定校准脚本读取的库路径与训练/验证切分日 |

### 跑回归测试

```bash
# 运行全部 Core/App 单测（仓库外 scratch-path 避开 FileProvider 签名错误）
swift test --package-path SelectedApp --disable-sandbox \
  --scratch-path "${TMPDIR:-/tmp}/selected-swift-test-build"

# 全量回归入口（单测 + Swift 自检驱动 + 53 条静态护栏，无外部网络依赖）
bash engine/tests/run_all.sh
```

回归共三类：`swift test` 单元测试（数值口径 / 取值语义 / 参数契约 / 分层 / App 纯状态逻辑）、
Swift 侧自检驱动、静态护栏。**"不做历史口径对账"指的是引擎计算口径，不是全部**：

- **有**逐点比对的：指标库 —— `Tests/SelectedCoreTests/Fixtures/indicator_golden/` 下的
  黄金 CSV 与参考实现逐点对照（容差与"从首个非 0 行起比"由 `IndicatorGoldenSupport` 钉住，
  **夹具缺失 = 显式失败，不会静默跳过**）⇒ 改指标种子/平滑口径**会**报红。
- **有**结构比对的：实体层若干文件对捕获下来的引擎输出做"键集相等 + JSON 无损往返"断言
  ⇒ 改字段名/丢字段会报红。
- **没有**对账的：`Screener` 的过滤链与打分合成、档位边界、三轮对比的信号分类、
  落库四表、四阶段输出 ⇒ **改这些计算口径没有自动化能发现**，只能靠纯函数单测 + 人工看结果。

两个随包 JSON 的生成源在 Swift 侧：改元数据改 `SelectedCore/SchemaExportData.swift`，
跑 `SelectedApp/Tools/export_schema.swift` 重新生成；`swift test` 的 `SchemaExportTests`
逐字节断言"文件 == 生成结果"。

跑完逐类打印 ✅/❌；**条数一律以输出为准**（文档不写死）。

代码分为 `Sources/SelectedCore`（引擎 + 数据层，**不允许 import 任何 UI 框架**，由
`CoreLayeringTests` 钉死）与 `Sources/SelectedApp`（SwiftUI 应用）两个 target。
`Tools/*.sh` 由 `Tools/core_lib.sh` 先构建 `SelectedCore.o` 再链接（新增 Core 文件无需改脚本）。

另有 **53 条静态护栏** —— 名单、各自防的是什么、以及为什么必须靠护栏
（共同点：**删掉不会让任何测试变红**）→ 见 [docs/功能说明.md](docs/功能说明.md) §十二。

⚠ 护栏条数在三处（**本文件** / `docs/功能说明.md` / `run_all.sh` 头部）**必须一致**，
由 `guard_count_sync` 强制（权威值 = `GUARD_NAMES` 数组长度；`docs/specs/README.md` 与 CI 若写数字也必须同步）。
**新增护栏要改两处**：往 `GUARD_NAMES` 加名字 + 同步数字，漏任一处都会报红。

> ⚠ `swift test` 必须用 `--scratch-path` 指到仓库外（`run_all.sh` 已这么做）：
> 本仓库目录受 macOS FileProvider 管理，新建目录会带 `com.apple.FinderInfo`，
> 导致 codesign 报 `resource fork … not allowed`。

### 异常回滚与数据库恢复

数据库（`selected.sqlite3` + `history.sqlite3` + `cache/`）是唯一不可再生资产，每次发版都会在 `Selected-backups/` 生成 WAL 合并后的一致性归档（滚动保留 5 份）。恢复步骤：

1. **退出正在运行的 Selected 实例**（确保无后台写连接占用文件锁）：
   ```bash
   pkill -x Selected || true
   ```
2. **校验备份归档完整性**（`scripts/verify_backup.sh` 会解包到临时目录校验 `PRAGMA quick_check` 与关键表记录数）：
   ```bash
   bash scripts/verify_backup.sh
   ```
3. **先备份当前异常库，再解压恢复目标归档**：
   ```bash
   DATA_DIR="${SELECTED_DATA_DIR:-$HOME/Library/Application Support/Selected}"
   mv "$DATA_DIR" "${DATA_DIR}.broken.$(date +%Y%m%d%H%M%S)"
   mkdir -p "$DATA_DIR"
   tar -xzf ../Selected-backups/<目标归档>.tar.gz -C "$DATA_DIR"
   ```
4. **启动后复核**：打开应用后检查设置页「数据源诊断」与最近选股日/自选分组是否完整。

### 常见排障索引

| 现象 | 原因 | 处理方法 |
|---|---|---|
| `swift test` / `run_all.sh` 报找不到 Xcode 工具链或 `swift-tools-version:6.2` 解析失败 | 当前默认指向 Command Line Tools 而非完整 Xcode 26+ | 设置 `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 后重试 |
| `codesign` 报 `resource fork, Finder information, or similar detritus not allowed` | 仓库目录受 macOS FileProvider 管理，新建构建目录携带 `com.apple.FinderInfo` | `swift build` / `swift test` 务必传 `--disable-sandbox --scratch-path "${TMPDIR:-/tmp}/..."`（已在 `run_all.sh` 内置） |
| 板块热度 / 基本面 / 历史日 K 批量拉取频繁失败或熔断 | 东方财富接口对高频并发或出口 IP 触发限流（同域名共限流桶） | 查看 **设置 › 数据 › 数据源诊断** 确认失败日志（`data_source_logs`），避开盘中高频并发操作并等待熔断窗口恢复后再手动重抓 |
| 指标筛选页长期空态或 `indsnap` 调度任务报错跳转「历史回放」 | `history.sqlite3` 的 `daily_bars` 尚未初始化或缺失最近交易日 | 打开 **设置 › 数据 › 历史回放** 下载/补齐日 K 缓存后点击重算 |

### 打包发布

`build_app.sh`（release 默认模式）末尾自动：回归闸门 → 签名校验 → 落位 `dist/Selected.app` → 数据归档（`scripts/backup_data.sh`）→ `git add -A && commit` → `git push origin/main`。
⚠ **打包前先看清工作区** —— 所有未提交改动会被捆成同一个「发布」提交；纯本地构建请加 `--no-commit`。

### 版本号规则

版本号唯一源头是 `SelectedApp/Resources/Info.plist` 的两键，**由打包脚本自动维护**：
`build_app.sh` 每次 release 打包把 `CFBundleShortVersionString` 末位 +1、把
`CFBundleVersion` 写成真实打包日期（北京时间 `yyyyMMdd`，同一天第二次起为 `yyyyMMdd.2`…）。

> ⚠ 本文档**不写"当前基线是多少"**：要当前版本，读 `Info.plist` 或看关于页
> （`AppInfo.version` 从它读取）。

| 变更类型 | 递增位 | 示例 |
|---------|--------|------|
| 小功能迭代 / 问题修复 | 第三位 +1（**打包脚本自动**） | `0.1.1` → `0.1.2` |
| 大功能 | 第二位 +1，**第三位归零** | `0.1.5` → `0.2.0` |
| 功能基本齐全 | 第一位 +1，**后两位归零** | `0.3.7` → `1.0.0` |

⚠ 后两档仍是**手改**（脚本只动末位）：那类跳变需要人判断，改完照常打包。

---

## 目录结构

```
.
├── SelectedApp/                 # SwiftUI macOS 应用（SwiftPM 包，四个 target）
│   ├── Sources/SelectedCore/    #   引擎 + 数据层 library target（无 UI 依赖：只许 import Foundation/SQLite3）
│   ├── Sources/SelectedApp/     #   SwiftUI 应用（Views / Store / Scheduler / Notifier / 入口）
│   │   ├── Views/               #   页面 + 公共组件 + Tokens.swift（颜色/字号唯一来源，明暗自适应）
│   │   └── Store*.swift         #   全局状态按职责拆：Store + 各 extension
│   ├── Tests/SelectedCoreTests/ #   `swift test` Core 单元测试
│   ├── Tests/SelectedAppTests/  #   `swift test` App 层纯状态/格式化单元测试
│   ├── Tools/                   #   Swift 自检驱动 + .sh 入口（core_lib.sh 负责链接 Core）
│   ├── LocalPackages/           #   两个本地 vendor 包（随仓分发，非 SPM 远程依赖）
│   │   ├── swift-trading-view/ #     K线/分时图表
│   │   └── ThinkingOrbs/       #     点阵动效（⚠ 只许 UI 层用，orb_layering 钉死）
│   ├── Resources/               #   Info.plist / 图标 / PrivacyInfo.xcprivacy
│   ├── dist/                    #   构建产物 .app（可忽略）
│   └── .build/                  #   Swift 增量构建缓存（可安全删除，会重建）
├── engine/
│   ├── params/                  #   出厂参数 / schema 元数据 / 证券列表基线（随包资源）
│   └── tests/
│       ├── run_all.sh           #   全量回归入口（无外部依赖）
│       └── fixtures/            #   黄金夹具（手工一次性捕获、不可再生，**不能当缓存删**）
├── scripts/                     #   backup_data.sh（数据库归档 + 恢复演练）/ verify_backup.sh 等
├── docs/                        #   文档（docs_paths 护栏会检查这里点名的路径都存在）
│   ├── 功能说明.md              #   主文档：界面 / 数据口径 / 边界 / 护栏名单（§十二）
│   └── specs/                   #   设计决策台账 —— 1 份
└── README.md
```

> ⚠ `engine/tests/fixtures/` 内容**几乎全部**被 `.gitignore` 忽略（仅 `*_outputs/`、
> `calendar_index.json`、`2026-09-14/expected_scan_result*.json` 纳管），但纳管的那部分是
> `swift test` 实体验证用的**结构样本**（一次性手工捕获、不可再生）——
> 删掉会让那批实体验证**显式失败**（夹具缺失 = 仓库坏了）。

**可安全删除的目录**（构建/缓存产物，自动重建）：`SelectedApp/.build`、`SelectedApp/dist`。

---

## 数据目录

正式运行数据存于 `~/Library/Application Support/Selected/`，**两个 SQLite 库 + 一个文件缓存目录**
（均 WAL 模式、全本地不上传；库为明文无加密，属单机工具的可接受风险）：

- `selected.sqlite3` — 主库（**37 张表**，清单见下）

- `history.sqlite3` — 回放日K缓存独立库（3 张表：`daily_bars` / `index_bars` / `bar_coverage`），
  由「设置 › 数据 › 历史回放」的下载日K缓存填充；回放用前需先联网下载（走全局限速，受东财出口 IP 限流约束）
- `cache/` — 文件级缓存（`stock_list.json`，证券主列表快照）

开发时用项目内 `data/`（同样的两库结构）。

`selected.sqlite3` 的 37 张表（22 张来自随包 DDL，15 张是 Swift-only 建表；
数字口径 = `SchemaExportData.schema_sql` 的 CREATE TABLE + `DBBootstrap.verifySwiftOnlyStructures`
里那张 `expectedTables` 清单，两处任一改动都要回到这里核对）：

- 证券与档案：`securities` / `funds`（场内基金）/ `hk_list`（港股列表）/ `index_members` / `stock_fundamentals`
- 选股主链：`scan_rounds` / `picks` / `excluded_stocks` / `etf_picks`
- 四阶段：`predicts` / `verifies` / `reviews` / `iterate_reports`
- 信号与结果：`signal_classes` / `compare_reports` / `stock_outcomes`
- 交易日历：`trading_days`
- 参数版本：`param_versions`（个股覆盖表 `stock_param_overrides` 已废弃，DDL 里只剩 `DROP`）
- 指标筛选（B 域）：`indicator_params` / `indicator_param_changes` / `indicator_snapshots`
- 自选：`watch_groups` / `watch_group_members` / `watchlist` / `watch_judgments`
- 自选提醒：`watch_alerts` / `watch_alert_settings`
- 收盘后数据：`board_heat` / `zt_sentiment` / `limit_up_pool` / `stock_fund_flows` / `stock_lhb` / `stock_lhb_seats`
- 运行时：`counters` / `meta` / `data_source_logs`


`history.sqlite3` 的 3 张表：`daily_bars` / `index_bars` / `bar_coverage`。

数据库是**唯一不可再生的资产**：每次打包发布自动跑 `scripts/backup_data.sh` 归档
（含 WAL 一致性快照，滚动保留 5 份，输出到 `Selected-backups/`）。

---

## 核心流程概览

每日循环：**早盘预判 → 盘中验证 → 尾盘三轮选股 → 三轮对比 → 收盘复盘 → 三日迭代**，
外加收盘后的板块热度 / 涨停统计 / 资金流向 / 指标快照 / 龙虎榜抓取，以及自选三层判定。

- 时刻**不在界面上改**（2026-10-27 起）：改 `SelectedCore/ScheduleCatalog` 出厂表；
  设置 → 自动化只管总开关，时刻与今日状态看主窗口左下角「调度」栏。⚠ **三轮必须依次递增**（该校验仍在 `ScheduleTimes.update`，只是暂时没有界面调用它）
- 调度器用单次定时器精确挂到下一个任务时刻；到点后 25 分钟内可补跑、失败自动重试
- **超窗不会静默跳过**：显式记为「未执行」并通知；系统睡眠唤醒后自动补偿

> 逐项时刻表、每个任务的说明 → 见 [docs/功能说明.md](docs/功能说明.md) §二 / §八；
> 调度器设计的完整理由 → 见 [docs/specs/README.md](docs/specs/README.md)。

---

## 技术要点

- **全原生**：运行期无 Python 子进程 / 长驻服务 / 内嵌解释器
- **单一事实来源**：库表结构（DDL）与参数元数据（13 组 / 71 项 + 工厂默认）由 Swift 侧定义
  （`SelectedCore/SchemaExportData.swift`），生成两个随包 JSON，`SchemaExportTests` 逐字节拦截漂移
- **不做历史口径对账**：只有 `swift test` + Swift 侧自检 + 静态护栏；
  ⚠ 代价：改引擎计算口径没有自动化能发现 —— 有意接受的取舍
  （[决策与代价](docs/specs/README.md)）

## License

[GNU General Public License v3.0](LICENSE)。分发二进制时按 GPL-3.0 要求随包附带许可全文
（`Contents/Resources/LICENSE.txt`），修改后再分发须提供对应源码（本仓库即源码）。
