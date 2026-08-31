#!/bin/bash
# Test de bout en bout de l'agent « cc » : envoie « @cc … » dans la note à soi
# AVEC TA SESSION (Trousseau), attend la réponse de l'agent, l'affiche.
#   scripts/agent-e2e.sh "quelle heure est-il ?"
set -euo pipefail
PROMPT="${1:-réponds exactement : pong}"
CREDS=$(security find-generic-password -s app.correspondance.matrix -a default -w)
TOKEN=$(printf '%s' "$CREDS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["accessToken"])')
HS=$(printf '%s' "$CREDS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["homeserver"].rstrip("/"))')
ME=$(printf '%s' "$CREDS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["userID"])')
ROOM=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$HS/_matrix/client/v3/user/$ME/account_data/fr.correspondance.self_note" | python3 -c 'import sys,json;print(json.load(sys.stdin)["room_id"])')
TXN="e2e-$(date +%s)"
BODY=$(python3 -c "import json,sys;print(json.dumps({'msgtype':'m.text','body':'@cc '+sys.argv[1]}))" "$PROMPT")
SENT=$(curl -fsS -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  "$HS/_matrix/client/v3/rooms/$ROOM/send/m.room.message/$TXN" -d "$BODY" | python3 -c 'import sys,json;print(json.load(sys.stdin)["event_id"])')
echo "→ envoyé $SENT : « @cc $PROMPT »"
for i in $(seq 1 60); do
  sleep 2
  REPLY=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$HS/_matrix/client/v3/rooms/$ROOM/messages?dir=b&limit=10" \
    | python3 -c "
import sys, json
for e in json.load(sys.stdin)['chunk']:
    if e.get('sender') == '@cc:correspondance.local' and e.get('type') == 'm.room.message':
        rel = e.get('content', {}).get('m.relates_to', {}).get('m.in_reply_to', {}).get('event_id')
        if rel == '$SENT':
            print(e['content']['body']); break
")
  if [ -n "$REPLY" ]; then echo "← cc ($((i*2)) s) : $REPLY"; exit 0; fi
done
echo "!! pas de réponse en 120 s" >&2; exit 1
