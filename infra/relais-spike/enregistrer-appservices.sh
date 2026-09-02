#!/usr/bin/env bash
# Correspondance — déclare les ponts auprès du Relais du spike.
#
# Chez Synapse, une registration est un fichier YAML listé dans homeserver.yaml,
# relu au démarrage. Chez Continuwuity, c'est un message dans #admins : le YAML
# se colle dans un bloc de code sous `!admin appservices register`, et le
# serveur le prend en compte sans redémarrer. Réenregistrer le même `id`
# remplace l'ancien — le script est donc relançable.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/config.sh"

SESSION="$SPIKE_HOME/proprietaire.json"
[[ -f "$SESSION" ]] || mourir "pas de session propriétaire — lance d'abord compte.sh"
JETON="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["access_token"])' "$SESSION")"

admin() { python3 "$HERE/salon-admin.py" "$RELAIS_URL" "$JETON" "$SERVER_NAME" "$1"; }

for nom in whatsapp signal; do
  reg="$SPIKE_HOME/mautrix-$nom/registration.yaml"
  [[ -f "$reg" ]] || mourir "$reg absent — lance d'abord generer-configs.sh"
  dire "enregistrement de l'appservice $nom"
  commande="$(printf '!admin appservices register\n```\n%s\n```' "$(cat "$reg")")"
  admin "$commande"
done

dire "vérification"
admin "!admin appservices list-registered"
