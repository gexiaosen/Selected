#!/usr/bin/env python3
"""从登录钥匙串导出一个签名身份的 .p12（命令行，不需要钥匙串访问 GUI）。

macOS 26 把「钥匙串访问」挪进了 /System/Library/CoreServices/Applications，
界面还经常是半残的（窗口开在屏幕外、列表加载不出来）。而 `security export`
本身是能用的，只是它只能"整串导"——一次把所有身份都写进同一个 p12。
本脚本负责把它拆开：按 CN 找到目标身份，用公钥配对出对应的私钥，
只把这一对（连同中间证书链）重新打包成标准 p12。

用法:
    python3 Scripts/export-identity-p12.py "<CN 关键字>" <输出.p12> [输出密码]

例:
    python3 Scripts/export-identity-p12.py "Apple Development: " ~/Desktop/MiscKitSign.p12

⚠ 中间产物（含**所有**身份的私钥）写在 0700 临时目录里，用完立即删除；
  但要知道它确实短暂落过盘 —— 不接受这一点就还是走 GUI 导出单条。

退出码: 0 成功 / 1 失败。选中的身份写到 stdout，供上层脚本取用。
"""

from __future__ import annotations

import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile

PEM_BLOCK = re.compile(
    r"-----BEGIN ([A-Z0-9 ]+)-----.+?-----END \1-----", re.DOTALL
)


def run(args: list[str], *, stdin: str | None = None) -> str:
    # 不用 text=True：`openssl pkcs12` 会在 PEM 之间打印 "Bag Attributes"，
    # 其中 friendlyName 可能带非 UTF-8 字节（钥匙串里的条目名不受编码约束），
    # 严格解码会直接炸在最无关的地方。我们只解析 PEM 块与 CN，替换掉即可。
    result = subprocess.run(
        args, input=stdin.encode() if stdin else None, capture_output=True, timeout=60
    )
    out = result.stdout.decode("utf-8", "replace")
    err = result.stderr.decode("utf-8", "replace")
    if result.returncode != 0:
        raise RuntimeError(f"{' '.join(args)} 失败: {err.strip() or out.strip()}")
    return out


def read_pkcs12(path: str, password: str) -> str:
    """解出 p12 里的私钥与证书（PEM）。

    `security export` 用的是 RC2-40-CBC 这种老编码，OpenSSL 3+ 默认 provider
    已经把它移除，会报 "unknown cipher:RC2-40-CBC"。必须显式加载 legacy
    provider —— 这不是可选的兼容开关，缺了连读都读不开。
    """
    base = ["openssl", "pkcs12", "-in", path, "-nodes",
            "-passin", f"pass:{password}", "-nomacver"]
    try:
        return run(base + ["-legacy"])
    except RuntimeError as error:
        if "Unknown option" not in str(error) and "unknown option" not in str(error):
            raise
        # 老一点的 OpenSSL 没有 -legacy 选项，退回 provider 形式
        return run(base + ["-provider", "legacy", "-provider", "default"])


def login_keychain() -> str:
    default = os.path.expanduser("~/Library/Keychains/login.keychain-db")
    if os.path.exists(default):
        return default
    out = run(["security", "default-keychain", "-d", "user"]).strip().strip('"')
    if not out:
        raise RuntimeError("找不到登录钥匙串")
    return out


def pem_blocks(pem: str) -> list[tuple[str, str]]:
    return [(PEM_BLOCK.match(m.group(0)).group(1), m.group(0))
            for m in PEM_BLOCK.finditer(pem)]


def write(path: str, text: str) -> None:
    with open(path, "w", encoding="ascii") as handle:
        handle.write(text if text.endswith("\n") else text + "\n")


def public_key_of_cert(path: str) -> str:
    return normalize_pem(run(["openssl", "x509", "-in", path, "-noout", "-pubkey"]))


def public_key_of_key(path: str) -> str:
    return normalize_pem(run(["openssl", "pkey", "-in", path, "-pubout"]))


