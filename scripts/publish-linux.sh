#!/usr/bin/env bash
# Publie l'archive Linux sur le dépôt public de releases, sous un lien qui ne change pas.
#
#   scripts/release-linux.sh          # d'abord : construit l'archive
#   scripts/publish-linux.sh          # ensuite : la pousse sur GitHub
#
# Deux releases sont touchées, comme pour le Mac (scripts/publish-mac.sh) :
#   - `linux-latest` : un seul asset, `Correspondance-linux-x86_64.tar.gz`, écrasé à chaque fois.
#     C'est le lien du site :
#     https://github.com/menufactory43/correspondance-releases/releases/download/linux-latest/Correspondance-linux-x86_64.tar.gz
#   - `linux-<version>` : l'archive de cette version, sous son nom versionné.
#
# Les tags `relais-*` sont au Relais, `mac-*` au Mac, `linux-*` à nous. On ne marque
# jamais une release Linux comme « latest » du dépôt, ce mot appartient au Relais.
set -euo pipefail
cd "$(dirname "$0")/.."

DEPOT="${CORRESPONDANCE_DEPOT:-menufactory43/correspondance-releases}"
VERSION="$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')"
BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')"
ARCH="x86_64"
TARBALL="build/release/Correspondance-${VERSION}-linux-${ARCH}.tar.gz"
STABLE="build/release/Correspondance-linux-${ARCH}.tar.gz"

[ -f "$TARBALL" ] || { echo "✗ $TARBALL absent — lance scripts/release-linux.sh d'abord"; exit 1; }
cp -f "$TARBALL" "$STABLE"

NOTES="$(mktemp)"
cat > "$NOTES" <<EOF2
Correspondance pour Linux ${VERSION} (build ${BUILD}) — x86_64, binaire statique, toute distribution.

Décompresser, puis \`./install.sh\` : tout va dans ~/.local (binaire, interface, entrée de menu). Lancer \`correspondance\` : l'inbox s'ouvre dans le navigateur, sur 127.0.0.1 seulement.

Lien stable, toujours la dernière version :
https://github.com/${DEPOT}/releases/download/linux-latest/Correspondance-linux-${ARCH}.tar.gz
EOF2

TAG_V="linux-${VERSION}"
if gh release view "$TAG_V" --repo "$DEPOT" >/dev/null 2>&1; then
  gh release upload "$TAG_V" "$TARBALL" --repo "$DEPOT" --clobber
  gh release edit "$TAG_V" --repo "$DEPOT" --notes-file "$NOTES" >/dev/null
else
  gh release create "$TAG_V" "$TARBALL" --repo "$DEPOT" --title "Correspondance pour Linux ${VERSION}" --notes-file "$NOTES" --latest=false
fi

if gh release view linux-latest --repo "$DEPOT" >/dev/null 2>&1; then
  gh release upload linux-latest "$STABLE" --repo "$DEPOT" --clobber
  gh release edit linux-latest --repo "$DEPOT" --title "Correspondance pour Linux — dernière version (${VERSION})" --notes-file "$NOTES" >/dev/null
else
  gh release create linux-latest "$STABLE" --repo "$DEPOT" --title "Correspondance pour Linux — dernière version (${VERSION})" --notes-file "$NOTES" --latest=false
fi
rm -f "$NOTES" "$STABLE"

echo
echo "✅ https://github.com/${DEPOT}/releases/download/linux-latest/Correspondance-linux-${ARCH}.tar.gz  →  ${VERSION} (${BUILD})"
