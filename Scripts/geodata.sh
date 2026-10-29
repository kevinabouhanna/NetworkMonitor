#!/bin/bash
#
# Refreshes Resources/Geo from DB-IP's free monthly databases: IP to Country
# Lite and IP to ASN Lite, licensed CC BY 4.0 (https://db-ip.com).
#
# The converted files are committed, not built: DB-IP removes each month's
# files once the next is out, so a build that downloaded a pinned month would
# stop working, and an old tag could never be rebuilt. Refresh before a
# release now and then, in a pull request of its own.
#
# Usage:
#   ./Scripts/geodata.sh            this month
#   ./Scripts/geodata.sh 2026-10    a given month, while DB-IP still has it

set -euo pipefail
cd "$(dirname "$0")/.."

MONTH="${1:-$(date -u +%Y-%m)}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for kind in country asn; do
  echo "==> Downloading DB-IP ${kind} lite, ${MONTH}"
  curl -fsSL -o "${WORK}/${kind}.csv.gz" \
    "https://download.db-ip.com/free/dbip-${kind}-lite-${MONTH}.csv.gz"
  gunzip "${WORK}/${kind}.csv.gz"
done

echo "==> Converting"
./Scripts/swiftpm.sh run -c release GeoDataBuilder \
  "${WORK}/country.csv" "${WORK}/asn.csv" Resources/Geo
echo "$MONTH" > Resources/Geo/MONTH
echo "    Resources/Geo now holds DB-IP's ${MONTH} data."
