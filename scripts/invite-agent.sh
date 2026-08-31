#!/bin/bash
# Invite l'agent « cc » dans une room, depuis TON compte Correspondance.
#
#   scripts/invite-agent.sh                    → dans la note à soi
#   scripts/invite-agent.sh '!abc:correspondance.local'   → dans une room précise
#
# Lit ta session Matrix dans le Trousseau (celle de l'app) : macOS peut demander
# d'autoriser `security` une fois. Le token ne quitte pas ce shell.
set -euo pipefail

AGENT="${AGENT_USER_ID:-@cc:correspondance.local}"
CREDS=$(security find-generic-password -s app.correspondance.matrix -a default -w)
TOKEN=$(printf '%s' "$CREDS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["accessToken"])')
HS=$(printf '%s' "$CREDS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["homeserver"].rstrip("/"))')
ME=$(printf '%s' "$CREDS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["userID"])')

ROOM="${1:-}"
if [ -z "$ROOM" ]; then
  ROOM=$(curl -fsS -H "Authorization: Bearer $TOKEN" \
    "$HS/_matrix/client/v3/user/$ME/account_data/fr.correspondance.self_note" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("room_id") or d.get("roomID") or "")')
  [ -n "$ROOM" ] || { echo "pas de note à soi enregistrée — ouvre-la une fois dans Correspondance, ou passe un room id" >&2; exit 1; }
fi

echo "→ $ME invite $AGENT dans $ROOM"
curl -fsS -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  "$HS/_matrix/client/v3/rooms/$ROOM/invite" -d "{\"user_id\":\"$AGENT\"}" >/dev/null
echo "invité. L'agent rejoint tout seul (il n'accepte que tes invitations)."
