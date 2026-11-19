#!/bin/bash
#
# A signed, notarized test build of a branch (#704): starts the Test build
# workflow on GitHub, waits for it, downloads its disk image to
# ~/Library/Caches/networkmonitor-dev/test-builds/<commit>/NetworkMonitor.dmg,
# and deletes it from GitHub (the repository is public). For checking what
# only a Developer ID build carries, in a VM (mac-vm). Never a release: no
# installed copy is offered it.
#
#   Scripts/test-build.sh <branch>     (pushed first: GitHub builds what it has)
#
# Prints the disk image's path last. Waits up to 30 minutes for a runner, then
# up to 95 for the build.

set -euo pipefail
cd "$(dirname "$0")/.."

ref="${1:?usage: Scripts/test-build.sh <branch>}"
repo=kevinabouhanna/NetworkMonitor

# CLAUDE.md: GitHub's runners only once they can run.
if ! command -v gh-actions >/dev/null 2>&1; then
  echo "error: gh-actions isn't on PATH (the shared-mac plugin): can't tell whether GitHub can run it" >&2
  exit 4
fi
gh-actions can-run >/dev/null || { echo "error: GitHub Actions can't run now (gh-actions can-run)" >&2; exit 4; }

# The run is found by an id of its own, never by time: another session may
# start one at the same moment.
id="$(hostname -s)-$$-$(date +%s)"
gh workflow run test-build.yml -R "$repo" -f ref="$ref" -f id="$id" >/dev/null
echo "==> Test build of $ref started on GitHub ($id)"

run=""
for _ in $(seq 1 30); do
  run=$(gh run list -R "$repo" --workflow test-build.yml --limit 20 --json databaseId,displayTitle \
        -q ".[] | select(.displayTitle | endswith(\"($id)\")) | .databaseId" | head -1)
  [ -n "$run" ] && break
  sleep 5
done
[ -n "$run" ] || { echo "error: the run didn't show up on GitHub" >&2; exit 1; }
url="https://github.com/$repo/actions/runs/$run"
echo "==> $url"

# Queued first, for a runner (30 minutes at most), then built (95 at most).
for _ in $(seq 1 180); do
  status=$(gh run view "$run" -R "$repo" --json status -q .status)
  [ "$status" != queued ] && [ "$status" != waiting ] && [ "$status" != pending ] && break
  sleep 10
done
if ! timeout 5700 gh run watch "$run" -R "$repo" --exit-status >/dev/null; then
  conclusion=$(gh run view "$run" -R "$repo" --json status,conclusion -q '.status + " " + .conclusion')
  echo "error: the test build didn't succeed ($conclusion): $url; gh run view $run -R $repo --log-failed" >&2
  exit 1
fi

artifact=$(gh api "repos/$repo/actions/runs/$run/artifacts" -q '.artifacts[0] | "\(.id) \(.name)"')
artifact_id="${artifact%% *}"
name="${artifact#* }"
commit="${name#NetworkMonitor-test-}"
out="$HOME/Library/Caches/networkmonitor-dev/test-builds/$commit"
mkdir -p "$out"
download="$(mktemp -d "${TMPDIR:-/tmp}/nm-test-build.XXXXXX")"
trap 'rm -rf "$download"' EXIT
gh run download "$run" -R "$repo" -n "$name" -D "$download"
mv -f "$download/NetworkMonitor.dmg" "$out/NetworkMonitor.dmg"
# Downloaded: off GitHub, where anyone signed in could fetch it.
gh api -X DELETE "repos/$repo/actions/artifacts/$artifact_id" >/dev/null || \
  echo "note: couldn't delete the artifact from GitHub; it expires within a day" >&2
echo "$out/NetworkMonitor.dmg"
