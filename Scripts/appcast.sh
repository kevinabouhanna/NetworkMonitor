#!/bin/bash
#
# Writes the appcast Sparkle reads (#132): one item, this release, its disk
# image signed with the key in SPARKLE_ED_KEY. Published as an asset of the
# release, so the app's feed, releases/latest/download/appcast.xml, is always
# the newest release's.
#
# Usage: SPARKLE_ED_KEY=… Scripts/appcast.sh <NetworkMonitor.dmg> <NetworkMonitor.app> <version>

set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:?usage: $0 <dmg> <app> <version>}"
APP="${2:?usage: $0 <dmg> <app> <version>}"
VERSION="${3:?usage: $0 <dmg> <app> <version>}"

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "${APP}/Contents/Info.plist"; }

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
      <sparkle:releaseNotesLink>${REPO}/releases/tag/v${VERSION}</sparkle:releaseNotesLink>
      <enclosure url="${REPO}/releases/download/v${VERSION}/NetworkMonitor.dmg"
                 length="${LENGTH}" type="application/octet-stream"
                 sparkle:edSignature="${SIGNATURE}"/>
    </item>
  </channel>
</rss>
XML
