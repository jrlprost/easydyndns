#!/bin/bash
# Builds build/EasyDynDNS.app (universal arm64 + x86_64).
# SIGN_IDENTITY: codesign identity, default "-" (ad-hoc). Use "Developer ID Application" for releases.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="$ROOT/build/EasyDynDNS.app"

cd "$ROOT"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/EasyDynDNS"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/EasyDynDNS"
sed "s/__VERSION__/$VERSION/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"

# Hardened runtime + timestamp are required for notarization; skipped for ad-hoc builds.
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP (version $VERSION, signed with: $SIGN_IDENTITY)"
