#!/bin/bash
#
# local-ci: CI for a pull request on this Mac, with each result recorded on the commit as a GitHub
# status under the project's own check names, so the pull request shows green or red and the merge
# rule doesn't change. One copy for every project: the shared-mac plugin puts it on PATH
# (~/.local/bin/local-ci), and each project gives its jobs in .claude/ci.conf.sh, or has a
# `make ci` (claude-parallel-sessions#12).
#
#   local-ci <pr | branch | commit>              the project of the current folder
#   local-ci -C <dir> <pr | branch | commit>     the project <dir> is in
#
# Local first (Kevin, 10 Nov 2026): pull requests and pushes run here only, never on GitHub
# Actions, which is kept for releases (gh-actions decides whether GitHub can take one).
#
# One run per project at a time (a kernel lock: it goes when its holder dies), checked out once
# the lock is held, in a fresh worktree, or a kept one (CI_WORKTREE=kept) for build tools that need
# the same path. Keep build folders under ~/Library/Caches/<project>-dev ($CI_CACHE) so builds
# are incremental. Each job's log is kept in $CI_DIR/logs.
#
# No wait is unbounded: the lock (CI_LOCK_TIMEOUT, 7200 s, or LOCAL_CI_LOCK_MINUTES) gives up with
# 75, and a job or the preparation past CI_JOB_TIMEOUT (3600 s, or LOCAL_CI_JOB_MINUTES) is stopped
# and recorded as failed. Run it in the
# background (run_in_background) when it takes minutes.
#
# .claude/ci.conf.sh (optional) is sourced from the checkout local-ci is run in:
#   CI_NAME              the project (default: the repo folder's name, in lower case)
#   CI_REPO              owner/repo on GitHub (default: from origin's URL)
#   CI_JOBS=(…)          the check names, one per job (default: local-ci)
#   ci_job_<name>        runs that job, in the checkout (- and other signs become _ in <name>);
#                        a job without one runs $CI_COMMAND (default: make ci)
#   ci_prepare           runs once in the checkout before the jobs (optional)
#   CI_WORKTREE          fresh (default) or kept; CI_KEEP=(…) paths a kept one keeps (.build)
# A pull request runs merged with the newest base branch (CI_MERGE_BASE=no: its head alone); one
# that doesn't merge cleanly fails at once. The jobs see CI_SRC (the checkout), CI_SHA, CI_PR (the
# pull request's number, if any), CI_HEAD (its branch), CI_BASE (the branch it merges into),
# CI_ROOT (the repo the run started from), CI_DIR, CI_CACHE, CI_NAME and CI_REPO.
#
# CI_NO_STATUS=1 records nothing on GitHub. A repo's copy of this file hands over to the shared
# one on PATH; LOCAL_CI_NO_SHARED=1 keeps the copy that was called.
set -euo pipefail

# Which project: -C, else the repo this file is in when it's a repo's own copy (one with
# .claude/ci.conf.sh, so `scripts/local-ci.sh …` works from any folder), else the current folder's.
dir="$PWD"
self_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$self_root" && -f "$self_root/.claude/ci.conf.sh" ]]; then dir="$self_root"; fi
given_dir=false
for a in "$@"; do [[ "$a" == -C ]] && given_dir=true; done

if [[ -z "${LOCAL_CI_NO_SHARED:-}" ]] && shared="$(command -v local-ci 2>/dev/null)" && [[ -n "$shared" ]] &&
  [[ ! "$shared" -ef "${BASH_SOURCE[0]}" ]]; then
  if $given_dir; then exec "$shared" "$@"; else exec "$shared" -C "$dir" "$@"; fi
fi

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 2; }
target=""
while (($#)); do
  case "$1" in
    -C) dir="${2:?local-ci: -C needs a folder}"; shift 2 ;;
    --here | --fallback) shift ;; # older habits: every run is here now
    -h | --help) usage ;;
    -*) echo "local-ci: unknown option '$1'" >&2; exit 2 ;;
    *) target="$1"; shift ;;
  esac
done
[[ -n "$target" ]] || { echo "usage: local-ci [-C <dir>] <pull request | branch | commit>" >&2; exit 2; }

CI_ROOT="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" ||
  { echo "local-ci: $dir isn't in a git repository" >&2; exit 2; }
