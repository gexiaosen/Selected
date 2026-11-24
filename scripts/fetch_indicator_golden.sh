#!/bin/bash
# 指标黄金夹具下载脚本
#
# 做什么：从 Go 库 cinar/indicator 的 testdata 目录下载指标黄金 CSV
#   （表头 = `输入列…,期望输出列…`，数值为公开指标公式的输入/输出事实数据），
#   落盘到 SelectedApp/Tests/SelectedCoreTests/Fixtures/indicator_golden/<分类>/。
#   kst.csv 不入库：其夹具值无法在当前上游实现口径下复现，
#     按"每个指标必须有可复现夹具"纪律排除。
#
# 许可证边界（为什么只拿数据、不拿代码）：
#   cinar/indicator v2 为 **AGPLv3 / 商业双许可**。本项目的指标实现全部按
#   **公开教科书定义 clean-room 独立编写，不翻译其任何 Go 源码**；
#   这里下载的 CSV 只是**数值事实**（公式输入 → 输出），事实数据不受版权保护，
#   用途等同于"参考答案"——测试用它校验我们的独立实现算得对不对。
#
# 幂等：重复执行会覆盖为相同内容；夹具**纳入版本管理**（与 *_outputs 黄金夹具
#   同一口径：缺失 = 仓库不完整，测试按 FixtureMissing 直接失败，不 skip）。
#
# 用法：bash scripts/fetch_indicator_golden.sh
#   需要网络可达 raw.githubusercontent.com；下载失败逐条报红并以非零码退出。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="https://raw.githubusercontent.com/cinar/indicator/master"
DEST="$ROOT/SelectedApp/Tests/SelectedCoreTests/Fixtures/indicator_golden"

# 分类|文件名（与 cinar/indicator 各包 testdata 一一对应）
FILES=(
  "trend|envelope_ema.csv"
  "trend|macd.csv"
  "trend|hma.csv"
  "trend|kama.csv"
  "trend|rma.csv"
  "momentum|stochastic_oscillator.csv"
  "momentum|stochastic_rsi.csv"
  "momentum|ppo.csv"
  "momentum|awesome_oscillator.csv"
  "momentum|ultimate_oscillator.csv"
  "momentum|rsi.csv"
  "volatility|bollinger_bands.csv"
  "volatility|bollinger_band_width.csv"
  "volatility|percent_b.csv"
  "volatility|donchian_channel.csv"
  "volatility|keltner_channel.csv"
  "volatility|super_trend.csv"
  "volatility|ulcer_index.csv"
  "volatility|moving_std.csv"
  "volatility|atr.csv"
  "volume|vwap.csv"
  "volume|cmf.csv"
  "volume|emv.csv"
  "volume|fi.csv"
  "volume|mfm.csv"
  "volume|mfv.csv"
)

fail=0
for entry in "${FILES[@]}"; do
  sub="${entry%%|*}"
  name="${entry##*|}"
  out="$DEST/$sub/$name"
  mkdir -p "$DEST/$sub"
  if curl -sfL --max-time 60 "$BASE/$sub/testdata/$name" -o "$out"; then
    # 校验：CSV 必须非空且有表头行（404 页面等异常内容在这里拦住）
    if [ ! -s "$out" ] || ! head -1 "$out" | grep -q ','; then
      echo "❌ $sub/$name 内容异常（空或无表头）"
      rm -f "$out"
      fail=1
    else
      echo "✅ $sub/$name ($(wc -l < "$out" | tr -d ' ') 行)"
    fi
  else
    echo "❌ $sub/$name 下载失败"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "存在下载失败项，请检查网络后重跑本脚本"
  exit 1
fi
echo "全部夹具就绪：$DEST"
