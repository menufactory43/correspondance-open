#!/usr/bin/env bash
# Phase 5, livrable 1 — `cc` lit et écrit chiffré.
#
# Ce que la phase 4 a mesuré : dans une note à soi chiffrée, `cc` ne journalise
# rien, ne répond rien, et ne dit pas pourquoi. Ce script rejoue exactement la
# même scène avec un `correspondance-agent` construit avec la machine crypto, et
# vérifie les quatre choses que la phase 5 demande :
#
#   1. la note à soi est chiffrée (m.room.encryption posé à la création) ;
#   2. « @cc ping » chiffré → « pong » ;
#   3. le journal des tours s'écrit dans la console (chiffrée elle aussi) ;
#   4. la réponse de cc est stockée **chiffrée** sur le Relais — vu par curl,
#      sans le client.
#
# Prérequis : le Relais du spike posé (infra/relais/install.sh), le paquet
# construit avec CORRESPONDANCE_CRYPTO=1 dans /tmp/build-unclic-crypto.
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.correspondance-unclic}"
RELAIS_URL="${RELAIS_URL:-http://127.0.0.1:8010}"
SERVEUR="${SERVEUR:-unclic.local}"
BUILD="${BUILD:-/tmp/build-unclic-crypto/debug}"
AGENT_HOME="${AGENT_HOME:-$HOME/.correspondance-agent-unclic}"
JOURNAL="${JOURNAL:-/tmp/correspondance-cc.unclic.log}"
RACINE="$(cd "$(dirname "$0")/../.." && pwd)"

B="$BUILD/preuve-chiffrement"
[ -x "$B" ] || { echo "✗ $B manquant — CORRESPONDANCE_CRYPTO=1 swift build … --scratch-path /tmp/build-unclic-crypto"; exit 1; }
[ -x "$BUILD/correspondance-agent" ] || { echo "✗ correspondance-agent manquant dans $BUILD"; exit 1; }

# shellcheck disable=SC1090
set -a; . "$PREFIX/secrets.env"; set +a
JETON=$(PREFIX="$PREFIX" python3 -c 'import json,os;print(json.load(open(os.environ["PREFIX"]+"/proprietaire.json"))["access_token"])')

export RELAIS_URL MATRIX_USER=essai
export MATRIX_PASSWORD
export PREUVE_HOME="$PREFIX/preuve-p5"

titre() { printf '\n### %s\n' "$*"; }
admin() { python3 "$RACINE/infra/relais-spike/salon-admin.py" "$RELAIS_URL" "$JETON" "$SERVEUR" "$1"; }

CC_PASSWORD="${CC_PASSWORD:-ccP5$(head -c 9 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')}"

titre "0. le compte de cc, créé par la commande d'administration"
admin "!admin users create cc $CC_PASSWORD" || true
admin "!admin users reset-password cc $CC_PASSWORD"
curl -s "$RELAIS_URL/_matrix/client/v3/profile/@cc:$SERVEUR" ; echo

titre "1. l'amorce de cc, dans son dossier d'essai (jamais ~/.correspondance-agent)"
mkdir -p "$AGENT_HOME"
cat > "$AGENT_HOME/config.json" <<JSON
{
  "homeserver": "$RELAIS_URL",
  "user": "cc",
  "password": "$CC_PASSWORD",
  "owners": ["@essai:$SERVEUR"],
  "trigger": "@cc",
  "hourlyCap": 30
}
JSON
chmod 600 "$AGENT_HOME/config.json"
rm -f "$AGENT_HOME/state.json"
rm -rf "$AGENT_HOME/crypto"
ls -l "$AGENT_HOME"

titre "2. la console de cc et la note à soi, toutes deux CHIFFRÉES"
CONSOLE=$("$B" console appareilA cc "@cc:$SERVEUR" | tee /dev/stderr | sed -n 's/^CONSOLE=//p')
SALON=$("$B" envoyer appareilA --nouveau "Note à soi de la phase 5." | tee /dev/stderr | sed -n 's/^SALON=//p')
"$B" inviter appareilA "$SALON" "@cc:$SERVEUR"
echo "CONSOLE=$CONSOLE"
echo "SALON=$SALON"

titre "3. cc démarre — avec la machine crypto"
rm -f "$JOURNAL"
CORRESPONDANCE_HOME=unclic "$BUILD/correspondance-agent" run --agent cc > "$JOURNAL" 2>&1 &
CC_PID=$!
trap 'kill $CC_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 40); do grep -q "à l'écoute" "$JOURNAL" && break; sleep 1; done
sed -n '1,12p' "$JOURNAL"

titre "4. « @cc ping » ENVOYÉ CHIFFRÉ dans la note à soi"
sleep 5
"$B" envoyer appareilA "$SALON" "@cc ping"

titre "5. ce que cc en fait"
for _ in $(seq 1 60); do grep -q "←" "$JOURNAL" && break; sleep 2; done
tail -n 12 "$JOURNAL"

titre "6. la réponse de cc, relue en clair par l'appareil A"
"$B" lire appareilA "$SALON"

titre "7. ce que le Relais stocke de la réponse de cc — vu sans le client"
python3 - "$RELAIS_URL" "$JETON" "$SALON" <<'PY'
import json, sys, urllib.parse, urllib.request
url, jeton, salon = sys.argv[1:4]
req = urllib.request.Request(
    f"{url}/_matrix/client/v3/rooms/{urllib.parse.quote(salon)}/messages?dir=b&limit=20",
    headers={"Authorization": f"Bearer {jeton}"})
for e in json.load(urllib.request.urlopen(req))["chunk"]:
    if e.get("sender", "").startswith("@cc:"):
        print(f"  {e['event_id']}  type={e['type']}  algorithm={e.get('content', {}).get('algorithm', '—')}")
        c = e.get("content", {}).get("ciphertext", "")
        if c:
            print(f"    ciphertext (100 premiers) : {c[:100]}…")
        print(f"    contenu brut : {json.dumps(e.get('content', {}))[:200]}")
PY

titre "8. le journal des tours, écrit chiffré dans la console"
"$B" lire appareilA "$CONSOLE"
python3 - "$RELAIS_URL" "$JETON" "$CONSOLE" <<'PY'
import json, sys, urllib.parse, urllib.request
url, jeton, salon = sys.argv[1:4]
req = urllib.request.Request(
    f"{url}/_matrix/client/v3/rooms/{urllib.parse.quote(salon)}/messages?dir=b&limit=20",
    headers={"Authorization": f"Bearer {jeton}"})
print("  ce que le Relais stocke dans la console :")
for e in json.load(urllib.request.urlopen(req))["chunk"]:
    if e.get("sender", "").startswith("@cc:"):
        print(f"    {e['event_id']}  type={e['type']}")
PY

kill $CC_PID 2>/dev/null || true
echo
echo "✓ preuve terminée."
