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
#   MAC_LANE=<lane> Scripts/mac-lane.sh <command> [args…]   run a command in a lane
#   Scripts/mac-lane.sh status                               every lane: free, or who and how long
#   Scripts/mac-lane.sh status <lane>                        one lane: free, or busy: who
#   . Scripts/mac-lane.sh; MAC_LANE=<lane> mac_lane_enter    in a script: hold it until it exits
#
# MAC_LANE_TIMEOUT (seconds) gives up with exit status 75 instead of waiting as long as it takes.
# MAC_LANE_WHAT names what you're doing in the holder text. Inside a lane MAC_LANE_HELD lists the
# lanes held, so nested scripts and make calls run straight through rather than wait on themselves.
#
# The lock is held on a file descriptor that child processes inherit: a process started with `&`
# that outlives the script keeps the lane busy. Start anything long-lived with `open`. Never hand
# Mac work to launchd, nohup, at or disown to run after your session: it lands in someone else's
# test. Wait in your session instead, or let the app update itself.

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

mac_lane_enter() {
  local lane="${MAC_LANE:-screen}"
  case "$lane" in *[!a-z0-9-]* | "") echo "mac-lane: bad lane name '$lane'" >&2; exit 2 ;; esac
  if mac_lane_is_held "$lane"; then return 0; fi
  mkdir -p "$MAC_LANE_DIR"
  # One descriptor per lane held, counting down from 9: children keep the ones above open.
  local held=0 l
  for l in ${MAC_LANE_HELD:-}; do held=$((held + 1)); done
  local fd=$((9 - held))
  if [ "$fd" -lt 5 ]; then echo "mac-lane: too many lanes held at once" >&2; exit 2; fi
  eval "exec $fd>>\"\$(mac_lane_file \"\$lane\" lock)\""
  if ! lockf -s -k -t 0 "$fd"; then
    echo "==> Mac lane '$lane' busy: $(mac_lane_holder "$lane")" >&2
    echo "    Waiting${MAC_LANE_TIMEOUT:+ up to ${MAC_LANE_TIMEOUT}s}…" >&2
    if ! lockf -s -k ${MAC_LANE_TIMEOUT:+-t "$MAC_LANE_TIMEOUT"} "$fd"; then
      echo "==> Gave up after ${MAC_LANE_TIMEOUT:-?}s. Lane '$lane' still busy: $(mac_lane_holder "$lane")" >&2
      exit 75
    fi
  fi
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
    status) mac_lane_status "${2:-}" ;;
    "" | -h | --help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 2
      ;;
    *)
      MAC_LANE_WHAT="${MAC_LANE_WHAT:-$*}"
      mac_lane_enter
      exec "$@"
      ;;
  esac
fi
