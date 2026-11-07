#!/bin/bash
#
# PreToolUse: keeps edits and branch switches out of the main checkout (#342).
#
# Several sessions work in this repo at once, each in a worktree of its own
# under .claude/worktrees/. Once a session is in one, Claude Code itself keeps
# it out of the main checkout. This covers a session that started here and has
# not entered one yet: it refuses, and the reason tells Claude what to do.

set -euo pipefail

input=$(cat)
field() { jq -r "$1 // \"\"" <<<"$input"; }

cwd=$(field .cwd)
common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
main=$(cd "$(dirname "$common")" && pwd -P)

deny() {
  jq -n --arg r "This is the main checkout, which several sessions share. Before changing anything, call EnterWorktree with the branch name for this issue (for example settings-v2-9), then work there. See Workflow in CLAUDE.md." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

case "$(field .tool_name)" in
  Bash)
    here=$(cd "$cwd" 2>/dev/null && pwd -P) || exit 0
    [ "$here" = "$main" ] || exit 0
    if grep -Eq '(^|[;&|(`[:space:]])git([[:space:]]+-[^[:space:]]+)*[[:space:]]+(checkout|switch)([[:space:]]|$)' <<<"$(field .tool_input.command)"; then
      deny
    fi
    ;;
  *)
    path=$(field '.tool_input.file_path // .tool_input.notebook_path')
    [ -n "$path" ] || exit 0
    case "$path" in /*) ;; *) path="$cwd/$path" ;; esac
    case "$path" in
      "$main"/.claude/worktrees/*) ;;
      "$main"/*) deny ;;
    esac
    ;;
esac
exit 0
