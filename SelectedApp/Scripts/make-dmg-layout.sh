#!/bin/bash
# 一次性烘焙 dmg 的窗口布局：把 Finder 窗口尺寸、图标落位、背景图写进 .DS_Store，
# 存到 Resources/DMG/DS_Store，之后 make-dmg.sh 每次打包直接复用。
#
# 为什么不在打包时现场用 AppleScript 摆位（create-dmg 的做法）：
#   CI 是无头环境，osascript 控制 Finder 常被自动化权限拦下（-1743），
#   发版链路会莫名其妙失败或悄悄退化成一个白底窗口。布局是静态的，
#   在这里算好一次、提交进仓库，打包就只剩"拷文件"，CI 与本地结果一致。
#
# 用法（维护者本机跑一次即可，需要 GUI 会话与 Finder）：
#   ./SelectedApp/Scripts/make-dmg-layout.sh
#
# 改了 Resources/DMG/background.png 或下面任何坐标，重跑一次。
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd)"
BACKGROUND="$REPO/Resources/DMG/background.png"
LAYOUT="$REPO/Resources/DMG/DS_Store"

# 布局参数：与 make-dmg.sh 产出的 dmg 完全对齐，改一处要同时改这里和 background.png 的绘制坐标。
VOLUME="Selected"
CONTENT_W=600
CONTENT_H=360
WINDOW_X=440
WINDOW_Y=260
ICON_SIZE=128
APP_POS_X=150
APP_POS_Y=160
LINK_POS_X=450
LINK_POS_Y=160

[ -f "$BACKGROUND" ] || { echo "缺少背景图：$BACKGROUND"; exit 1; }

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/selected-layout.XXXXXX")"
RW_DMG="$(mktemp -u "${TMPDIR:-/tmp}/selected-layout.XXXXXX.dmg")"
# 必须让系统挂到 /Volumes/<卷名>：Finder 的 `disk "<卷名>"` 只认这个位置，
# 自定 mountpoint 时 AppleScript 会报 -1728（不能获得 disk）。
MOUNT="/Volumes/$VOLUME"
cleanup() {
    hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
    rm -rf "$STAGING" "$RW_DMG"
}
trap cleanup EXIT

# 摆位用的 app 只是个同名占位：.DS_Store 只记名字与坐标，不关心 bundle 内容。
# 但图标必须是真的，否则截图里看不出最终观感——用它和真包比对落位。
APP="$STAGING/$VOLUME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$REPO/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Selected</string>
    <key>CFBundleIdentifier</key><string>com.selected.layout</string>
    <key>CFBundleName</key><string>Selected</string>
    <key>CFBundleIconFile</string><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
PLIST
printf '#!/bin/sh\nexit 0\n' > "$APP/Contents/MacOS/Selected"
chmod +x "$APP/Contents/MacOS/Selected"

ln -s /Applications "$STAGING/Applications"
mkdir -p "$STAGING/.background"
cp "$BACKGROUND" "$STAGING/.background/background.png"

hdiutil create -volname "$VOLUME" -srcfolder "$STAGING" -format UDRW -ov -quiet "$RW_DMG"
hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
hdiutil attach "$RW_DMG" -noautoopen -quiet

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {$WINDOW_X, $WINDOW_Y, $((WINDOW_X + CONTENT_W)), $((WINDOW_Y + CONTENT_H + 28))}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to $ICON_SIZE
        set text size of opts to 12
        set background picture of opts to file ".background:background.png"
        set position of item "Selected.app" of container window to {$APP_POS_X, $APP_POS_Y}
        set position of item "Applications" of container window to {$LINK_POS_X, $LINK_POS_Y}
        update without registering applications
        delay 1
        close
        delay 1
        open
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Finder 是异步落盘的，给它一拍再取。
sleep 1
[ -f "$MOUNT/.DS_Store" ] || { echo "Finder 没写出 .DS_Store（自动化权限被拦？）"; exit 1; }
cp "$MOUNT/.DS_Store" "$LAYOUT"

echo "已更新 $LAYOUT"
echo "提醒：改了坐标或背景图后，make-dmg.sh 打出新包即为最终效果"
