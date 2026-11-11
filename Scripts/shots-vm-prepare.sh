#!/bin/bash
#
# On this Mac, before the website's pictures are taken in a VM (#561; shots-kit's
# vm.prepare, product-kit#12): what the VM needs from this Mac, into $SHOTS_VM_DIR.
#   timezone     this Mac's time zone, so the charts' hours are the same
#   appearance   Dark or Light, as this Mac shows windows
#   home         this Mac's home folder, for the apps in ~/Applications
#   icons/…      stand-ins for this Mac's apps (Scripts/shots-vm-icons.swift): the
#                ones the history names, and the ones the Network section finds
#   icons.txt    their paths
# Scripts/shots-vm-setup.sh puts them in place in the VM.
set -euo pipefail
out="${SHOTS_VM_DIR:?run by shots-kit, which sets SHOTS_VM_DIR}"
readlink /etc/localtime | sed 's#.*/zoneinfo/##' >"$out/timezone"
defaults read -g AppleInterfaceStyle 2>/dev/null | grep -qx Dark && echo Dark >"$out/appearance" || echo Light >"$out/appearance"
echo "$HOME" >"$out/home"
# The program each app's stand-in holds in place of its own: it does nothing.
exec="$out/stand-in"
printf 'int main(void) { return 0; }\n' | cc -x c - -o "$exec"
db="$HOME/Library/Application Support/NetworkMonitor/history.sqlite"
{
  if [ -f "$db" ]; then
    sqlite3 -readonly "$db" "select bundle_path from apps where bundle_path is not null
      union select parent_bundle_path from apps where parent_bundle_path is not null"
  fi
  # Where ApplicationSearch looks: these folders and one level down.
  find /Applications "$HOME/Applications" -maxdepth 2 -name '*.app' -prune 2>/dev/null
} | swift "$(dirname "$0")/shots-vm-icons.swift" "$out/icons" "$exec" >"$out/icons.txt"
rm -f "$exec"
