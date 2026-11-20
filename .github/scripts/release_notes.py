#!/usr/bin/env python3
"""Generate grouped release notes from Conventional Commits.

GitHub's built-in `generate_release_notes` only lists **merged pull requests**.
This repo commits straight to `main`, so that produces an empty body with a
lonely "Full Changelog" link. This script builds the notes from git history
instead, grouped by commit type.

Usage:
    python3 .github/scripts/release_notes.py <tag> [-o OUT.md] [--repo OWNER/REPO]
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from collections import OrderedDict

# commit type -> (emoji + heading, sort order)
SECTIONS = OrderedDict(
    [
        ("feat", "✨ 新功能 Features"),
        ("perf", "⚡ 性能 Performance"),
        ("fix", "🐛 修复 Fixes"),
        ("refactor", "♻️ 重构 Refactors"),
        ("docs", "📝 文档 Docs"),
        ("build", "🔧 构建与 CI Build & CI"),
        ("test", "🧪 测试 Tests"),
        ("style", "💅 代码风格 Style"),
        ("chore", "🧹 其他 Chores"),
        ("other", "📦 其他变更 Other"),
    ]
)

SKIP_SUBJECTS = re.compile(
    r"^(chore(\(release\))?|release|v?\d+\.\d+\.\d+)\b", re.IGNORECASE
)

CONVENTIONAL = re.compile(
    r"^(?P<type>[a-zA-Z]+)(?:\((?P<scope>[^)]*)\))?(?P<breaking>!)?:\s*(?P<desc>.+)$"
)

BREAKING_FOOTER = re.compile(r"^BREAKING[ -]CHANGE:", re.MULTILINE)

# Commit subjects sometimes smuggle the version in, e.g.
# "perf: shrink bundle by 97% (v0.3.2)". Strip it: the release title already
# carries the version and it just reads as noise in the changelog.
TRAILING_VERSION = re.compile(r"\s*[(\[]?(?:v|release[- ])?\d+\.\d+\.\d+[)\]]?\s*$", re.I)

# Per-platform install hints rendered under the changelog.
# Raw string: keeps the shell line-continuation backslashes intact.
INSTALL_HINTS = r"""### 📥 安装 / 升级 Install & Upgrade

```sh
# macOS (Apple Silicon)
mkdir -p ~/.gemini/antigravity-cli && \
  curl -fsSL https://github.com/{repo}/releases/latest/download/agy-statusline-macos-arm64.tar.gz \
  | tar -xz -C ~/.gemini/antigravity-cli && chmod +x ~/.gemini/antigravity-cli/agy-statusline

# Linux (x64)
mkdir -p ~/.gemini/antigravity-cli && \
  curl -fsSL https://github.com/{repo}/releases/latest/download/agy-statusline-linux-x64.tar.gz \
  | tar -xz -C ~/.gemini/antigravity-cli && chmod +x ~/.gemini/antigravity-cli/agy-statusline

# Desktop 右侧面板 plugin
curl -fsSL https://raw.githubusercontent.com/{repo}/main/desktop-panel/install.sh | bash
```

> **macOS 提示**：二进制内置 ad-hoc 签名（非 Developer ID 签名、未经 Apple 公证）。
> 若从浏览器下载后被 Gatekeeper 拦截，改用上面的 `curl` 命令，或执行
> `xattr -dr com.apple.quarantine /path/to/agy-statusline`。
"""


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, check=True
    ).stdout


def previous_tag(tag: str) -> str | None:
    """Latest tag (by version order) that is not `tag` and is reachable from it."""
    try:
        tags = [t.strip() for t in git("tag", "--list", "v*").splitlines() if t.strip()]
    except subprocess.CalledProcessError:
        return None

    def key(name: str) -> tuple:
        return tuple(int(p) if p.isdigit() else 0 for p in re.split(r"[.v-]", name) if p)

    candidates = [t for t in tags if t != tag]
    older = [t for t in candidates if key(t) < key(tag)]
    # No older tag -> this is the first release: show full history instead of
    # comparing against a newer tag (which would yield an empty, wrong range).
    if not older:
        return None
    return max(older, key=key)


def read_commits(rev_range: str) -> list[dict]:
    raw = git(
        "log",
        rev_range,
        "--no-merges",
        "--pretty=format:%h%x1f%s%x1f%b%x1e",
    )
    commits = []
    for record in raw.split("\x1e"):
        record = record.strip("\n")
        if not record:
            continue
        parts = record.split("\x1f")
        if len(parts) < 2:
            continue
        sha, subject = parts[0], parts[1]
        body = parts[2] if len(parts) > 2 else ""
        commits.append({"sha": sha, "subject": subject, "body": body})
    return commits


def classify(commit: dict) -> tuple[str, str, str | None, bool]:
    """Return (type, description, scope, breaking)."""
    subject = commit["subject"].strip()
    match = CONVENTIONAL.match(subject)
    if not match:
        return "other", subject, None, bool(BREAKING_FOOTER.search(commit["body"]))

    ctype = match.group("type").lower()
    desc = match.group("desc").strip()
    scope = (match.group("scope") or "").strip() or None
    breaking = bool(match.group("breaking")) or bool(
        BREAKING_FOOTER.search(commit["body"])
    )
    return ctype, desc, scope, breaking


def build(tag: str, repo: str) -> str:
    prev = previous_tag(tag)
    rev_range = f"{prev}..{tag}" if prev else tag
    commits = read_commits(rev_range)

    buckets: dict[str, list[str]] = {k: [] for k in SECTIONS}
    breaking_lines: list[str] = []

    for commit in commits:
        subject = commit["subject"].strip()
        if SKIP_SUBJECTS.match(subject):
            continue
        ctype, desc, scope, breaking = classify(commit)
        desc = TRAILING_VERSION.sub("", desc).strip() or desc
        section = ctype if ctype in SECTIONS else "other"
        if ctype == "chore" and scope == "release":
            continue

        line = f"- {desc}"
        if scope:
            line += f" (`{scope}`)"
        line += f" — {commit['sha']}"
        buckets[section].append(line)

        if breaking:
            breaking_lines.append(f"- {desc} — {commit['sha']}")

    out: list[str] = []
    out.append(
        f"**{tag}** · {len(commits)} commits"
        + (f" · changes since `{prev}`" if prev else " · initial release")
    )
    out.append("")

    if breaking_lines:
        out.append("### 💥 破坏性变更 Breaking Changes")
        out.extend(breaking_lines)
        out.append("")

    empty = True
    for section, heading in SECTIONS.items():
        lines = buckets[section]
        if not lines:
            continue
        empty = False
        out.append(f"### {heading}")
        out.extend(lines)
        out.append("")

    if empty:
        out.append("_本次发布仅包含内部改动，详见下方完整变更记录。_")
        out.append("")

    out.append(INSTALL_HINTS.format(repo=repo))

    if prev:
        out.append(
            f"**完整变更 Full Changelog**: "
            f"https://github.com/{repo}/compare/{prev}...{tag}"
        )
    out.append("")
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("tag")
    parser.add_argument("-o", "--output", help="write to file instead of stdout")
    parser.add_argument("--repo", default="2fa0/agy-statusline")
    args = parser.parse_args()

    body = build(args.tag, args.repo)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as fh:
            fh.write(body)
        print(f"wrote {len(body)} bytes to {args.output}", file=sys.stderr)
    else:
        sys.stdout.write(body)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
