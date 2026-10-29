#!/bin/bash
#
# Rebuilds Resources/Geo/world.bin, the Connections map, from Natural Earth's
# 1:10m countries (public domain, https://www.naturalearthdata.com). Natural
# Earth changes rarely; the output is committed, like the DB-IP data.
#
# Usage:
#   ./Scripts/mapdata.sh

set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "==> Downloading Natural Earth's countries"
curl -fsSL -o "${WORK}/countries.geojson" \
  https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_admin_0_countries.geojson
echo "==> Converting"
./Scripts/swiftpm.sh run -c release MapDataBuilder "${WORK}/countries.geojson" Resources/Geo/world.bin
