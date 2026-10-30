#!/bin/bash
#
# Writes the appcast Sparkle reads (#132): one item, this release, its disk
# image signed with the key in SPARKLE_ED_KEY. Published as an asset of the
# release, so the app's feed, releases/latest/download/appcast.xml, is always
# the newest release's.
#
# The update window shows What's new from ReleaseNotes/ (#152), carried in the
# appcast so there's nothing to fetch: every recent version's, as HTML that
# Sparkle trims to the versions newer than the one installed (#163). See
# Scripts/release-notes.swift. The release's own notes take this version's
# file alone.
#
# Usage: SPARKLE_ED_KEY=… Scripts/appcast.sh <NetworkMonitor.dmg> <NetworkMonitor.app> <version>

set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:?usage: $0 <dmg> <app> <version>}"
APP="${2:?usage: $0 <dmg> <app> <version>}"
VERSION="${3:?usage: $0 <dmg> <app> <version>}"

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "${APP}/Contents/Info.plist"; }

NOTES="ReleaseNotes/${VERSION}.md"
if [ ! -s "$NOTES" ]; then
  echo "error: ${NOTES} is missing: write the version's What's new before tagging" >&2
  exit 1
fi

# The key that signs must be the one the app trusts, or every update is
# refused: checked before anything is published.
expected="$(plist SUPublicEDKey)"
actual="$(swift Scripts/ed25519-sign.swift --public)"
if [ "$expected" != "$actual" ]; then
  echo "error: SPARKLE_ED_KEY's public half is ${actual}, but the app trusts ${expected}" >&2
  exit 1
fi

BUILD="$(plist CFBundleVersion)"
MINIMUM="$(plist LSMinimumSystemVersion)"
DESCRIPTION="$(swift Scripts/release-notes.swift "$VERSION" "$BUILD")"
if [[ "$DESCRIPTION" == *']]>'* ]]; then
  echo "error: the release notes can't contain ]]>, which would end the appcast's CDATA" >&2
  exit 1
fi
LENGTH="$(stat -f %z "$DMG")"
SIGNATURE="$(swift Scripts/ed25519-sign.swift "$DMG")"
DATE="$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")"
REPO="https://github.com/kevinabouhanna/NetworkMonitor"

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>NetworkMonitor</title>
    <link>https://kevinabouhanna.github.io/NetworkMonitor/</link>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${DATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MINIMUM}</sparkle:minimumSystemVersion>
      <description><![CDATA[
${DESCRIPTION}
]]></description>
      <sparkle:fullReleaseNotesLink>${REPO}/releases</sparkle:fullReleaseNotesLink>
      <enclosure url="${REPO}/releases/download/v${VERSION}/NetworkMonitor.dmg"
                 length="${LENGTH}" type="application/octet-stream"
                 sparkle:edSignature="${SIGNATURE}"/>
    </item>
  </channel>
</rss>
XML
