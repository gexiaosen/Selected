/* ============================================================================
 * 版权与来源声明（2026-10-06 补，此前本文件无任何许可/来源头）
 *
 * ⚠⚠ **本文件不是 TA-Lib 上游源码**，是本项目自行实现的最小版本：
 *   · 参照了上游的**函数命名与 TA_RetCode 错误码取值**（API 形状）
 *   · **未复制上游任何函数体**（上游实现在 ta_func/ta_SMA.c 等独立文件里，
 *     本目录没有那些文件，也没有等价物）
 *   · 7 个签名里**只有 TA_MA 是真实实现**，其余 6 个是返回
 *     `TA_NOT_SUPPORTED` + 0 个输出元素的**未实现占位桩**（见下方说明）
 *
 * 上游：TA-Lib — https://www.ta-lib.org/ ｜ https://github.com/TA-Lib/ta-lib
 * 上游许可：BSD License（官网明示「Open-Source (BSD License)」）
 * 完整说明（含"未复制什么"的逐条界定）见同目录 THIRD-PARTY-NOTICE.md
 *
 * 本项目自有代码的许可：见仓库根 LICENSE（Unlicense）。
 * ==========================================================================*/

#include "ta_libc.h"
#include <string.h>

/* --- Real SMA implementation --- */
TA_RetCode TA_MA(int startIdx, int endIdx, const double inReal[],
                 int optInTimePeriod, TA_MAType optInMAType,
                 int *outBegIdx, int *outNBElement, double outReal[])
{
    if (startIdx < 0 || endIdx < startIdx) return TA_BAD_PARAM;
    if (optInTimePeriod < 2) return TA_BAD_PARAM;
    if (!inReal || !outBegIdx || !outNBElement || !outReal) return TA_BAD_PARAM;

    int lookback = optInTimePeriod - 1;
    if (startIdx < lookback) startIdx = lookback;
    if (startIdx > endIdx) {
        *outBegIdx = 0;
        *outNBElement = 0;
        return TA_SUCCESS;
    }

    *outBegIdx = startIdx;
    int outIdx = 0;

    if (optInMAType == TA_MAType_SMA) {
        /* Simple Moving Average */
        double sum = 0.0;
        for (int i = startIdx - lookback; i <= startIdx; i++) {
            sum += inReal[i];
        }
        outReal[outIdx++] = sum / optInTimePeriod;

        for (int i = startIdx + 1; i <= endIdx; i++) {
            sum += inReal[i] - inReal[i - optInTimePeriod];
            outReal[outIdx++] = sum / optInTimePeriod;
        }
    } else {
        /* EMA fallback: use SMA for unsupported types */
        double sum = 0.0;
        for (int i = startIdx - lookback; i <= startIdx; i++) {
            sum += inReal[i];
        }
        double multiplier = 2.0 / (optInTimePeriod + 1.0);
        double ema = sum / optInTimePeriod;
        outReal[outIdx++] = ema;

        for (int i = startIdx + 1; i <= endIdx; i++) {
            ema = (inReal[i] - ema) * multiplier + ema;
            outReal[outIdx++] = ema;
        }
    }

    *outNBElement = outIdx;
    return TA_SUCCESS;
}

/* --- 占位桩（unused / not yet implemented） ---
 *
 * ⚠⚠ 2026-10-06（审计 P0-07）：原先这 6 个函数返回 **`TA_SUCCESS` + 0 个输出元素**
 *   —— 那是**最坏的形态**：调用方（`TALib.swift`）会拿到"成功 + 三个空数组"，
 *   既不抛错也不打日志，图表**静默空白**而没有任何线索。
 *
 * 现在改为返回 `TA_NOT_SUPPORTED`：让 Swift 侧的 `guard ret == TA_SUCCESS else { throw }`
 * 走**显式失败**路径。⚠ 行为变化见 `TALib.swift` 里对应的 `throw .notImplemented` 映射。
 *
 * 这 6 个签名在本项目**当前无人调用**（实测：主源码与测试都只经 `MAIndicator` /
 * `VolumeIndicator` 用到 `TA_MA`）⇒ 本次改动对现有 UI **零影响**。
 *   若将来要接 `MACDIndicator` 等组件，**必须先真正实现它们**（或改用
 *   `SelectedCore/Oscillators.swift` 的 Swift 原生实现，见 docs/specs/README.md）。
 */

TA_RetCode TA_BBANDS(int startIdx, int endIdx, const double inReal[],
                     int optInTimePeriod, double optInNbDevUp, double optInNbDevDn,
                     TA_MAType optInMAType,
                     int *outBegIdx, int *outNBElement,
                     double outRealUpperBand[], double outRealMiddleBand[],
                     double outRealLowerBand[])
{
    *outBegIdx = 0;
    *outNBElement = 0;
    return TA_NOT_SUPPORTED;   /* ⚠ 见上方说明：未实现 ≠ 成功 */
}

TA_RetCode TA_RSI(int startIdx, int endIdx, const double inReal[],
                  int optInTimePeriod,
                  int *outBegIdx, int *outNBElement, double outReal[])
{
    *outBegIdx = 0;
    *outNBElement = 0;
    return TA_NOT_SUPPORTED;   /* ⚠ 见上方说明：未实现 ≠ 成功 */
}

TA_RetCode TA_MACD(int startIdx, int endIdx, const double inReal[],
                   int optInFastPeriod, int optInSlowPeriod, int optInSignalPeriod,
                   int *outBegIdx, int *outNBElement,
                   double outMACD[], double outMACDSignal[], double outMACDHist[])
{
    *outBegIdx = 0;
    *outNBElement = 0;
    return TA_NOT_SUPPORTED;   /* ⚠ 见上方说明：未实现 ≠ 成功 */
}

TA_RetCode TA_STOCH(int startIdx, int endIdx,
                    const double inHigh[], const double inLow[], const double inClose[],
                    int optInFastKPeriod, int optInSlowKPeriod, TA_MAType optInSlowKMType,
                    int optInSlowDPeriod, TA_MAType optInSlowDMType,
                    int *outBegIdx, int *outNBElement,
                    double outSlowK[], double outSlowD[])
{
    *outBegIdx = 0;
    *outNBElement = 0;
    return TA_NOT_SUPPORTED;   /* ⚠ 见上方说明：未实现 ≠ 成功 */
}

TA_RetCode TA_WILLR(int startIdx, int endIdx,
                    const double inHigh[], const double inLow[], const double inClose[],
                    int optInTimePeriod,
                    int *outBegIdx, int *outNBElement, double outReal[])
{
    *outBegIdx = 0;
    *outNBElement = 0;
    return TA_NOT_SUPPORTED;   /* ⚠ 见上方说明：未实现 ≠ 成功 */
}

TA_RetCode TA_STOCHRSI(int startIdx, int endIdx, const double inReal[],
                       int optInTimePeriod, int optInFastKPeriod, int optInFastDPeriod,
                       TA_MAType optInFastDMAType,
                       int *outBegIdx, int *outNBElement,
                       double outFastK[], double outFastD[])
{
    *outBegIdx = 0;
    *outNBElement = 0;
    return TA_NOT_SUPPORTED;   /* ⚠ 见上方说明：未实现 ≠ 成功 */
}
