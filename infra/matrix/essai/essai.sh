#!/usr/bin/env bash
# Un Relais d'ESSAI, jetable : Synapse seul, un propriétaire, un bot, un code
# d'appairage. Pour éprouver l'appairage, l'agent et le MCP sans toucher au vrai.
#
#   infra/matrix/essai/essai.sh up        # monte, crée les comptes, rend le code
#   infra/matrix/essai/essai.sh code      # réémet un code (le précédent périme)
#   infra/matrix/essai/essai.sh status    # ce qui tourne
#   infra/matrix/essai/essai.sh down      # arrête, garde les données
#   infra/matrix/essai/essai.sh destroy   # arrête ET efface tout
#   infra/matrix/essai/essai.sh --dry-run up
#
# L'isolation de la prod est dans le compose (server_name, projet, port 8009,
# volumes). Ici on ajoute la garde qui compte : **toutes** les commandes docker
# passent par `compose()`, qui impose `-p correspondance-essai` et ce
# fichier-là. Un `down -v` ne peut donc pas atteindre le projet de la prod —
# l'erreur est rendue impossible, pas documentée.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJET="correspondance-essai"
SERVER_NAME="${SERVER_NAME:-correspondance.essai}"
MATRIX_USER="${MATRIX_USER:-essai}"
AGENT_USER="${AGENT_USER:-cc}"
PUBLIC_URL="${PUBLIC_URL:-http://127.0.0.1:8009}"
DRY_RUN=0

if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; shift; fi
COMMANDE="${1:-up}"

# Le moteur de conteneurs, tel qu'il s'appelle ici.
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DOCKER_COMPOSE=(docker-compose)
else
  DOCKER_COMPOSE=()
fi

# LA garde. Aucune commande docker de ce script ne s'écrit sans passer par ici :
# le projet et le fichier sont posés, pas hérités d'un environnement.
compose() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "PLAN  ${DOCKER_COMPOSE[*]:-docker compose} -p $PROJET -f $HERE/docker-compose.yml $*"
    return 0
  fi
  [ ${#DOCKER_COMPOSE[@]} -gt 0 ] || { echo "!! aucun moteur de conteneurs" >&2; exit 1; }
  "${DOCKER_COMPOSE[@]}" -p "$PROJET" -f "$HERE/docker-compose.yml" "$@"
}

dans_synapse() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "PLAN  docker exec correspondance-essai-synapse $*"
    return 0
  fi
  docker exec correspondance-essai-synapse "$@"
}

# ------------------------------------------------------------------- monter
generer_config() {
  mkdir -p "$HERE/data"
  if [ -f "$HERE/data/homeserver.yaml" ]; then
    echo "   configuration déjà là"
    return 0
  fi
  echo "→ Configuration de Synapse (server_name : $SERVER_NAME)"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "PLAN  générer data/homeserver.yaml puis y activer l'inscription par secret"
    return 0
  fi
  compose run --rm \
    -e SYNAPSE_SERVER_NAME="$SERVER_NAME" \
    -e SYNAPSE_REPORT_STATS=no \
    synapse generate >/dev/null
  # Postgres plutôt que SQLite, comme en prod : on éprouve la même pile.
  python3 - "$HERE/data/homeserver.yaml" "$SERVER_NAME" <<'PY'
import re, sys
chemin, server = sys.argv[1], sys.argv[2]
conf = open(chemin, encoding='utf-8').read()
conf = re.sub(
    r'database:\n(  .*\n)+',
    'database:\n'
    '  name: psycopg2\n'
    '  args:\n'
    '    user: matrix\n'
    '    password: essai\n'
    '    database: synapse\n'
    '    host: postgres\n'
    '    cp_min: 1\n'
    '    cp_max: 5\n',
    conf, count=1)
if 'registration_shared_secret' not in conf:
    conf += '\nregistration_shared_secret: "essai-essai-essai"\n'
# Un Relais d'essai ne parle à personne d'autre.
conf += '\nenable_registration: false\n'
open(chemin, 'w', encoding='utf-8').write(conf)
print("   homeserver.yaml : Postgres, inscription par secret, fédération fermée")
PY
}

