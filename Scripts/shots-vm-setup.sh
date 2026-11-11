#!/bin/bash
#
# In the VM, before the website's pictures are taken there (#561; shots-kit's
# vm.setup, product-kit#12). The image (claude-image-networkmonitor, see
# docs/development.md#website-pictures) has the content filter, the background
# item and Location Services approved, and passwordless sudo. This makes the VM
# look like this Mac from what Scripts/shots-vm-prepare.sh wrote: its time zone,
# light or dark, and its apps' stand-ins, each where it is on this Mac (and
# those in ~/Applications in the VM's too, where the Network section looks).
set -euo pipefail
d="${SHOTS_VM_DIR:?run by shots-kit, which sets SHOTS_VM_DIR}"
if [ -s "$d/timezone" ]; then sudo -n systemsetup -settimezone "$(cat "$d/timezone")" >/dev/null 2>&1; fi
dark=false
[ "$(cat "$d/appearance" 2>/dev/null)" = Dark ] && dark=true
# Through System Events, which the image allows (Scripts/shots-vm-image.sh): at once, for every app.
osascript -e "with timeout of 20 seconds" -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $dark" -e "end timeout" >/dev/null 2>&1 ||
  { if $dark; then defaults write -g AppleInterfaceStyle Dark; else defaults delete -g AppleInterfaceStyle 2>/dev/null || true; fi; }
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
hosthome="$(cat "$d/home" 2>/dev/null || true)"
placed=0
place() { # <stand-in's path on this Mac> <where in the VM>
  # Only where the VM has nothing: its own apps stay as they are.
  [ -e "$2" ] && return 0
  sudo -n mkdir -p "$(dirname "$2")"
  sudo -n ditto "$d/icons$1" "$2"
  case "$2" in *.app) "$lsregister" -f "$2" >/dev/null 2>&1 || true ;; esac
  placed=$((placed + 1))
}
if [ -f "$d/icons.txt" ]; then
  while IFS= read -r path; do
    place "$path" "$path"
    if [ -n "$hosthome" ] && [[ "$path" == "$hosthome/Applications/"* ]]; then
      place "$path" "$HOME/Applications/${path#"$hosthome/Applications/"}"
    fi
  done <"$d/icons.txt"
fi
echo "shots-vm-setup: time zone $(cat "$d/timezone" 2>/dev/null || echo unchanged), dark mode $dark, $placed apps' stand-ins"
