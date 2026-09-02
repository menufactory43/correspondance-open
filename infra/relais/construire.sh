#!/usr/bin/env bash
# Correspondance — construit les binaires du Relais que nous publions, depuis
# les sources épinglées, et les dépose dans un dossier de publication avec un
# SHA256SUMS. Rien n'est poussé nulle part : publier est une autre décision
# (infra/relais/publier.sh).
#
#   bash infra/relais/construire.sh                       # tout, dans ~/unclic-publication
#   bash infra/relais/construire.sh --quoi ponts          # les quatre ponts seulement
#   bash infra/relais/construire.sh --quoi continuwuity   # le homeserver macOS seulement
#   bash infra/relais/construire.sh --quoi tailcat        # le mandataire macOS seulement
#   bash infra/relais/construire.sh --quoi sommes         # ne fait que régénérer SHA256SUMS
#   bash infra/relais/construire.sh --sortie /tmp/pub --src /tmp/src
#
# Deux choses, et pourquoi elles sont ici plutôt qu'amont.
#
# 1. **Continuwuity ne publie aucun binaire macOS** (phase 1) : l'amont ne
#    connaît que Linux, et les fonctionnalités par défaut supposent Linux
#    (io_uring, systemd, journald). On construit donc au même tag, avec la ligne
#    de fonctionnalités qui passe sur Darwin.
# 2. **Tailcat ne publie aucun binaire macOS** (phase 7a) : la release v0.4.0
#    porte Linux et Windows, et macOS y passe par un tap Homebrew — que le spike
#    s'interdit dans la pile livrée. On construit donc au même tag. C'est ce
#    binaire-là que l'app embarque (`Contents/Helpers/tailcat`), et l'installeur
#    Linux, lui, prend l'archive amont.
# 3. **Les ponts mautrix officiels chargent encore libolm** (`@rpath/libolm.3.dylib`),
#    abandonnée amont depuis 2024 pour faiblesses cryptographiques et retirée de
#    Homebrew. `-tags goolm` remplace la bibliothèque C par l'implémentation Go
#    de mautrix : plus de dylib à poser, à signer, à notariser.
#
# Ce script est un outil de **construction**, pas une partie de la pile livrée :
# il demande Go, cargo et git. `install.sh`, lui, ne construit jamais rien.
set -euo pipefail

CONTINUWUITY_TAG=v26.8.1
MAUTRIX_TAG=v0.2608.0
TAILCAT_TAG=v0.4.0
TAILCAT_GIT=https://github.com/tailscale/tailcat.git
CONTINUWUITY_GIT=https://forgejo.ellis.link/continuwuation/continuwuity.git
# La ligne de la phase 3, § 8 — mot pour mot.
CONTINUWUITY_FEATURES=brotli_compression,element_hacks,gzip_compression,media_thumbnail,ring,url_preview,zstd_compression,bindgen-runtime,console

SORTIE="${CORRESPONDANCE_PUBLICATION:-$HOME/unclic-publication}"
SRC="${CORRESPONDANCE_SRC:-$HOME/.correspondance-unclic-src}"
QUOI=tout
CIBLES="darwin-arm64 linux-amd64"

while [ $# -gt 0 ]; do
  case "$1" in
    --sortie) SORTIE="$2"; shift ;;
    --src) SRC="$2"; shift ;;
    --quoi) QUOI="$2"; shift ;;
    --cibles) CIBLES="$2"; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "!! option inconnue : $1" >&2; exit 2 ;;
  esac
  shift
done

case "$QUOI" in tout|ponts|continuwuity|tailcat|sommes) ;; *) echo "!! --quoi : tout | ponts | continuwuity | tailcat | sommes" >&2; exit 2 ;; esac

dire() { printf '→ %s\n' "$*"; }
mourir() { printf '✗ %s\n' "$*" >&2; exit 1; }
somme() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || sha256sum "$1" | awk '{print $1}'; }
chrono() { date +%s; }
duree() { printf '%dm%02ds' $(( ($2 - $1) / 60 )) $(( ($2 - $1) % 60 )); }

