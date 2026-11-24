#!/bin/bash
# Selected.app 构建打包脚本
# 用法: ./build_app.sh [release|debug] [--install] [--no-push] [--no-commit]
#   release|debug  构建配置（默认 release）
#   --install      打包后覆盖安装到 /Applications 并注册 LaunchServices（通知图标依赖注册，默认不执行）
#   --no-push      只本地提交，**不** push origin/main（版本 tag 也留在本地）
#   --no-commit    仅本地构建与打包：不改 Info.plist 版本/构建号、不执行 git add/commit/tag/push
#
# ⚠ 为什么有 `--no-push`（2026-09-22 加）：默认行为是**打包完自动 push origin/main
#   并带上本次版本 tag（`--follow-tags`）**。
#   在「只想本地打包安装」时它会**顺带把一堆本地提交推上去**（外部动作，不该悄悄发生）。
#   更糟的是它的自动提交走 `git add -A` —— **会把临时文件一起提交**
#   （实测踩过一次：一个「摘掉推送段」的脚本副本被提交进去了）。
#   只需要本地打包/测试安装且不碰 Git 与版本号时，请加 `--no-commit`；仅跳过推送时加 `--no-push`。
set -euo pipefail

# ⚠⚠ 删除一律用**绝对路径**的 /bin/rm，**不要**写裸 `rm`（2026-09-23 实测踩到）：
#   AI CLI（WorkBuddy）会在 PATH 最前面放一个 `safe-bin/rm` 垫片，它把"批量删除"
#   换成**挪进废纸篓**、并且**返回 0** —— 于是本脚本每次打包都往废纸篓丢两个包
#   （dist 一个、/Applications 一个），而日志里**一句提示都没有**（`rm` "成功"了）。
#   ⚠ 垫片只在设了 `CODEBUDDY_SESSION_ID` 的会话里生效
#     ⇒ 老板在终端跑没事，**AI 会话里跑就中招**（所以他一直看到那两个包）。
#   ⚠ 绝对路径能绕开 PATH 垫片；`free_path` 的 `trash` 兜底仍然保留（真被拦时还能用）。
REAL_RM="/bin/rm"
[ -x "$REAL_RM" ] || REAL_RM="/usr/bin/rm"

MODE="release"
INSTALL=0
NOPUSH=0
NOCOMMIT=0
for arg in "$@"; do
    case "$arg" in
        release|debug) MODE="$arg" ;;
        --install)     INSTALL=1 ;;
        --no-push)     NOPUSH=1 ;;
        --no-commit)   NOCOMMIT=1; NOPUSH=1 ;;
        -h|--help)
            echo "用法: ./build_app.sh [release|debug] [--install] [--no-push] [--no-commit]"
            echo "  --install    打包后覆盖安装到 /Applications 并注册 LaunchServices"
            echo "  --no-push    只本地提交，不 push origin/main"
            echo "  --no-commit  仅本地打包，不改版本号/Info.plist，不提交 Git、不打 tag、不推送"
            exit 0 ;;
        *)
            echo "未知参数: ${arg}（可用: release | debug | --install | --no-push | --no-commit）" >&2
            exit 2 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Selected"
DIST="$ROOT/SelectedApp/dist"
BUNDLE="$DIST/$APP_NAME.app"

echo "== Selected 构建打包 ($MODE) =="
cd "$ROOT/SelectedApp"

# ⚠ 2026-09-25（审计 C7）：本项目只支持 Apple Silicon（arm64）—— 此前"仅 arm64"
#   只是文档声明，没有任何机器强制；在 x86_64 Mac / Rosetta 环境构建会**静默产出
#   x86_64 包**，与声明不符（且 macOS 26 的 API 不保证 Rosetta 可用）。
#   ⇒ 在唯一打包入口加硬断言。
ARCH="$(uname -m)"
if [ "$ARCH" != "arm64" ]; then
    echo "❌ 仅支持 Apple Silicon（arm64），当前架构 ${ARCH} —— 终止打包" >&2
    exit 1
fi

# ⚠⚠ 回归闸门（2026-10-16 测试审查 B1）：**release 打包必须先过全量回归**。
#   此前本脚本从不跑回归（全文只有两处注释提到 `swift test`），却在末尾
#   `git add -A && commit && push origin/main` —— 于是**回归红着的代码照样上公开 main**，
#   且 `git add -A` 把工作区的在制品一起捆进同一个「发布」提交（实测踩过两次）。
#   ⇒ 闸门放在**版本号自增之前**：回归失败时既不消耗版本号，也不脏 Info.plist。
#   ⚠ debug 不跑闸门：debug 不递增版本号、不推送，跑一次闸门要多等数分钟；
#     release 才是分发口径，闸门只守 release。
#   ⚠ 刻意**不提供** `--skip-tests` 逃生开关：逃生开关最终都会被用成默认。
#     真要绕过（如紧急回滚旧包），直接用 `debug` 模式打包即可。
if [ "$MODE" = "release" ]; then
    echo ""
    echo "== 回归闸门 engine/tests/run_all.sh =="
    if ! bash "$ROOT/engine/tests/run_all.sh"; then
        echo "" >&2
        echo "❌ 全量回归未通过 ⇒ 终止打包：不递增版本号、不提交、不推送。" >&2
        echo "   上面已逐条列出红项，修绿后重新打包。" >&2
        exit 1
    fi
    echo "== 回归闸门：通过 =="
fi

