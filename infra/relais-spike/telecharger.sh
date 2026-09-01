#!/usr/bin/env bash
# Correspondance — pose les binaires du Relais du spike, épinglés et vérifiés.
#
#   infra/relais-spike/telecharger.sh
#
# Les ponts mautrix se téléchargent (darwin-arm64 publié en amont, sha256 comparé
# à la valeur épinglée dans config.sh). Continuwuity ne publie que des binaires
# Linux : sur macOS on le construit depuis la source au tag épinglé, avec le
# sous-ensemble de fonctionnalités portable — c'est le coût du spike, il est dit
# dans le rapport.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/config.sh"

mkdir -p "$BIN_DIR" "$SPIKE_HOME/src"

case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) MAUTRIX_SUFFIXE="darwin-arm64" ;;
  Linux/x86_64) MAUTRIX_SUFFIXE="amd64" ;;
  Linux/aarch64) MAUTRIX_SUFFIXE="arm64" ;;
  *) mourir "hôte non prévu : $(uname -s)/$(uname -m)" ;;
esac

poser_pont() {
  local nom="$1" tag="$2" attendu="$3"
  local cible="$BIN_DIR/mautrix-$nom"
  if [[ -x "$cible" ]]; then
    dire "mautrix-$nom déjà posé ($(somme "$cible"))"
    return
  fi
  local url="https://github.com/mautrix/$nom/releases/download/$tag/mautrix-$nom-$MAUTRIX_SUFFIXE"
  dire "mautrix-$nom $tag ← $url"
  curl -fsSL -o "$cible.part" "$url" || mourir "téléchargement de mautrix-$nom impossible"
  local vu; vu="$(somme "$cible.part")"
  if [[ "$vu" != "$attendu" ]]; then
    rm -f "$cible.part"
    mourir "mautrix-$nom : sha256 $vu ≠ $attendu attendu — on n'installe rien"
  fi
  mv "$cible.part" "$cible"
  chmod +x "$cible"
  # macOS met en quarantaine tout ce qui vient du réseau : sans ça le binaire est tué.
  xattr -d com.apple.quarantine "$cible" 2>/dev/null || true
  dire "mautrix-$nom : sha256 $vu ✓"
}

poser_pont whatsapp "$WHATSAPP_TAG" "$WHATSAPP_SHA256"
poser_pont signal "$SIGNAL_TAG" "$SIGNAL_SHA256"

# ---------------------------------------------------------------------- libolm
# Les binaires darwin-arm64 publiés par mautrix ne sont pas autonomes : ils
# chargent `@rpath/libolm.3.dylib`, que Homebrew ne fournit plus (formule retirée,
# libolm étant abandonné en amont). On la construit au tag épinglé et on la pose
# À CÔTÉ du binaire — le rpath sonde le dossier de l'exécutable en premier, donc
# rien n'est installé sur le système.
if [[ "$(uname -s)" == "Darwin" && ! -f "$BIN_DIR/libolm.3.dylib" ]]; then
  command -v cmake >/dev/null || mourir "cmake est nécessaire pour construire libolm"
  OLM="$SPIKE_HOME/src/olm"
  [[ -d "$OLM/.git" ]] || git clone --depth 1 --branch "$OLM_TAG" "$OLM_REPO" "$OLM"
  # libolm 3.2.16 ne compile pas avec Apple clang 21 : une boucle de `operator=`
  # incrémente un `T * const`. Un caractère, dans du code jamais instancié
  # ailleurs, sur un amont qui ne corrigera plus rien.
  sed -i '' 's|        T \* const other_pos = other._data;|        T * other_pos = other._data;|' \
    "$OLM/include/olm/list.hh"
  dire "construction de libolm $OLM_TAG"
  cmake "$OLM" -B "$OLM/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
    -DOLM_TESTS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >"$SPIKE_HOME/build-olm.log" 2>&1
  cmake --build "$OLM/build" -j8 >>"$SPIKE_HOME/build-olm.log" 2>&1 \
    || { tail -20 "$SPIKE_HOME/build-olm.log" >&2; mourir "libolm n'a pas voulu se construire"; }
  cp "$OLM/build/libolm.3.2.16.dylib" "$BIN_DIR/libolm.3.dylib"
  dire "libolm posée : sha256 $(somme "$BIN_DIR/libolm.3.dylib")"
fi

# ------------------------------------------------------------------ Continuwuity
CONDUIT="$BIN_DIR/continuwuity"
if [[ -x "$CONDUIT" ]]; then
  dire "continuwuity déjà posé ($(somme "$CONDUIT"))"
  exit 0
fi

if [[ "$(uname -s)" == "Linux" ]]; then
  case "$(uname -m)" in
    x86_64) ASSET="conduwuit-linux-amd64" ;;
    aarch64) ASSET="conduwuit-linux-arm64" ;;
  esac
  URL="https://forgejo.ellis.link/continuwuation/continuwuity/releases/download/$CONTINUWUITY_TAG/$ASSET"
  dire "continuwuity $CONTINUWUITY_TAG ← $URL"
  curl -fsSL -o "$CONDUIT" "$URL"
  chmod +x "$CONDUIT"
  dire "continuwuity : sha256 $(somme "$CONDUIT")"
  exit 0
fi

# macOS : aucune release binaire en amont, on construit.
command -v cargo >/dev/null || mourir "cargo est nécessaire pour construire Continuwuity sur macOS"
SRC="$SPIKE_HOME/src/continuwuity"
if [[ ! -d "$SRC/.git" ]]; then
  dire "clone de Continuwuity au tag $CONTINUWUITY_TAG"
  git clone --depth 1 --branch "$CONTINUWUITY_TAG" "$CONTINUWUITY_REPO" "$SRC"
fi
dire "commit source : $(git -C "$SRC" rev-parse HEAD)"
dire "construction (cargo build --release, ~20 min à froid) — journal : $SPIKE_HOME/build-continuwuity.log"
( cd "$SRC" && CARGO_TARGET_DIR="$SPIKE_HOME/src/target" \
    cargo build --release --no-default-features --features "$CONTINUWUITY_FEATURES" ) \
  >"$SPIKE_HOME/build-continuwuity.log" 2>&1 || {
    tail -30 "$SPIKE_HOME/build-continuwuity.log" >&2
    mourir "la construction de Continuwuity a échoué"
  }
cp "$SPIKE_HOME/src/target/release/conduwuit" "$CONDUIT"
dire "continuwuity construit : sha256 $(somme "$CONDUIT") ($(du -h "$CONDUIT" | awk '{print $1}'))"
