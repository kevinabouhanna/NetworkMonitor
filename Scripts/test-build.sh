#!/bin/bash
#
# A signed, notarized test build of a branch (#704): starts the Test build
# workflow on GitHub, waits for it, and downloads its disk image to
# ~/Library/Caches/networkmonitor-dev/test-builds/<commit>/NetworkMonitor.dmg,
# for checking what only a Developer ID build carries, in a VM (mac-vm).
# Never a release: no installed copy is offered it.
#
#   Scripts/test-build.sh <branch>     (pushed first: GitHub builds what it has)
#
# Prints the disk image's path last. Waits 90 minutes at most.

set -euo pipefail
cd "$(dirname "$0")/.."

ref="${1:?usage: Scripts/test-build.sh <branch>}"
repo=kevinabouhanna/NetworkMonitor

if command -v gh-actions >/dev/null 2>&1 && ! gh-actions can-run >/dev/null; then
  echo "error: GitHub Actions can't run now (gh-actions can-run)" >&2
  exit 4
fi

started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run test-build.yml -R "$repo" -f ref="$ref" >/dev/null
echo "==> Test build of $ref started on GitHub"

# The run just started: the newest of this workflow's, made since.
run=""
for _ in $(seq 1 30); do
  run=$(gh run list -R "$repo" --workflow test-build.yml --limit 5 --json databaseId,createdAt \
        -q "[.[] | select(.createdAt >= \"$started\")][0].databaseId // empty")
  [ -n "$run" ] && break
  sleep 5
done
[ -n "$run" ] || { echo "error: the run didn't show up on GitHub" >&2; exit 1; }
echo "==> https://github.com/$repo/actions/runs/$run"

# Bounded: the workflow's own limit is 90 minutes.
if ! timeout 5700 gh run watch "$run" -R "$repo" --exit-status >/dev/null; then
  echo "error: the test build failed or didn't finish: gh run view $run -R $repo --log-failed" >&2
  exit 1
fi

name=$(gh api "repos/$repo/actions/runs/$run/artifacts" -q '.artifacts[0].name')
commit="${name#NetworkMonitor-test-}"
out="$HOME/Library/Caches/networkmonitor-dev/test-builds/$commit"
mkdir -p "$out"
gh run download "$run" -R "$repo" -n "$name" -D "$out"
echo "$out/NetworkMonitor.dmg"
