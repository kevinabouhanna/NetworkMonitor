#!/usr/bin/env python3
#
# Builds the GitHub wiki from docs/ and SECURITY.md (#177). The repository is
# the source; the wiki is a copy, rebuilt by .github/workflows/wiki.yml on every
# push to main that touches the docs, so it never needs editing by hand.
#
# Only files git tracks are read. docs/ also holds private notes that git
# ignores, and the wiki is public.
#
# Each page keeps its text. Links are rewritten for the wiki: page to page, to
# images at the commit being mirrored, to other files in the repository, and
# #N to the issue. The sidebar follows docs/README.md's tables, and a page
# whose doc is gone is removed.
#
# Usage:
#   python3 Scripts/wiki.py <wiki checkout> [commit]    commit defaults to HEAD

import pathlib
import re
import subprocess
import sys

REPO = "https://github.com/kevinabouhanna/NetworkMonitor"
RAW = "https://raw.githubusercontent.com/kevinabouhanna/NetworkMonitor"
ROOT = pathlib.Path(__file__).resolve().parent.parent

# Pages named other than after their file.
NAMES = {
    "SECURITY.md": "Security-Policy",
    "docs/development.md": "Building-Testing-and-Releasing",
}

LINK = re.compile(r"(!?)\[([^\]]*)\]\(([^)\s]+)\)")
ATTRIBUTE = re.compile(r'(src|href)="([^"]+)"')
ISSUE = re.compile(r"(?<![\w/&\[])#(\d{1,4})\b(?!\])")


def tracked_docs() -> list[str]:
    files = subprocess.run(["git", "ls-files", "docs/*.md", "SECURITY.md"], cwd=ROOT,
                           check=True, capture_output=True, text=True).stdout.split()
    return [f for f in files if f != "docs/README.md" and "/" not in f.removeprefix("docs/")]


def page_name(file: str) -> str:
    if file in NAMES:
        return NAMES[file]
    words = pathlib.PurePosixPath(file).stem.split("-")
    return "-".join(w if w == "and" else w.capitalize() for w in words)


def resolve(target: str, source: str, pages: dict[str, str], commit: str, image: bool) -> str:
    """Where a link in `source` points on the wiki."""
    if re.match(r"^[a-z]+:", target) or target.startswith("#"):
        return target
    path, _, anchor = target.partition("#")
    parts: list[str] = []
    for part in (pathlib.PurePosixPath(source).parent / path).parts:
        if part == "..":
            parts.pop()
        elif part != ".":
            parts.append(part)
    file = "/".join(parts)
    suffix = f"#{anchor}" if anchor else ""
    if file in pages:
        return pages[file] + suffix
    if file == "docs/README.md":
        return "Home" + suffix
    if file == "README.md":
        return f"{REPO}{suffix or '#readme'}"
    if image or re.search(r"\.(png|gif|jpe?g|svg)$", file):
        return f"{RAW}/{commit}/{file}"
    kind = "blob" if "." in file.rsplit("/", 1)[-1] else "tree"
    return f"{REPO}/{kind}/main/{file}{suffix}"


def link_issues(text: str) -> str:
    """#N to a link, outside inline code and outside links already there."""
    def issue(m: re.Match) -> str:
        return f"[#{m.group(1)}]({REPO}/issues/{m.group(1)})"

    def outside_links(piece: str) -> str:
        out, last = [], 0
        for m in LINK.finditer(piece):
            out += [ISSUE.sub(issue, piece[last:m.start()]), m.group(0)]
            last = m.end()
        return "".join(out) + ISSUE.sub(issue, piece[last:])

    pieces = text.split("`")
    pieces[::2] = [outside_links(p) for p in pieces[::2]]
    return "`".join(pieces)


def convert(text: str, source: str, pages: dict[str, str], commit: str) -> str:
    lines, fenced = [], False
    for line in text.split("\n"):
        if line.lstrip().startswith("```"):
            fenced = not fenced
        elif not fenced:
            line = LINK.sub(lambda m: f"{m.group(1)}[{m.group(2)}]"
                            f"({resolve(m.group(3), source, pages, commit, bool(m.group(1)))})", line)
            line = ATTRIBUTE.sub(lambda m: f'{m.group(1)}="'
                                 f'{resolve(m.group(2), source, pages, commit, m.group(1) == "src")}"', line)
            line = link_issues(line)
        lines.append(line)
    return "\n".join(lines)


def sidebar(index: str, pages: dict[str, str]) -> str:
    """The pages in docs/README.md's order, under its headings."""
    lines, listed = ["**[Home](Home)**"], set()
    for line in index.split("\n"):
        if line.startswith("## "):
            lines += ["", f"**{line[3:]}**", ""]
        elif line.startswith("| ["):
            m = LINK.search(line)
            file = str(pathlib.PurePosixPath("docs") / m.group(3)).replace("docs/../", "")
            if file in pages:
                lines.append(f"- [{m.group(2)}]({pages[file]})")
                listed.add(file)
    unlisted = [f for f in pages if f not in listed]
    if unlisted:
        lines += ["", "**More**", ""] + [f"- [{pages[f].replace('-', ' ')}]({pages[f]})" for f in unlisted]
    return "\n".join(lines) + "\n"


def main() -> None:
    if len(sys.argv) not in (2, 3):
        sys.exit(f"usage: {sys.argv[0]} <wiki checkout> [commit]")
    wiki = pathlib.Path(sys.argv[1])
    commit = sys.argv[2] if len(sys.argv) == 3 else subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()

    pages = {file: page_name(file) for file in tracked_docs()}
    written = {"Home.md", "_Sidebar.md", "_Footer.md"}
    for file, page in pages.items():
        (wiki / f"{page}.md").write_text(convert((ROOT / file).read_text(), file, pages, commit))
        written.add(f"{page}.md")

    index = (ROOT / "docs/README.md").read_text()
    body = index.split("\n", 1)[1].lstrip("\n") if index.startswith("# ") else index
    (wiki / "Home.md").write_text(
        "**Live network speed in your Mac's menu bar, and which apps used your data.**\n\n"
        f"[Download]({REPO}/releases/latest/download/NetworkMonitor.dmg) · "
        f"[Website](https://kevinabouhanna.github.io/NetworkMonitor/) · [Source]({REPO})\n\n"
        + convert(body, "docs/README.md", pages, commit))
    (wiki / "_Sidebar.md").write_text(sidebar(index, pages))
    (wiki / "_Footer.md").write_text(
        f"Copied from [`docs/`]({REPO}/tree/main/docs) at [`{commit[:7]}`]({REPO}/commit/{commit}). "
        "The repository is the source: change the docs there, in a pull request, and the wiki follows.\n")

    for stale in wiki.glob("*.md"):
        if stale.name not in written:
            stale.unlink()


if __name__ == "__main__":
    main()
