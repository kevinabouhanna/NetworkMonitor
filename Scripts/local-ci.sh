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
#                                        (a billing or spending-limit error, a job with no check
#                                        at all, or a job not started, after CI_START_MINUTES, 15)
#
# Nothing waits forever (#483). Each wait gives up with a message saying what it waited for:
#   CI_WAIT_MINUTES        --fallback: GitHub's result (the start window + 60). Exits 2.
#   LOCAL_CI_LOCK_MINUTES  another run here to finish (120). Exits 75.
#   LOCAL_CI_JOB_MINUTES   each job here (60): stopped, with everything it started, and failed.
#   SMOKE_LANE_TIMEOUT     the networkmonitor Mac lane for the smoke test, in seconds (900).
#
# Scripts/tests/local-ci-test.sh (in `make test`) checks which way --fallback decides, against
# a stand-in `gh` and GitHub's answers saved as files (#461), and each of those limits. It sets
# these to run in seconds:
#   CI_START_SECONDS, CI_WAIT_SECONDS, LOCAL_CI_LOCK_SECONDS   instead of the minutes above
#   CI_POLL_SECONDS    how often GitHub's checks are read (30)
#   LOCAL_CI_DECIDE_ONLY=1   stop once decided: print that it would run here, and run nothing
# Sourced, the script only defines run_bounded, which the tests check on their own.
#
# Builds reuse one worktree (~/Library/Caches/networkmonitor-dev/ci), one run at a time, so
# SwiftPM builds incrementally. Only the smoke test touches the Mac: it runs in the
# networkmonitor Mac lane and opens the installed copy again afterwards. Takes 5-15 minutes:
# run it in the background.
set -euo pipefail

# run_bounded <seconds> <command…>: runs the command (a function too) in a process group of its
# own and returns its status; after <seconds>, stops the whole group (TERM, then KILL 5 s later)
# and returns 124, as timeout(1) does. Stopping this script (Ctrl-C, kill) stops the group too.
run_bounded() {
  local limit="$1" pid rc=0 _; shift
  set -m # job control: the command gets its own process group, so all it started can be stopped
  "$@" &
  pid=$!
  set +m
  trap "kill -TERM -- -$pid 2>/dev/null; exit 130" INT
  trap "kill -TERM -- -$pid 2>/dev/null; exit 143" TERM HUP
  local deadline=$((SECONDS + limit))
  while kill -0 "$pid" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
      kill -TERM -- "-$pid" 2>/dev/null || true
      for _ in {1..10}; do kill -0 -- "-$pid" 2>/dev/null || break; sleep 0.5; done
      kill -KILL -- "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      trap - INT TERM HUP
      echo "(stopped after ${limit}s)"
      return 124
    fi
    sleep 1
  done
  wait "$pid" || rc=$?
  trap - INT TERM HUP
  return "$rc"
}
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

REPO=kevinabouhanna/NetworkMonitor
JOBS=(build-and-test universal)
fallback=false
if [[ "${1:-}" == --fallback ]]; then fallback=true; shift; fi
target="${1:?usage: Scripts/local-ci.sh [--fallback] <pull request number | branch | commit>}"
root="$(cd "$(dirname "$0")/.." && pwd)"

start_window=$((${CI_START_SECONDS:-$((${CI_START_MINUTES:-15} * 60))}))
poll=$((${CI_POLL_SECONDS:-30}))
wait_limit=$((${CI_WAIT_SECONDS:-$((${CI_WAIT_MINUTES:-$((start_window / 60 + 60))} * 60))}))
lock_limit=$((${LOCAL_CI_LOCK_SECONDS:-$((${LOCAL_CI_LOCK_MINUTES:-120} * 60))}))
job_limit=$((${LOCAL_CI_JOB_MINUTES:-60} * 60))
duration() { if (($1 % 60)); then echo "${1}s"; else echo "$(($1 / 60)) min"; fi; }
window_text="$(duration "$start_window")"

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
    # After the start window, a job with no check run at all is one GitHub can't run (#483),
    # whatever the other job did.
    late=false
    ((SECONDS - began >= start_window)) && late=true
    states="" missing="" summary=""
    for job in "${JOBS[@]}"; do
      state="$(github_job "$job")"
      if [[ "$state" == none ]] && $late; then state=missing missing="$missing $job"; fi
      states="$states $state" summary="${summary:+$summary, }$job: $state"
    done
    case "$states" in
      *cant*) echo "local-ci: GitHub can't run CI for ${sha:0:7} (billing, or not started): running it here"; break ;;
      *fail*) echo "local-ci: GitHub ran CI and it failed:"; gh pr checks "$target" -R "$REPO" 2>/dev/null || true; exit 1 ;;
      " pass pass") echo "local-ci: GitHub's CI passed for ${sha:0:7}; nothing to run here"; exit 0 ;;
      *missing*missing*) echo "local-ci: no GitHub checks for ${sha:0:7} after $window_text: running here"; break ;;
      *missing*) echo "local-ci: no GitHub check for${missing} on ${sha:0:7} after $window_text: running here"; break ;;
    esac
    if ((SECONDS - began >= wait_limit)); then
      echo "local-ci: GitHub's CI for ${sha:0:7} hasn't finished after $(duration "$wait_limit") ($summary): giving up."
      echo "  Look at it with: gh pr checks $target -R $REPO. To run it here instead: Scripts/local-ci.sh $target"
      exit 2
    fi
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
  echo "local-ci: waiting up to $(duration "$lock_limit") for another local run to finish…"
  if ! lockf -s -k -t "$lock_limit" 4; then
    echo "local-ci: another local run still holds $ci/lock after $(duration "$lock_limit"): giving up."
    echo "  Which one: pgrep -fl local-ci.sh. Then run this again."
    exit 75
  fi
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
  if $was; then sleep 1; open -g /Applications/NetworkMonitor.app; fi
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

in_src() { set -euo pipefail; cd "$src"; "$@"; } # run_bounded runs it in a process of its own

failed=0
for job in "${JOBS[@]}"; do
  log="$ci/$job.log"
  started=$(date +%s)
  echo "local-ci: $job on ${sha:0:7} (log: $log)"
  # Not in an `if`: there bash ignores `set -e` inside the job's functions.
  set +e
  run_bounded "$job_limit" in_src "${job//-/_}" >"$log" 2>&1
  rc=$?
  set -e
  if ((rc == 0)); then
    status "$job" success "Passed on Kevin's Mac in $(($(date +%s) - started))s"
    echo "local-ci: $job passed"
  elif ((rc == 124)); then
    status "$job" failure "Stopped on Kevin's Mac after $(duration "$job_limit")"
    tail -n 30 "$log"
    echo "local-ci: $job didn't finish in $(duration "$job_limit") (LOCAL_CI_JOB_MINUTES), so it was stopped: FAILED (whole log: $log)"
    failed=1
  else
    status "$job" failure "Failed on Kevin's Mac"
    tail -n 30 "$log"
    echo "local-ci: $job FAILED (whole log: $log)"
    failed=1
  fi
done
exit $failed