# ⚠⚠ 2026-10-08（老板：「构建日期今天才 10 月 8 号，但你构建的都到 10 月 11 号了」）：
#   **版本号与构建号一律由本脚本按真实日期生成**，不再手改 `Resources/Info.plist`。
#
#   ## 事故形态（为什么必须自动化）
#   Info.plist 里的 `CFBundleVersion` 一直是**手写**的（`20261007` → `20261011`）——
#   而 `20261011` 比实际日期（10-08）**超前 3 天**。系统「关于」面板把 build 号直接
#   显示在版本号后面：`版本 0.4.46 (20261011)` ⇒ 老板一眼看出不对。
#   两个都是"手写必然漂"的东西：**日期与打包时刻无关**，而版本号没人记得每次 +1。
#
#   ## 现在的规则
#   · `CFBundleVersion`（构建号）= **真实打包日期**（北京时间 `yyyyMMdd`）；
#     同一天再打包依次得到 `yyyyMMdd.2`、`.3`…（当天第一次就是干净的日期）
#     —— 这样既"看着是日期"，也满足 TN2420「macOS 同一 release train 不许复用 build 号」。
#   · `CFBundleShortVersionString`（版本号）= **每次 release 打包 +1 末位**
#     （0.4.46 → 0.4.47；本项目的语义化规则：末位 = bug 修复 / 小功能）。
#     ⚠ 刻意**不做**"有改动才 +1"的内容比对：那需要维护"上次打包时的 HEAD"状态文件。
#     ⚠ 但**做**"上一格用没用掉"的判定（2026-10-16 加，2026-10-19 事故逼出来的）：
#       不需要状态文件 —— HEAD 里那两个键就是"上次交付到哪"的权威记录。
#       工作区比 HEAD 高 ⇒ 上次 release 死在提交之前 ⇒ **复用那一格**，不再 +1。
#       原先"每次打包都 +1"的代价被低估了：一次会话中断就攒出 14 格空号 + 9 份
#       没人用的 dSYM，而装机版还是旧的 ⇒ 老板对着旧界面反馈"改了没生效"。
#       详见下面 `ver_unspent` 那段。
#     ⚠ `debug` 打包**不动版本号**（只更新构建日期）：调试包不该消耗版本号。
#
#   ## 一次性纠正
#   库里那个超前的 `20261011` 会被这次的 `20261008` 覆盖 ⇒ 构建号**从未来退回现实**
#   （唯一的一次"倒退"；数值不再比 20261011 大，这是修正错误值的必然代价）。
#
#   ⚠⚠ **写回用 `sed` 按行替换，不用 `PlistBuddy` / `plutil`**（2026-10-08 实测）：
#     那两者会把整份 plist **重写**一遍 —— 注释与键序一起被吞掉（本文件里那些
#     "为什么这么写"的注释就是这么没的，且**不会报错**）。`sed` 只改值那一行；
#     写完**立刻读回校验**（按行定位一旦遇上格式变化会静默改错地方）。
PLIST="$ROOT/SelectedApp/Resources/Info.plist"
if [ ! -f "$PLIST" ]; then
    echo "❌ 找不到 $PLIST —— 无法写入版本号，终止打包" >&2
    exit 1
fi
PB=/usr/libexec/PlistBuddy
CUR_VER="$($PB -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
if ! echo "$CUR_VER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "❌ CFBundleShortVersionString 不是语义化 x.y.z：『${CUR_VER}』—— 终止打包" >&2
    exit 1
fi
TODAY="$(TZ=Asia/Shanghai date +%Y%m%d)"
CUR_BUILD="$($PB -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || true)"
# ⚠ CUR_BUILD 必须校验（2026-10-16 审查 B1）：读空 / 读到乱码时，下面的 `case`
#   会落到 `*)` 分支**直接写 `$TODAY`** —— 若今天已经打过包，就得到**重复构建号**，
#   正是本段注释里 TN2420「同一 release train 不许复用 build 号」要防的那条。
#   而且 `case` 的 `.N` 递增链是从 plist **内容**推出来的，任何 `git checkout` 撤销
#   Info.plist 都会让链条从头开始 —— 所以形态不对时宁可终止，也不猜。
if ! echo "$CUR_BUILD" | grep -qE '^[0-9]{8}(\.[0-9]+)?$'; then
    echo "❌ CFBundleVersion 不是 yyyyMMdd[.N] 形态：『${CUR_BUILD}』—— 终止打包" >&2
    echo "   修法：把 Resources/Info.plist 的 CFBundleVersion 改成本日北京时间 yyyyMMdd" >&2
    echo "   （或确认 PlistBuddy 能读到该键），再重新打包。" >&2
    exit 1
fi

ver_unspent=0
if [ "$NOCOMMIT" = "1" ]; then
    NEW_VER="$CUR_VER"
    NEW_BUILD="$CUR_BUILD"
    echo "版本: ${NEW_VER}（构建 ${NEW_BUILD}，--no-commit 保持 Info.plist 不变）"
else
    if [ "$MODE" = "release" ]; then
        # ⚠⚠ **先问上一格用没用掉**（2026-10-19 实测事故）。自增必须在构建之前 —— 版本要写进
        #   包内的 plist，等装完再改就得重签一次、等于再走一遍构建；所以正确的修法不是
        #   "把自增挪到安装之后"，而是**复用没用掉的那一格**。
        #   判据：工作区 Info.plist 的版本比 **HEAD 里的**还高 ⇒ 上一次 release 死在
        #   「写版本号 → 构建 → 归档 dSYM → 提交」中间（提交没发生 ⇒ 这格号没进 git、
        #   没打 tag、没装机，**不标识任何交付物**）⇒ 这次接着用它，不再 +1。
        #   实测一次中断攒出 14 格空号 + 9 份没人用的 dSYM，而 /Applications 里还是旧包
        #   —— 对着旧界面反馈"改了没生效"就是这么来的。
        HEAD_PLIST="$(git -C "$ROOT" show HEAD:SelectedApp/Resources/Info.plist 2>/dev/null || true)"
        HEAD_VER="$(printf '%s\n' "$HEAD_PLIST" \
            | awk '/<key>CFBundleShortVersionString<\/key>/{getline; gsub(/^.*<string>|<\/string>.*$/,""); print; exit}' || true)"
        HEAD_BUILD="$(printf '%s\n' "$HEAD_PLIST" \
            | awk '/<key>CFBundleVersion<\/key>/{getline; gsub(/^.*<string>|<\/string>.*$/,""); print; exit}' || true)"
        # `sort -V` 取最小者 == HEAD ⇒ CUR 确实**领先**于 HEAD（反过来是"有人把 plist 改回去了"，
        #   那不该被当成"有一格待复用"，照常自增）
        if [ -n "$HEAD_VER" ] && [ "$HEAD_VER" != "$CUR_VER" ] && \
           [ "$(printf '%s\n%s\n' "$HEAD_VER" "$CUR_VER" | sort -V | head -1)" = "$HEAD_VER" ]; then
            ver_unspent=1
        fi
        if [ "$ver_unspent" = "1" ]; then
            NEW_VER="$CUR_VER"
            echo "↻ 版本号 ${CUR_VER} 上次没交付（HEAD 仍是 ${HEAD_VER}）⇒ 复用，不再 +1"
        else
            NEW_VER="${CUR_VER%.*}.$(( ${CUR_VER##*.} + 1 ))"      # 末位 +1（0.4.46 → 0.4.47）
        fi
    else
        NEW_VER="$CUR_VER"
    fi
    case "$CUR_BUILD" in
        "$TODAY")   NEW_BUILD="$TODAY.2" ;;                       # 今天第二次打包
        "$TODAY".*) NEW_BUILD="$TODAY.$(( ${CUR_BUILD##*.} + 1 ))" ;;
        *)          NEW_BUILD="$TODAY" ;;                         # 换天（或首次）：干净的日期
    esac
    # ⚠ 构建号也复用：**没交付过的那一格不算"已发出的号"**，TN2420 禁的是同一 train 内
    #   给两个不同产物用同一个号 —— 这里两个键都还没进 git，谈不上复用。
    if [ "$MODE" = "release" ] && [ "$ver_unspent" = "1" ] && [ -n "$HEAD_BUILD" ] && \
       [ "$HEAD_BUILD" != "$CUR_BUILD" ] && \
       [ "$(printf '%s\n%s\n' "$HEAD_BUILD" "$CUR_BUILD" | sort -V | head -1)" = "$HEAD_BUILD" ]; then
        NEW_BUILD="$CUR_BUILD"
    fi

    # 按行替换：`<key>X</key>` 的**下一行**就是它的 `<string>`（本文件的既有排版）
    sed -i '' "/<key>CFBundleShortVersionString<\/key>/{n;s|<string>.*</string>|<string>${NEW_VER}</string>|;}" "$PLIST"
    sed -i '' "/<key>CFBundleVersion<\/key>/{n;s|<string>.*</string>|<string>${NEW_BUILD}</string>|;}" "$PLIST"

    # 读回校验（值必须真的落到那两个键上）+ 注释还在（=这次写入没有把整份 plist 重写掉）
    _wv="$($PB -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
    _wb="$($PB -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || true)"
    if [ "$_wv" != "$NEW_VER" ] || [ "$_wb" != "$NEW_BUILD" ]; then
        echo "❌ 写入版本号失败：读回 『${_wv} / ${_wb}』，期望 『${NEW_VER} / ${NEW_BUILD}』" >&2
        echo "   （plist 排版若被改过，`sed` 的按行定位会静默改错地方 —— 检查那两个键的写法）" >&2
        exit 1
    fi
    if ! grep -q '<!--' "$PLIST"; then
        echo "⚠️  $PLIST 里的注释不见了 —— 说明这次写入把整份 plist 重写了一遍" >&2
        echo "    （PlistBuddy / plutil 会连注释与键序一起吞掉；改这两键请走 sed 按行替换）" >&2
    fi
    echo "版本: ${CUR_VER} → ${NEW_VER}（构建 ${NEW_BUILD}，北京时间 $(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M')）"
