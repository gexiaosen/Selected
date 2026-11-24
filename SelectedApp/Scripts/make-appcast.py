#!/usr/bin/env python3
"""生成 Sparkle 的 appcast.xml。

为什么单独成脚本（而不是塞在 YAML 里）：appcast 的字段与 dmg 文件名/大小/签名强耦合，
放在脚本里可以用 `--help` 看清全部输入，也能在本地跑一次验证 XML 结构。

用法:
  make-appcast.py --version 1.0.0 --build 20261124 --repo gexiaosen/Selected \
      --dmg-name Selected-v1.0.0-arm64.dmg --dmg-size 123456 \
      --signature 'sparkle:edSignature="..." length="123456"' \
      --notes-html /tmp/appcast-notes.html --out /tmp/appcast.xml
"""
import argparse
import datetime
import html
import xml.dom.minidom
from pathlib import Path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--build", required=True)
    ap.add_argument("--repo", required=True, help="owner/repo")
    ap.add_argument("--min-system", default="26.0")
    ap.add_argument("--dmg-name", required=True)
    ap.add_argument("--dmg-size", required=True)
    ap.add_argument("--signature", required=True,
                    help="sign_update 原始输出：sparkle:edSignature=... length=...")
    ap.add_argument("--notes-html", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    notes = Path(args.notes_html).read_text(encoding="utf-8").replace("]]>", "]]&gt;")
    pub = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    enclosure_url = (
        f"https://github.com/{args.repo}/releases/download/"
        f"v{args.version}/{args.dmg_name}"
    )
    appcast = f"""<?xml version="1.0" encoding="utf-8" standalone="no"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
  <channel>
    <title>Selected</title>
    <link>https://github.com/{args.repo}/releases/latest/download/appcast.xml</link>
    <description>Most recent changes</description>
    <language>zh_CN</language>
    <item>
      <title>Selected {html.escape(args.version)}</title>
      <pubDate>{pub}</pubDate>
      <sparkle:version>{html.escape(args.build)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(args.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(args.min_system)}</sparkle:minimumSystemVersion>
      <enclosure
        url="{html.escape(enclosure_url)}"
        {args.signature}
        type="application/x-apple-diskimage"
      />
      <description><![CDATA[{notes}]]></description>
    </item>
  </channel>
</rss>
"""
    out = Path(args.out)
    out.write_text(appcast, encoding="utf-8")
    # 立刻做一次结构校验：CI 里发出去的 feed 坏了，客户端只会静默不更新
    xml.dom.minidom.parse(str(out))
    print(out)


if __name__ == "__main__":
    main()
