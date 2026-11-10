#!/bin/bash
#
# Which way `Scripts/local-ci.sh --fallback` decides (#461): GitHub's result reported, or both
# jobs run on this Mac. Each case answers the script's `gh` calls from the files in
# Scripts/tests/local-ci/<case>, through the stand-in in local-ci/bin, with GitHub's own
# texts. LOCAL_CI_DECIDE_ONLY stops the script once it decides to run here, so nothing is
# built, fetched or recorded, and the start window and polling are cut to seconds.
# Then that every wait gives up (#483): on GitHub, on another run here, and on a job.
#
#   Scripts/tests/local-ci-test.sh     (`make test` runs it)
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../local-ci.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/local-ci-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
failures=0 count=0

# capped <output file> <command…>: runs it, its output to the file. A case that never decides
# would loop forever: stop it after 20 seconds.
capped() {
  local out="$1"; shift
  "$@" >"$out" 2>&1 &
  local pid=$!
  (for _ in {1..200}; do kill -0 "$pid" 2>/dev/null || exit 0; sleep 0.1; done
    kill "$pid" 2>/dev/null && echo "(stopped after 20 s: it never decided)" >>"$out") >/dev/null 2>&1 &
  local watchdog=$! rc
  { wait "$pid"; } 2>/dev/null; rc=$? # quiet: no "Terminated" line from the shell
  wait "$watchdog"
  return "$rc"
}
fail() { # <what>: a check that failed, then the output of the run it checked
  failures=$((failures + 1))
  echo "  ✗ $1"
  [[ -z "${2:-}" ]] || sed 's/^/      /' "$2"
}

# expect <case> <exit code> <what it prints> [VAR=value…]: run --fallback on the case's files.
expect() {
  local case="$1" want_rc="$2" want_text="$3"; shift 3
  local log="$tmp/$case.gh.log" out="$tmp/$case.out" rc
  count=$((count + 1))
  rm -f "$log" "$log.check-runs"; : >"$log"
  capped "$out" env PATH="$here/local-ci/bin:$PATH" FIXTURE="$here/local-ci/$case" GH_LOG="$log" \
    LOCAL_CI_DECIDE_ONLY=1 CI_POLL_SECONDS=0 "$@" "$script" --fallback 455
  rc=$?
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

# One job with no check run, the other passed (#483), either way round: wait out the start
# window, then run here. A job GitHub ran and failed still counts first.
expect one-passed-one-missing 0 "$here_line" CI_START_SECONDS=1
also one-passed-one-missing "no GitHub check for universal on 1234567 after 1s: running here"
p="$(polls one-passed-one-missing)"
((p > 1)) || fail "one-passed-one-missing: read the checks $p times: it didn't wait for the start window"
expect one-missing-one-passed 0 "$here_line" CI_START_SECONDS=1
also one-missing-one-passed "no GitHub check for build-and-test on 1234567 after 1s: running here"
expect one-failed-one-missing 1 "GitHub ran CI and it failed" CI_START_SECONDS=1

# Nothing waits forever (#483).
echo "local-ci limits:"
# GitHub's jobs still running at CI_WAIT_SECONDS: give up, saying where they were.
expect running-long 2 "hasn't finished after 1s (build-and-test: running, universal: running): giving up" \
  CI_WAIT_SECONDS=1
also running-long "Scripts/local-ci.sh 455"
# No check at all yet, and the wait ends before the start window: give up too.
expect one-passed-one-missing 2 "(build-and-test: pass, universal: none): giving up" CI_WAIT_SECONDS=1

# Another run here holds the lock past LOCAL_CI_LOCK_SECONDS: give up before recording anything.
lock="$tmp/home/Library/Caches/networkmonitor-dev/ci/lock"
mkdir -p "$(dirname "$lock")"
(exec 9>>"$lock"; lockf -s -k -t 0 9 && exec sleep 30) & # the sleep holds it, and goes with kill
holder=$!
for _ in {1..50}; do lockf -s -k -t 0 "$lock" true 2>/dev/null || break; sleep 0.1; done
count=$((count + 1)) log="$tmp/lock.gh.log"
: >"$log"
capped "$tmp/lock.out" env PATH="$here/local-ci/bin:$PATH" FIXTURE="$here/local-ci/pass" GH_LOG="$log" \
  HOME="$tmp/home" LOCAL_CI_GIT_FETCH=ok LOCAL_CI_LOCK_SECONDS=1 "$script" 455
rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
if ((rc != 75)) || ! grep -qF "another local run still holds" "$tmp/lock.out" || grep -q UNEXPECTED "$log"; then
  fail "lock: exited $rc, not 75, or didn't say why, or called gh/git: $(grep UNEXPECTED "$log" | head -1)" "$tmp/lock.out"
else echo "  ✓ lock (LOCAL_CI_LOCK_SECONDS=1)"; fi

# A job past LOCAL_CI_JOB_MINUTES: run_bounded stops it and all it started, and returns 124.
count=$((count + 2))
marker="local-ci-test-$$"
began=$SECONDS
capped "$tmp/bounded.out" bash -c '
  . "$1"; set +e; marker="$2"
  hang() { (exec -a "$marker" sleep 30) & sleep 30; } # and something it started, named by the marker
  (sleep 0.5; pgrep -qf "$marker" && echo "started: yes") &
  run_bounded 1 hang; echo "hang: $?"
  run_bounded 5 sh -c "exit 3"; echo "exit 3: $?"' _ "$script" "$marker"
took=$((SECONDS - began))
if ! grep -qx "hang: 124" "$tmp/bounded.out" || ! grep -qx "started: yes" "$tmp/bounded.out" ||
  ((took > 10)) || pgrep -f "$marker" >/dev/null; then
  pkill -f "$marker"
  fail "run_bounded: didn't stop a hung job with all it started within 10 s (took ${took}s)" "$tmp/bounded.out"
else echo "  ✓ run_bounded stops a hung job, and what it started"; fi
grep -qx "exit 3: 3" "$tmp/bounded.out" && echo "  ✓ run_bounded passes a job's own status on" ||
  fail "run_bounded: didn't pass on a job's status" "$tmp/bounded.out"
# Stopping the script stops the job too, though it runs in a process group of its own.
count=$((count + 1))
bash -c '. "$1"; marker="$2"; hang() { (exec -a "$marker" sleep 30) & sleep 30; }
  run_bounded 60 hang' _ "$script" "$marker-kill" >"$tmp/stopped.out" 2>&1 &
runner=$!
for _ in {1..30}; do pgrep -qf "$marker-kill" && break; sleep 0.1; done
kill -TERM "$runner"; { wait "$runner"; } 2>/dev/null
for _ in {1..30}; do pgrep -qf "$marker-kill" || break; sleep 0.1; done
if pgrep -qf "$marker-kill"; then
  pkill -f "$marker-kill"
  fail "run_bounded: the job outlived the script that was stopped" "$tmp/stopped.out"
else echo "  ✓ stopping the script stops its job"; fi

if ((failures)); then
  echo "local-ci --fallback: $failures of $count failed"
  exit 1
fi
echo "local-ci --fallback: all $count passed"