mkdir -p "$SORTIE" "$SRC"
JOURNAL="$SORTIE/construction.log"
: > "$JOURNAL"
mesure() { printf '%-34s %10s  %12s o  %s\n' "$1" "$2" "$3" "$4" >> "$JOURNAL"; }

# Homebrew met Go dans /opt/homebrew/bin, qui n'est pas toujours dans le PATH
# d'un shell non interactif.
export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"

# --------------------------------------------------------- sources épinglées
cloner() {
  local url="$1" tag="$2" dossier="$SRC/$3"
  if [ -d "$dossier/.git" ]; then
    dire "$3 : sources déjà là ($(git -C "$dossier" describe --tags --always 2>/dev/null || echo '?'))"
  else
    dire "$3 : clone $tag"
    git clone --depth 1 -b "$tag" "$url" "$dossier" 2>&1 | tail -1
  fi
}

# =========================================================== 1. Continuwuity
construire_continuwuity() {
  command -v cargo >/dev/null || mourir "cargo est nécessaire (rustup ; le rust-toolchain.toml du dépôt épingle la version)"
  cloner "$CONTINUWUITY_GIT" "$CONTINUWUITY_TAG" continuwuity
  local d="$SRC/continuwuity" t0 t1
  t0=$(chrono)
  dire "cargo build --release --no-default-features --features $CONTINUWUITY_FEATURES"
  ( cd "$d" && cargo build --release --no-default-features --features "$CONTINUWUITY_FEATURES" ) \
    || mourir "la construction de Continuwuity a échoué"
  t1=$(chrono)
  # Le binaire s'appelle encore `conduwuit` : le projet a changé de nom, pas sa cible.
  local bin="$d/target/release/conduwuit"
  [ -f "$bin" ] || mourir "binaire introuvable : $bin"
  cp -f "$bin" "$SORTIE/continuwuity-macos-arm64"
  chmod 755 "$SORTIE/continuwuity-macos-arm64"
  dire "continuwuity-macos-arm64 : $(duree "$t0" "$t1"), $(somme "$SORTIE/continuwuity-macos-arm64")"
  mesure continuwuity-macos-arm64 "$(duree "$t0" "$t1")" \
    "$(wc -c < "$SORTIE/continuwuity-macos-arm64" | tr -d ' ')" "$(somme "$SORTIE/continuwuity-macos-arm64")"
}

# =============================================================== 2. Tailcat
# `-trimpath` pour que le binaire ne porte pas les chemins de cette machine :
# il est publié, il n'a pas à dire où vit le dossier personnel de qui l'a
# construit. Go est reproductible à condition d'une même version de Go et d'un
# même tag ; la somme est relevée à chaque construction, comme pour les ponts.
construire_tailcat() {
  command -v go >/dev/null || mourir "go est nécessaire (brew install go — pour construire, pas pour installer)"
  cloner "$TAILCAT_GIT" "$TAILCAT_TAG" tailcat
  local d="$SRC/tailcat" t0 t1
  t0=$(chrono)
  ( cd "$d" && GOFLAGS=-trimpath GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 \
      go build -o "$SORTIE/tailcat-darwin-arm64" ./cmd/tailcat ) \
    || mourir "tailcat-darwin-arm64 : la construction a échoué"
  t1=$(chrono)
  chmod 755 "$SORTIE/tailcat-darwin-arm64"
  dire "tailcat-darwin-arm64 : $(duree "$t0" "$t1"), $(somme "$SORTIE/tailcat-darwin-arm64")"
  mesure tailcat-darwin-arm64 "$(duree "$t0" "$t1")" \
    "$(wc -c < "$SORTIE/tailcat-darwin-arm64" | tr -d ' ')" "$(somme "$SORTIE/tailcat-darwin-arm64")"
}

