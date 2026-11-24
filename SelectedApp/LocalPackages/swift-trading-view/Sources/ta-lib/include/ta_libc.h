/* ============================================================================
 * 版权与来源声明（2026-10-06 补，此前本文件无任何许可/来源头）
 *
 * ⚠⚠ **本文件不是 TA-Lib 上游源码**，是本项目自行实现的最小版本：
 *   · 参照了上游的**函数命名与 TA_RetCode 错误码取值**（API 形状）
 *   · **未复制上游任何函数体**（上游实现在 ta_func/ta_SMA.c 等独立文件里，
 *     本目录没有那些文件，也没有等价物）
 *   · 7 个签名里**只有 TA_MA 是真实实现**，其余 6 个是返回
 *     `TA_NOT_SUPPORTED` + 0 个输出元素的**未实现占位桩**（见 `ta_stubs.c`）
 *
 * 上游：TA-Lib — https://www.ta-lib.org/ ｜ https://github.com/TA-Lib/ta-lib
 * 上游许可：BSD License（官网明示「Open-Source (BSD License)」）
 * 完整说明（含"未复制什么"的逐条界定）见同目录 THIRD-PARTY-NOTICE.md
 *
 * 本项目自有代码的许可：见仓库根 LICENSE（Unlicense）。
 * ==========================================================================*/

#ifndef TA_LIBC_H
#define TA_LIBC_H

#ifdef __cplusplus
extern "C" {
#endif

/* Return codes */
typedef enum {
    TA_SUCCESS = 0,
    TA_LIB_NOT_INITIALIZE = 1,
    TA_BAD_PARAM = 2,
    TA_ALLOC_ERR = 3,
    TA_GROUP_NOT_FOUND = 4,
    TA_FUNC_NOT_FOUND = 5,
    TA_INVALID_HANDLE = 6,
    TA_INVALID_PARAM_HOLDER = 7,
    TA_INVALID_PARAM_HOLDER_TYPE = 8,
    TA_INVALID_PARAM_FUNCTION = 9,
    TA_INPUT_NOT_ALL_INITIALIZE = 10,
    TA_OUTPUT_NOT_ALL_INITIALIZE = 11,
    TA_OUT_OF_RANGE_START_INDEX = 12,
    TA_OUT_OF_RANGE_END_INDEX = 13,
    TA_INVALID_LIST_TYPE = 14,
    TA_BAD_OBJECT = 15,
    TA_NOT_SUPPORTED = 16,
    TA_INTERNAL_ERROR = 5000,
    TA_UNKNOWN_ERR = 65535
} TA_RetCode;

/* MA types */
typedef enum {
    TA_MAType_SMA = 0,
    TA_MAType_EMA = 1,
    TA_MAType_WMA = 2,
    TA_MAType_DEMA = 3,
    TA_MAType_TEMA = 4,
    TA_MAType_TRIMA = 5,
    TA_MAType_KAMA = 6,
    TA_MAType_MAMA = 7,
    TA_MAType_T3 = 8
} TA_MAType;

/* Function declarations */
TA_RetCode TA_MA(int startIdx, int endIdx, const double inReal[],
                 int optInTimePeriod, TA_MAType optInMAType,
                 int *outBegIdx, int *outNBElement, double outReal[]);

TA_RetCode TA_BBANDS(int startIdx, int endIdx, const double inReal[],
                     int optInTimePeriod, double optInNbDevUp, double optInNbDevDn,
                     TA_MAType optInMAType,
                     int *outBegIdx, int *outNBElement,
                     double outRealUpperBand[], double outRealMiddleBand[],
                     double outRealLowerBand[]);

TA_RetCode TA_RSI(int startIdx, int endIdx, const double inReal[],
                  int optInTimePeriod,
                  int *outBegIdx, int *outNBElement, double outReal[]);

TA_RetCode TA_MACD(int startIdx, int endIdx, const double inReal[],
                   int optInFastPeriod, int optInSlowPeriod, int optInSignalPeriod,
                   int *outBegIdx, int *outNBElement,
                   double outMACD[], double outMACDSignal[], double outMACDHist[]);

TA_RetCode TA_STOCH(int startIdx, int endIdx,
                    const double inHigh[], const double inLow[], const double inClose[],
                    int optInFastKPeriod, int optInSlowKPeriod, TA_MAType optInSlowKMType,
                    int optInSlowDPeriod, TA_MAType optInSlowDMType,
                    int *outBegIdx, int *outNBElement,
                    double outSlowK[], double outSlowD[]);

TA_RetCode TA_WILLR(int startIdx, int endIdx,
                    const double inHigh[], const double inLow[], const double inClose[],
                    int optInTimePeriod,
                    int *outBegIdx, int *outNBElement, double outReal[]);

TA_RetCode TA_STOCHRSI(int startIdx, int endIdx, const double inReal[],
                       int optInTimePeriod, int optInFastKPeriod, int optInFastDPeriod,
                       TA_MAType optInFastDMAType,
                       int *outBegIdx, int *outNBElement,
                       double outFastK[], double outFastD[]);

#ifdef __cplusplus
}
#endif

#endif /* TA_LIBC_H */