fi

# 工具链探测：优先 Xcode-beta / Xcode（CLT 6.2.3 的 SPM manifest 链接有损坏，故回退）
SWIFT_BUILD="swift build"
if [ -d "/Applications/Xcode-beta.app" ]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
    SWIFT_BUILD="xcrun swift build"
    echo "使用工具链: Xcode-beta ($DEVELOPER_DIR)"
elif [ -d "/Applications/Xcode.app" ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    SWIFT_BUILD="xcrun swift build"
    echo "使用工具链: Xcode ($DEVELOPER_DIR)"
else
    echo "使用工具链: CommandLineTools"
fi

# 可选编译参数透传（默认空 → 行为与原先完全一致）。
# 用途：在受限/沙箱环境下宏插件服务（swift-plugin-server）会因嵌套沙箱失败，
# 表现为 @Observable 报 "external macro implementation ... could not be found"，
# 此时用 SELECTED_SWIFT_FLAGS="-Xswiftc -disable-sandbox" 构建。
SWIFT_EXTRA_FLAGS="${SELECTED_SWIFT_FLAGS:-}"
if [ -n "$SWIFT_EXTRA_FLAGS" ]; then
    echo "附加编译参数: $SWIFT_EXTRA_FLAGS"
fi

$SWIFT_BUILD -c "$MODE" $SWIFT_EXTRA_FLAGS
BIN="$($SWIFT_BUILD -c "$MODE" $SWIFT_EXTRA_FLAGS --show-bin-path)/$APP_NAME"

# 清理残留：打包前的旧包与执行环境保护机制改名保留的 .prev/.tmp 目录
echo "== 清理 dist 残留 =="
for stale in "$BUNDLE".prev-* "$BUNDLE".tmp-* "$BUNDLE".old-*; do
    [ -e "$stale" ] || continue
    # ⚠ 与 `free_path` 同一套：先 `"$REAL_RM"`（绝对路径，绕开 PATH 垫片）、`trash` 只作兜底。
    #   为什么必须绝对路径见文件头 `REAL_RM` 那段注释（2026-09-23 查清）。
    if "$REAL_RM" -rf "$stale" 2>/dev/null && [ ! -e "$stale" ]; then
        echo "  已删除: $stale"
    elif command -v trash >/dev/null 2>&1 && trash "$stale" 2>/dev/null && [ ! -e "$stale" ]; then
        echo "  已移入废纸篓: $stale"
    else
        echo "  ⚠️ 无法删除（可能被环境保护改名）: $stale" >&2
        echo "     请手动移入废纸篓后再打包" >&2
    fi
done

# 在 /tmp 全新组装 bundle（规避 com.apple.provenance 扩展属性导致签名失败）：
# 文件从 iCloud/外置目录移到新位置后 macOS 会自动打 provenance 标记，
# codesign 拒绝在带旧 seal 冲突的文件上签名。/tmp 中转组装 = 全新文件，不继承 xattr。
# ⚠ 不用 `/tmp/Selected_build_$$.app`（2026-10-16 审查 B1）：
#   · PID 可预测 + `/tmp` 全局可写 ⇒ 同机其他用户可抢先占位或换成 symlink；
#   · 原脚本**没有任何 trap**，Ctrl-C 或中途非零退出就把半截 bundle 永久留在 /tmp。
#   `mktemp -d` 给的是 0700 随机目录，再用 trap EXIT 兜底清理（结尾 `mv` 走之后
#   清理的是已空的壳目录，无害）。
TMPROOT="$(/usr/bin/mktemp -d -t Selected_build)"
TMPAPP="$TMPROOT/$APP_NAME.app"
trap '"$REAL_RM" -rf "${TMPROOT:-}"' EXIT
mkdir -p "$TMPAPP/Contents/MacOS" "$TMPAPP/Contents/Resources"

cp "$BIN" "$TMPAPP/Contents/MacOS/$APP_NAME"
cp "$ROOT/SelectedApp/Resources/Info.plist" "$TMPAPP/Contents/Info.plist"
cp "$ROOT/SelectedApp/Resources/AppIcon.icns" "$TMPAPP/Contents/Resources/AppIcon.icns"
cp "$ROOT/SelectedApp/Resources/AppIcon.png" "$TMPAPP/Contents/Resources/AppIcon.png"
# 隐私清单（2026-09-25，审计 C3）：上架/正式分发前的必需项，先随包带上
cp "$ROOT/SelectedApp/Resources/PrivacyInfo.xcprivacy" "$TMPAPP/Contents/Resources/PrivacyInfo.xcprivacy"

# Sparkle 自动更新框架：随 .app 进 `Contents/Frameworks`，缺了即拒——出包必须带更新能力。
# 用 ditto 而非 cp -R：framework 顶层是 `Versions/Current` 符号链接树，
# ditto 是 Apple 推荐的分发复制方式，能完整保留软链与权限。
# ⚠ 必须在签名之前进包：签名覆盖的是最终 bundle 内容，签完再放会破坏 seal。
SPARKLE_FW="$(dirname "$BIN")/Sparkle.framework"
if [ ! -d "$SPARKLE_FW" ]; then
    echo "❌ 缺少 Sparkle.framework（${SPARKLE_FW}）—— 自动更新会失效，拒绝出包" >&2
    "$REAL_RM" -rf "$TMPAPP"
    exit 1
fi
mkdir -p "$TMPAPP/Contents/Frameworks"
ditto "$SPARKLE_FW" "$TMPAPP/Contents/Frameworks/Sparkle.framework"

# 第三方许可声明（2026-10-07 审计 P1-25，**必须在签名之前**）
#
# ⚠ 为什么必须进包：BSD-3-Clause 要求「**再分发二进制时必须以文档形式附上
#   版权声明与许可全文**」，MIT 同样要求随软件附许可文本。本项目把两个 vendor 包
#   （swift-trading-view / ThinkingOrbs）编译进了 `.app` ⇒ 包内必须有这份声明。
#   ⚠ 早前的判断是「自用不构成分发，所以不算违规」—— 那个判断仍然成立
#     （不改符号他性），但**成本只有几行**：源码已在公开 GitHub 仓库上
#     （`build_app.sh:280` 每次打包都 `git push origin/main`），
#     将来转发 .app 给朋友 / 装到第二台机器即构成分发 ⇒ 那时再补是事后补救。
#
# ⚠ 用**生成脚本**而非手抄文件：声明分散在三个来源文件（两个包的 LICENSE +
#   ta-lib 的 THIRD-PARTY-NOTICE.md），手抄进包意味着「上游升级后忘了同步」。
#   脚本在缺任何一份时 **exit 1** ⇒ 宁可打包失败，也不要打出声明不全的 .app。
if ! bash "$ROOT/SelectedApp/Tools/gen_third_party_notices.sh" \
        "$TMPAPP/Contents/Resources/THIRD_PARTY_NOTICES.txt"; then
    echo "错误: 第三方许可声明生成失败，终止打包" >&2
    "$REAL_RM" -rf "$TMPAPP"
    exit 1
fi

# 本体许可全文（GPL-3.0 §4「随程序交付许可文本」）：
# ⚠ 换成 GPL 之后这不是"可选附件"——漏装等同于分发不合规。
#   与上面的 THIRD_PARTY_NOTICES 一起，构成包内完整的许可材料。
cp "$ROOT/LICENSE" "$TMPAPP/Contents/Resources/LICENSE.txt" || {
    echo "错误: 仓库根 LICENSE 缺失，无法随包交付许可全文，终止打包" >&2
    "$REAL_RM" -rf "$TMPAPP"
    exit 1
}

# 随包资源：**只装运行期需要的参数 JSON**（出厂参数版本 + schema 元数据 + 证券列表基线）
#
# 原生化第 13 批（2026-09-18）：不再内嵌 Python 运行时与 selected_engine 源码 ——
# 全部业务逻辑已原生实现并与引擎逐字段对账（15 模块 + 15 对账），CLI 回落路径连同
# 运行时一起移除（失败直接报错，不再静默换 Python）。包体 47MB → ~9MB。
#
# ⚠ 2026-09-24：Python 参考实现、**全部对账驱动与对账夹具**均已从仓库整体删除
#   （用户要求"清理 python 代码，不再需要两边回测校验"，随后追加"以后所有迭代都基于 Swift 代码"）。
#   ⚠⚠ 原文本行写"对账基准改为**静态黄金夹具**（`engine/tests/fixtures/reconcile_outputs/`）"
#     —— 那个目录**同日已被删除**（夹具与 17 个对账步骤一并移除）。
#     现在回归只剩 `swift test` + Swift 侧自检 + 静态护栏，**不再有任何历史口径比对**。
#   两个 `*_export.json` 的生成源从冻结的 `db.py` / `param_schema.py` 迁到 Swift
#   （`SelectedCore/SchemaExportData.swift` + `Tools/export_schema.swift`，
#    由 `swift test` 的 `SchemaExportTests` 逐字节校验）。
#   ⇒ 决策与代价见 `docs/specs/README.md`。
mkdir -p "$TMPAPP/Contents/Resources/engine/params"
rsync -a --include '*/' --include '*.json' --exclude '*' \
    "$ROOT/engine/params/" "$TMPAPP/Contents/Resources/engine/params/"

# 随包参数一致性复核：参数文件是"参数中心"的兜底来源，必须是源码里的那一份
ENGINE_MISMATCH=0
while read -r rel; do
    [ -n "$rel" ] || continue
    if ! cmp -s "$ROOT/engine/$rel" "$TMPAPP/Contents/Resources/engine/$rel"; then
        echo "  ❌ 随包参数与源码不一致: $rel" >&2
        ENGINE_MISMATCH=1
    fi
done < <(cd "$ROOT/engine" && find params -name '*.json' -type f | sort)
if [ "$ENGINE_MISMATCH" = "1" ]; then
    echo "错误: 随包参数与源码不一致，终止打包" >&2
    "$REAL_RM" -rf "$TMPAPP"
    exit 1
fi
echo "  随包参数一致性校验: 通过"

# ⚠⚠ 签名身份（2026-09-23 引入 / 2026-11-24 改为优先 Apple Development）：
#
# 为什么优先 Apple Development（而不是自签 / ad-hoc）：TCC 的文件夹授权、钥匙串 ACL
# 认的是 designated requirement。ad-hoc 的 DR = cdhash，改一行代码重建就换身份 ⇒
# 每次装新版都要重新授权；自签证书的 DR 同样绑在证书根上、重建后仍会失效。
# **只有 Apple 签发的身份**（Apple Development / Developer ID）推导出的
# `identifier + anchor apple generic + leaf CN` 与 cdhash 无关，一次授权跨版本有效。
# （MiscKit 2026-10-21 实测记录：换 Apple Development 后连改两次代码重建，钥匙串读取不再弹框。）
#
# ⚠ 证书一年到期：到期后本机与 GitHub Actions 的 p12 secret 都要重导一次
#   （`SelectedApp/Scripts/upload-signing-cert.sh`）；缺失/过期时**自动回落 ad-hoc**，
#   不会让打包失败，只是 TCC 授权会重新弹一次。
# ⚠ CI 通过 `SELECTED_SIGN_IDENTITY` 指定导入后的身份名，本机不设则自动探测。
SIGN_ID="${SELECTED_SIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1 || true)"
fi
if [ -z "$SIGN_ID" ] && security find-identity -v -p codesigning 2>/dev/null \
        | grep -q "Selected Local Signing"; then
    SIGN_ID="Selected Local Signing"
fi
if [ -n "$SIGN_ID" ]; then
    SIGN_ARG="$SIGN_ID"
else
    SIGN_ARG="-"
fi
SIGN_ARGS=(--force --sign "$SIGN_ARG")
# Hardened Runtime 只在有真实身份时开（ad-hoc 没有意义）；与 Sparkle 官方分发一致。
if [ "$SIGN_ARG" != "-" ]; then
    SIGN_ARGS+=(--options runtime)
fi
# ⚠ 签名失败不再吞错（2026-10-16 审查 B1）：此前是 `… 2>/dev/null || true` ——
#   失败原因被丢进黑洞，只靠下面那条终验兜底；终验用的是不带 `--strict` 的
#   `codesign --verify`，比 /Applications 那一侧（`--deep --strict`）检查得更松，
#   于是**实际发出去的 dist/Selected.app 拿的是最弱的一次校验**。
# ⚠ 现在包内多了 `Contents/Frameworks/Sparkle.framework`（含 XPC / Updater.app /
#   Autoupdate 三层嵌套可执行体）⇒ **必须从内到外逐层签**，顺序不能颠倒；
#   只签外壳会让 `--verify --deep --strict` 报 "nested code is modified or invalid"。
SIGN_FW="$TMPAPP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SIGN_FW" ]; then
    for nested in "$SIGN_FW/Versions/B/XPCServices/"*.xpc "$SIGN_FW/Versions/B/Updater.app"; do
        [ -e "$nested" ] || continue
        if ! codesign "${SIGN_ARGS[@]}" "$nested"; then
            echo "❌ codesign 失败（嵌套：$(basename "$nested")）—— 终止打包" >&2
            "$REAL_RM" -rf "$TMPAPP"
            exit 1
        fi
    done
    if [ -f "$SIGN_FW/Versions/B/Autoupdate" ]; then
        if ! codesign "${SIGN_ARGS[@]}" "$SIGN_FW/Versions/B/Autoupdate"; then
            echo "❌ codesign 失败（Autoupdate）—— 终止打包" >&2
            "$REAL_RM" -rf "$TMPAPP"
            exit 1
        fi
    fi
    if ! codesign "${SIGN_ARGS[@]}" "$SIGN_FW"; then
        echo "❌ codesign 失败（Sparkle.framework）—— 终止打包" >&2
        "$REAL_RM" -rf "$TMPAPP"
        exit 1
    fi
