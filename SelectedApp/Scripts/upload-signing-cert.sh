#!/bin/bash
# 把签名证书写进 GitHub Secrets，供 .github/workflows/release.yml 在 CI 里复用。
#
# 为什么需要它：ad-hoc 包的 designated requirement 就是 cdhash，而版本号写在
# Info.plist 里被 CodeDirectory 哈希覆盖 ⇒ 每发一版身份必变 ⇒ TCC 的文件夹授权
# 与钥匙串 ACL 记录全部作废，装一次新版就要重点一遍「桌面/文稿/下载」。
# 用固定证书签名后 DR 变成 `identifier + anchor apple generic + leaf CN`，
# 与 cdhash 无关，一次授权跨版本有效。
#
# 用法（两种）：
#   ./Scripts/upload-signing-cert.sh
#       直接从登录钥匙串导出 Apple Development 身份，不需要图形界面。
#       macOS 26 的「钥匙串访问」藏在 /System/Library/CoreServices/Applications，
#       界面还常是半残的（窗口开在屏幕外、列表加载不出来），这条路更省事。
#
#   ./Scripts/upload-signing-cert.sh ~/Desktop/SelectedSign.p12
#       用你手动导出的 p12（钥匙串访问 → 登录 → 我的证书 → 右键导出）。
#
# 安全说明：证书私钥会进入 GitHub Secrets（**不随仓库公开内容分发**；fork PR 默认
# 拿不到 secrets）。本仓已公开，仍安全；不用了随时删：gh secret delete SELECTED_SIGNING_CERT_P12
# base64 只在管道里过一手，不写普通文件、不进 shell 历史、不打印。
set -euo pipefail

# ⚠ 必须优先用 Homebrew 的 OpenSSL：系统自带的 /usr/bin/openssl 是 LibreSSL，
#   不认 `-legacy` / provider，读 `security export` 产出的 RC2 p12 会直接失败
#   （2026-11-24 实测：报 pkcs12 用法后 "导出失败"）。
if [ -x /opt/homebrew/bin/openssl ]; then
    PATH="/opt/homebrew/bin:$PATH"
    export PATH
fi

REPO_SLUG="${SELECTED_REPO:-gexiaosen/Selected}"
SIGNING_CN="${SELECTED_SIGNING_CN:-Apple Development: }"

die() { echo "✗ $*" >&2; exit 1; }

command -v gh >/dev/null || die "没装 gh（brew install gh）"
gh auth status >/dev/null 2>&1 || die "gh 未登录：gh auth login"

WORK="$(mktemp -d)"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

# 钥匙串访问导出的 p12 用 RC2-40-CBC，OpenSSL 3+ 默认 provider 已移除，
# 必须显式 -legacy 才读得开；本脚本自己导的（3DES）两种都能读。
read_p12() {
    local file="$1" pass="$2"
    shift 2
    openssl pkcs12 -in "$file" -passin "pass:${pass}" -legacy "$@" 2>/dev/null \
        || openssl pkcs12 -in "$file" -passin "pass:${pass}" "$@" 2>/dev/null
}

if [ $# -ge 1 ]; then
    P12="$1"
    [ -f "$P12" ] || die "找不到文件：$P12"
    printf 'p12 密码（导出时设的那个，输入不回显；没设过直接回车）：'
    read -rs P12_PASS
    echo
    read_p12 "$P12" "$P12_PASS" -noout >/dev/null \
        || die "打不开这个 p12：密码不对，或不是 PKCS#12 格式"
else
    echo "→ 从登录钥匙串导出「${SIGNING_CN}…」身份"
    P12="$WORK/signing.p12"
    P12_PASS="$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')"
    CN="$(python3 "$(dirname "$0")/export-identity-p12.py" "$SIGNING_CN" "$P12" "$P12_PASS")" \
        || die "导出失败（钥匙串里没有匹配这个 CN 的身份？）"
    echo "  选中：$CN"
fi

# 必须有私钥，否则 CI 只能拿到公钥、codesign 会失败
read_p12 "$P12" "$P12_PASS" -nocerts -nodes | grep -q "BEGIN" \
    || die "这个 p12 里没有私钥（只导出了证书）"

echo "→ 写入 secret: SELECTED_SIGNING_CERT_P12"
base64 -i "$P12" | tr -d '\n' | gh secret set SELECTED_SIGNING_CERT_P12 --repo "$REPO_SLUG"
echo "→ 写入 secret: SELECTED_SIGNING_CERT_PASSWORD"
printf '%s' "$P12_PASS" | gh secret set SELECTED_SIGNING_CERT_PASSWORD --repo "$REPO_SLUG"

echo
echo "✓ 已写入："
gh secret list --repo "$REPO_SLUG" | grep -E "SELECTED_SIGNING_CERT" || true
echo
echo "下一步：打 tag 发一版，CI 会用这个身份签名（工作流里专门有一步核对 DR，"
echo "        签成 ad-hoc 会直接失败，不会静默退回）。"
echo "  · 换身份那一次，文件夹权限与钥匙串授权会**再问一轮**，点「始终允许」；"
echo "  · 之后任何版本都不再问。"
echo "  · 证书一年到期：过期后新签的包身份又变了，重跑本脚本上传新证书即可。"