def normalize_pem(text: str) -> str:
    body = re.sub(r"-----[^-]+-----", "", text)
    return "".join(body.split())


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        print('用法: export-identity-p12.py "<CN 关键字>" <输出.p12> [密码]', file=sys.stderr)
        return 1

    needle = sys.argv[1]
    out_path = os.path.abspath(os.path.expanduser(sys.argv[2]))
    # 输出密码：调用方不给就随机生成一个，避免"顺手用空密码"
    out_pass = sys.argv[3] if len(sys.argv) == 4 else secrets.token_urlsafe(24)
    scratch_pass = secrets.token_urlsafe(24)

    work = tempfile.mkdtemp(prefix="misckit-identity-")
    os.chmod(work, 0o700)
    try:
        all_p12 = os.path.join(work, "all.p12")
        run([
            "security", "export",
            "-k", login_keychain(),
            "-t", "identities",
            "-f", "pkcs12",
            "-o", all_p12,
            "-P", scratch_pass,
        ])

        pem = read_pkcs12(all_p12, scratch_pass)
        blocks = pem_blocks(pem)
        certs = [(kind, body) for kind, body in blocks if kind == "CERTIFICATE"]
        keys = [(kind, body) for kind, body in blocks if kind in ("PRIVATE KEY", "RSA PRIVATE KEY", "EC PRIVATE KEY")]
        if not certs or not keys:
            raise RuntimeError("p12 里没有同时找到证书与私钥")

        leaf_index = None
        leaf_cn = ""
        for index, (_, body) in enumerate(certs):
            path = os.path.join(work, f"cert{index}.pem")
            write(path, body)
            subject = run(["openssl", "x509", "-in", path, "-noout",
                           "-subject", "-nameopt", "RFC2253"]).strip()
            if needle in subject:
                leaf_index = index
                # RFC2253 把 C 排在最前，不能取第一段；直接抓 CN=
                match = re.search(r"CN=([^,]+)", subject)
                leaf_cn = match.group(1).strip() if match else subject
                break
        if leaf_index is None:
            raise RuntimeError(f"钥匙串里没有 CN 含「{needle}」的身份")

        leaf_path = os.path.join(work, f"cert{leaf_index}.pem")
        leaf_pub = public_key_of_cert(leaf_path)
        key_path = None
        for index, (_, body) in enumerate(keys):
            path = os.path.join(work, f"key{index}.pem")
            write(path, body)
            if public_key_of_key(path) == leaf_pub:
                key_path = path
                break
        if key_path is None:
            raise RuntimeError("找到了证书，但配不上对应的私钥（只导出了证书）")

        # 其余证书（中间证书 / 根）一并带上，否则 CI 侧链是断的
        chain_path = None
        chain = [body for index, (_, body) in enumerate(certs) if index != leaf_index]
        if chain:
            chain_path = os.path.join(work, "chain.pem")
            write(chain_path, "\n".join(chain))

        # 输出格式必须用 Security.framework 认得的算法：
        # OpenSSL 3+ 默认 AES-256-CBC + SHA-256 MAC，`security import` 会报
        # "MAC verification failed during PKCS12 import"（本机实测）。
        args = ["openssl", "pkcs12", "-export",
                "-inkey", key_path, "-in", leaf_path,
                "-out", out_path,
                "-passout", f"pass:{out_pass}",
                "-macalg", "sha1",
                "-certpbe", "PBE-SHA1-3DES",
                "-keypbe", "PBE-SHA1-3DES"]
        if chain_path:
            args += ["-certfile", chain_path]
        run(args)

        # 回读校验：能被 openssl 打开、且含私钥
        # 回读校验：能被 openssl 打开、且含私钥（自己导的格式，不需要 legacy）
        run(["openssl", "pkcs12", "-in", out_path, "-noout",
             "-passin", f"pass:{out_pass}"])
        run(["openssl", "pkcs12", "-in", out_path, "-nocerts", "-noout",
             "-passin", f"pass:{out_pass}"])

        # 密码由调用方传入并自行保管：不打印，免得留在终端回滚里
        print(leaf_cn)
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # noqa: BLE001 - CLI 入口，统一转成一行错误
        print(f"✗ {error}", file=sys.stderr)
        sys.exit(1)