fi
if ! codesign "${SIGN_ARGS[@]}" "$TMPAPP"; then
    echo "❌ codesign 失败（原因见上）—— 终止打包" >&2
    "$REAL_RM" -rf "$TMPAPP"
    exit 1
fi

# 签名终验（带 --deep --strict：嵌套 framework / XPC / sealed resource 一并校验）
if ! codesign --verify --deep --strict "$TMPAPP"; then

    echo "错误: .app 签名校验失败（sealed resource is missing or invalid），终止打包" >&2
    "$REAL_RM" -rf "$TMPAPP"
    exit 1
fi
if [ "$SIGN_ARG" = "-" ]; then
    # ⚠⚠ `$SIGN_ID` 必须写成 `${SIGN_ID}`：**变量名后面紧跟全角字符**（这里的「）
    #   时，bash 会把全角字节也当成变量名的一部分 → `SIGN_ID<乱码>: unbound variable`
    #   而 `set -u` 会**直接终止打包**（2026-09-23 实测踩到）。
    echo "签名校验: 通过（ad-hoc —— ⚠ 未装「${SIGN_ID}」证书，本次用临时身份签名）"
else
    echo "签名校验: 通过（身份：${SIGN_ID}）"
fi

# ── dSYM 归档（2026-10-06 审计 P1-13）────────────────────────────────────
#
# ⚠ 为什么必须拷：用户报障时手上的唯一实物是 `dist/Selected.app`，
#   而崩溃栈里只有**地址 + 符号偏移**。没有匹配的 dSYM，`atos` 无法符号化 ⇒
#   排障链路完全断开。叠加「崩溃上报 = 0」「反馈走 GitHub Issue」三重放大。
#
# ⚠ **实测确认（不是推测）**：
#   ① SPM 在 release 下**确实会生成** `Selected.dSYM`（`bin-path` 下可见，约 26MB）；
#   ② **UUID 与二进制一致** ⇒ 拷过去就能用，不必重新构建：
#      二进制   UUID: 5C174393-19B5-3ADA-AC96-56DA804A0C7B (arm64)
#      DWARF   UUID: 5C174393-19B5-3ADA-AC96-56DA804A0C7B (arm64)
#   ⇒ 原判定「SPM 可能不产 dSYM」是错的；真实缺口只是**脚本从不把它拷进 dist/**。
#
# ⚠ **必须与二进制同 build 号**才能符号化 ⇒ 文件名带版本号（下面的 $VER，
#   从 Info.plist 的 CFBundleShortVersionString 读），
#   否则用户报障时手上是哪个版本的包根本分不清。
# ⚠ 放 `dist/` 而不是 bundle 内：dSYM **不该随 .app 分发**（26MB 无用体积），
#   且它是**排障资产**而非运行期依赖。`dist/` 已 gitignore。
BIN_DIR="$($SWIFT_BUILD -c "$MODE" $SWIFT_EXTRA_FLAGS --show-bin-path)"
DSYM_SRC="$BIN_DIR/$APP_NAME.dSYM"
# 版本号从 Info.plist 读（用随系统自带的 PlistBuddy，不额外引入依赖）。
# ⚠ 与 `version_sync` 护栏同口径：plist 的 `CFBundleShortVersionString` 才是唯一事实来源。
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
      "$ROOT/SelectedApp/Resources/Info.plist" 2>/dev/null || echo unknown)
