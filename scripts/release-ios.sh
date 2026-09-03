#!/usr/bin/env bash
# La build TestFlight de Correspondance iOS : numéro de build incrémenté,
# archive Release, export App Store Connect, envoi par `asc`.
#
#   scripts/release-ios.sh                # incrémente le build, archive, envoie
#   UPLOAD=0 scripts/release-ios.sh       # archive et exporte, sans envoyer
#   BUMP=0 scripts/release-ios.sh         # garde le numéro de build du projet
#
# Ce qu'il faut sur la machine :
#   - la clé d'API d'équipe « Aede » (~/.appstoreconnect/private_keys) : c'est
#     elle qui provisionne l'archive et l'export, pas le compte Apple d'Xcode —
#     ce compte ne voit pas toujours l'équipe (accord en attente chez l'Account
#     Holder, 3 sept. 2026). ASC_KEY_ID / ASC_KEY_PATH / ASC_ISSUER_ID pour
#     en changer ; sans fichier de clé, repli sur le compte Xcode ;
#   - `asc` (brew install rork/tap/asc) avec un profil qui voit l'app
#     com.correspondance.ios — `asc auth doctor` le dit.
#
# Le numéro de build vit dans project.yml (CURRENT_PROJECT_VERSION) : App Store
# Connect refuse tout envoi qui ne le dépasse pas. Le script l'incrémente
# avant d'archiver et laisse la modification dans l'arbre, à commettre avec
# ce que la build embarque — comme la build 3 l'a été.
#
# Le drapeau CORRESPONDANCE_CRYPTO=1 est levé : une build sans chiffrement ne
# se distribue pas. DerivedData à part (build/release/ios/dd), parce qu'un
# DerivedData résolu avec le drapeau ne construit plus sans lui.
set -euo pipefail
cd "$(dirname "$0")/.."

UPLOAD="${UPLOAD:-1}"
BUMP="${BUMP:-1}"
TEAM="AKMNXGVVGX"
APP_ID="6807945434"          # Correspondance, com.correspondance.ios
SCHEME="Correspondance iOS"
OUT="build/release/ios"
DD="$OUT/dd"
ARCHIVE="$OUT/Correspondance-iOS.xcarchive"
EXPORT="$OUT/export"
IPA="$EXPORT/Correspondance.ipa"

etape() { printf '\n▸ %s\n' "$*"; }

ASC_KEY_ID="${ASC_KEY_ID:-P2DPLW2SRN}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-fb365280-db5a-48bb-84b3-98ae481c1235}"
AUTH=()
[ -f "$ASC_KEY_PATH" ] && AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')"
if [ "$BUMP" = "1" ]; then
  BUILD=$((BUILD + 1))
  # perl, pas sed : le `0,/re/` de GNU sed n'existe pas sur macOS, et sed s'y
  # taisait — la build 4 est partie avec un 3 dedans, Apple l'a refusée.
  perl -0pi -e "s/CURRENT_PROJECT_VERSION: \"\\d+\"/CURRENT_PROJECT_VERSION: \"${BUILD}\"/" project.yml
  grep -q "CURRENT_PROJECT_VERSION: \"${BUILD}\"" project.yml || { echo "✗ project.yml n'a pas pris le build ${BUILD}"; exit 1; }
fi
VERSION="$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')"

etape "Projet régénéré, build ${VERSION} (${BUILD})"
xcodegen generate >/dev/null

etape "Archive Release, chiffrement compris"
rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p "$OUT"
CORRESPONDANCE_CRYPTO=1 xcodebuild archive \
  -project Correspondance.xcodeproj -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -derivedDataPath "$DD" -allowProvisioningUpdates "${AUTH[@]}" DEVELOPMENT_TEAM="$TEAM" \
  | grep -E 'error:|ARCHIVE (SUCCEEDED|FAILED)' || true
[ -d "$ARCHIVE" ] || { echo "✗ pas d'archive"; exit 1; }
EMBARQUE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ARCHIVE/Products/Applications/Correspondance.app/Info.plist")"
[ "$EMBARQUE" = "$BUILD" ] || { echo "✗ l'archive porte le build ${EMBARQUE}, pas ${BUILD}"; exit 1; }

etape "Export App Store Connect"
OPTIONS="$OUT/export-options.plist"
cat > "$OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>${TEAM}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$OPTIONS" -allowProvisioningUpdates "${AUTH[@]}" \
  | grep -E 'error:|EXPORT (SUCCEEDED|FAILED)' || true
[ -f "$IPA" ] || { echo "✗ pas d'IPA exporté"; exit 1; }

if [ "$UPLOAD" != "1" ]; then
  echo "IPA prêt, non envoyé : $IPA"
  exit 0
fi

etape "Envoi à App Store Connect (build ${BUILD})"
asc builds upload --app "$APP_ID" --ipa "$IPA" --version "$VERSION" --build-number "$BUILD"

etape "Fait. Le traitement côté Apple prend quelques minutes ; ensuite :"
echo "  asc builds list --app $APP_ID --output table"
echo "  project.yml porte le build ${BUILD} : à commettre avec cette livraison."
