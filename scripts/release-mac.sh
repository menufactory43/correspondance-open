#!/usr/bin/env bash
# Le DMG de Correspondance pour Mac : archive Release, signature Developer ID
# (runtime durci, horodatage), notarisation Apple, ticket agrafé, puis un DMG
# glisser-déposer lui-même signé, notarisé et agrafé.
#
#   scripts/release-mac.sh                # tout, notarisation comprise (quelques minutes)
#   NOTARIZE=0 scripts/release-mac.sh     # signé Developer ID, sans aller-retour Apple
#
# Ce qu'il faut sur la machine, et rien d'autre :
#   - Xcode connecté au compte de l'équipe AKMNXGVVGX (Réglages › Comptes) : c'est
#     lui qui pose la signature Developer ID à l'export, sans profil à la main ;
#   - un profil notarytool dans le Trousseau, nommé par git config correspondance.notaryProfile ;
#   - ~/unclic-publication/tailcat-darwin-arm64 pour que le mandataire soit embarqué
#     (sinon l'app le dit à l'écran, et la build ne casse pas).
#
# Architecture : arm64 seulement. Le mandataire Tailcat et les ponts sont arm64,
# et un Mac Intel n'a pas de Relais local possible aujourd'hui. Un binaire
# universel attendra des helpers universels.
#
# Le drapeau CORRESPONDANCE_CRYPTO=1 est levé ici : un DMG sans chiffrement
# n'existe pas. Et un DerivedData à part (build/release/dd), parce qu'un
# DerivedData résolu avec le drapeau ne construit plus sans lui.
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARIZE="${NOTARIZE:-1}"
# Le nom du profil notarytool est propre à chaque machine : il se lit dans la
# config git locale (git config correspondance.notaryProfile <nom>), jamais
# dans le dépôt. À défaut : « notarisation ».
NOTARY_PROFILE="${NOTARY_PROFILE:-$(git config --get correspondance.notaryProfile 2>/dev/null || echo notarisation)}"
TEAM="AKMNXGVVGX"
SCHEME="Correspondance"
OUT="build/release"
DD="$OUT/dd"
ARCHIVE="$OUT/Correspondance.xcarchive"
EXPORT="$OUT/export"
APP="$EXPORT/Correspondance.app"

VERSION="$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')"
BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')"
DMG="$OUT/Correspondance-${VERSION}.dmg"

etape() { printf '\n▸ %s\n' "$*"; }

etape "Archive Release ${VERSION} (${BUILD}), arm64, chiffrement compris"
rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p "$OUT"
CORRESPONDANCE_CRYPTO=1 xcodebuild archive \
  -project Correspondance.xcodeproj -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  -derivedDataPath "$DD" -allowProvisioningUpdates \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  | grep -E 'error:|warning: tailcat|ARCHIVE (SUCCEEDED|FAILED)' || true
[ -d "$ARCHIVE" ] || { echo "✗ pas d'archive"; exit 1; }

etape "Export Developer ID (Xcode re-signe l'app et ses helpers)"
OPTIONS="$OUT/export-options.plist"
cat > "$OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>${TEAM}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$OPTIONS" -allowProvisioningUpdates \
  | grep -E 'error:|EXPORT (SUCCEEDED|FAILED)' || true
[ -d "$APP" ] || { echo "✗ pas d'app exportée"; exit 1; }

etape "Vérification de la signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "^Authority=Developer ID Application" | head -1 || { echo "✗ pas de signature Developer ID"; exit 1; }
if [ -x "$APP/Contents/Helpers/tailcat" ]; then
  codesign -dvv "$APP/Contents/Helpers/tailcat" 2>&1 | grep -q 'Developer ID' && echo "   tailcat embarqué et signé"
else
  echo "   tailcat absent du bundle (l'app le dira à l'écran)"
fi

if [ "$NOTARIZE" = "1" ]; then
  etape "Notarisation de l'app (profil « ${NOTARY_PROFILE} »)"
  ZIP="$OUT/Correspondance-notarize.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait | grep -E 'id:|status:' | tail -2
  rm -f "$ZIP"
  xcrun stapler staple "$APP" | tail -1
fi

etape "DMG"
STAGING="$OUT/dmg-staging"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Correspondance" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
codesign --force --timestamp --sign "Developer ID Application" "$DMG"

if [ "$NOTARIZE" = "1" ]; then
  etape "Notarisation du DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait | grep -E 'id:|status:' | tail -2
  xcrun stapler staple "$DMG" | tail -1
  etape "Ce que Gatekeeper en dit"
  spctl -a -vvv -t install "$DMG" 2>&1 | grep -E 'accepted|rejected|source='
  spctl -a -vvv -t exec "$APP" 2>&1 | grep -E 'accepted|rejected|source='
  echo
  echo "✅ $DMG — notarisé et agrafé ($(du -h "$DMG" | cut -f1))"
else
  echo
  echo "✅ $DMG — signé Developer ID, non notarisé ($(du -h "$DMG" | cut -f1))"
fi
