#!/bin/bash
#
# Mac lanes: whatever uses one shared part of this Mac runs one at a time, across every
# worktree, session and project. There's a lane per part, so unrelated work doesn't wait:
#
#   <app>      one per app, named after it (home-control, networkmonitor…): its installed copy,
#              extensions, helper, settings, quitting, replacing, relaunching or testing it
#   screen     the pointer, the screen, screen captures, computer use, recordings. The default,
#              and the same lock older copies of this script take for the whole Mac
#   <other>    anything else shared, named after it (house: the live smart-home devices…)
#
# Hold a lane only while you use that part, never while building, notarizing or waiting on a
# person. Anything paced by a person (a review build, a recording) takes its own app's lane, or
# screen, and says so in MAC_LANE_WHAT. The lock is the kernel's (lockf): it goes when its holder
# dies, so it never goes stale and never expires under a holder that is still working.
#
# Usage:
#   MAC_LANE=<lane> mac-lane <command> [args…]          run a command in a lane
#   mac-lane status                                      every lane: free, or who and how long
#   mac-lane status <lane>                               one lane: free, or busy: who
#   mac-lane status --watch                              every lane, again every 2 s (Ctrl-C ends)
#   . "$(command -v mac-lane)"; MAC_LANE=<lane> mac_lane_enter   in a script: hold it until it exits
#   mac-lane idle                                        seconds since the keyboard or mouse was
#                                                        last used (a large number while locked)
#
# One copy for every project: the shared-mac plugin (claude-parallel-sessions) keeps it at
# ~/.local/bin/mac-lane. A copy inside a repo (Scripts/mac-lane.sh) is only a fallback for where
# that isn't installed, such as a CI runner: when a shared copy is on PATH, the repo's copy hands
# over to it, so every project runs the same lanes the same way. MAC_LANE_NO_SHARED=1 keeps the
# copy that was called (the tests use it).
#
# MAC_LANE_IDLE (seconds) waits, before taking the lane, until nobody has touched the keyboard or
# mouse for that long, or the screen is locked; then checks again once the lane is held. Use it,
# with the screen lane, for anything that moves the real pointer or drives the UI (drag tests,
# computer use): MAC_LANE=screen MAC_LANE_IDLE=90. Inside, `mac-lane idle` tells a long test
# whether someone is back, so it can stop. MAC_LANE_NOTIFY=0 skips the notification it posts once
# while waiting.
# MAC_LANE_TIMEOUT (seconds) gives up with exit status 75 instead of waiting as long as it takes.
# MAC_LANE_WHAT names what you're doing in the holder text. Inside a lane MAC_LANE_HELD lists the
# lanes held, so nested scripts and make calls run straight through rather than wait on themselves.
#
# The lock is held on a file descriptor that child processes inherit: a process started with `&`
# that outlives the script keeps the lane busy. Start anything long-lived with `open`. Never hand
# Mac work to launchd, nohup, at or disown to run after your session: it lands in someone else's
# test. Wait in your session instead, or let the app update itself.

# A repo's copy hands over to the shared one on PATH, unless it is this very file.
if [ -z "${MAC_LANE_NO_SHARED:-}" ] && mac_lane_shared="$(command -v mac-lane 2>/dev/null)" \
  && [ -n "$mac_lane_shared" ] && [ ! "$mac_lane_shared" -ef "${BASH_SOURCE[0]}" ]; then
  if [ "${BASH_SOURCE[0]}" = "$0" ]; then exec "$mac_lane_shared" "$@"; fi
  # shellcheck disable=SC1090
  . "$mac_lane_shared"
  return
fi
unset mac_lane_shared

MAC_LANE_DIR="${MAC_LANE_DIR:-$HOME/Library/Caches/mac-lane}"

# The screen lane keeps the original file names, so older copies of this script share it.
mac_lane_file() { # <lane> <lock|holder>
  if [ "$1" = screen ]; then echo "$MAC_LANE_DIR/$2"; else echo "$MAC_LANE_DIR/$1.$2"; fi
}

mac_lane_holder() { # [lane]
  local f; f="$(mac_lane_file "${1:-${MAC_LANE:-screen}}" holder)"
  local text since
  text="$(head -n 1 "$f" 2>/dev/null)"
  since="$(sed -n 2p "$f" 2>/dev/null)"
  if [ -n "$since" ]; then text="$text, $((($(date +%s) - since) / 60)) min so far"; fi
  echo "${text:-unknown}"
}

mac_lane_is_held() { # <lane>: held by this process tree
  case " ${MAC_LANE_HELD:-} " in
    *" $1 "*) return 0 ;;
    " 1 ") [ "$1" = screen ] ;; # an older copy of this script set MAC_LANE_HELD=1
    *) return 1 ;;
  esac
}

mac_lane_free() { # [lane]
  mkdir -p "$MAC_LANE_DIR"
  lockf -s -k -t 0 "$(mac_lane_file "${1:-${MAC_LANE:-screen}}" lock)" true
}

# Seconds since the last keyboard or mouse input (HIDIdleTime), or a large number while the screen
# is locked. MAC_LANE_IDLE_SOURCE, a command that prints seconds, replaces it in tests.
mac_lane_idle_seconds() {
  if [ -n "${MAC_LANE_IDLE_SOURCE:-}" ]; then eval "$MAC_LANE_IDLE_SOURCE"; return; fi
  if ioreg -n Root -d 1 2>/dev/null | grep -q '"CGSSessionScreenIsLocked"=Yes'; then echo 999999; return; fi
  ioreg -c IOHIDSystem -d 4 2>/dev/null | awk '/"HIDIdleTime"/ { print int($NF / 1000000000); exit }'
}

