#!/bin/bash
#
# Deletes the settings files the test suite left in ~/Library/Preferences
# before it kept them in a temporary folder (#557): one per test per run,
# named after the test and a UUID, tens of thousands of them.
#
# Only files named exactly so: a test's prefix, then a UUID. Nothing else in
# ~/Library/Preferences is touched. Without --delete it only counts them.
#
# Usage:  Scripts/sweep-test-settings.sh [--delete]

set -euo pipefail

prefs="$HOME/Library/Preferences"
uuid='[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'
# Every prefix the tests have used for a suite of their own.
prefixes='a11y|ad-networks|ad-rules|ad-team|ads-choose|ads-pause|AppPlacementTests|block-everything|connections-home|connections-live|firewall-tests|keyboard|l10n|list-block-count|list-blocks|lists|menu-bar-colors|nettop-failure|network-rules|popover-period-test|rule-export|settings-main|settings-pane|settings-period|settings-window|signature|site-rules|speedstyle|speedtest-tests|speedunit-chosen|speedunit-fresh|until-quit'
pattern="^((${prefixes})-|netmon\\.tests\\.([a-z-]+\\.)?)${uuid}\\.plist\$"

files=()
while IFS= read -r name; do files+=("$name"); done < <(ls "$prefs" | grep -E "$pattern" || true)

echo "${#files[@]} settings files the tests left in $prefs"
if [ "${#files[@]}" -eq 0 ]; then exit 0; fi
printf '%s\n' "${files[@]}" | sed -E "s/[-.]${uuid}\\.plist\$//" | sort | uniq -c | sort -rn | head -40

if [ "${1:-}" = "--delete" ]; then
  for name in "${files[@]}"; do rm -f "$prefs/$name"; done
  echo "deleted them"
else
  echo "run with --delete to delete them"
fi
