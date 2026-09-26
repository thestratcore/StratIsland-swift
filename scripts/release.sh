#!/bin/bash
# Builds, signs, notarizes and staples StratIsland.app, leaving a zip ready to attach to a
# GitHub Release. Publishing is deliberately left to you: this script never pushes.
#
#   ./scripts/release.sh 1.1
#
# Needs a Developer ID Application identity in the keychain and a notarytool credential
# profile, created once with:
#
#   xcrun notarytool store-credentials stratisland --apple-id <id> --team-id 78KDVL5883
#
# NOTARY_PROFILE overrides the profile name.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>, e.g. 1.1}"
PROFILE="${NOTARY_PROFILE:-stratisland}"
APP="build/StratIsland.app"
ZIP="build/StratIsland-$VERSION.zip"

security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "no Developer ID Application identity in the keychain"; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || { echo "notarytool profile '$PROFILE' missing — see the header of this script"; exit 1; }

VERSION="$VERSION" ./package.sh

# notarytool takes a zip; ditto keeps the bundle's extended attributes and symlinks intact,
# which plain zip does not.
echo "==> notarizing"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

# Stapling puts the ticket inside the bundle so Gatekeeper can check it offline. The zip
# sent to Apple predates the ticket, so it is rebuilt from the stapled app.
echo "==> stapling"
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> gatekeeper check"
spctl --assess --type execute --verbose "$APP"

echo "==> done: $ZIP"
echo "    publish with: gh release create v$VERSION $ZIP --title v$VERSION --generate-notes"