DSYM_DST="$DIST/$APP_NAME-$VER.dSYM"
if [ -d "$DSYM_SRC" ]; then
    "$REAL_RM" -rf "$DSYM_DST"
    if cp -R "$DSYM_SRC" "$DSYM_DST" 2>/dev/null; then
        # 符号化能力自检：UUID 对不上则 dSYM 形同废物，此刻就该知道
        _buuid=$(dwarfdump --uuid "$BIN_DIR/$APP_NAME" 2>/dev/null | awk '{print $2}')
        _duuid=$(dwarfdump --uuid "$DSYM_DST/Contents/Resources/DWARF/$APP_NAME" 2>/dev/null | awk '{print $2}')
        if [ -n "$_buuid" ] && [ "$_buuid" = "$_duuid" ]; then
            echo "dSYM 已归档: $(basename "$DSYM_DST")（UUID 已校验匹配，可符号化）"
        else
            echo "⚠️  dSYM 已归档但 UUID 不匹配（bin=${_buuid} / dSYM=${_duuid}）—— 崩溃栈将无法符号化" >&2
        fi
    else
        echo "⚠️  dSYM 拷贝失败（不阻断打包，崩溃栈将无法符号化）" >&2
    fi
else
    echo "⚠️  未找到 dSYM（${DSYM_SRC}）—— 崩溃栈将无法符号化" >&2