attendre_synapse() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "PLAN  attendre que $PUBLIC_URL réponde (60 s au plus)"
    return 0
  fi
  echo "→ Attente de Synapse"
  for _ in $(seq 1 60); do
    if curl -fsS "$PUBLIC_URL/_matrix/client/versions" >/dev/null 2>&1; then
      echo "   prêt"
      return 0
    fi
    sleep 1
  done
  echo "!! Synapse n'a pas répondu en 60 s — essai.sh status, puis les journaux" >&2
  return 1
}

creer_compte() {
  local nom="$1" mot="$2" role="$3"
  if [ "$DRY_RUN" -eq 1 ]; then
    dans_synapse register_new_matrix_user -u "$nom" "$role" -c /data/homeserver.yaml
    return 0
  fi
  dans_synapse register_new_matrix_user -u "$nom" -p "$mot" "$role" \
    -c /data/homeserver.yaml http://localhost:8008 >/dev/null 2>&1 \
    || echo "   $nom existe déjà"
}

creer_comptes() {
  echo "→ Comptes : @$MATRIX_USER (propriétaire, admin) et @$AGENT_USER (bot)"
  creer_compte "$MATRIX_USER" "$MOT_DE_PASSE" --admin
  creer_compte "$AGENT_USER" "$MOT_DE_PASSE_BOT" --no-admin
}

emettre_code() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "PLAN  émettre le code d'appairage pour $PUBLIC_URL"
    return 0
  fi
  python3 - "$PUBLIC_URL" "$SERVER_NAME" "$MATRIX_USER" "$MOT_DE_PASSE" <<'PY'
import base64, json, sys, time
url, server, user, password = sys.argv[1:5]
payload = {"v": 1, "homeserver": url, "server": server, "user": user,
           "password": password, "exp": time.time() + 900}
raw = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
token = base64.b64encode(raw).decode().replace("+", "-").replace("/", "_").rstrip("=")
print()
print("  correspondance://relais/" + token)

lexicon = ["arbre","banc","cabane","dune","encre","falaise","givre","halo",
           "iris","jardin","kiosque","lampe","marée","neige","olive","pluie",
           "quai","roseau","sable","tuile","usine","vague","wagon","zeste",
           "brume","chêne","digue","étang","flotte","grange","houle","index"]
h = 1469598103934665603
for b in "|".join([url, server, f"@{user}:{server}"]).encode():
    h ^= b
    h = (h * 1099511628211) % (1 << 64)
mots, reste = [], h
for _ in range(6):
    mots.append(lexicon[reste % len(lexicon)])
    reste = (reste // len(lexicon) + reste * 31) % (1 << 64)
print()
print("  Vérification :", " ".join(mots))
print("  Il périme dans 15 minutes.")
PY
}

# Les mots de passe de l'essai : fixes et sans valeur, écrits en clair ici.
# Un Relais d'essai écoute en loopback, ne fédère pas, et se détruit d'une
# commande — un secret tiré au hasard ne protégerait rien et compliquerait la
# réémission d'un code.
MOT_DE_PASSE="essai-proprietaire"
MOT_DE_PASSE_BOT="essai-bot"

case "$COMMANDE" in
  up)
    echo "Relais d'essai — $SERVER_NAME sur $PUBLIC_URL (la prod, elle, est sur 8008)"
    generer_config
    echo "→ Démarrage"
    compose up -d
    attendre_synapse
    creer_comptes
    emettre_code
    echo
    echo "  Ensuite : CORRESPONDANCE_HOME=essai open -a Correspondance,"
    echo "  puis Réglages › Matrix › « Connecter un Relais » et colle le code."
    ;;

  code)
    emettre_code
    ;;

  status)
    compose ps
    ;;

  down)
    echo "→ Arrêt (les données restent)"
    compose down
    ;;

  destroy)
    # `-v` n'atteint que les volumes de CE projet : `compose()` impose
    # `-p correspondance-essai`, la prod est hors de portée.
    echo "→ Arrêt et effacement du projet $PROJET"
    compose down -v
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "PLAN  rm -rf $HERE/data"
    else
      rm -rf "$HERE/data"
    fi
    echo "   effacé. Pense aussi à : rm -rf ~/Library/Application\\ Support/Correspondance-essai"
    echo "   et à retirer « app.correspondance.matrix.essai » du Trousseau."
    ;;

  *)
    echo "commande inconnue : $COMMANDE (up | code | status | down | destroy)" >&2
    exit 2
    ;;
esac
