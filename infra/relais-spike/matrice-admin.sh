#!/usr/bin/env bash
# Correspondance — éprouve, un par un, les appels d'administration Synapse dont
# l'app et l'agent se servent, contre le Relais du spike.
#
# Ce n'est pas une lecture de documentation : chaque ligne est un appel réel, et
# la sortie de ce script est ce qui remplit la matrice de compatibilité de
# docs/spike-un-clic/phase-1.md. Pour chaque appel Synapse on essaie aussi
# l'équivalent Continuwuity (une commande dans #admins) quand il en existe un.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/config.sh"

SESSION="$SPIKE_HOME/proprietaire.json"
[[ -f "$SESSION" ]] || mourir "pas de session propriétaire — lance d'abord compte.sh"
JETON="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["access_token"])' "$SESSION")"
MOI="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["user_id"])' "$SESSION")"
CIBLE="@cc:${SERVER_NAME}"

essai() {
  local titre="$1" methode="$2" chemin="$3" corps="${4:-}"
  echo
  echo "### $titre"
  echo "\$ curl -s -X $methode \"\$RELAIS/$chemin\" ${corps:+-d '$corps'}"
  if [[ -n "$corps" ]]; then
    curl -s -o /tmp/unclic-admin.out -w 'HTTP %{http_code}\n' -X "$methode" \
      -H "Authorization: Bearer $JETON" -H 'Content-Type: application/json' \
      -d "$corps" "$RELAIS_URL/$chemin"
  else
    curl -s -o /tmp/unclic-admin.out -w 'HTTP %{http_code}\n' -X "$methode" \
      -H "Authorization: Bearer $JETON" "$RELAIS_URL/$chemin"
  fi
  head -c 400 /tmp/unclic-admin.out; echo
}

admin() {
  echo
  echo "### équivalent Continuwuity : $1"
  python3 "$HERE/salon-admin.py" "$RELAIS_URL" "$JETON" "$SERVER_NAME" "$1"
}

echo "Relais : $RELAIS_URL — $(curl -s "$RELAIS_URL/_continuwuity/server_version")"
echo "Propriétaire : $MOI"

essai "1. suis-je administrateur ? (MatrixClient.isServerAdmin)" \
  GET "_synapse/admin/v1/users/$MOI/admin"

essai "2. ce compte existe-t-il ? (MatrixClient.userExists)" \
  GET "_synapse/admin/v2/users/$CIBLE"

essai "3. créer le compte d'un agent (MatrixClient.provisionUser)" \
  PUT "_synapse/admin/v2/users/$CIBLE" \
  '{"password":"jamais-utilise","admin":false,"deactivated":false,"logout_devices":false}'
admin "!admin users create-user cc"

essai "4. les sessions d'un compte (MatrixClient.userDevices — la garde du second cc)" \
  GET "_synapse/admin/v2/users/$CIBLE/devices"
admin "!admin query users list-devices-metadata $CIBLE"

SALON="$(curl -s -X POST -H "Authorization: Bearer $JETON" -H 'Content-Type: application/json' \
  -d '{"preset":"private_chat","name":"matrice admin"}' \
  "$RELAIS_URL/_matrix/client/v3/createRoom" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("room_id",""))')"
essai "5. me donner le pouvoir dans un salon (MatrixClient.makeRoomAdmin)" \
  POST "_synapse/admin/v1/rooms/$SALON/make_room_admin" "{\"user_id\":\"$MOI\"}"

essai "6. l'API d'administration que Continuwuity a vraiment (pour mémoire)" \
  GET "_continuwuity/admin/rooms/list"

echo
echo "### le compte a-t-il été créé par la commande admin ?"
curl -s -o /tmp/unclic-admin.out -w 'HTTP %{http_code} ' \
  -H "Authorization: Bearer $JETON" \
  "$RELAIS_URL/_matrix/client/v3/profile/$CIBLE"
head -c 200 /tmp/unclic-admin.out; echo
