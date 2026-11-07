#!/bin/bash
#
# WorktreeCreate: makes .claude/worktrees/<name> on branch <name> (#342).
#
# Claude Code's own worktrees are on a branch called worktree-<name>; here a
# branch is named after its issue (settings-v2-9), so EnterWorktree, `claude -w`
# and background sessions all use the name as given. A new branch starts from
# origin/main, freshly fetched, without tracking it (so a bare `git push` can
# never go to main); an existing one is checked out as it is. The path printed
# on the last line is how Claude Code learns where the worktree is, so git's
# own messages go to stderr.

set -euo pipefail

input=$(cat)
name=$(jq -r '.name' <<<"$input")
cwd=$(jq -r '.cwd' <<<"$input")

common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir)
main=$(cd "$(dirname "$common")" && pwd -P)
path="$main/.claude/worktrees/$name"

if git -C "$main" show-ref --verify --quiet "refs/heads/$name"; then
  git -C "$main" worktree add "$path" "$name" >&2
else
  git -C "$main" fetch --quiet origin main >&2
  git -C "$main" worktree add --no-track -b "$name" "$path" origin/main >&2
fi

echo "$path"
