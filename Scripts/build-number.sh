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
#        Scripts/build-number.sh --version
#
# --version prints the version to stamp, from the tags: the commit's own
# release's; else the commit's own beta's; else the last release's, never a
# beta's (a build after a beta isn't that beta). Promoting a beta puts its
# release's tag on the same commit, and the release wins. Nothing without a tag.

set -euo pipefail
if [ "${1:-}" = --version ]; then
  tag=$(git tag --points-at HEAD --list 'v[0-9]*' | grep -v -- '-beta\.' | head -1 || true)
  [ -n "$tag" ] || tag=$(git tag --points-at HEAD --list 'v[0-9]*-beta.*' --sort=-v:refname | head -1 || true)
  [ -n "$tag" ] || tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude '*-beta.*' 2>/dev/null || true)
  echo "${tag#v}"
  exit 0
fi
VERSION="${1:?usage: $0 <version> <commit count>}"
COUNT="${2:?usage: $0 <version> <commit count>}"

if [[ "$VERSION" =~ -beta\.([0-9]+)$ ]]; then
  echo "$((COUNT - 1)).${BASH_REMATCH[1]}"
else
  echo "$COUNT"
fi
