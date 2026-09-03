#!/bin/zsh
# Envoie un VRAI push à l'iPhone, sans attendre qu'un message arrive.
#
# Le chemin est celui de production, moins Synapse : on parle directement à la
# passerelle Sygnal (publique, cf. docs/MATRIX-SETUP.md § « Vérifier ») avec le
# pusher que l'iPhone a déclaré au Relais. Sygnal signe et Apple livre — sandbox
# ou production selon l'app_id, exactement comme pour un message réel.
#
# La charge utile nomme un vrai événement d'un vrai salon : l'extension de
# service peut donc aller lire le texte, et le tap sur la notification a un fil
# à ouvrir. C'est ce qui permet de reproduire « je touche, écran noir » à volonté
# — tuer l'app d'abord pour tester le lancement à froid.
#
# Usage :
#   scripts/push-iphone.sh                 # dernier message reçu, build Xcode (.dev)
#   scripts/push-iphone.sh '!room:…'       # ce salon, son dernier message
#   APP_ID=com.correspondance.ios scripts/push-iphone.sh   # build TestFlight/App Store
#
# Le jeton d'accès vient du Trousseau du Mac : même compte que l'iPhone.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_ID="${APP_ID:-com.correspondance.ios.dev}"
GATEWAY="${GATEWAY:-https://push.fauconnier.app/_matrix/push/v1/notify}"

CREDS=$(security find-generic-password -s app.correspondance.matrix -a default -w)
TOKEN=$(printf '%s' "$CREDS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["accessToken"])')
HS=$(printf '%s' "$CREDS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["homeserver"].rstrip("/"))')
ME=$(printf '%s' "$CREDS" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("userID",""))')

# 1. Le pusher de l'iPhone pour cet app_id : c'est lui qui porte le jeton APNs.
PUSHKEY=$(curl -fsS -m 15 -H "Authorization: Bearer $TOKEN" "$HS/_matrix/client/v3/pushers" \
  | python3 -c '
import sys, json
app = sys.argv[1]
for p in json.load(sys.stdin)["pushers"]:
    if p["app_id"] == app:
        print(p["pushkey"]); break
' "$APP_ID")
[[ -n "$PUSHKEY" ]] || { echo "✗ aucun pusher $APP_ID sur le Relais : l'iPhone n'a pas déclaré ce build" >&2; exit 1; }

# 2. Un événement à nommer : celui demandé, ou le dernier message reçu.
if [[ -n "${1:-}" ]]; then
  ROOM="$1"
  ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$ROOM")
  EVENT=$(curl -fsS -m 15 -H "Authorization: Bearer $TOKEN" \
    "$HS/_matrix/client/v3/rooms/$ENC/messages?dir=b&limit=20" \
    | python3 -c '
import sys, json
for e in json.load(sys.stdin)["chunk"]:
    if e.get("type") in ("m.room.message", "m.room.encrypted"):
        print(e["event_id"]); break
')
else
  FILTER='{"room":{"timeline":{"limit":1,"types":["m.room.message","m.room.encrypted"]},"state":{"types":[]},"ephemeral":{"types":[]}},"presence":{"types":[]},"account_data":{"types":[]}}'
  ENCF=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$FILTER")
  read -r ROOM EVENT < <(curl -fsS -m 60 -H "Authorization: Bearer $TOKEN" \
    "$HS/_matrix/client/v3/sync?timeout=0&filter=$ENCF" \
    | python3 -c '
import sys, json
me = sys.argv[1]
best = None
for room_id, room in json.load(sys.stdin).get("rooms", {}).get("join", {}).items():
    for e in room.get("timeline", {}).get("events", []):
        if e.get("sender") == me:
            continue
        ts = e.get("origin_server_ts", 0)
        if best is None or ts > best[0]:
            best = (ts, room_id, e["event_id"])
if best:
    print(best[1], best[2])
' "$ME")
fi
[[ -n "${ROOM:-}" && -n "${EVENT:-}" ]] || { echo "✗ aucun message à nommer" >&2; exit 1; }

# 3. Le POST que Synapse aurait fait. `counts.unread` fait le badge.
# Le `default_payload` est ce que l'app déclare dans son pusher (voir
# MatrixClient.pusherDefaultPayload) : sans lui, Sygnal n'écrit aucun `aps`
# en event_id_only et l'iPhone jette le push sans le montrer.
PAYLOAD=$(python3 -c '
import sys, json
print(json.dumps({"notification": {
  "event_id": sys.argv[1], "room_id": sys.argv[2],
  "counts": {"unread": 1},
  "devices": [{"app_id": sys.argv[3], "pushkey": sys.argv[4], "data": {
    "format": "event_id_only",
    "default_payload": {"aps": {"mutable-content": 1, "sound": "default",
                                "alert": {"title": "Correspondance", "body": "Nouveau message"}}},
  }}],
}}))' "$EVENT" "$ROOM" "$APP_ID" "$PUSHKEY")

echo "→ $APP_ID · $ROOM · $EVENT"
RESP=$(curl -sS -m 20 -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' "$GATEWAY" -d "$PAYLOAD")
CODE="${RESP##*$'\n'}"
BODY="${RESP%$'\n'*}"
echo "← HTTP $CODE $BODY"
case "$BODY" in
  *'"rejected": []'*|*'"rejected":[]'*) echo "✓ accepté par Sygnal — Apple livre dans la seconde. Journal : ssh nuc 'cd correspondance-matrix && docker-compose logs --tail=20 sygnal'" ;;
  *rejected*) echo "✗ pushkey rejeté : jeton périmé ou environnement croisé (BadDeviceToken). Relancer l'app pour redéclarer le pusher." >&2; exit 1 ;;
  *) echo "✗ réponse inattendue — voir le journal de Sygnal" >&2; exit 1 ;;
esac