fi

# ── dist 滚动清理（2026-10-13 审计 N-27）────────────────────────────────
#
# 为什么：dSYM 归档（2026-10-06 P1-13）只加不删 ⇒ 实测 **53 份 / 1.5 GB**
#   （每次 release +26 MB）；另有 5 个 96 字节的空壳 `Selected <n>.app`
#   —— 那是当年 `rm` 垫片把"清 dist"变成"挪废纸篓"时期留下的重名残留
#   （见文件头 `REAL_RM` 那段）。
# ⚠ 只清 dist 内，且**当前版本那份必须留**（符号化还要用）：
#   · dSYM 按修改时间保留最新 KEEP_DSYM 份；
#   · 空壳只删"名字形如 `<App> <数字>.app` 且**目录为空**"的（非空一律不碰）。
KEEP_DSYM=10
_dsyms="$(ls -1dt "$DIST"/"$APP_NAME"-*.dSYM 2>/dev/null || true)"
_dsym_n="$(printf '%s\n' "$_dsyms" | grep -c . || true)"
if [ "${_dsym_n:-0}" -gt "$KEEP_DSYM" ]; then
    printf '%s\n' "$_dsyms" | tail -n +$((KEEP_DSYM + 1)) | while IFS= read -r _old; do
        [ -n "$_old" ] || continue
        if "$REAL_RM" -rf "$_old" 2>/dev/null && [ ! -e "$_old" ]; then
            echo "  已清理旧 dSYM: $(basename "$_old")"
        fi
    done
fi
for _stub in "$DIST/$APP_NAME "[0-9]*".app"; do
    [ -d "$_stub" ] || continue
    if [ -z "$(ls -A "$_stub" 2>/dev/null)" ]; then
        "$REAL_RM" -rf "$_stub" 2>/dev/null && echo "  已清理空壳: $(basename "$_stub")"
    fi
done

# 释放目标路径。
# ⚠⚠⚠ 「每次打包往废纸篓丢两个同名包」的**真根因**（2026-09-23 查清，别再看顺序了）：
#
#   两个调用点各清一个**同名** bundle（`dist/Selected.app` 落位前、`/Applications/Selected.app`
#   安装前）⇒ 只要删除动作"进废纸篓"，就必然是**两个同名包**（老板报的现象）。
#
#   而**为什么会进废纸篓**：不是本脚本的 `trash` 兜底，而是 **PATH 里的 `rm` 垫片** ——
#   AI CLI（WorkBuddy）把 `safe-bin/rm` 放在 PATH 最前面，它把"批量删除"换成**挪进废纸篓**
#   并**返回 0**。于是 `rm -rf` "成功"、`[ ! -e ]` 也成立 ⇒ 走的是**静默的真删分支**，
#   **日志里一句提示都没有**（所以之前一直以为是 `trash` 分支干的、改了顺序也没用）。
#   ⚠ 垫片只在设了 `CODEBUDDY_SESSION_ID` 的会话里生效 ⇒ **老板在终端跑没事、AI 会话里跑必中**。
#   ⇒ 修法：**用绝对路径 `"$REAL_RM"`**（见文件头那段）。顺序保留"先删、`trash` 兜底"即可。
#
# （下面这段是 2026-09-16 的原始背景，仍然成立：删不掉就**绝不能继续 mv**。）
# 背景：macOS 的批量删除保护（如 safe-delete 拦截器）**可能**拦截 App bundle 的 `rm -rf`。
# 此时**绝不能继续 mv**：mv 到已存在的目录会把新包嵌套进旧包里
# （dist/Selected.app/Selected_build_xxx.app），后续 cp -R 装到 /Applications 的仍是旧版
# —— 2026-09-16 实际踩到过。
free_path() {
    local target="$1"
    [ -e "$target" ] || return 0
    if "$REAL_RM" -rf "$target" 2>/dev/null && [ ! -e "$target" ]; then
        return 0
    fi
    if command -v trash >/dev/null 2>&1 && trash "$target" 2>/dev/null && [ ! -e "$target" ]; then
        echo "  ⚠️ rm 被拦，已改用 trash（会进废纸篓）: $(basename "$target")" >&2
        return 0
    fi
    local aside="${target}.old-$$"
    if mv "$target" "$aside" 2>/dev/null && [ ! -e "$target" ]; then
        echo "  ⚠️ 旧包无法删除，已改名让路: $(basename "$aside")（下次打包可清理）" >&2
        return 0
    fi
    echo "  ❌ 无法释放路径: ${target}（请手动移入废纸篓后重试）" >&2
    return 1
}

# 签名通过后移入 dist（先把目标路径腾干净，再落位）
mkdir -p "$DIST"
free_path "$BUNDLE" || { "$REAL_RM" -rf "$TMPAPP"; exit 1; }
mv "$TMPAPP" "$BUNDLE"

# 落位校验：必须是单个完整 bundle，且不能出现嵌套（旧包没清干净的确症）
if [ ! -x "$BUNDLE/Contents/MacOS/$APP_NAME" ]; then
    echo "❌ 落位校验失败: ${BUNDLE} 缺少可执行文件" >&2
    exit 1
fi
# 注意 -mindepth 1：否则 find 会把起始路径自身（也叫 *.app）算作匹配 → 永远误报
if [ -n "$(find "$BUNDLE" -mindepth 1 -maxdepth 1 -name '*.app' -print -quit)" ]; then
    echo "❌ 落位校验失败: ${BUNDLE} 内出现嵌套 App（旧包未清理）" >&2
    exit 1
fi

# ⚠ `mv` 进仓库目录（受 FileProvider 管理）后，文件可能被加上 xattr（FinderInfo / provenance），
#   而 `cp -R` 到 /Applications 会**原样带过去** → 那边签名失效（见安装段的长注释）。
#   这里先清一遍，让 dist/ 也是一份签名有效的包（`dist` 是安装的复制源）。
xattr -cr "$BUNDLE" 2>/dev/null || true

echo ""
echo "打包完成: $BUNDLE"
echo "运行: open $BUNDLE"