main_checkout="$(cd "$(dirname "$(git -C "$CI_ROOT" rev-parse --path-format=absolute --git-common-dir)")" && pwd)"
CI_NAME="$(basename "$main_checkout" | tr '[:upper:]' '[:lower:]')"
CI_JOBS=()
CI_KEEP=()
conf="${CI_CONF:-$CI_ROOT/.claude/ci.conf.sh}"
# shellcheck disable=SC1090
if [[ -f "$conf" ]]; then . "$conf"; fi
((${#CI_JOBS[@]})) || CI_JOBS=(local-ci)
CI_COMMAND="${CI_COMMAND:-make ci}"
if [[ -z "${CI_REPO:-}" ]]; then
  CI_REPO="$(git -C "$CI_ROOT" remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"
fi
[[ "$CI_REPO" == */* ]] || { echo "local-ci: can't tell the GitHub repo from origin: set CI_REPO in $conf" >&2; exit 2; }
CI_CACHE="${CI_CACHE:-$HOME/Library/Caches/$CI_NAME-dev}"
CI_DIR="${CI_DIR:-$CI_CACHE/ci}"
CI_WORKTREE="${CI_WORKTREE:-fresh}"
# NetworkMonitor's names for the same limits (#483), in minutes, still count.
lock_timeout=$((${CI_LOCK_TIMEOUT:-$((${LOCAL_CI_LOCK_MINUTES:-120} * 60))}))
job_timeout=$((${CI_JOB_TIMEOUT:-$((${LOCAL_CI_JOB_MINUTES:-60} * 60))}))
span() { if (($1 % 60)); then echo "${1}s"; else echo "$(($1 / 60)) min"; fi; }

job_fn() { echo "ci_job_$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }

# The commit: a pull request's head, or a branch on origin, or any commit.
CI_PR="" CI_HEAD="" CI_BASE=""
if [[ "$target" =~ ^[0-9]+$ ]]; then
  CI_PR="$target"
  read -r CI_SHA CI_HEAD CI_BASE < <(gh pr view "$target" -R "$CI_REPO" --json headRefOid,headRefName,baseRefName \
    --jq '.headRefOid + " " + .headRefName + " " + .baseRefName') || true
  [[ -n "${CI_SHA:-}" ]] || { echo "local-ci: couldn't read pull request $target on $CI_REPO" >&2; exit 2; }
else
  git -C "$CI_ROOT" fetch -q origin
  CI_SHA="$(git -C "$CI_ROOT" rev-parse --verify -q "origin/$target^{commit}" || git -C "$CI_ROOT" rev-parse --verify "$target^{commit}")"
  git -C "$CI_ROOT" rev-parse --verify -q "origin/$target" >/dev/null && CI_HEAD="$target"
fi
short="${CI_SHA:0:7}"
CI_BASE="${CI_BASE:-main}"
export CI_ROOT CI_NAME CI_REPO CI_CACHE CI_DIR CI_SHA CI_PR CI_HEAD CI_BASE

here_jobs=("${CI_JOBS[@]}")

# bounded <seconds> <command…>: runs the command (a function too) in a subshell with set -e on, in a
# process group of its own, and returns its status. After <seconds> it stops the whole group (TERM,
# then KILL 5 s later) and returns 124, as timeout(1) does; stopping this script stops the group
# too (NetworkMonitor#483's run_bounded). Call it with set +e, never in an if or ||, where bash
# would ignore set -e inside the command.
bounded() {
  local limit="$1" pid rc=0 _
  shift
  set -m # job control: the command gets its own process group, so all it started can be stopped
  (set -euo pipefail; "$@") &
  pid=$!
  set +m
  trap "kill -TERM -- -$pid 2>/dev/null; exit 130" INT
  trap "kill -TERM -- -$pid 2>/dev/null; exit 143" TERM HUP
  local deadline=$((SECONDS + limit))
  while kill -0 "$pid" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
      kill -TERM -- "-$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 -- "-$pid" 2>/dev/null || break; sleep 0.5; done
      kill -KILL -- "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      trap - INT TERM HUP
      return 124
    fi
    sleep 0.2
  done
  wait "$pid" || rc=$?
  trap - INT TERM HUP
  return "$rc"
}

status() { # <job> <state> <description>
  [[ -n "${CI_NO_STATUS:-}" ]] && return 0
  gh api -X POST "repos/$CI_REPO/statuses/$CI_SHA" -f state="$2" -f context="$1" -f description="$3" >/dev/null ||
    echo "(couldn't record $1 on GitHub)" >&2
}

if [[ -n "$CI_PR" ]]; then git -C "$CI_ROOT" fetch -q origin "pull/$CI_PR/head"; fi

# One run per project at a time: runs share the build folders.
mkdir -p "$CI_DIR/logs"
exec 4>>"$CI_DIR/lock"
if ! lockf -s -k -t 0 4; then
  echo "local-ci: another run of $CI_NAME is going ($(head -n 1 "$CI_DIR/holder" 2>/dev/null || echo unknown)):" \
    "waiting up to $(span "$lock_timeout")…"
  if ! lockf -s -k -t "$lock_timeout" 4; then
    echo "local-ci: gave up after $(span "$lock_timeout"): another run still holds $CI_NAME's CI." \
      "Try again later (CI_LOCK_TIMEOUT waits longer)." >&2
    exit 75
  fi
fi
printf 'local-ci %s for %s, since %s (pid %s)\n' "$target" "$short" "$(date '+%H:%M:%S')" "$$" >"$CI_DIR/holder"

# Check out only once the lock is held (home-control#318): a checkout made while waiting is older
# than what the run before built into the shared folders.
work=""
if [[ "$CI_WORKTREE" == kept ]]; then
  CI_SRC="$CI_DIR/src"
  if [[ -e "$CI_SRC/.git" ]]; then
    git -C "$CI_SRC" checkout -q --detach -f "$CI_SHA"
    keep=()
    for k in ${CI_KEEP[@]+"${CI_KEEP[@]}"}; do keep+=(-e "$k"); done
    git -C "$CI_SRC" clean -q -fdx ${keep[@]+"${keep[@]}"}
  else
    git -C "$CI_ROOT" worktree prune
    git -C "$CI_ROOT" worktree add -q --detach "$CI_SRC" "$CI_SHA"
  fi
else
  work="$(mktemp -d "${TMPDIR:-/tmp}/$CI_NAME-ci.XXXXXX")"
  CI_SRC="$work/src"
  git -C "$CI_ROOT" worktree add -q --detach "$CI_SRC" "$CI_SHA"
fi
export CI_SRC
cleanup() {
  if [[ -n "$work" ]]; then
    git -C "$CI_ROOT" worktree remove --force "$CI_SRC" 2>/dev/null || true
    rm -rf "$work"
    git -C "$CI_ROOT" worktree prune 2>/dev/null || true
  fi
}
trap cleanup EXIT

# A pull request runs merged with the newest base branch (home-control#349): two pull requests
# that each passed on their own once broke main together. The result is still recorded on the
# pull request's head. CI_MERGE_BASE=no runs the head alone.
with=""
if [[ -n "$CI_PR" && "${CI_MERGE_BASE:-yes}" != no ]]; then
  git -C "$CI_ROOT" fetch -q origin "$CI_BASE"
  base_sha="$(git -C "$CI_ROOT" rev-parse "origin/$CI_BASE")"
  if ! git -C "$CI_SRC" -c user.name=local-ci -c user.email=local-ci@localhost merge -q --no-edit "$base_sha" >/dev/null 2>&1; then
    git -C "$CI_SRC" merge --abort >/dev/null 2>&1 || true
    for job in "${here_jobs[@]}"; do status "$job" failure "Doesn't merge with $CI_BASE: merge $CI_BASE into the branch"; done
    echo "local-ci: FAILED: $short doesn't merge cleanly with $CI_BASE (${base_sha:0:7}): merge $CI_BASE into the branch"
    exit 1
  fi
  with=" with $CI_BASE ${base_sha:0:7}"
fi
for job in "${here_jobs[@]}"; do status "$job" pending "Running$with on Kevin's Mac"; done

run_job() { # <job>
  cd "$CI_SRC"
  local fn; fn="$(job_fn "$1")"
  if declare -F "$fn" >/dev/null; then "$fn"; else eval "$CI_COMMAND"; fi
}
prepare() { cd "$CI_SRC"; ci_prepare; }

if declare -F ci_prepare >/dev/null; then
  set +e
  bounded "$job_timeout" prepare >"$CI_DIR/logs/prepare.log" 2>&1
  rc=$?
  set -e
  if ((rc)); then
    for job in "${here_jobs[@]}"; do status "$job" failure "Couldn't prepare on Kevin's Mac"; done
    tail -n 40 "$CI_DIR/logs/prepare.log"
    echo "local-ci: preparing $short FAILED (whole log: $CI_DIR/logs/prepare.log)"
    exit 1
  fi
fi

failed=0
for job in "${here_jobs[@]}"; do
  log="$CI_DIR/logs/$job.log"
  started=$SECONDS
  echo "local-ci: $job on $short$with (log: $log)"
  set +e
  bounded "$job_timeout" run_job "$job" >"$log" 2>&1
  rc=$?
  set -e
  took=$((SECONDS - started))
  if ((rc == 0)); then
    status "$job" success "Passed$with on Kevin's Mac in ${took}s"
    echo "local-ci: $job passed in ${took}s"
  elif ((rc == 124)); then
    status "$job" failure "Stopped after $(span "$job_timeout") on Kevin's Mac"
    tail -n 40 "$log"
    echo "local-ci: $job took more than $(span "$job_timeout"): stopped (whole log: $log)"
    failed=1
  else
    status "$job" failure "Failed on Kevin's Mac"
    tail -n 40 "$log"
    echo "local-ci: $job FAILED (whole log: $log)"
    failed=1
  fi
done
exit $failed
