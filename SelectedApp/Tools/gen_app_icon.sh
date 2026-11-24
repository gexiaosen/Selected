#!/bin/bash
# 重建 App 图标全套产物：SelectedApp/Resources/AppIcon.icns + AppIcon.png
#
# 为什么要有这个脚本（2026-10-22，老板判定）：现版图标源文件只有 256×256，
#   icns 里那枚 1024 是**拉大的**（与 256 归一化后平均只差 0.68/255，三个尺寸
#   边缘强度 3.05/3.25/3.19 基本持平）⇒ Retina Dock 上必然发肉。
#   样式保持原样，几何由 `gen_app_icon.swift` 里那批**实测常量**矢量重绘。
#
# 用法: bash SelectedApp/Tools/gen_app_icon.sh [输出目录，默认 Resources]
#   ⚠ 会覆盖 AppIcon.icns / AppIcon.png。两者都在 git 里，改坏了 `git checkout --` 可回。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="$ROOT/SelectedApp/Tools/gen_app_icon.swift"
OUT="${1:-$ROOT/SelectedApp/Resources}"
TMP="$(mktemp -d)"
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"

if ! command -v swift >/dev/null 2>&1; then
    echo "❌ 缺 swift：图标无法生成（不是"通过"，是"没跑"）" >&2
    exit 2
fi

# iconutil 要求的尺寸清单（少一个就会在 icns 里留空档，Dock 某些尺寸回退成通用图标）
render() {  # render <像素> <文件名>
    PATH=/usr/bin:$PATH swift "$GEN" "$SET/$2" "$1" >/dev/null
    [ -s "$SET/$2" ] || { echo "❌ 生成失败：$2" >&2; exit 1; }
}
render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$SET" -o "$OUT/AppIcon.icns"
# 通知附件固定读 AppIcon.png（见 build_app.sh:597）。原先它是 256×256；
# 这里直接放 **1024**（复用 @2x 最大档，边缘由矢量直供，不再靠放大）。
# ⚠ 别照注释写"512"——`icon_512x512@2x.png` 的文件名意思是"512pt @2x"，像素是 1024。
#   （第一版注释就是这么写错的，被自己生成的产物打脸：装完 sips 一量是 1024。）
cp "$SET/icon_512x512@2x.png" "$OUT/AppIcon.png"

# 自证：icns 必须真的含 1024 档。⚠ 不用 Python（本仓纪律：工具链零 Python，
#   见 run_all.sh 头部）—— `sips` 在 macOS 上必然存在，够用了。
iconutil -c iconset "$OUT/AppIcon.icns" -o "$TMP/verify.iconset" >/dev/null
for f in icon_16x16.png icon_16x16@2x.png icon_32x32.png icon_32x32@2x.png \
         icon_128x128.png icon_128x128@2x.png icon_256x256.png icon_256x256@2x.png \
         icon_512x512.png icon_512x512@2x.png; do
    if [ ! -s "$TMP/verify.iconset/$f" ]; then
        echo "❌ icns 里缺 ${f}（Dock 对应尺寸会回退成通用图标）" >&2
        exit 1
    fi
done
BIG_W=$(sips -g pixelWidth "$TMP/verify.iconset/icon_512x512@2x.png" | awk -F': ' '/pixelWidth/{print $2}')
if [ "${BIG_W:-0}" != "1024" ]; then
    echo "❌ icns 最大档是 ${BIG_W:-?}px，不是 1024" >&2
    exit 1
fi
echo "  icns 十档齐全，最大档 $(sips -g pixelWidth -g pixelHeight "$TMP/verify.iconset/icon_512x512@2x.png" | awk -F': ' '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w"×"h}')"

/bin/rm -rf "$TMP"
echo "✅ 已重建：$OUT/AppIcon.icns 与 $OUT/AppIcon.png"
