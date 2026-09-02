#!/usr/bin/env bash
# Correspondance — les deux preuves du chiffrement, phase 2 du spike « un clic ».
#
#   bash infra/relais-spike/preuve-chiffrement.sh
#
# Preuve A : la Note à soi créée chiffrée, un message envoyé, un **processus
#            neuf** (l'app relancée) qui le relit par son /sync.
# Preuve B : une **seconde session du même compte**, magasin de clés vierge,
#            qui ne lit rien — puis qui lit, une fois la clé de salon reçue.
#
# Rien de tout ceci ne touche la prod : le Relais est celui du spike, les
# sessions et les magasins de clés vivent sous $SPIKE_HOME/preuve/.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/config.sh"
RACINE="$(cd "$HERE/../.." && pwd)"

set -a; . "$SPIKE_HOME/secrets.env"; set +a
export RELAIS_URL MATRIX_USER
export PREUVE_HOME="${PREUVE_HOME:-$SPIKE_HOME/preuve}"

# Un dossier de construction **à part** : le drapeau levé et le drapeau éteint
# ne partagent pas leurs modules, sinon un `canImport` reste vrai par accident.
SCRATCH="${SCRATCH:-/tmp/build-unclic-crypto}"
BIN="$SCRATCH/debug/preuve-chiffrement"
if [[ ! -x "$BIN" ]]; then
  dire "construction du banc de preuve (drapeau du chiffrement levé)"
  CORRESPONDANCE_CRYPTO=1 swift build --package-path "$RACINE/Packages/CorrespondanceCore" \
    --scratch-path "$SCRATCH" --product preuve-chiffrement
fi

titre() { printf '\n\033[1m### %s\033[0m\n' "$*"; }

# Un jeu d'appareils neuf à chaque exécution : deux magasins de clés vierges,
# c'est la seule façon d'éprouver le partage plutôt que le cache.
rm -rf "$PREUVE_HOME"

titre "PREUVE A — 1. l'appareil A crée la Note à soi CHIFFRÉE et y écrit"
SORTIE="$("$BIN" envoyer appareilA --nouveau "Preuve A : ce message part chiffré dans la Note à soi.")"
echo "$SORTIE"
SALON="$(printf '%s\n' "$SORTIE" | sed -n 's/^SALON=//p')"

titre "PREUVE A — 2. ce que le Relais stocke vraiment, vu sans le client"
JETON="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["accessToken"])' "$PREUVE_HOME/appareilA/session.json")"
curl -s -H "Authorization: Bearer $JETON" \
  "$RELAIS_URL/_matrix/client/v3/rooms/$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$SALON")/state/m.room.encryption/" \
  | python3 -m json.tool

titre "PREUVE A — 3. processus NEUF (« l'app relancée »), même appareil, même magasin"
"$BIN" lire appareilA "$SALON"

titre "PREUVE B — 1. une SECONDE session du même compte, magasin vierge : elle ne lit rien"
"$BIN" lire appareilB "$SALON" || true

titre "PREUVE B — 2. l'appareil A réécrit : sa machine voit le nouvel appareil et lui porte la clé"
"$BIN" envoyer appareilA "$SALON" "Preuve B : envoyé par A, à lire par la seconde session."

titre "PREUVE B — 3. la seconde session relit : la clé de salon est arrivée"
"$BIN" lire appareilB "$SALON"

printf '\nSalon de la preuve : %s\n' "$SALON"
