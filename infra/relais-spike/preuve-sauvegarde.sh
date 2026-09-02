#!/usr/bin/env bash
# Phase 5, livrables 2 et 3 — la sauvegarde des clés avec phrase, et la
# vérification d'appareil.
#
# Ce qu'on veut faire disparaître : la limite mesurée en phase 2 —
# « first known index 1, index of the message 0 ». Un appareil qui arrive après
# un message ne le lit pas. Avec la sauvegarde, il le lit.
#
# Le contrôle négatif compte autant que la preuve : l'appareil neuf commence
# par NE PAS lire, avec son magasin vierge. C'est seulement après la phrase
# qu'il lit.
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.correspondance-unclic}"
RELAIS_URL="${RELAIS_URL:-http://127.0.0.1:8010}"
BUILD="${BUILD:-/tmp/build-unclic-crypto/debug}"
B="$BUILD/preuve-chiffrement"

# shellcheck disable=SC1090
set -a; . "$PREFIX/secrets.env"; set +a
JETON=$(PREFIX="$PREFIX" python3 -c 'import json,os;print(json.load(open(os.environ["PREFIX"]+"/proprietaire.json"))["access_token"])')
export RELAIS_URL MATRIX_USER=essai MATRIX_PASSWORD
export PREUVE_HOME="$PREFIX/preuve-p5"

PHRASE="${PHRASE:-marée dune chêne zeste encre usine}"
titre() { printf '\n### %s\n' "$*"; }

# L'appareil neuf doit être NEUF : magasin de clés et session effacés.
rm -rf "$PREUVE_HOME/appareilNeuf"

titre "1. l'appareil A écrit dans un salon chiffré — AVANT que l'appareil neuf existe"
SALON=$("$B" envoyer appareilA --nouveau "Message écrit avant la naissance de l'appareil neuf." | tee /dev/stderr | sed -n 's/^SALON=//p')

titre "2. l'appareil A crée la sauvegarde depuis la phrase"
echo "  phrase : « $PHRASE »"
"$B" sauvegarder appareilA "$PHRASE"

titre "3. ce que le Relais héberge, vu sans le client"
curl -s -H "Authorization: Bearer $JETON" "$RELAIS_URL/_matrix/client/v3/room_keys/version" \
  | python3 -m json.tool
echo "  et les clés elles-mêmes (nombre de sessions par salon) :"
VERSION=$(curl -s -H "Authorization: Bearer $JETON" "$RELAIS_URL/_matrix/client/v3/room_keys/version" | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])')
curl -s -H "Authorization: Bearer $JETON" "$RELAIS_URL/_matrix/client/v3/room_keys/keys?version=$VERSION" \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
for salon, contenu in d.get("rooms", {}).items():
    sessions = contenu.get("sessions", {})
    print(f"    {salon} : {len(sessions)} session(s)")
    for sid, s in list(sessions.items())[:1]:
        idx = s.get("first_message_index")
        print("      %s first_message_index=%s" % (sid, idx))
        print("      session_data (chiffrée par la clé de sauvegarde) : %s…" % json.dumps(s.get("session_data"))[:120])
'

titre "4. CONTRÔLE NÉGATIF — un appareil NEUF, magasin vierge : il ne lit rien"
"$B" lire appareilNeuf "$SALON" || true

titre "5. la phrase, et rien d'autre"
"$B" restaurer appareilNeuf "$PHRASE"

titre "6. le même appareil neuf relit — l'historique d'avant sa naissance"
"$B" lire appareilNeuf "$SALON"

titre "7. une phrase fausse est refusée avant tout téléchargement"
"$B" restaurer appareilNeuf "ceci n est pas la phrase" && echo "✗ elle aurait dû être refusée" || true

titre "8. les signatures croisées, posées par l'appareil A"
"$B" amorcer-signatures appareilA
curl -s -H "Authorization: Bearer $JETON" \
  -X POST -d '{"device_keys":{"@essai:unclic.local":[]}}' \
  "$RELAIS_URL/_matrix/client/v3/keys/query" \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
for nom in ("master_keys", "self_signing_keys", "user_signing_keys"):
    for user, cle in d.get(nom, {}).items():
        print("  %s de %s : %s" % (nom, user, list(cle.get("keys", {}))))
'

titre "9. les appareils du compte, et leur état"
"$B" appareils appareilA

titre "10. le coffre : l'appareil A y dépose ses clés de signature, scellées par la phrase"
"$B" deposer-signatures appareilA "$PHRASE"
echo "  ce que le Relais en voit :"
curl -s -H "Authorization: Bearer $JETON" \
  "$RELAIS_URL/_matrix/client/v3/user/@essai:unclic.local/account_data/fr.correspondance.coffre.v1" \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print("   ",d.get("algorithme"),":",d.get("scelle","")[:90]+"…")'

titre "11. l'appareil neuf reprend les clés du coffre avec la phrase — et devient vérifié"
"$B" reprendre-signatures appareilNeuf "$PHRASE"

titre "12. l'écran « mes appareils », vu par l'appareil A"
"$B" appareils appareilA

echo
echo "✓ preuve terminée."
