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
# La signature passe par une clé d'API d'équipe App Store Connect plutôt que par
# le compte Apple d'Xcode : ce compte-là ne voit pas toujours l'équipe (accord
# de programme en attente chez l'Account Holder, et Xcode barre alors
# « Certificates, Identifiers & Profiles » — vécu le 3 sept. 2026). La clé,
# elle, provisionne toujours, capacités nouvelles comprises. Clé « Aede » de
# l'équipe, la même qu'`asc` ; l'issuer est celui de l'équipe, pas un secret.
ASC_KEY_ID="${ASC_KEY_ID:-P2DPLW2SRN}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-fb365280-db5a-48bb-84b3-98ae481c1235}"
AUTH=()
if [ -f "$ASC_KEY_PATH" ]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
else
  echo "  (pas de clé $ASC_KEY_PATH : signature par le compte Xcode)"
fi
set +e
CORRESPONDANCE_CRYPTO=1 xcodebuild build \
  -project Correspondance.xcodeproj -scheme "$SCHEME" -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath "$DD" -allowProvisioningUpdates \
  ${AUTH[@]+"${AUTH[@]}"} DEVELOPMENT_TEAM=AKMNXGVVGX \
  | grep -E 'error:|BUILD (SUCCEEDED|FAILED)'
BUILD_STATUS="${PIPESTATUS[0]}"
set -e
# Une build ratée laisse l'app PRÉCÉDENTE dans DerivedData : sans cette garde,
# le script installait tranquillement l'ancienne et disait « lancée ».
[ "$BUILD_STATUS" -eq 0 ] || { echo "✗ build échouée — rien d'installé"; exit 1; }
APP="$DD/Build/Products/Debug-iphoneos/Correspondance.app"
[ -d "$APP" ] || { echo "✗ pas d'app construite"; exit 1; }

etape "Installation et lancement"
xcrun devicectl device install app --device "$DEVICE" "$APP" | grep -E 'installed|error' || true
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" | grep -E 'Launched|error' || true
