#!/bin/bash
# Builds, signs with Developer ID, notarizes and staples EasyDynDNS.app, then zips it into dist/.
#
# One-time setup (credentials stay in your Keychain, never in this repo):
#   xcrun notarytool store-credentials easydyndns-notary \
#     --apple-id <your-apple-id> --team-id <your-team-id> --password <app-specific-password>
#
# Usage: VERSION=1.0.0 scripts/release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${VERSION:?Set VERSION, e.g. VERSION=1.0.0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-easydyndns-notary}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
APP="$ROOT/build/EasyDynDNS.app"
ZIP="$ROOT/dist/EasyDynDNS-$VERSION.zip"

VERSION="$VERSION" SIGN_IDENTITY="$SIGN_IDENTITY" "$ROOT/scripts/build.sh"

mkdir -p "$ROOT/dist"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

# Re-zip so the published archive contains the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"
shasum -a 256 "$ZIP"
echo "Release ready: $ZIP"
