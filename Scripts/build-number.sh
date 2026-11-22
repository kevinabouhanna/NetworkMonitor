#!/bin/bash
#
# The build number for a version (#585), what Sparkle compares to decide
# whether an update is newer.
#
# - A release (X.Y.Z): the commit count, as since 1.15.
# - A beta (X.Y.Z-beta.N): one less than the commit count, then .N, so
#   `1199.1` for beta 1 at commit 1200. Newer than anything built from the
#   commit before (1199), older than the release tagged on its own commit
#   (1200): promoting a beta to everyone is tagging X.Y.Z on that commit,
#   and beta users are offered it too. Sparkle compares part by part.
#
# Usage: Scripts/build-number.sh <version> <commit count>

set -euo pipefail
VERSION="${1:?usage: $0 <version> <commit count>}"
COUNT="${2:?usage: $0 <version> <commit count>}"

if [[ "$VERSION" =~ -beta\.([0-9]+)$ ]]; then
  echo "$((COUNT - 1)).${BASH_REMATCH[1]}"
else
  echo "$COUNT"
fi