mac_lane_wait_idle() { # <seconds> <deadline or empty>: returns 75 past the deadline
  local need="$1" deadline="$2" idle told=""
  while :; do
    idle="$(mac_lane_idle_seconds)"
    case "$idle" in "" | *[!0-9]*) echo "mac-lane: can't read the idle time" >&2; exit 2 ;; esac
    if [ "$idle" -ge "$need" ]; then return 0; fi
    if [ -z "$told" ]; then
      told=1
      echo "==> Waiting until the keyboard and mouse have been idle ${need}s, or the screen is locked (idle ${idle}s now)…" >&2
      if [ "${MAC_LANE_NOTIFY:-1}" != 0 ]; then
        osascript -e "display notification \"An agent will use the screen when you step away for $((need / 60 > 0 ? need / 60 : 1)) min: ${MAC_LANE_WHAT:-$0}\" with title \"Waiting for you to step away\"" >/dev/null 2>&1 || true
      fi
    fi
    if [ -n "$deadline" ] && [ "$(date +%s)" -ge "$deadline" ]; then return 75; fi
    sleep "${MAC_LANE_IDLE_POLL:-5}"
  done
}

mac_lane_enter() {
  local lane="${MAC_LANE:-screen}"
  case "$lane" in *[!a-z0-9-]* | "") echo "mac-lane: bad lane name '$lane'" >&2; exit 2 ;; esac
  case "${MAC_LANE_IDLE:-}" in *[!0-9]*) echo "mac-lane: MAC_LANE_IDLE must be seconds" >&2; exit 2 ;; esac
  if mac_lane_is_held "$lane"; then return 0; fi
  mkdir -p "$MAC_LANE_DIR"
  # One descriptor per lane held, counting down from 9: children keep the ones above open.
  local held=0 l
  for l in ${MAC_LANE_HELD:-}; do held=$((held + 1)); done
  local fd=$((9 - held))
  if [ "$fd" -lt 5 ]; then echo "mac-lane: too many lanes held at once" >&2; exit 2; fi
  local deadline="" left
  if [ -n "${MAC_LANE_TIMEOUT:-}" ]; then deadline=$(($(date +%s) + MAC_LANE_TIMEOUT)); fi
  while :; do
    if [ -n "${MAC_LANE_IDLE:-}" ] && ! mac_lane_wait_idle "$MAC_LANE_IDLE" "$deadline"; then
      echo "==> Gave up after ${MAC_LANE_TIMEOUT}s: the keyboard or mouse was in use" >&2
      exit 75
    fi
    eval "exec $fd>>\"\$(mac_lane_file \"\$lane\" lock)\""
    if ! lockf -s -k -t 0 "$fd"; then
      echo "==> Mac lane '$lane' busy: $(mac_lane_holder "$lane")" >&2
      left="${deadline:+$((deadline > $(date +%s) ? deadline - $(date +%s) : 0))}"
      echo "    Waiting${left:+ up to ${left}s}…" >&2
      if ! lockf -s -k ${left:+-t "$left"} "$fd"; then
        echo "==> Gave up after ${MAC_LANE_TIMEOUT:-?}s. Lane '$lane' still busy: $(mac_lane_holder "$lane")" >&2
        exit 75
      fi
    fi
    # The lane may have taken a while: if someone came back meanwhile, let it go and wait again.
    if [ -z "${MAC_LANE_IDLE:-}" ] || [ "$(mac_lane_idle_seconds)" -ge "$MAC_LANE_IDLE" ]; then break; fi
    eval "exec $fd>&-"
  done
  printf '%s, from %s, since %s (pid %s)\n%s\n' \
    "${MAC_LANE_WHAT:-$0}" "$PWD" "$(date '+%H:%M:%S')" "$$" "$(date +%s)" > "$(mac_lane_file "$lane" holder)"
  if [ "${MAC_LANE_HELD:-}" = 1 ]; then MAC_LANE_HELD=screen; fi
  export MAC_LANE_HELD="${MAC_LANE_HELD:+$MAC_LANE_HELD }$lane"
}

mac_lane_status() { # [lane]
  local lanes lane f
  if [ -n "${1:-}" ]; then
    if mac_lane_is_held "$1"; then echo "held by this process tree"
    elif mac_lane_free "$1"; then echo "free"
    else echo "busy: $(mac_lane_holder "$1")"; fi
    return
  else
    lanes="screen"
    for f in "$MAC_LANE_DIR"/*.lock; do [ -e "$f" ] && lanes="$lanes $(basename "$f" .lock)"; done
  fi
  for lane in $lanes; do
    if mac_lane_is_held "$lane"; then printf '%-14s held by this process tree\n' "$lane"
    elif mac_lane_free "$lane"; then printf '%-14s free\n' "$lane"
    else printf '%-14s busy: %s\n' "$lane" "$(mac_lane_holder "$lane")"; fi
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  case "${1:-}" in
    status)
      if [ "${2:-}" = --watch ]; then
        while :; do
          if [ -t 1 ]; then printf '\033[H\033[2J'; fi
          echo "Mac lanes at $(date '+%H:%M:%S')"
          mac_lane_status
          sleep "${MAC_LANE_WATCH_EVERY:-2}"
        done
      fi
      mac_lane_status "${2:-}"
      ;;
    idle) mac_lane_idle_seconds ;;
    "" | -h | --help)
      awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
      exit 2
      ;;
    *)
      MAC_LANE_WHAT="${MAC_LANE_WHAT:-$*}"
      mac_lane_enter
      exec "$@"
      ;;
  esac
fi
