#!/usr/bin/env bash
# Correspondance pour Linux : un binaire statique croisé depuis ce Mac, l'interface,
# les polices, l'entrée de menu et l'icône, dans une archive prête à installer.
#
#   scripts/release-linux.sh                 # x86_64, chiffrement compris
#   CRYPTO=0 scripts/release-linux.sh        # sans le moteur crypto (dev seulement)
#
# Ce qu'il faut sur la machine :
#   - la chaîne swift.org 6.3.3 : ~/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain
#     (celle d'Xcode ne lit pas les modules du SDK statique) ;
#   - le SDK statique Linux : `swift sdk list` → swift-6.3.3-RELEASE_static-linux-0.1.0 ;
#   - ~/.correspondance-unclic/crypto-linux/x86_64/libmatrix_sdk_crypto_ffi.a
#     (infra/relais/crypto-linux.sh) pour le chiffrement.
#
# Architecture : x86_64 seulement, comme l'agent et les ponts (`linux-amd64`). La
# bibliothèque crypto n'existe pas encore en aarch64 ; un binaire sans chiffrement
# ne se publie pas, pas plus qu'un DMG.
set -euo pipefail
cd "$(dirname "$0")/.."

CRYPTO="${CRYPTO:-1}"
TC="$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin"
SDK="x86_64-swift-linux-musl"
ARCH="x86_64"
CRYPTO_LIB="${CORRESPONDANCE_CRYPTO_LINUX:-$HOME/.correspondance-unclic/crypto-linux/$ARCH}"
PKG="Packages/CorrespondanceCore"
SCRATCH="$PKG/.build-linux-release"
OUT="build/release"
VERSION="$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')"
BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')"
NOM="Correspondance-${VERSION}-linux-${ARCH}"
STAGE="$OUT/$NOM"
TARBALL="$OUT/$NOM.tar.gz"

etape() { printf '\n▸ %s\n' "$*"; }

[ -x "$TC/swift" ] || { echo "✗ chaîne swift.org absente : $TC"; exit 1; }
"$TC/swift" sdk list 2>/dev/null | grep -q static-linux || { echo "✗ SDK statique Linux absent (swift sdk install …static-linux…)"; exit 1; }
if [ "$CRYPTO" = "1" ] && [ ! -f "$CRYPTO_LIB/libmatrix_sdk_crypto_ffi.a" ]; then
  echo "✗ bibliothèque crypto Linux absente : $CRYPTO_LIB — bash infra/relais/crypto-linux.sh"; exit 1
fi

etape "Binaire statique ${VERSION} (${BUILD}), ${ARCH}$([ "$CRYPTO" = "1" ] && echo ', chiffrement compris' || echo ', SANS chiffrement')"
ENV=()
[ "$CRYPTO" = "1" ] && ENV=(CORRESPONDANCE_CRYPTO=1 CORRESPONDANCE_CRYPTO_LINUX="$CRYPTO_LIB")
env ${ENV[@]+"${ENV[@]}"} PATH="$TC:$PATH" "$TC/swift" build \
  --package-path "$PKG" --swift-sdk "$SDK" -c release --product correspondance-linux --scratch-path "$SCRATCH" \
  -Xswiftc -gnone -Xlinker -s 2>&1 | grep -E "error:|warning: unre|Compiling|Build complete|Build of" | tail -5
BIN="$(env ${ENV[@]+"${ENV[@]}"} PATH="$TC:$PATH" "$TC/swift" build --package-path "$PKG" --swift-sdk "$SDK" -c release \
  --product correspondance-linux --scratch-path "$SCRATCH" --show-bin-path)/correspondance-linux"
[ -f "$BIN" ] || { echo "✗ pas de binaire"; exit 1; }
file "$BIN" | grep -q "ELF 64-bit.*x86-64.*statically linked" || { echo "✗ ce n'est pas un ELF statique x86_64 : $(file "$BIN")"; exit 1; }

etape "Archive $NOM"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/share/correspondance" "$STAGE/share/applications" "$STAGE/share/icons/hicolor/512x512/apps"
cp -f "$BIN" "$STAGE/bin/correspondance"
if [ -x "$TC/llvm-strip" ]; then "$TC/llvm-strip" "$STAGE/bin/correspondance"; fi
chmod 755 "$STAGE/bin/correspondance"
cp -R linux/ui "$STAGE/share/correspondance/ui"
mkdir -p "$STAGE/share/correspondance/fonts"
cp -f Correspondance/Resources/Fonts/*.ttf Correspondance/Resources/Fonts/LICENSE-* Correspondance/Resources/Fonts/NOTICE-* "$STAGE/share/correspondance/fonts/"
cp -f linux/correspondance.desktop "$STAGE/share/applications/"
cp -f site/img/icon.png "$STAGE/share/icons/hicolor/512x512/apps/correspondance.png"
cp -f linux/install.sh linux/README.md "$STAGE/"
printf '%s\n' "$VERSION ($BUILD) — $ARCH — $(date -u +%Y-%m-%dT%H:%MZ)" > "$STAGE/VERSION"
rm -f "$TARBALL"
tar -C "$OUT" -czf "$TARBALL" "$NOM"
rm -rf "$STAGE"
echo
echo "✅ $TARBALL ($(du -h "$TARBALL" | cut -f1)) — binaire $(du -h "$BIN" | cut -f1) avant strip"
