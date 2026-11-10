#!/bin/bash
# .claude/ci.conf.sh, the CI `local-ci <pr>` runs on this Mac (#490): it loads, names the two
# jobs the merge rule waits for, and defines each, with the kept worktree SwiftPM needs. Nothing
# runs. How local-ci itself decides is tested in the shared-mac plugin (claude-parallel-sessions).
set -euo pipefail
conf="$(cd "$(dirname "$0")/../.." && pwd)/.claude/ci.conf.sh"
fail() { echo "ci-conf-test: FAIL: $*" >&2; exit 1; }
(
  CI_JOBS=() CI_KEEP=()
  # shellcheck disable=SC1090
  . "$conf"
  [[ "${CI_JOBS[*]}" == "build-and-test universal" ]] || fail "jobs are '${CI_JOBS[*]}', not build-and-test universal"
  for job in "${CI_JOBS[@]}"; do
    declare -F "ci_job_$(printf '%s' "$job" | tr -c 'A-Za-z0-9' '_')" >/dev/null || fail "no ci_job function for $job"
  done
  declare -F ci_prepare >/dev/null || fail "no ci_prepare (the website checkout)"
  [[ "$CI_WORKTREE" == kept && " ${CI_KEEP[*]} " == *" .build "* ]] || fail "not a kept worktree keeping .build"
  [[ "$CI_REPO" == kevinabouhanna/NetworkMonitor ]] || fail "CI_REPO is $CI_REPO"
)
echo "ci-conf-test: .claude/ci.conf.sh defines build-and-test and universal"
