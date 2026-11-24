# 第三方来源与许可说明

本目录（`Sources/ta-lib/`）下的 C 代码是**本项目自行实现**的，不是 TA-Lib 上游源码。
但它的 **API 命名与错误码取值参照了 TA-Lib**，故在此明确出处与许可，避免日后误判为「抄了上游」。

---

## 1. 这是什么

`ta_libc.h` / `ta_stubs.c` 是一份**精简到只剩本项目所需函数**的最小实现：

- 只有 7 个函数签名：`TA_MA` / `TA_BBANDS` / `TA_RSI` / `TA_MACD` / `TA_STOCH` / `TA_WILLR` / `TA_STOCHRSI`
- **其中只有 `TA_MA` 是真实实现**（SMA 用滚动求和；EMA 用 `multiplier = 2.0/(period+1)`）
- 其余 6 个是**未实现占位桩**：`return TA_NOT_SUPPORTED`（+ 0 个输出元素），使 `TALib.swift` 显式抛出 `TALibError.notImplemented` 而不会静默返回空数组
- `ta_abstract/` `ta_common/` 下的子目录是**空的**（上游对应位置是数千行的抽象层与公共工具）

**当前调用面**：本项目**只用到 `TA_MA`**，且只经由
`SwiftTradingView` 的 `MAIndicator` 与 `VolumeIndicator` 两个组件
（见 `SelectedApp/Sources/SelectedApp/Views/StockKLineChart.swift:266, 284`）。
那 6 个占位桩**项目主源码与测试都零调用**（`grep -rn 'MACDIndicator|RSIIndicator|BBIndicator' Sources/ Tests/` → 0 命中）。

> ⚠ **为什么留着这 6 个桩**：它们是「将来若要接 `MACDIndicator` 等组件时才会用到」的预留签名。
> 自 2026-10-06 起，它们已在 `ta_stubs.c` 改为显式返回 `TA_NOT_SUPPORTED`（`TALib.swift` 对应映射为 `TALibError.notImplemented`），避免图表静默空白。`TALib.swift` 里对它们的调用仅在
> 各预留 Indicator 组件内，不在本项目主链路上。**若将来要启用这些组件，必须先补全对应算法实现。**

## 2. 参照来源

- **上游项目**：TA-Lib（Technical Analysis Library）— https://www.ta-lib.org/ ｜ https://github.com/TA-Lib/ta-lib
- **上游许可**：BSD License（官网首页明示「Open-Source (BSD License). Can be freely
  integrated in your own open-source or commercial applications.」）
- **参照了什么**：函数命名（`TA_MA` / `TA_RSI` / …）、参数顺序、`TA_RetCode` 错误码的
  名称与数值、`TA_MAType` 枚举成员名。
- **没参照什么**：任何上游函数体。上游的 SMA 实现是 `TA_Sma` 等一组独立源文件
  （`ta_func/ta_SMA.c` 等），本目录**没有**这些文件，也没有它们的等价物。

## 3. 许可声明

上游 TA-Lib 采用 BSD License，其核心条款要求「再分发时保留版权声明与许可全文」。
本项目**未复制上游源码**，但为避免任何歧义：

- 本目录代码的著作权归本项目所有者（与仓库根 `LICENSE` 的 GNU GPL v3.0 一致）；
- 上游 TA-Lib 的 BSD 许可文本见 https://github.com/TA-Lib/ta-lib/blob/main/LICENSE
  （BSD-3-Clause 全文亦可在本仓库 `LocalPackages/swift-trading-view/LICENSE` 参照同一许可证族）；
- 若日后**确实**从上游复制了任何代码片段，**必须**在本文件补上：来源文件路径、
  上游 commit SHA、该片段的原始版权头。

## 4. 为什么目录名还叫 `ta-lib`

沿用上游名是为了让 `TALib.swift:2` 的 `import TALib` 与 SPM target 名保持一致
（SPM 的 C target 名 = 目录名，改名要同步改 `Package.swift` 的 target 定义与
每个文件的 import，风险大于收益）。

⚠ 但**这个命名有误导性** —— 后来人可能以为这是上游源码。`Package.swift` 里那 4 个
`TA_LIB_VERSION_*` define（伪造的 `0.6.0-dev`）尤其误导：**它已在上游 v0.6.4 真实存在
的情况下声称自己是 0.6.0-dev**。这两个 define 已在 2026-10-06 删除（见 git 历史），
因为「伪造上游版本号」比「没有版本号」更糟。

## 5. 维护提醒

- 本项目自己的 RSI / KDJ / 指标计算**不走这里** —— 它们在
  `SelectedCore/Oscillators.swift` / `KLinePatterns.swift` / `TechnicalIndicators.swift`
  里用 Swift 原生实现（见 `docs/specs/README.md`）。
- 不要因为「有 ta-lib」就以为指标都走 C 实现 —— 实际只有均线的 SMA/EMA 走。
