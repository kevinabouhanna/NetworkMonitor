#!/bin/bash
#
# CI on this Mac, for when GitHub Actions can't run it (#456). It runs the two jobs in
# .github/workflows/ci.yml, `build-and-test` and `universal`, on a pull request's head and
# records each result on the commit under the same name, so the pull request reads the same
# either way.
#
# GitHub stays the first choice: NetworkMonitor is public, so its macOS runners cost nothing,
# and running CI here adds load to the Mac every session shares.
#
#   Scripts/local-ci.sh 455              run both jobs here now
#   Scripts/local-ci.sh --fallback 455   watch GitHub's checks; run here only if GitHub can't
#                                        (a billing or spending-limit error, no checks at all,
#                                        or a job not started after CI_START_MINUTES, 15)
#
# Scripts/tests/local-ci-test.sh (in `make test`) checks which way --fallback decides, against
# a stand-in `gh` and GitHub's answers saved as files (#461). It sets these to run in seconds:
#   CI_START_SECONDS   the start window in seconds, instead of CI_START_MINUTES
#   CI_POLL_SECONDS    how often GitHub's checks are read (30)
#   LOCAL_CI_DECIDE_ONLY=1   stop once decided: print that it would run here, and run nothing
#
# Builds reuse one worktree (~/Library/Caches/networkmonitor-dev/ci), one run at a time, so
# SwiftPM builds incrementally. Only the smoke test touches the Mac: it runs in the
# networkmonitor Mac lane and opens the installed copy again afterwards. Takes 5-15 minutes:
# run it in the background.
set -euo pipefail

REPO=kevinabouhanna/NetworkMonitor
JOBS=(build-and-test universal)
fallback=false
if [[ "${1:-}" == --fallback ]]; then fallback=true; shift; fi
target="${1:?usage: Scripts/local-ci.sh [--fallback] <pull request number | branch | commit>}"
root="$(cd "$(dirname "$0")/.." && pwd)"

start_window=$((${CI_START_SECONDS:-$((${CI_START_MINUTES:-15} * 60))}))
poll=$((${CI_POLL_SECONDS:-30}))
if ((start_window % 60)); then window_text="${start_window}s"; else window_text="$((start_window / 60)) min"; fi

if [[ "$target" =~ ^[0-9]+$ ]]; then
  # The commit itself is fetched only to run here, once --fallback has decided to.
  sha="$(gh pr view "$target" -R "$REPO" --json headRefOid --jq .headRefOid)"
else
  git -C "$root" fetch -q origin
  sha="$(git -C "$root" rev-parse --verify -q "origin/$target^{commit}" || git -C "$root" rev-parse --verify "$target^{commit}")"
fi