# ================================================================ 3. les ponts
# Un pont, une cible. `maubuild` est l'outil du dépôt lui-même (déclaré en
# `tool` dans go.mod) : il pose les ldflags de version que `--version` affiche,
# et lit TARGET_GOOS/TARGET_GOARCH pour croiser.
#
# **`CGO_ENABLED=0` ne marche pas, et goolm n'y change rien.** goolm retire la
# seule dépendance C que nous visions — libolm —, mais deux autres restent :
# `github.com/mattn/go-sqlite3` (la base des ponts) et `go.mau.fi/webp` (les
# vignettes). Sans cgo, la construction s'arrête sur « undefined: sqlite3.Error »
# et « undefined: webpDecodeRGB ». cgo est donc obligatoire, et croiser vers
# Linux demande un compilateur C croisé : `zig cc` en tient lieu (une seule
# commande, pas de chaîne à monter), sur la machine de construction seulement.
compilateur_croise() {
  case "$1" in
    linux-amd64) echo "x86_64-linux-musl" ;;
    linux-arm64) echo "aarch64-linux-musl" ;;
    *) echo "" ;;
  esac
}

pont() {
  local depot="$1" binaire="$2" cible="$3" nom_sortie="$4"
  local d="$SRC/$depot" goos goarch t0 t1 cible_zig
  case "$cible" in
    darwin-arm64) goos=darwin; goarch=arm64 ;;
    linux-amd64)  goos=linux;  goarch=amd64 ;;
    linux-arm64)  goos=linux;  goarch=arm64 ;;
    *) mourir "cible inconnue : $cible" ;;
  esac
  cible_zig="$(compilateur_croise "$cible")"
  local -a env_c=()
  if [ -n "$cible_zig" ]; then
    command -v zig >/dev/null || {
      echo "   ($nom_sortie : non construit — zig absent, et cgo est obligatoire pour croiser ; brew install zig)"
      return 0; }
    env_c=(CC="zig cc -target $cible_zig" CXX="zig c++ -target $cible_zig")
  fi
  t0=$(chrono)
  ( cd "$d" && env BINARY_NAME="$binaire" TARGET_GOOS="$goos" TARGET_GOARCH="$goarch" CGO_ENABLED=1 \
      ${env_c[@]+"${env_c[@]}"} go tool maubuild -tags goolm -o "$SORTIE/$nom_sortie" ) \
    || mourir "$nom_sortie : la construction a échoué"
  t1=$(chrono)
  chmod 755 "$SORTIE/$nom_sortie"
  dire "$nom_sortie : $(duree "$t0" "$t1"), $(somme "$SORTIE/$nom_sortie")"
  mesure "$nom_sortie" "$(duree "$t0" "$t1")" \
    "$(wc -c < "$SORTIE/$nom_sortie" | tr -d ' ')" "$(somme "$SORTIE/$nom_sortie")"
}

# Signal a une dépendance C de plus que les autres : libsignal, du Rust exposé en
# C et lié statiquement (`libsignal_ffi.a`, ~100 Mo, un sous-module git). Croiser
# vers Linux demanderait donc AUSSI une cible Rust `x86_64-unknown-linux-musl` et
# la reconstruction complète de libsignal pour elle — c'est-à-dire un conteneur.
# On construit donc Signal pour l'hôte seulement, et on le dit.
pont_signal() {
  local cible="$1" nom_sortie="$2"
  local d="$SRC/mautrix-signal" t0 t1
  local hote_goos hote_goarch
  hote_goos="$(go env GOOS)"; hote_goarch="$(go env GOARCH)"
  case "$cible" in
    "$hote_goos-$hote_goarch"|darwin-arm64) ;;
    *) echo "   (Signal $cible : non construit — libsignal est en cgo, croiser demande un conteneur ; voir phase-6.md)"
       return 0 ;;
  esac
  command -v cargo >/dev/null || mourir "cargo est nécessaire pour libsignal"
  t0=$(chrono)
  if [ ! -f "$d/libsignal_ffi.a" ]; then
    dire "mautrix-signal : libsignal (Rust, sous-module) — c'est le morceau long"
    ( cd "$d" && ./build-rust.sh ) || mourir "libsignal : la construction a échoué"
    cp -f "$d/pkg/libsignalgo/libsignal/target/release/libsignal_ffi.a" "$d/libsignal_ffi.a"
  else
    dire "mautrix-signal : libsignal_ffi.a déjà là, réutilisée"
  fi
  ( cd "$d" && BINARY_NAME=mautrix-signal LIBRARY_PATH=".:${LIBRARY_PATH:-}" CGO_ENABLED=1 \
      go tool maubuild -tags goolm -o "$SORTIE/$nom_sortie" ) \
    || mourir "$nom_sortie : la construction a échoué"
  t1=$(chrono)
  chmod 755 "$SORTIE/$nom_sortie"
  dire "$nom_sortie : $(duree "$t0" "$t1"), $(somme "$SORTIE/$nom_sortie")"
  mesure "$nom_sortie" "$(duree "$t0" "$t1")" \
    "$(wc -c < "$SORTIE/$nom_sortie" | tr -d ' ')" "$(somme "$SORTIE/$nom_sortie")"
}

