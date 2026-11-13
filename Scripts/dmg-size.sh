#!/bin/bash
# The latest release's DMG size, in 1024-based MB with one decimal, as the website's download
# line shows it: the `size` fact product-kit writes there (#633, product-kit#40).
set -euo pipefail
tag="$(git describe --tags --abbrev=0)"
bytes="$(gh release view "$tag" -R kevinabouhanna/NetworkMonitor --json assets \
  --jq '.assets[] | select(.name == "NetworkMonitor.dmg") | .size')"
[ -n "$bytes" ] || { echo "dmg-size: $tag has no NetworkMonitor.dmg" >&2; exit 1; }
python3 -I -c 'import sys; print(f"{int(sys.argv[1]) / 1048576:.1f} MB")' "$bytes"
