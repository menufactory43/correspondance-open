#!/bin/bash
# Le relais, room par room : où il est armé, et l'armer.
#
#   scripts/agent-relay.sh                     → liste les portails armés (3 ponts)
#   scripts/agent-relay.sh '!room:…'           → arme cette room (!wa/!signal/!meta set-relay,
#                                                envoyé depuis TA session ; le bot confirme)
# Armé = ce que « cc » dit dans la room part sur le réseau EN TON NOM,
# préfixé « 🤖 cc : ». Ne s'arme que si tu le demandes, room par room.
set -euo pipefail
SSH_HOST="${SSH_HOST:-nuc}"

if [ -z "${1:-}" ]; then
  ssh "$SSH_HOST" 'for b in whatsapp signal meta; do
    echo "== $b"
    docker exec correspondance-postgres psql -U matrix -d mautrix_$b -tAc \
      "SELECT mxid || COALESCE('"'"'  ('"'"' || NULLIF(name,'"'"''"'"') || '"'"')'"'"', '"'"''"'"') FROM portal WHERE relay_login_id IS NOT NULL;" 2>/dev/null \
      | sed "s/^$/  (aucun)/" | sed "s/^/  /"
  done'
  exit 0
fi

ROOM="$1"
CREDS=$(security find-generic-password -s app.correspondance.matrix -a default -w)
TOKEN=$(printf '%s' "$CREDS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["accessToken"])')
HS=$(printf '%s' "$CREDS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["homeserver"].rstrip("/"))')
ENC=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$ROOM")

# Le préfixe de commande dépend du pont de la room : on regarde quel bot y est.
MEMBERS=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$HS/_matrix/client/v3/rooms/$ENC/joined_members")
PREFIX=$(printf '%s' "$MEMBERS" | python3 -c '
import sys,json
joined=json.load(sys.stdin)["joined"]
for bot,prefix in [("@whatsappbot:","!wa"),("@signalbot:","!signal"),("@instagrambot:","!meta")]:
    if any(u.startswith(bot) for u in joined): print(prefix); break
')
[ -n "$PREFIX" ] || { echo "aucun bot de pont dans cette room — ce n'est pas un portail" >&2; exit 1; }

curl -fsS -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  "$HS/_matrix/client/v3/rooms/$ENC/send/m.room.message/setrelay-$(date +%s)" \
  -d "{\"msgtype\":\"m.text\",\"body\":\"$PREFIX set-relay\"}" >/dev/null
sleep 4
curl -fsS -H "Authorization: Bearer $TOKEN" "$HS/_matrix/client/v3/rooms/$ENC/messages?dir=b&limit=3" | python3 -c '
import sys,json
for e in reversed(json.load(sys.stdin)["chunk"]):
    if e["type"]=="m.room.message" and "bot:" in e["sender"]: print("pont :", e["content"]["body"][:140])
'
