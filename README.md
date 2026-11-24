# Selected

A股尾盘量化选股 Mac 应用。

围绕「尾盘买入、次日午前卖出」的短线策略，把选股、验证、复盘和参数迭代串成一条可复现的闭环。原生 Swift + SwiftUI 实现，数据存本地 SQLite，运行时不依赖 Python。

> 仅用于信号分析与决策辅助，不构成投资建议，不含下单交易功能。

## 功能

- **三轮尾盘扫描**：14:00 / 14:30 / 14:50 各扫一轮，按行情、形态、资金和分时结构打分。
- **三轮对比**：交并集、信号分类、分档，收敛成当日候选。
- **四阶段闭环**：早盘预判 → 盘中验证 → 收盘复盘 → 三日迭代，结果自动回填。
- **自选与持仓**：分组管理、三层判定、成本/盈亏统计、价格提醒。
- **收盘数据**：板块热度、涨停统计、资金流向、龙虎榜、指标快照。
- **参数中心**：参数版本、单域编辑、版本对比、历史重放调优。
- **菜单栏常驻**：自动调度、任务状态、通知提醒。

## 下载与安装

从 [Releases](https://github.com/gexiaosen/Selected/releases/latest) 下载 `Selected-v<版本>-arm64.dmg`，打开后把 Selected 拖进「应用程序」。

- 仅支持 **Apple Silicon（arm64）+ macOS 26 及以上**。
- 应用未做 Apple 公证，首次打开需右键选择「打开」，或到「系统设置 › 隐私与安全性」允许。
- 内置自动更新：每日静默检查，发现新版只在侧栏齿轮亮红点；需要立即更新时用菜单「Selected › 检查更新…」。

## 使用

1. 首次启动会自动建库并载入出厂参数。
2. 到「设置 › 数据 › 历史回放」下载日 K 缓存，历史回放和指标快照需要它。
3. 到「设置 › 提醒」授权系统通知，否则调度和价格提醒不会弹窗。
4. 日常保持菜单栏常驻即可；任务时刻和今日状态在主窗口左下角「调度」栏查看。

## 从源码构建

要求 macOS 26+、Xcode 26+、Apple Silicon。

```bash
# 本地打包（跑回归 + 签名，产物在 SelectedApp/dist/）
bash SelectedApp/build_app.sh --no-commit

# 只生成 DMG
bash SelectedApp/Scripts/make-dmg.sh SelectedApp/dist/Selected.app \
  SelectedApp/dist/Selected-v1.0.0-arm64.dmg
```

发布由 `v*.*.*` tag 触发 GitHub Actions：校验版本、跑回归、出 DMG、签名并生成更新源。

## 目录

```text
.
├── SelectedApp/          # macOS 应用（SwiftPM）
├── engine/               # 出厂参数与回归测试
├── scripts/              # 数据备份与校验
├── docs/
│   ├── 功能说明.md        # 功能与口径
│   └── specs/            # 设计取舍 —— 1 份
└── README.md
```

## 开发与校验

```bash
bash engine/tests/run_all.sh
```

覆盖单元测试、Swift 自检和 **53 条静态护栏**。新增功能或修改计算口径后先跑一遍再打包。

更多功能细节见 [docs/功能说明.md](docs/功能说明.md)，设计取舍见 [docs/specs/README.md](docs/specs/README.md)。

## License

[GNU General Public License v3.0](LICENSE)。分发二进制时随包附带许可全文，修改后再分发需提供对应源码。
