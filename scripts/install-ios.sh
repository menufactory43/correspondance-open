#!/usr/bin/env bash
# La build Debug de Correspondance iOS posée sur un iPhone branché, sans Xcode
# ouvert : build, installation, lancement.
#
#   scripts/install-ios.sh                # sur le premier iPhone appairé
#   scripts/install-ios.sh "iPhone de."   # sur celui-là (nom ou identifiant)
#
# Debug, signature de développement : c'est la build qui parle à la passerelle
# push sandbox (`com.correspondance.ios.dev`). Rien à voir avec TestFlight —
# pour ça, scripts/release-ios.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

WANTED="${1:-}"
SCHEME="Correspondance iOS"
DD="build/release/ios/dd-device"
BUNDLE="com.correspondance.ios"

etape() { printf '\n▸ %s\n' "$*"; }

etape "Appareil"
if [ -n "$WANTED" ]; then
  DEVICE="$(xcrun devicectl list devices 2>/dev/null | grep -F "$WANTED" | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)"
else
  DEVICE="$(xcrun devicectl list devices 2>/dev/null | grep -i iphone | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)"
fi
[ -n "$DEVICE" ] || { echo "✗ aucun iPhone appairé (xcrun devicectl list devices)"; exit 1; }
echo "  $DEVICE"

etape "Build Debug, chiffrement compris"
xcodegen generate >/dev/null
CORRESPONDANCE_CRYPTO=1 xcodebuild build \
  -project Correspondance.xcodeproj -scheme "$SCHEME" -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath "$DD" -allowProvisioningUpdates \
  | grep -E 'error:|BUILD (SUCCEEDED|FAILED)' || true
APP="$DD/Build/Products/Debug-iphoneos/Correspondance.app"
[ -d "$APP" ] || { echo "✗ pas d'app construite"; exit 1; }

etape "Installation et lancement"
xcrun devicectl device install app --device "$DEVICE" "$APP" | grep -E 'installed|error' || true
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" | grep -E 'Launched|error' || true
