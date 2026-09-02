#!/usr/bin/env bash
# Correspondance — construit les binaires de l'agent que nous publions et les
# dépose dans le dossier de publication, à côté de ceux du Relais. Rien n'est
# poussé nulle part : publier est une autre décision (infra/relais/publier.sh).
#
#   bash infra/agent/construire.sh                  # les deux tranches
#   bash infra/agent/construire.sh --quoi linux     # Linux x86_64 seulement
#   bash infra/agent/construire.sh --quoi macos     # macOS arm64 seulement
#   bash infra/agent/construire.sh --sortie /tmp/pub
#
# Pourquoi ce script existe : les fichiers de l'agent étaient recopiés à la
# main dans la release. Or `releases/latest/download/<fichier>` ne sert que la
# release la plus récente — publier le Relais seul le 2 septembre a rendu 404 à
# l'installeur de cc pendant vingt minutes. Une release porte tout le produit,
# donc tout le produit doit se construire.
#
# La tranche Linux est **croisée depuis ce Mac** (SDK statique musl), pas
# construite dans un conteneur sur le NUC comme le fait `deploy.sh` : c'est la
# bascule que la conclusion du spike demandait. Le binaire qui en sort est
# statique — aucune version de glibc à respecter chez celui qui l'installe.
#
# La machine crypto est **dedans** (`CORRESPONDANCE_CRYPTO=1`), et c'est un
# choix d'ordre : l'app sait déjà lire et écrire du chiffré (`release-mac.sh`
# lève le même drapeau), mais rien ne crée encore de salon chiffré — le défaut
# de `createSelfRoom(chiffre:)` est faux, et seul le binaire de preuve du spike
# l'a levé. Le jour où le chantier E l'allumera côté app, un agent construit
# sans crypto se retrouverait dans une console qu'il ne sait plus lire : il le
# dirait (« pas de machine crypto dans ce binaire ») mais ne lirait plus sa
# configuration. On rend donc l'agent capable avant que le salon le devienne.
#
# Sous Linux il ne suffit pas du drapeau : `matrix-sdk-crypto-ffi` n'est publié
# qu'en XCFramework de tranches Apple, donc la bibliothèque doit être construite
# (`infra/relais/crypto-linux.sh`, ~2 min, cargo + zig cc, musl comme le SDK
# Swift) et désignée par `CORRESPONDANCE_CRYPTO_LINUX`. Sans elle, ce script
# s'arrête en disant quoi lancer — il ne produit pas en silence un binaire
# moins capable que celui d'hier.
set -euo pipefail

SORTIE="${CORRESPONDANCE_PUBLICATION:-$HOME/unclic-publication}"
ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PAQUET="$ICI/Packages/CorrespondanceCore"
TOOLCHAIN="${CORRESPONDANCE_TOOLCHAIN:-$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain}"
SDK_LINUX="${CORRESPONDANCE_SDK_LINUX:-x86_64-swift-linux-musl}"
CRYPTO_LINUX="${CORRESPONDANCE_CRYPTO_LINUX:-$HOME/.correspondance-unclic/crypto-linux/x86_64}"
QUOI=tout

while [ $# -gt 0 ]; do
  case "$1" in
    --sortie) SORTIE="$2"; shift ;;
    --quoi) QUOI="$2"; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "!! option inconnue : $1" >&2; exit 2 ;;
  esac
  shift
done
case "$QUOI" in tout|linux|macos|scripts) ;; *) echo "!! --quoi : tout | linux | macos | scripts" >&2; exit 2 ;; esac

dire() { echo "  $*"; }
somme() { shasum -a 256 "$1" | awk '{print $1}'; }
mkdir -p "$SORTIE"

echo "Construction de l'agent → $SORTIE"

# Un binaire non dépouillé pèse trois fois son poids utile : 171 Mio contre 55.
# `llvm-objcopy` de la toolchain Swift sait le faire pour un ELF ; le `strip`
# d'Xcode, lui, ne connaît que Mach-O.
depouiller_elf() {
  local objcopy="$TOOLCHAIN/usr/bin/llvm-objcopy"
  [ -x "$objcopy" ] || { dire "llvm-objcopy absent — le binaire reste non dépouillé"; return 0; }
  "$objcopy" --strip-all "$1" "$1.strip" && mv -f "$1.strip" "$1"
}

macos() {
  dire "— macOS arm64 (natif, avec la crypto)"
  CORRESPONDANCE_CRYPTO=1 \
  swift build --package-path "$PAQUET" --product correspondance-agent -c release \
    --scratch-path /tmp/build-agent-macos >/dev/null
  local bin=/tmp/build-agent-macos/release/correspondance-agent
  cp -f "$bin" "$SORTIE/correspondance-agent-macos-arm64"
  strip -x "$SORTIE/correspondance-agent-macos-arm64" 2>/dev/null || true
  chmod 755 "$SORTIE/correspondance-agent-macos-arm64"
  dire "  correspondance-agent-macos-arm64 — $(wc -c < "$SORTIE/correspondance-agent-macos-arm64" | tr -d ' ') o"
}

linux() {
  dire "— Linux x86_64 (croisé, $SDK_LINUX, avec la crypto)"
  [ -x "$TOOLCHAIN/usr/bin/swift" ] || {
    echo "!! toolchain absente : $TOOLCHAIN" >&2
    echo "   (elle porte le SDK statique Linux ; --help dit comment la remplacer)" >&2
    exit 1
  }
  [ -f "$CRYPTO_LINUX/libmatrix_sdk_crypto_ffi.a" ] || {
    echo "!! la machine crypto Linux manque : $CRYPTO_LINUX" >&2
    echo "   La construire (~2 min) : bash infra/relais/crypto-linux.sh" >&2
    exit 1
  }
  CORRESPONDANCE_CRYPTO=1 CORRESPONDANCE_CRYPTO_LINUX="$CRYPTO_LINUX" \
  "$TOOLCHAIN/usr/bin/swift" build --package-path "$PAQUET" \
    --product correspondance-agent -c release --swift-sdk "$SDK_LINUX" \
    --scratch-path /tmp/build-agent-linux >/dev/null
  local bin=/tmp/build-agent-linux/release/correspondance-agent
  cp -f "$bin" "$SORTIE/correspondance-agent-linux-x86_64"
  depouiller_elf "$SORTIE/correspondance-agent-linux-x86_64"
  chmod 755 "$SORTIE/correspondance-agent-linux-x86_64"
  dire "  correspondance-agent-linux-x86_64 — $(wc -c < "$SORTIE/correspondance-agent-linux-x86_64" | tr -d ' ') o"
}

# L'installeur de l'agent est publié **avec** les binaires qu'il pose : c'est ce
# qui rend sa somme vérifiable, et c'est ce que `publier.sh` recompare au dépôt.
scripts() {
  cp -f "$ICI/infra/agent/install.sh" "$SORTIE/install.sh"
  dire "install.sh copié depuis infra/agent/"
}

case "$QUOI" in
  tout)   macos; linux; scripts ;;
  macos)  macos ;;
  linux)  linux ;;
  scripts) scripts ;;
esac

echo
echo "Sommes (SHA256SUMS se régénère par : bash infra/relais/construire.sh --quoi sommes)"
for f in "$SORTIE"/correspondance-agent-* "$SORTIE/install.sh"; do
  [ -f "$f" ] || continue
  printf '  %-34s %s\n' "$(basename "$f")" "$(somme "$f")"
done
