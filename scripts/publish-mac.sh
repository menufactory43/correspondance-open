#!/usr/bin/env bash
# Publie le DMG Mac sur le dépôt public de releases, sous un lien qui ne change pas.
#
#   scripts/release-mac.sh          # d'abord : construit, signe, notarise le DMG
#   scripts/publish-mac.sh          # ensuite : le pousse sur GitHub
#
# Deux releases sont touchées :
#   - `mac-latest` : un seul asset, `Correspondance.dmg`, écrasé à chaque fois.
#     C'est le lien du site :
#     https://github.com/menufactory43/correspondance-releases/releases/download/mac-latest/Correspondance.dmg
#   - `mac-<version>` : l'archive de cette version, avec le DMG sous son nom versionné.
#
# Le dépôt est celui du Relais (infra/relais/publier.sh) : ses tags sont `relais-*`,
# les nôtres `mac-*`, ils ne se marchent pas dessus. On ne marque jamais une release
# Mac comme « latest » du dépôt, ce mot appartient au Relais.
set -euo pipefail
cd "$(dirname "$0")/.."

DEPOT="${CORRESPONDANCE_DEPOT:-menufactory43/correspondance-releases}"
VERSION="$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')"
BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')"
DMG="build/release/Correspondance-${VERSION}.dmg"
STABLE="build/release/Correspondance.dmg"

[ -f "$DMG" ] || { echo "✗ $DMG absent — lance scripts/release-mac.sh d'abord"; exit 1; }
spctl -a -t install "$DMG" >/dev/null 2>&1 || { echo "✗ $DMG n'est pas notarisé, je ne publie pas"; exit 1; }
cp -f "$DMG" "$STABLE"

NOTES="$(mktemp)"
cat > "$NOTES" <<EOF
Correspondance pour Mac ${VERSION} (build ${BUILD}) — Apple Silicon, macOS 14 et plus.

Signé Developer ID et notarisé. Glisser l'app dans Applications, puis l'ouvrir.

Lien stable, toujours la dernière version :
https://github.com/${DEPOT}/releases/download/mac-latest/Correspondance.dmg
EOF

TAG_V="mac-${VERSION}"
if gh release view "$TAG_V" --repo "$DEPOT" >/dev/null 2>&1; then
  gh release upload "$TAG_V" "$DMG" --repo "$DEPOT" --clobber
  gh release edit "$TAG_V" --repo "$DEPOT" --notes-file "$NOTES" >/dev/null
else
  gh release create "$TAG_V" "$DMG" --repo "$DEPOT" --title "Correspondance pour Mac ${VERSION}" --notes-file "$NOTES" --latest=false
fi

if gh release view mac-latest --repo "$DEPOT" >/dev/null 2>&1; then
  gh release upload mac-latest "$STABLE" --repo "$DEPOT" --clobber
  gh release edit mac-latest --repo "$DEPOT" --title "Correspondance pour Mac — dernière version (${VERSION})" --notes-file "$NOTES" >/dev/null
else
  gh release create mac-latest "$STABLE" --repo "$DEPOT" --title "Correspondance pour Mac — dernière version (${VERSION})" --notes-file "$NOTES" --latest=false
fi
rm -f "$NOTES" "$STABLE"

echo
echo "✅ https://github.com/${DEPOT}/releases/download/mac-latest/Correspondance.dmg  →  ${VERSION} (${BUILD})"