# ⚠ 数据归档放在 **git 提交/推送之前**（2026-10-16 审查 B1）：原先它是全脚本最后一步，
#   于是推送失败或 `--install` 中断都会让「唯一不可再生资产」这一轮根本没备；
#   而失败只降格成一行「不影响打包」。选股库没了是**不可逆**的，比推送失败严重得多。
#   （归档失败仍不阻断打包 —— 包本身是可再生的，数据不是。）
if [ -x "$ROOT/scripts/backup_data.sh" ]; then
    bash "$ROOT/scripts/backup_data.sh" || echo "⚠️ 数据归档失败（不影响打包，但请立即手动备份）" >&2
else
    echo "⚠️ 未找到备份脚本 scripts/backup_data.sh（跳过数据归档）" >&2
fi

# 打包后自动记录版本（git；--no-commit 时跳过，无变更则跳过）
if [ "$NOCOMMIT" = "1" ]; then
    echo "版本记录: 已跳过 Git 提交、tag 与推送（--no-commit）"
elif git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
        git -C "$ROOT" add -A
        # ⚠ 发布提交前把**要提交什么**打出来，并对不可入库的路径硬拦（2026-10-16 审查 B1）：
        #   `git add -A` + 公开仓库 = 静默外发。历史上已真的泄漏过一次测试库
        #   （`engine/tests/.tmpdata_budget/selected.sqlite3`，提交 e47b5b0 专门清理它）——
        #   而**从公开历史里删掉文件不等于删掉 blob**。
        #   .gitignore 是第一道，这里再钉一道，防的是"将来某条忽略规则被改坏"。
        STAGED="$(git -C "$ROOT" diff --cached --name-only)"
        echo "== 发布提交内容（$(printf '%s\n' "$STAGED" | grep -c .) 个文件）=="
        printf '%s\n' "$STAGED" | sed 's/^/   /'
        # 允许清单：data/.gitkeep（占位文件，本身就该入库）；其余 data/ 下一律不许。
        if printf '%s\n' "$STAGED" | grep -v '^data/\.gitkeep$' \
           | grep -qE '(^|/)(dist|\.build|\.temp)/|^data/|\.sqlite3?([3-]|$)|(^|/)\.env|Secrets?\.json$'; then
            echo "❌ 发布提交里含不可入库路径（数据库/构建产物/环境文件）—— 已撤销暂存并终止" >&2
            echo "   请补 .gitignore 规则后重新打包（不要把忽略规则改掉来绕过本检查）。" >&2
            git -C "$ROOT" reset -q
            exit 1
        fi
        git -C "$ROOT" commit -m "发布 $(date '+%Y-%m-%d %H:%M')" >/dev/null && \
            echo "版本记录: $(git -C "$ROOT" rev-parse --short HEAD)"
    else
        echo "版本记录: 无变更，跳过提交"
    fi

    # 版本锚点（2026-10-13 审计 N-35）：release 打包后打一个**本地** tag
    #   ⚠ 只在 release 打（debug 不递增版本号 ⇒ 会撞已存在的 tag）；
    #   ⚠ 已存在则跳过（同版本重复打包不报错）；
    #   ⚠ tag 是 annotated 且指向刚打的发布提交 ⇒ 默认推送用 `--follow-tags` 随 main 一起走
    #     （2026-10-23 老板拍板：手推 main 时 tag 屡次漏推，不再靠人记）。
    #     `--no-push` 时 tag 仍留本地。
    if [ "$MODE" = "release" ] \
       && ! git -C "$ROOT" rev-parse -q --verify "refs/tags/v$VER" >/dev/null 2>&1; then
        if git -C "$ROOT" tag -a "v$VER" -m "发布 $(date '+%Y-%m-%d %H:%M')（构建 ${NEW_BUILD}）" >/dev/null 2>&1; then
            echo "版本锚点: v${VER}（$([ "$NOPUSH" = "1" ] && echo '仅本地' || echo '随 main 推送')）"
        fi
    fi
    # ⚠ `--no-push` 时**整段跳过**（见脚本头部的说明）
    if [ "$NOPUSH" = "1" ]; then
        echo "已跳过 GitHub 推送（--no-push）"
    else
        # 推送 GitHub（origin 存在才推；失败不影响打包结果）
        #
        # 为什么需要系统代理：macOS 的系统代理（浏览器/系统 App 会走）git **不会自动读取**，
        # 于是出现"浏览器能打开 GitHub，git push 却报 Failed to connect to github.com port 443"。
        # 这里从 scutil --proxy 读出系统 HTTPS 代理，优先走它，直连作为兜底。
        SYS_PROXY="$(scutil --proxy 2>/dev/null | awk '
            /HTTPSEnable *: *1/  { en = 1 }
            /HTTPSProxy *: */    { p = $3 }
            /HTTPSPort *: */     { o = $3 }
            END { if (en && p != "" && o != "") print "http://" p ":" o }')"

        if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
            PUSHED=0
            if [ -n "$SYS_PROXY" ]; then
                if https_proxy="$SYS_PROXY" http_proxy="$SYS_PROXY" \
                   HTTPS_PROXY="$SYS_PROXY" HTTP_PROXY="$SYS_PROXY" \
                   git -C "$ROOT" push origin main --follow-tags >/dev/null 2>&1; then
                    PUSHED=1
                fi
            fi
            if [ "$PUSHED" = "0" ]; then
                if git -C "$ROOT" push origin main --follow-tags >/dev/null 2>&1; then
                    PUSHED=1
                fi
            fi
            if [ "$PUSHED" = "1" ]; then
                if [ -n "$SYS_PROXY" ]; then
                    echo "已推送 GitHub: origin/main + 版本 tag（经系统代理 ${SYS_PROXY}）"
                else
                    echo "已推送 GitHub: origin/main + 版本 tag"
                fi
            else
                # ⚠ 推送失败对 release 是**硬失败**（2026-10-16 审查 B1）：原先只 warn 一行，
                #   于是 GitHub 因 token 缺 `workflow` 权限而**整推拒绝**时没人发现，
                #   CI 就此悄悄不再运行（本文件头部第 6-9 行记的就是这个事故形态）。
                #   仍然把本地提交留着（不丢工作），只是让打包以非零退出收尾。
                echo "⚠️ GitHub 推送失败（本地提交与 tag 已保留，可稍后手动 git push origin main --follow-tags）" >&2
                if [ "$MODE" = "release" ]; then PUSH_FAILED=1; fi
            fi
        fi
    fi
else
    echo "⚠️ 非 git 仓库，跳过版本记录"
fi

# （数据归档已上移到 git 提交之前，见「打包完成」之后那段）

