#!/usr/bin/env bash
# Build a distributable Honeycomb.app: universal (Apple Silicon + Intel),
# gateway bundled inside, zipped with a checksum.
#
#   ./Scripts/make_release.sh                 # ad-hoc signed (free)
#   APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#     ./Scripts/make_release.sh               # signed for distribution
#
# An ad-hoc signed app is NOT notarized: on another Mac, Gatekeeper blocks a
# double-click. Users must right-click → Open once (documented in the README).
# Notarizing requires a paid Apple Developer ID; see Scripts/sign-and-notarize
# in the packaging docs if you get one.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source "$ROOT/version.env"

DIST="$ROOT/dist"
rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> Building universal release (arm64 + x86_64)"
ARCHES="arm64 x86_64" SIGNING_MODE="${SIGNING_MODE:-adhoc}" \
  "$ROOT/Scripts/package_app.sh" release

APP="$ROOT/${APP_NAME}.app"
[[ -d "$APP" ]] || { echo "package_app.sh produced no app" >&2; exit 1; }

echo "==> Verifying"
lipo -archs "$APP/Contents/MacOS/$APP_NAME"
codesign --verify --deep --strict "$APP" && echo "signature ok"
[[ -f "$APP/Contents/Resources/gateway/server.py" ]] \
  && echo "gateway bundled ok" \
  || { echo "gateway missing from bundle" >&2; exit 1; }

ZIP="$DIST/${APP_NAME}-${VERSION}-macos-universal.zip"
echo "==> Zipping → $(basename "$ZIP")"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

echo
echo "Release ready:"
echo "  $ZIP"
echo
echo "Install (end user):"
echo "  unzip, drag ${APP_NAME}.app to /Applications,"
echo "  right-click → Open the first time (unsigned app)."
