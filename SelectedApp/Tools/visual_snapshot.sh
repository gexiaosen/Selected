#!/bin/bash
# 调试用视觉快照（浅/深各一轮，输出 PNG 供人工比对）
#
# 用法:
#   bash SelectedApp/Tools/visual_snapshot.sh [输出目录] [--save-baseline DIR] [--baseline DIR]
#
#   --save-baseline DIR  本次截图另存为基线
#   --baseline DIR       与基线逐张做像素对比（跳过顶部 120px / 左侧 320px 的动态区；
#                        设置与引导页不跳），差异 >0.2% 退出 1
#
# 固定查看日：默认取库里最近有数据的交易日；可另设
#   SELECTED_SNAPSHOT_DATE=2026-09-10 bash SelectedApp/Tools/visual_snapshot.sh ...
#
# 依赖：本机已安装 /Applications/Selected.app（或 SelectedApp/dist/Selected.app）
# 作为 .app 模板；会把它复制到临时目录、替换成 debug 可执行文件并 ad-hoc 签名，
# **不会覆盖**已安装的应用。数据用 data/ 的副本（SELECTED_DATA_DIR），不写生产库。
#
# 输出：默认 SelectedApp/.visual-snapshots/<时间戳>/{light,dark}/*.png
# 说明：diff 用 Swift + CoreGraphics 实现（Tools/image_diff.swift），不依赖 Python/ImageMagick。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DIR="$ROOT/SelectedApp"
BIN="$APP_DIR/.build/debug/Selected"

TEMPLATE="${SELECTED_SNAPSHOT_TEMPLATE:-}"
if [ -z "$TEMPLATE" ]; then
    if [ -d "/Applications/Selected.app" ]; then
        TEMPLATE="/Applications/Selected.app"
    elif [ -d "$APP_DIR/dist/Selected.app" ]; then
        TEMPLATE="$APP_DIR/dist/Selected.app"
    fi
fi
if [ ! -d "$TEMPLATE" ]; then
    echo "❌ 找不到 .app 模板：请先安装 Selected，或设置 SELECTED_SNAPSHOT_TEMPLATE 指向一个 .app" >&2
    exit 1
fi

echo "== 构建 debug 可执行文件 =="
(cd "$APP_DIR" && swift build --product Selected)

OUT=""
SAVE_BASELINE=""
BASELINE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --save-baseline)
            SAVE_BASELINE="${2:-}"
            [ -n "$SAVE_BASELINE" ] || { echo "❌ --save-baseline 需要目录" >&2; exit 2; }
            shift 2
            ;;
        --baseline)
            BASELINE="${2:-}"
            [ -n "$BASELINE" ] || { echo "❌ --baseline 需要目录" >&2; exit 2; }
            shift 2
            ;;
        *)
            OUT="$1"
            shift
            ;;
    esac
done
STAMP="$(date +%Y%m%d-%H%M%S)"
if [ -z "$OUT" ]; then
    OUT="$APP_DIR/.visual-snapshots/$STAMP"
fi
mkdir -p "$OUT"

TMP="$(mktemp -d)"
DATA="$TMP/data"
BUNDLE="$TMP/SelectedSnapshot.app"
mkdir -p "$DATA"
for f in selected.sqlite3 selected.sqlite3-wal selected.sqlite3-shm \
         history.sqlite3 history.sqlite3-wal history.sqlite3-shm; do
    if [ -f "$ROOT/data/$f" ]; then
        cp "$ROOT/data/$f" "$DATA/$f"
    fi
done

cp -R "$TEMPLATE" "$BUNDLE"
cp "$BIN" "$BUNDLE/Contents/MacOS/Selected"
PLIST="$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.selected.snapshot" "$PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleName SelectedSnapshot" "$PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName SelectedSnapshot" "$PLIST" >/dev/null
rm -rf "$BUNDLE/Contents/_CodeSignature"
codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1

for mode in light dark; do
    mkdir -p "$OUT/$mode"
    echo "== 截取 $mode =="
    SELECTED_SNAPSHOT_DIR="$OUT/$mode" \
    SELECTED_DATA_DIR="$DATA" \
    SELECTED_STOCK_LIST_HTTP=off \
        "$BUNDLE/Contents/MacOS/Selected" -onboardingCompleted YES -appearanceMode "$mode" \
        >"$OUT/$mode.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 90); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "⚠ $mode 超时，结束实例" >&2
        kill "$pid" 2>/dev/null || true
    fi
done

if [ -n "$SAVE_BASELINE" ]; then
    mkdir -p "$SAVE_BASELINE"
    cp -R "$OUT"/. "$SAVE_BASELINE"/
    echo "✅ 基线已更新：$SAVE_BASELINE"
fi

if [ -n "$BASELINE" ]; then
    if [ ! -d "$BASELINE" ]; then
        echo "❌ 基线目录不存在：$BASELINE" >&2
        rm -rf "$TMP"
        exit 1
    fi
    DIFF_TOOL="$TMP/image_diff"
    swiftc -O "$APP_DIR/Tools/image_diff.swift" -o "$DIFF_TOOL"
    failures=0
    for mode in light dark; do
        [ -d "$OUT/$mode" ] || continue
        for img in "$OUT/$mode"/*.png; do
            name="$(basename "$img")"
            case "$name" in diff-*) continue ;; esac
            base="$BASELINE/$mode/$name"
            if [ ! -f "$base" ]; then
                echo "⚠ 缺少基线：$mode/$name"
                failures=$((failures + 1))
                continue
            fi
            case "$name" in
                onboarding.png) itop=0; ileft=0; threshold=1.5 ;;
                # 设置窗口左侧是系统材质/焦点噪声；只比内容区
                settings-*) itop=120; ileft=320; threshold=1.0 ;;
                *) itop=120; ileft=320; threshold=1.0 ;;
            esac
            if ! "$DIFF_TOOL" "$base" "$img" "$itop" "$ileft" "$threshold" "$OUT/$mode/diff-$name"; then
                failures=$((failures + 1))
            fi
        done
    done
    if [ "$failures" -gt 0 ]; then
        echo "❌ 视觉基线差异：$failures 张（diff 图见 $OUT/<mode>/diff-*.png）" >&2
    else
        echo "✅ 视觉基线与本次截图一致"
    fi
fi

rm -rf "$TMP"
echo "✅ 快照输出：$OUT"
[ -z "$BASELINE" ] || [ "$failures" -eq 0 ]
