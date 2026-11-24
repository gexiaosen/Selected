#!/bin/bash
# 打包拖拽安装 dmg：Selected.app + /Applications 快捷方式。
# 用法: ./SelectedApp/Scripts/make-dmg.sh <Selected.app 路径> <输出.dmg 路径>
#
# 纯 hdiutil，零外部依赖（不用 create-dmg）：挂载后用户把 app 拖到
# Applications 链接即完成安装。UDZO 压缩格式兼容性最稳。
# Sparkle 支持 dmg 更新通道，同一产物既给新用户下载也给老用户自动更新。
#
# 窗口观感（尺寸、居中位置、图标落位、背景图）来自 Resources/DMG/ 里烘焙好的
# .DS_Store 与 background.png，由 make-dmg-layout.sh 生成一次、随仓库走。
# 打包阶段只做拷贝，不用 AppleScript 摆位——CI 上控制 Finder 会被自动化权限拦住。
set -euo pipefail

APP="${1:?用法: make-dmg.sh <Selected.app> <输出.dmg>}"
DMG="${2:?缺少输出 dmg 路径}"

if [ ! -d "$APP" ]; then
    echo "找不到 .app：$APP"
    exit 1
fi
APP_NAME="$(basename "$APP" .app)"
DMG_DIR="$(cd "$(dirname "$DMG")" && pwd)"
DMG_PATH="$DMG_DIR/$(basename "$DMG")"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LAYOUT="$REPO/Resources/DMG/DS_Store"
BACKGROUND="$REPO/Resources/DMG/background.png"

# staging 必须在 iCloud 同步区之外（理由同 build_app.sh 的 /tmp 约定），
# 且打完即删——里面只是临时摆位。
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/selected-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

# 布局是锦上添花：缺了就退回纯白窗口，绝不能让打包失败。
if [ -f "$LAYOUT" ] && [ -f "$BACKGROUND" ]; then
    mkdir -p "$STAGING/.background"
    cp "$BACKGROUND" "$STAGING/.background/background.png"
    cp "$LAYOUT" "$STAGING/.DS_Store"
else
    echo "警告：缺少 Resources/DMG 布局，dmg 将使用默认窗口（跑 Scripts/make-dmg-layout.sh 生成）"
fi

rm -f "$DMG_PATH"
# 卷名必须与烘焙 .DS_Store 时的卷名一致，否则背景图的书签解不出来。
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -format UDZO -ov -quiet "$DMG_PATH"

# 终验：挂载镜像确认两个入口都在，防"空壳 dmg 交出去"。
# 顺带核对布局是否真的进了镜像——隐藏文件被 ditto/hdiutil 漏掉时，
# 外观会悄悄退回白底，发出去才发现就晚了。
VERIFY="$(mktemp -d "${TMPDIR:-/tmp}/selected-verify.XXXXXX")"
hdiutil attach -readonly -nobrowse -mountpoint "$VERIFY" -quiet "$DMG_PATH"
trap 'hdiutil detach "$VERIFY" -quiet >/dev/null 2>&1 || true; rm -rf "$STAGING" "$VERIFY"' EXIT
test -d "$VERIFY/$APP_NAME.app" || { echo "dmg 内缺少 $APP_NAME.app，拒绝交付"; exit 1; }
test -L "$VERIFY/Applications" || { echo "dmg 内缺少 Applications 快捷方式，拒绝交付"; exit 1; }
if [ -f "$LAYOUT" ]; then
    test -f "$VERIFY/.DS_Store" || { echo "dmg 内缺少 .DS_Store，窗口布局会退回默认"; exit 1; }
    test -f "$VERIFY/.background/background.png" || { echo "dmg 内缺少背景图"; exit 1; }
fi

echo "$DMG_PATH"
