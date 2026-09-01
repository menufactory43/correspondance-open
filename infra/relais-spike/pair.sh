#!/usr/bin/env bash
# Correspondance — émet le code d'appairage du Relais du spike, au format exact
# de infra/matrix/pair.sh : c'est le même RelayPairingCode que l'app décode.
#
#   infra/relais-spike/pair.sh
#
# Le code porte un mot de passe : il se colle, jamais il ne se poste. Il périme
# en quinze minutes.
#
# Différence avec le Relais Synapse du NUC : là-bas le mot de passe se repose par
# l'API d'administration. Ici, Continuwuity n'en a pas — on passe par la commande
# `users reset-password` dans #admins, qui accepte un mot de passe choisi et, sans
# `--logout`, conserve les sessions ouvertes (l'équivalent de `logout_devices:
# false`, ce qui évite de tuer un agent qui tourne ailleurs).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/config.sh"
set -a; . "$SPIKE_HOME/secrets.env"; set +a

SESSION="$SPIKE_HOME/proprietaire.json"
[[ -f "$SESSION" ]] || mourir "pas de session propriétaire — lance d'abord compte.sh"
JETON="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["access_token"])' "$SESSION")"

NOUVEAU="$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(24)))')"
dire "mot de passe reposé pour $MATRIX_ADMIN (sessions conservées)"
python3 "$HERE/salon-admin.py" "$RELAIS_URL" "$JETON" "$SERVER_NAME" \
  "!admin users reset-password $MATRIX_USER $NOUVEAU" >/dev/null

# La session locale reste valide (pas de --logout), mais on note le mot de passe
# à côté d'elle pour que le script soit relançable.
python3 - "$SPIKE_HOME/secrets.env" "$NOUVEAU" <<'PY'
import pathlib, sys
fichier, mot = pathlib.Path(sys.argv[1]), sys.argv[2]
lignes = [l for l in fichier.read_text().splitlines() if not l.startswith("MATRIX_PASSWORD=")]
lignes.append(f"MATRIX_PASSWORD={mot}")
fichier.write_text("\n".join(lignes) + "\n")
PY

python3 "$HERE/appairage.py" "$RELAIS_URL" "$SERVER_NAME" "$MATRIX_USER" "$NOUVEAU"