# --fallback: what GitHub says about a job: pass, fail, running, or cant (GitHub can't run it).
github_job() { # <name>
  local run status conclusion created id
  run="$(gh api "repos/$REPO/commits/$sha/check-runs?per_page=100" \
    --jq "[.check_runs[] | select(.name == \"$1\" and .app.slug == \"github-actions\")] | sort_by(.started_at) | last // empty | \"\(.id) \(.status) \(.conclusion) \(.started_at)\"")"
  [[ -n "$run" ]] || { echo none; return; }
  read -r id status conclusion created <<<"$run"
  case "$status/$conclusion" in
    completed/success) echo pass ;;
    completed/*)
      if gh api "repos/$REPO/check-runs/$id/annotations" --jq '.[].message' 2>/dev/null |
        grep -qiE 'billing|spending limit|payment|account is locked'; then echo cant; else echo fail; fi ;;
    *)
      if [[ "$status" == queued ]] &&
        (($(date +%s) - $(date -juf '%Y-%m-%dT%H:%M:%SZ' "$created" +%s 2>/dev/null || date +%s) > start_window)); then
        echo cant
      else echo running; fi ;;
  esac
}

if $fallback; then
  began=$SECONDS
  while :; do
    states=""
    for job in "${JOBS[@]}"; do states="$states $(github_job "$job")"; done
    case "$states" in
      *cant*) echo "local-ci: GitHub can't run CI for ${sha:0:7} (billing, or not started): running it here"; break ;;
      *fail*) echo "local-ci: GitHub ran CI and it failed:"; gh pr checks "$target" -R "$REPO" 2>/dev/null || true; exit 1 ;;
      " pass pass") echo "local-ci: GitHub's CI passed for ${sha:0:7}; nothing to run here"; exit 0 ;;
      *none*none*) if ((SECONDS - began >= start_window)); then
          echo "local-ci: no GitHub checks for ${sha:0:7} after $window_text: running here"; break; fi ;;
    esac
    sleep "$poll"
  done
fi

if [[ "${LOCAL_CI_DECIDE_ONLY:-}" == 1 ]]; then
  echo "local-ci: would run ${JOBS[*]} here for ${sha:0:7} (LOCAL_CI_DECIDE_ONLY)"
  exit 0
fi
if [[ "$target" =~ ^[0-9]+$ ]]; then git -C "$root" fetch -q origin "pull/$target/head"; fi

ci="$HOME/Library/Caches/networkmonitor-dev/ci"
src="$ci/src" site="$ci/site"
mkdir -p "$ci"
exec 4>>"$ci/lock"
if ! lockf -s -k -t 0 4; then
  echo "local-ci: waiting for another local run to finish…"
  lockf -s -k 4
fi

status() { # <job> <state> <description>
  gh api -X POST "repos/$REPO/statuses/$sha" -f state="$2" -f context="$1" -f description="$3" >/dev/null ||
    echo "(couldn't record $1 on GitHub)" >&2
}
for job in "${JOBS[@]}"; do status "$job" pending "Running on Kevin's Mac"; done

# The kept worktree, moved to this commit; .build stays for incremental builds.
if [[ -d "$src/.git" || -f "$src/.git" ]]; then
  git -C "$src" checkout -q --detach -f "$sha"
  git -C "$src" clean -q -fdx -e .build
else
  git -C "$root" worktree prune
  git -C "$root" worktree add -q --detach "$src" "$sha"
fi
# The website as CI.yml finds it: gh-pages, or the pull request's branch with -site (#426).
head=""
[[ "$target" =~ ^[0-9]+$ ]] && head="$(gh pr view "$target" -R "$REPO" --json headRefName --jq .headRefName)"
site_ref=gh-pages
if [[ -n "$head" ]] && git -C "$root" ls-remote --exit-code --heads origin "$head-site" >/dev/null; then site_ref="$head-site"; fi
git -C "$root" fetch -q origin main "$site_ref"
if [[ -e "$site/.git" ]]; then git -C "$site" checkout -q --detach -f "origin/$site_ref"
else git -C "$root" worktree add -q --detach "$site" "origin/$site_ref"; fi

# The smoke test stops every running copy, the installed one too: hold the app's lane, and open
# the installed copy again if it was running.
smoke() {
  . Scripts/mac-lane.sh
  MAC_LANE=networkmonitor MAC_LANE_TIMEOUT="${SMOKE_LANE_TIMEOUT:-900}" MAC_LANE_WHAT="local-ci smoke test ${sha:0:7}" mac_lane_enter
  local was=false
  pgrep -qf "/Applications/NetworkMonitor.app/Contents/MacOS" && was=true
  local ok=0
  ./Scripts/smoke-test.sh || ok=$?
  if $was; then sleep 1; open /Applications/NetworkMonitor.app; fi
  return $ok
}

build_and_test() {
  # The pull request's description can say a change is English only (#434).
  if [[ "$target" =~ ^[0-9]+$ ]]; then PR="$target" make translation-check BASE=origin/main
  else PR_BODY="" make translation-check BASE=origin/main; fi
  swift build
  CI=true make test # as on GitHub: skips the tests that need live traffic
  GITHUB_BASE_REF=main GITHUB_HEAD_REF="$head" make asset-check SITE="$site"
  make app
  codesign --verify --verbose=1 build/NetworkMonitor.app
  for f in Info.plist Resources/AppIcon.icns Resources/Geo/countries.bin Resources/Geo/owners.bin \
    Resources/Geo/world.bin Resources/Geo/README.md; do test -f "build/NetworkMonitor.app/Contents/$f"; done
  test -x build/NetworkMonitor.app/Contents/MacOS/NetworkMonitor
  (smoke)
}

universal() {
  make universal
  local archs; archs="$(lipo -archs build/NetworkMonitor.app/Contents/MacOS/NetworkMonitor)"
  echo "built: $archs"
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]]
}

failed=0
for job in "${JOBS[@]}"; do
  log="$ci/$job.log"
  started=$(date +%s)
  echo "local-ci: $job on ${sha:0:7} (log: $log)"
  # Not in an `if`: there bash ignores `set -e` inside the job's functions.
  set +e
  (set -euo pipefail; cd "$src"; "${job//-/_}") >"$log" 2>&1
  rc=$?
  set -e
  if ((rc == 0)); then
    status "$job" success "Passed on Kevin's Mac in $(($(date +%s) - started))s"
    echo "local-ci: $job passed"
  else
    status "$job" failure "Failed on Kevin's Mac"
    tail -n 30 "$log"
    echo "local-ci: $job FAILED (whole log: $log)"
    failed=1
  fi
done
exit $failed
