#!/bin/bash
# The appcast's notes in every language (#640): Scripts/appcast.sh, run on made-up notes in a
# throwaway repo with a throwaway key, writes one <description> per language with its xml:lang,
# the Chinese one in Chinese (an older version without a copy in English), and refuses a release
# whose Chinese copy is missing. Then the pick: what Sparkle 2.10 does with those xml:lang values
# (+[NSBundle preferredLocalizationsFromArray:]), for a Mac in Chinese and one in English.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "appcast-test: FAIL: $*" >&2; exit 1; }
work="$(mktemp -d "${TMPDIR:-/tmp}/appcast-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

repo="$work/repo"
mkdir -p "$repo/Scripts" "$repo/ReleaseNotes/zh-Hans"
cp "$here/Scripts/appcast.sh" "$here/Scripts/release-notes.swift" "$here/Scripts/ed25519-sign.swift" "$repo/Scripts/"
echo '- **An older change** in English only (#1).' > "$repo/ReleaseNotes/1.0.0.md"
echo '- **A new change.** It does something (#2).' > "$repo/ReleaseNotes/1.1.0.md"
echo '- **新的改动。** 它能做某件事（#2）。' > "$repo/ReleaseNotes/zh-Hans/1.1.0.md"
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm one
git -C "$repo" tag v1.0.0

SPARKLE_ED_KEY="$(openssl rand -base64 32)"
export SPARKLE_ED_KEY
app="$work/Fake.app"
mkdir -p "$app/Contents"
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $(swift "$repo/Scripts/ed25519-sign.swift" --public)" \
  -c "Add :CFBundleVersion string 2" -c "Add :LSMinimumSystemVersion string 14.0" "$app/Contents/Info.plist" >/dev/null
echo "not a disk image" > "$work/Fake.dmg"

"$repo/Scripts/appcast.sh" "$work/Fake.dmg" "$app" 1.1.0 > "$work/appcast.xml" || fail "appcast.sh failed"
xpath() { xmllint --xpath "$1" "$work/appcast.xml" 2>/dev/null || true; }
[ "$(xpath 'count(//item/description)')" = 2 ] || fail "not one description per language: $(xpath 'count(//item/description)')"
english="$(xpath "string(//description[@xml:lang='en'])")"
chinese="$(xpath "string(//description[@xml:lang='zh-Hans'])")"
[[ "$english" == *"<h3>Version 1.1.0</h3>"* && "$english" == *"A new change."* ]] || fail "English notes: $english"
[[ "$english" != *"新的改动"* ]] || fail "Chinese in the English notes"
[[ "$chinese" == *'lang="zh-Hans"'*"<h3>版本 1.1.0</h3>"*"新的改动。"* ]] || fail "Chinese notes: $chinese"
[[ "$chinese" == *'data-sparkle-version="1" lang="en"'*"An older change"* ]] || fail "older version not in English: $chinese"

# A beta (#585): its build sits between the commit before's release and its own commit's, its
# item carries the beta channel and its own disk image, with its release's What's new; the
# release from the same commit hides those notes from a beta user who already has them.
cp "$here/Scripts/build-number.sh" "$repo/Scripts/"
[ "$("$repo/Scripts/build-number.sh" 1.1.0-beta.3 1200)" = 1199.3 ] || fail "a beta's build at commit 1200"
[ "$("$repo/Scripts/build-number.sh" 1.1.0 1200)" = 1200 ] || fail "a release's build at commit 1200"
echo change > "$repo/change"
git -C "$repo" add -A
git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm two
git -C "$repo" tag v1.1.0-beta.1
beta_build="$("$repo/Scripts/build-number.sh" 1.1.0-beta.1 "$(git -C "$repo" rev-list --count HEAD)")"
[ "$beta_build" = 1.1 ] || fail "the beta's build: $beta_build"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $beta_build" "$app/Contents/Info.plist"
"$repo/Scripts/appcast.sh" "$work/Fake.dmg" "$app" 1.1.0-beta.1 > "$work/appcast.xml" || fail "appcast.sh failed for a beta"
[ "$(xpath 'string(//item/title)')" = "Version 1.1.0-beta.1" ] || fail "the beta's title: $(xpath 'string(//item/title)')"
[ "$(xpath 'string(//item/*[local-name()="channel"])')" = beta ] || fail "no beta channel"
[ "$(xpath 'string(//item/*[local-name()="version"])')" = 1.1 ] || fail "the beta's build in the appcast"
[[ "$(xpath 'string(//enclosure/@url)')" == */download/v1.1.0-beta.1/NetworkMonitor.dmg ]] || fail "the beta's disk image: $(xpath 'string(//enclosure/@url)')"
beta_notes="$(xpath "string(//description[@xml:lang='zh-Hans'])")"
[[ "$beta_notes" == *'data-sparkle-version="1.1" lang="zh-Hans"'*"新的改动。"* ]] || fail "the beta's notes: $beta_notes"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 2" "$app/Contents/Info.plist"
"$repo/Scripts/appcast.sh" "$work/Fake.dmg" "$app" 1.1.0 > "$work/appcast.xml" || fail "appcast.sh failed for the release"
[ "$(xpath 'count(//item/*[local-name()="channel"])')" = 0 ] || fail "a release with a channel"
english="$(xpath "string(//description[@xml:lang='en'])")"
[[ "$english" == *'data-sparkle-version="2" lang="en"'*'A new change.'*'</div>'*'<div data-sparkle-version="1.1"></div>'*'data-sparkle-version="1" lang="en"'* ]] \
  || fail "the release's notes don't hide themselves from its beta: $english"
for bad in 1.1 1.1.0-rc.1 1.1.0-beta; do
  if "$repo/Scripts/appcast.sh" "$work/Fake.dmg" "$app" "$bad" > /dev/null 2>&1; then fail "published version $bad"; fi
done

rm "$repo/ReleaseNotes/zh-Hans/1.1.0.md"
if "$repo/Scripts/appcast.sh" "$work/Fake.dmg" "$app" 1.1.0 > /dev/null 2> "$work/error"; then
  fail "appcast.sh published without the Chinese notes"
fi
grep -q "ReleaseNotes/zh-Hans/1.1.0.md is missing" "$work/error" || fail "unclear error: $(cat "$work/error")"

picks="$(swift - <<'SWIFT'
import Foundation
for mac in [["zh-Hans-CN"], ["en-US"], ["fr-FR"]] {
    print(Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: mac).first ?? "-")
}
SWIFT
)"
[ "$(echo $picks)" = "zh-Hans en en" ] || fail "Sparkle's pick for a Mac in Chinese, English, French: $(echo $picks)"
echo "appcast-test: the appcast has the notes in English and Chinese, each picked by the app's language; a beta's has its channel, its build and its release's notes"
