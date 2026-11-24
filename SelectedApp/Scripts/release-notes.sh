#!/bin/bash
# 从 CHANGELOG.md 提取指定版本的 Release 正文，供 release.yml 的
# `gh release create --notes-file` 使用。
#
# 用法: ./SelectedApp/Scripts/release-notes.sh <version>
# 例:   ./SelectedApp/Scripts/release-notes.sh 1.0.0
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "用法: $0 <version>" >&2; exit 2; }

python3 - "$VERSION" "$ROOT/CHANGELOG.md" <<'PY'
import re
import sys
from pathlib import Path

version = sys.argv[1]
text = Path(sys.argv[2]).read_text(encoding="utf-8")
match = re.search(
    r"^## \[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^## \[|\Z)",
    text,
    re.M | re.S,
)
if not match:
    sys.exit(f"CHANGELOG.md 缺少 ## [{version}] 段落")
body = match.group(1).strip()
if not body:
    sys.exit(f"## [{version}] 段落为空")
print(body)
PY
