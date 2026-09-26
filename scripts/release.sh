#!/bin/bash
# Builds, signs, notarizes and staples StratIsland.app, leaving a DMG and a zip ready to
# attach to a GitHub Release. Publishing is deliberately left to you: this script never
# pushes or creates the release.
#
#   ./scripts/release.sh 1.1
#
# Needs a Developer ID Application identity in the keychain and a notarytool credential
# profile, created once with:
#
#   xcrun notarytool store-credentials stratisland --apple-id <id> --team-id 78KDVL5883
#
# NOTARY_PROFILE overrides the profile name. TAP_DIR, if set to a local clone of
# thestratcore/homebrew-tap, gets its cask's version and sha256 bumped at the end.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>, e.g. 1.1}"
PROFILE="${NOTARY_PROFILE:-stratisland}"
APP="build/StratIsland.app"
ZIP="build/StratIsland-$VERSION.zip"
DMG_VERSIONED="build/StratIsland-$VERSION.dmg"
DMG_FIXED="build/StratIsland.dmg"   # permanent name for the README's latest-download link

SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
[ -n "$SIGN_IDENTITY" ] \
  || { echo "no Developer ID Application identity in the keychain"; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || { echo "notarytool profile '$PROFILE' missing — see the header of this script"; exit 1; }

VERSION="$VERSION" ./package.sh

# notarytool takes a zip; ditto keeps the bundle's extended attributes and symlinks intact,
# which plain zip does not.
echo "==> notarizing the app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

# Stapling puts the ticket inside the bundle so Gatekeeper can check it offline. The zip
# sent to Apple predates the ticket, so it is rebuilt from the stapled app — and the DMG
# below is built from this same stapled copy, so it never needs its own staple on the app.
echo "==> stapling the app"
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> building the DMG"
STAGE="$(mktemp -d)/StratIsland"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG_VERSIONED"
hdiutil create -volname "StratIsland" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG_VERSIONED"
rm -rf "$(dirname "$STAGE")"

# A disk image gets its own signature — separate from the app's, which is unaffected.
echo "==> signing the DMG"
codesign --force --sign "$SIGN_IDENTITY" "$DMG_VERSIONED"

echo "==> notarizing the DMG"
xcrun notarytool submit "$DMG_VERSIONED" --keychain-profile "$PROFILE" --wait

echo "==> stapling the DMG"
xcrun stapler staple "$DMG_VERSIONED"
cp "$DMG_VERSIONED" "$DMG_FIXED"

echo "==> gatekeeper check"
spctl --assess --type execute --verbose "$APP"
spctl -a -t open --context context:primary-signature -v "$DMG_VERSIONED"

if [ -n "${TAP_DIR:-}" ] && [ -f "$TAP_DIR/Casks/stratisland.rb" ]; then
  echo "==> bumping the Homebrew cask in $TAP_DIR"
  SHA256="$(shasum -a 256 "$DMG_VERSIONED" | awk '{print $1}')"
  sed -i '' \
    -e "s/version \".*\"/version \"$VERSION\"/" \
    -e "s/sha256 \".*\"/sha256 \"$SHA256\"/" \
    "$TAP_DIR/Casks/stratisland.rb"
  echo "    updated version=$VERSION sha256=$SHA256"
  echo "    review and push: (cd \"$TAP_DIR\" && git commit -am 'stratisland $VERSION' && git push)"
else
  echo "==> TAP_DIR not set or cask not found — skipping the Homebrew cask bump"
fi

echo
echo "==> done: $DMG_FIXED, $DMG_VERSIONED, $ZIP"
echo "    publish with: gh release create v$VERSION $DMG_VERSIONED $DMG_FIXED $ZIP \\"
echo "        --title v$VERSION --generate-notes"
