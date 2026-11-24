#!/usr/bin/env python3
"""把 CHANGELOG 里某个版本的 Markdown 段落转成 Sparkle 更新窗能直接渲染的 HTML。

为什么需要它：Sparkle 的 `<description>` 是按 HTML 渲染的，直接塞 Markdown 会把
`###`、`**`、反引号原样显示出来——1.0.1 第一次发布就踩了这个坑，几千字挤成一坨。

只支持 CHANGELOG 实际用到的子集：`### 小标题`、`- 列表`、`**粗体**`、`` `代码` ``
与段落。刻意不引第三方库：发版链路只依赖系统 python3。

用法: python3 Scripts/changelog-to-html.py <version>
"""
import html
import re
import sys
from pathlib import Path


def extract(version: str) -> str:
    root = Path(__file__).resolve().parents[2]
    text = (root / "CHANGELOG.md").read_text(encoding="utf-8")
    match = re.search(
        r"^## \[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^## \[|\Z)",
        text, re.M | re.S)
    if not match or not match.group(1).strip():
        sys.exit(f"CHANGELOG.md 缺少 ## [{version}] 段落或段落为空")
    return match.group(1).strip()


def inline(text: str) -> str:
    """行内标记：先转义，再按固定顺序替换，避免转义出来的实体被二次解析。"""
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)
    return text


def convert(markdown: str) -> str:
    # 段落/列表的续行是软换行（Markdown 里靠缩进对齐），这里合并成一行再排。
    lines = markdown.splitlines()
    blocks: list[tuple[str, list[str]]] = []
    for raw in lines:
        line = raw.rstrip()
        if not line.strip():
            continue
        if line.startswith("### "):
            blocks.append(("h", [line[4:].strip()]))
        elif re.match(r"^\s*[-*] ", line):
            if blocks and blocks[-1][0] == "ul":
                blocks[-1][1].append(re.sub(r"^\s*[-*] ", "", line))
            else:
                blocks.append(("ul", [re.sub(r"^\s*[-*] ", "", line)]))
        elif blocks and blocks[-1][0] == "ul":
            # 续行属于上一条列表项，不能当成新的一项。中文标点后不补空格，
            # 否则「……前 80 条"， 而不是……」会多出一个空档。
            tail = blocks[-1][1][-1]
            joiner = "" if tail and tail[-1] in "，。；：、）」" else " "
            blocks[-1][1][-1] += joiner + line.strip()
        elif blocks and blocks[-1][0] == "p":
            blocks[-1][1].append(line.strip())
        else:
            blocks.append(("p", [line.strip()]))

    body_style = 'style="margin:0 0 10px 0"'
    head_style = 'style="margin:16px 0 6px 0;font-size:13px;font-weight:500;color:#111"'
    list_style = 'style="margin:0 0 12px 0;padding-left:20px"'
    item_style = 'style="margin:0 0 5px 0"'

    out: list[str] = []
    for kind, chunk in blocks:
        if kind == "h":
            prefix = "" if out else ""
            out.append(f'<p {head_style}>{prefix}{inline(chunk[0])}</p>')
        elif kind == "p":
            out.append(f'<p {body_style}>{inline(" ".join(chunk))}</p>')
        else:
            items = "".join(f'<li {item_style}>{inline(item.strip())}</li>' for item in chunk)
            out.append(f'<ul {list_style}>{items}</ul>')
    return "".join(out)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("用法: changelog-to-html.py <version>")
    print(convert(extract(sys.argv[1])))
