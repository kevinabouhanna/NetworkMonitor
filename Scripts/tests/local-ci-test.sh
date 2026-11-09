#!/bin/bash
#
# Which way `Scripts/local-ci.sh --fallback` decides (#461): GitHub's result reported, or both
# jobs run on this Mac. Each case answers the script's `gh` calls from the files in
# Scripts/tests/local-ci/<case>, through the stand-in in local-ci/bin, with GitHub's own
# texts. LOCAL_CI_DECIDE_ONLY stops the script once it decides to run here, so nothing is
# built, fetched or recorded, and the start window and polling are cut to seconds.
#
#   Scripts/tests/local-ci-test.sh     (`make test` runs it)
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../local-ci.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/local-ci-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
failures=0 count=0

# expect <case> <exit code> <what it prints> [VAR=value…]: run --fallback on the case's files.
expect() {
  local case="$1" want_rc="$2" want_text="$3"; shift 3
  local log="$tmp/$case.gh.log" out="$tmp/$case.out" rc
  count=$((count + 1))
  rm -f "$log" "$log.check-runs"; : >"$log"
  env PATH="$here/local-ci/bin:$PATH" FIXTURE="$here/local-ci/$case" GH_LOG="$log" \
    LOCAL_CI_DECIDE_ONLY=1 CI_POLL_SECONDS=0 "$@" "$script" --fallback 455 >"$out" 2>&1 &
  local pid=$!
  # A case that never decides would loop forever: stop it after 20 seconds.
  (for _ in {1..200}; do kill -0 "$pid" 2>/dev/null || exit 0; sleep 0.1; done
    kill "$pid" 2>/dev/null && echo "(stopped after 20 s: it never decided)" >>"$out") >/dev/null 2>&1 &
  local watchdog=$!
  { wait "$pid"; } 2>/dev/null; rc=$? # quiet: no "Terminated" line from the shell
  wait "$watchdog"
  local problem=""
  ((rc == want_rc)) || problem="exited $rc, not $want_rc"
  grep -qF -- "$want_text" "$out" || problem="${problem:+$problem; }didn't print \"$want_text\""
  if grep -q UNEXPECTED "$log"; then problem="${problem:+$problem; }$(grep UNEXPECTED "$log" | head -1)"; fi
  if [[ -n "$problem" ]]; then
    failures=$((failures + 1))
    echo "  ✗ $case${*:+ ($*)}: $problem"
    sed 's/^/      /' "$out"
  else
    echo "  ✓ $case${*:+ ($*)}"
  fi
}
also() { # <case> <text>: the case's last run printed this too
  grep -qF -- "$2" "$tmp/$1.out" || { failures=$((failures + 1)); echo "  ✗ $1: didn't print \"$2\""; }
}
polls() { # <case>: how many times the case read GitHub's checks, per job
  echo $(($(cat "$tmp/$1.gh.log.check-runs" 2>/dev/null || echo 0) / 2))
}

here_line="would run build-and-test universal here"
echo "local-ci --fallback decisions:"

# GitHub could run it: report its result, run nothing here.
expect pass 0 "GitHub's CI passed for 1234567"
expect rerun-passed 0 "GitHub's CI passed"
expect fail 1 "GitHub ran CI and it failed"
also fail "build-and-test	fail" # and shows GitHub's checks

# GitHub couldn't: run both jobs here.
expect billing-payments 0 "$here_line"
also billing-payments "GitHub can't run CI for 1234567 (billing, or not started)"
expect billing-locked 0 "$here_line"
expect billing-one-job 0 "$here_line"
expect queued-past-window 0 "$here_line" # the default window, 15 minutes
expect queued-10-min 0 "$here_line" CI_START_MINUTES=5
expect no-checks 0 "$here_line" CI_START_SECONDS=1
also no-checks "no GitHub checks for 1234567 after 1s: running here"

# Not yet: keep watching until GitHub decides.
expect queued-then-pass 0 "GitHub's CI passed"
p="$(polls queued-then-pass)"
((p == 3)) || { failures=$((failures + 1)); echo "  ✗ queued-then-pass: read the checks $p times, not 3"; }
expect no-checks-then-pass 0 "GitHub's CI passed"

if ((failures)); then
  echo "local-ci --fallback: $failures of $count failed"
  exit 1
fi
echo "local-ci --fallback: all $count passed"
