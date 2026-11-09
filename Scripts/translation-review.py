#!/usr/bin/env python3
"""What a release says for the first time, or says differently, in each language
(#434): a Markdown table of the English and its translation, and the translated
pages that changed, to post for the language's native reviewer on the release's
issue or pull request. Nothing waits on the review; changes follow on the issue.

    python3 -I Scripts/translation-review.py v1.28.0            since that tag
    python3 -I Scripts/translation-review.py v1.28.0 v1.29.0    between two
    make translation-review FROM=v1.28.0

The reviewer is each language's Glossary.json `reviewer`.
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LINE = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', re.M)


def git(*args):
    return subprocess.run(["git", "-C", ROOT, *args], capture_output=True, text=True).stdout


def table(ref, path):
    return {k: v for k, v in LINE.findall(git("show", f"{ref}:{path}"))}


def cell(text):
    return text.replace("\\n", " ").replace("\\\"", "\"").replace("|", "\\|")


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: translation-review.py <from> [to]")
    old, new = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "HEAD")
    folder = os.path.join(ROOT, "Resources/Localization")
    for lproj in sorted(os.listdir(folder)):
        code = lproj[: -len(".lproj")]
        if not lproj.endswith(".lproj") or code == "en":
            continue
        path = f"Resources/Localization/{lproj}/Localizable.strings"
        before, after = table(old, path), table(new, path)
        rows = [(k, v) for k, v in after.items() if before.get(k) != v]
        pages = git("diff", "--name-only", old, new, "--", f"README.{code}.md", f"docs/{code}/").split()
        try:
            with open(os.path.join(folder, lproj, "Glossary.json"), encoding="utf-8") as f:
                glossary = json.load(f)
        except OSError:
            glossary = {}
        name = glossary.get("name", code)
        reviewer = glossary.get("reviewer")
        print(f"### {name} ({code}), {old} to {new}" + (f", for @{reviewer}" if reviewer else ""))
        print()
        if not rows and not pages:
            print("Nothing new or changed.\n")
            continue
        if rows:
            print(f"{len(rows)} new or changed in the app:\n")
            print(f"| English | {name} |")
            print("|---|---|")
            for english, translated in rows:
                print(f"| {cell(english)} | {cell(translated)} |")
            print()
        if pages:
            print("Pages changed: " + ", ".join(f"`{p}`" for p in pages))
            print()


if __name__ == "__main__":
    main()