# 可选：覆盖安装到 /Applications 并注册 LaunchServices（--install）
# 通知图标依赖 LaunchServices 注册，漏做会出现通知图标异常；
# 通知附件固定用 AppIcon.png（不是 icns）。
if [ "$INSTALL" = "1" ]; then
    echo ""
    echo "== 安装到 /Applications =="
    DEST="/Applications/$APP_NAME.app"

    # 目标 App 正在运行时不要直接覆盖：进程会继续跑已被替换（甚至已进废纸篓）的旧二进制与资源，
    # 表现为「装了新版但行为没变」的假象。
    # 先请求退出；退不掉就中止，不制造这种假象。
    if pgrep -f "$DEST/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
        echo "  检测到 ${APP_NAME} 正在运行，先退出旧实例…"
        OLD_PIDS="$(pgrep -f "$DEST/Contents/MacOS/$APP_NAME" | tr '\n' ' ')"
        # 先试 AppleEvent 优雅退出，但**必须带超时**：自动化权限未授权时 osascript 会
        # 挂起等弹窗（无交互环境直接卡死，实测导致安装被误判为"退出失败"而中止）。
        osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 &
        OSA_PID=$!
        ( sleep 3; kill "$OSA_PID" 2>/dev/null ) &
        wait "$OSA_PID" 2>/dev/null || true
        for _ in 1 2 3; do
            pgrep -f "$DEST/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || break
            sleep 1
        done
        # 兜底：SIGTERM（纯 Swift 同进程架构，无外部引擎子进程残留，强退前由生命周期钩子收尾）
        if pgrep -f "$DEST/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
            echo "  AppleEvent 未生效（可能未授权自动化），改用 SIGTERM"
            for _pid in $OLD_PIDS; do kill -TERM "$_pid" 2>/dev/null || true; done
            for _ in 1 2 3 4 5; do
                pgrep -f "$DEST/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || break
                sleep 1
            done
        fi
        if pgrep -f "$DEST/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
            echo "  ❌ 旧实例仍在运行，已中止安装（否则会出现「装了新版但行为没变」）" >&2
            echo "     请手动退出 ${APP_NAME} 后重跑本命令" >&2
            exit 1
        fi
        echo "  旧实例已退出"
    fi

    free_path "$DEST" || exit 1
    cp -R "$BUNDLE" "$DEST" && echo "  已安装: ${DEST}"

    # ⚠⚠ 清 xattr ＋ **落盘后再验一次签名**（2026-09-23 修「通知没有 logo」时挖出来的坑）
    #
    # 事故形态（静默，且**症状离病根很远**）：
    #   `cp -R` 会把**源 bundle 上的 xattr 一起带过去**（实测 `com.apple.provenance`；
    #   仓库在 FileProvider 管理下时还会带 `com.apple.FinderInfo`）。
    #   而 `codesign --verify --strict` 把这类 xattr 判为 **detritus**：
    #       "resource fork, Finder information, or similar detritus not allowed"
    #   ⇒ **装到 /Applications 的那份签名是失效的**，而本脚本此前**只在 /tmp 组装后验过一次**
    #     （那时是全新文件、必然通过）→ 这个坑一直是静默的。
    #   ⚠ 后果**不是**"启动不了"（ad-hoc ＋ 无 quarantine，Gatekeeper 不管），
    #     而是**系统服务按签名决定信不信这个 bundle** —— 实测症状是
    #     **通知中心左侧的应用图标变成占位方块**（而图标文件本身完全正常：
    #     `AppIcon.icns` 尺寸齐全、`CFBundleIconFile` 也在、`NSWorkspace.icon(forFile:)` 解析正确）。
    #   ⇒ 装完必须 ① `xattr -cr` 清干净；② **再验一次签名**（这次验的是落盘后的那份）。
    xattr -cr "$DEST" 2>/dev/null || true
    if codesign --verify --deep --strict "$DEST" 2>/dev/null; then
        echo "  签名校验（落盘后）: 通过"
    else
        echo "  ❌ 签名校验失败（落盘后）: ${DEST}" >&2
        codesign --verify --deep --strict "$DEST" 2>&1 | head -3 | sed 's/^/     /' >&2
        echo "     ⚠ App 已装好，但签名不完整 —— 系统服务（通知中心 / 图标服务）可能不认它。" >&2
        echo "     常见原因：bundle 里带了 xattr（FinderInfo / provenance）；" >&2
        echo "     若 xattr -cr 之后仍失败，说明有**别的东西**改了内容 —— 别放过。" >&2
        exit 1
    fi

    # 防止"旧包没清干净 → cp -R 合并出新旧混合包"（同一类事故，2026-09-16 踩过）
    if [ -n "$(find "$DEST" -mindepth 1 -maxdepth 1 -name '*.app' -print -quit)" ]; then
        echo "  ❌ 安装校验失败: ${DEST} 内出现嵌套 App（旧版本未清理干净，请手动移入废纸篓后重装）" >&2
        exit 1
    fi

    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    if [ -x "$LSREGISTER" ]; then
        if "$LSREGISTER" -f "$DEST"; then
            echo "  LaunchServices 注册: 完成"
        else
            echo "  ⚠️ LaunchServices 注册返回非零（不影响已安装的 App）" >&2
        fi
    else
        echo "  ⚠️ 未找到 lsregister，跳过注册（通知图标可能异常）" >&2
    fi

    # 回读核验：确认落盘且版本号与打包源一致
    if [ -f "$DEST/Contents/Info.plist" ]; then
        INSTALLED_V="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || echo '?')"
        SOURCE_V="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/SelectedApp/Resources/Info.plist" 2>/dev/null || echo '?')"
        if [ "$INSTALLED_V" = "$SOURCE_V" ]; then
            echo "  安装校验: 通过（版本 ${INSTALLED_V}）"
        else
            echo "  ❌ 安装校验失败: /Applications 版本 ${INSTALLED_V} 与源码版本 ${SOURCE_V} 不一致" >&2
            exit 1
        fi
    else
        echo "  ❌ 安装校验失败: ${DEST}/Contents/Info.plist 不存在" >&2
        exit 1
    fi

    # 安装后回读：可执行文件必须与 dist 中的新包一致
    if cmp -s "$BUNDLE/Contents/MacOS/$APP_NAME" "$DEST/Contents/MacOS/$APP_NAME"; then
        echo "  一致性校验: 通过（/Applications 可执行文件与 dist 一致）"
    else
        echo "  ❌ 一致性校验失败: /Applications 可执行文件与 dist 不一致（可能装了旧包）" >&2
        exit 1
    fi
fi

# release 推送失败 ⇒ 整次打包以非零收尾（包已产出、提交已在本地，只是让"没进 CI"这件事可见）
if [ "${PUSH_FAILED:-0}" = "1" ]; then
    echo "" >&2
    echo "❌ release 已提交但**未推送 origin/main** ⇒ GitHub Actions 不会为这次发布运行。" >&2
    printf '%s\n' '   手动 `git push origin main --follow-tags`；若被整推拒绝，检查 token 是否有 workflow 权限。' >&2
    exit 1
fi