construire_ponts() {
  command -v go >/dev/null || mourir "go est nécessaire (brew install go — pour construire, pas pour installer)"
  dire "go $(go version | awk '{print $3}')"
  cloner https://github.com/mautrix/whatsapp.git "$MAUTRIX_TAG" mautrix-whatsapp
  cloner https://github.com/mautrix/signal.git   "$MAUTRIX_TAG" mautrix-signal
  cloner https://github.com/mautrix/meta.git     "$MAUTRIX_TAG" mautrix-meta
  for cible in $CIBLES; do
    dire "— cible $cible"
    pont mautrix-whatsapp mautrix-whatsapp  "$cible" "mautrix-whatsapp-$cible"
    # Instagram et Messenger sont le MÊME dépôt et le même tag, mais deux
    # binaires (cmd/mautrix-instagram et cmd/mautrix-meta) : depuis v26.08 un
    # binaire ne fait plus qu'un réseau.
    pont mautrix-meta     mautrix-instagram "$cible" "mautrix-instagram-$cible"
    pont mautrix-meta     mautrix-meta      "$cible" "mautrix-meta-$cible"
    pont_signal "$cible" "mautrix-signal-$cible"
  done
}

# ============================================================== 4. les scripts
# `relais-install.sh` et `relais-uninstall.sh` sont publiés **avec** les binaires
# qu'ils posent : c'est ce qui rend leurs sha256 vérifiables. Un installeur
# publié à part d'une release pointerait sur des sommes qu'il ne connaît pas.
scripts() {
  local ici; ici="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cp -f "$ici/install.sh" "$SORTIE/relais-install.sh"
  cp -f "$ici/uninstall.sh" "$SORTIE/relais-uninstall.sh"
  dire "relais-install.sh et relais-uninstall.sh copiés depuis $ici"
}

# ================================================================ 5. les sommes
sommes() {
  ( cd "$SORTIE" && rm -f SHA256SUMS &&
    for f in *; do
      # `NOTES.md` sert de corps à la release, il n'en est pas un fichier :
      # lui donner une somme publierait un contrôle sur un absent.
      case "$f" in SHA256SUMS|NOTES.md|construction.log|*.log) continue ;; esac
      printf '%s  %s\n' "$(somme "$f")" "$f"
    done > SHA256SUMS )
  dire "SHA256SUMS régénéré :"
  sed 's/^/     /' "$SORTIE/SHA256SUMS"
}

DEBUT=$(chrono)
case "$QUOI" in
  continuwuity) construire_continuwuity; scripts ;;
  ponts)        construire_ponts; scripts ;;
  tailcat)      construire_tailcat; scripts ;;
  tout)         construire_continuwuity; construire_tailcat; construire_ponts; scripts ;;
  sommes)       scripts ;;
esac
sommes
FIN=$(chrono)

echo
echo "✓ construit en $(duree "$DEBUT" "$FIN") dans $SORTIE"
echo "  Mesures : $JOURNAL"
echo "  Les ponts macOS ne chargent plus libolm : otool -L $SORTIE/mautrix-whatsapp-darwin-arm64"
echo "  Le mandataire que l'app embarque : $SORTIE/tailcat-darwin-arm64 (phase de build « Embed tailcat »)"
echo "  Publier (rien n'est poussé sans le dire) : bash infra/relais/publier.sh --dry-run"
