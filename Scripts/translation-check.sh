#!/bin/bash
#
# Nothing drifts (#434): fails when a branch changes an English page for people
# using the app and not its translation in each language, or adds a page to docs/
# with none. The app's own text is held to its tables by `make test`.
#
#   README.md     → README.<code>.md
#   SECURITY.md   → docs/<code>/security.md
#   docs/<page>.md → docs/<code>/<page>.md, where that exists
#
# The languages are the app's: each Resources/Localization/<code>.lproj but English.
# Pages for working on the app (development.md, architecture.md, …) have no copy,
# so changing them asks for nothing. A new page in docs/ does: give it a copy, or
# say why not.
#
# When a change is deliberately English only (a typo, a link, a page for
# developers), a line in the pull request's description says so and why:
#
#   No translation needed: fixes a typo in a command
#
#   Scripts/translation-check.sh [base]   compares with base (origin/main), the
#                                         uncommitted changes included
#   PR=455 Scripts/translation-check.sh   reads that pull request's description;
#                                         without PR, the current branch's, if any
#   PR_BODY="…" Scripts/translation-check.sh   or this text
set -euo pipefail
cd "$(dirname "$0")/.."
base="${1:-origin/main}"
from="$(git merge-base "$base" HEAD)"

# What the branch changed, committed or not, with A for a page it added.
changes="$( (git diff --name-status --no-renames "$from"; git ls-files --others --exclude-standard | sed 's/^/A	/') | sort -u)"
changed() { awk -F'\t' -v f="$1" '$2 == f { found = 1 } END { exit !found }' <<<"$changes"; }

languages=()
for lproj in Resources/Localization/*.lproj; do
  code="$(basename "$lproj" .lproj)"
  [[ "$code" == en ]] || languages+=("$code")
done

problems=()
while IFS=$'\t' read -r status file; do
  case "$file" in
    README.md | SECURITY.md) ;;
    docs/*/*) continue ;;
    docs/*.md) ;;
    *) continue ;;
  esac
  for code in ${languages[@]+"${languages[@]}"}; do
    case "$file" in
      README.md) copy="README.$code.md" ;;
      SECURITY.md) copy="docs/$code/security.md" ;;
      *) copy="docs/$code/${file#docs/}" ;;
    esac
    if [[ -e "$copy" ]] || changed "$copy"; then
      changed "$copy" || problems+=("$file changed, but not $copy")
    elif [[ "$status" == A ]]; then
      problems+=("$file is new, with no $copy")
    fi
  done
done <<<"$changes"

if ((${#problems[@]} == 0)); then
  echo "translation-check: every changed English page's translations changed with it (${languages[*]-none})"
  exit 0
fi

# Said to be deliberate in the pull request?
if [[ -z "${PR_BODY+set}" ]]; then
  PR_BODY="$(gh pr view ${PR:+"$PR"} --json body --jq .body 2>/dev/null || true)"
fi
reason="$(tr -d '\r' <<<"$PR_BODY" | grep -iE '^[[:space:]]*no translation needed:[[:space:]]*[^[:space:]]' | head -1 || true)"
if [[ -n "$reason" ]]; then
  echo "translation-check: English only, as the pull request says (${reason#"${reason%%[![:space:]]*}"}):"
  printf '  %s\n' "${problems[@]}"
  exit 0
fi

echo "translation-check: an English page changed without its translation (#434):"
printf '  %s\n' "${problems[@]}"
echo "Change each translation in the same pull request, in the app's words (Resources/Localization/<code>.lproj/Glossary.json)."
echo "If it's deliberately English only, add a line to the pull request's description, then run the check again:"
echo "  No translation needed: <why>"
exit 1
