#!/usr/bin/env bash
# Correspondance — crée le compte propriétaire du Relais du spike.
#
# Continuwuity n'a pas d'API d'administration HTTP (deux routes seulement, cf.
# docs/spike-un-clic/phase-1.md) : on ne peut donc pas « PUT un utilisateur »
# comme le fait l'app avec Synapse. Mais le PREMIER compte enregistré devient
# administrateur du serveur et rejoint #admins tout seul — il suffit de
# l'enregistrer par l'API cliente standard, avec le jeton d'enregistrement.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/config.sh"
set -a; . "$SPIKE_HOME/secrets.env"; set +a

SESSION="$SPIKE_HOME/proprietaire.json"
jeton() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["access_token"])' "$SESSION"; }

if [[ -f "$SESSION" ]] && curl -fsS -H "Authorization: Bearer $(jeton)" \
     "$RELAIS_URL/_matrix/client/v3/account/whoami" >/dev/null 2>&1; then
  dire "compte $MATRIX_ADMIN déjà là, session valide"
  exit 0
fi

# Piège éprouvé : sur une base neuve, le `registration_token` du fichier de
# configuration NE MARCHE PAS. Continuwuity tire un jeton d'amorçage à usage
# unique et ne le dit que dans son journal — « The registration token you set in
# your configuration will not function until you create an account using the
# token above. » On le relit donc là où il est écrit.
JETON="$REGISTRATION_TOKEN"
AMORCE="$(python3 -c "
import re, sys
texte = open(sys.argv[1], errors='ignore').read()
texte = re.sub(r'\x1b\[[0-9;]*m', '', texte)
trouves = re.findall(r'using the registration token (\S+)', texte)
print(trouves[-1] if trouves else '')
" "$LOG_DIR/relais.log" 2>/dev/null || true)"
[[ -n "$AMORCE" ]] && { dire "jeton d'amorçage relevé dans le journal du Relais"; JETON="$AMORCE"; }

dire "enregistrement de $MATRIX_ADMIN (jeton d'enregistrement)"
REPONSE="$(python3 "$HERE/enregistrer.py" "$RELAIS_URL" "$MATRIX_USER" "$MATRIX_PASSWORD" "$JETON")"

python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if "access_token" in d else 1)' "$REPONSE" \
  || mourir "enregistrement refusé : $REPONSE"

umask 077
printf '%s\n' "$REPONSE" > "$SESSION"
chmod 600 "$SESSION"
dire "✓ $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["user_id"])' "$SESSION") enregistré — session dans $SESSION"
