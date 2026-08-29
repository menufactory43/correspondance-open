#!/usr/bin/env bash
# Correspondance — installe/actualise la pile Matrix sur le NUC. Idempotent : relançable sans dégât.
#
# Usage (depuis le Mac, à la racine du repo) :
#   ./infra/matrix/bootstrap.sh            # copie vers le NUC puis applique
#   ./infra/matrix/bootstrap.sh --remote   # (interne) exécuté sur le NUC par la passe ci-dessus
#
# Contraintes NUC : docker-compose 1.29 (pas « docker compose »), pas de sudo, ports 80/443 pris.
set -euo pipefail

SSH_HOST="${SSH_HOST:-nuc}"
REMOTE_DIR="${REMOTE_DIR:-correspondance-matrix}"
SERVER_NAME="${SERVER_NAME:-correspondance.local}"
# Tailscale tourne sur le NUC en userspace-networking (aucune interface tailscale0) : l'IP 100.x
# n'est pas assignable en bind. tailscaled relaie le trafic entrant du tailnet vers 127.0.0.1 de
# l'hôte — on écoute donc en loopback. Résultat identique et plus fermé : rien sur le LAN 192.168.
SYNAPSE_BIND_IP="${SYNAPSE_BIND_IP:-127.0.0.1}"
# Adresse par laquelle les clients (Mac, iPhone) joignent le homeserver.
SYNAPSE_PUBLIC_IP="${SYNAPSE_PUBLIC_IP:-100.64.0.7}"
MATRIX_USER="${MATRIX_USER:-meffysto}"
MATRIX_ADMIN="@${MATRIX_USER}:${SERVER_NAME}"
WHATSAPP_IMAGE_TAG="${WHATSAPP_IMAGE_TAG:-v26.08}"

# ---------------------------------------------------------------- phase locale
if [[ "${1:-}" != "--remote" ]]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  echo "→ Copie de infra/matrix vers ${SSH_HOST}:~/${REMOTE_DIR}/"
  ssh "$SSH_HOST" "mkdir -p ~/${REMOTE_DIR}"
  scp -q -r \
    "$HERE/docker-compose.yml" \
    "$HERE/bootstrap.sh" \
    "$HERE/templates" \
    "$HERE/initdb" \
    "$SSH_HOST:~/${REMOTE_DIR}/"
  echo "→ Application sur le NUC"
  ssh "$SSH_HOST" "SERVER_NAME='${SERVER_NAME}' SYNAPSE_BIND_IP='${SYNAPSE_BIND_IP}' SYNAPSE_PUBLIC_IP='${SYNAPSE_PUBLIC_IP}' WHATSAPP_IMAGE_TAG='${WHATSAPP_IMAGE_TAG}' MATRIX_USER='${MATRIX_USER}' bash ~/${REMOTE_DIR}/bootstrap.sh --remote"
  exit 0
fi

# ---------------------------------------------------------------- phase distante
cd "$HOME/$REMOTE_DIR"
mkdir -p data/synapse data/mautrix-whatsapp data/postgres
CREDS="$HOME/$REMOTE_DIR/CREDENTIALS.txt"

# 1) Secrets — générés une seule fois, relus ensuite (idempotence).
ENVFILE=".env"
if [[ ! -f "$ENVFILE" ]]; then
  echo "→ Génération des secrets"
  {
    echo "POSTGRES_PASSWORD=$(openssl rand -hex 24)"
    echo "MACAROON_SECRET=$(openssl rand -hex 32)"
    echo "FORM_SECRET=$(openssl rand -hex 32)"
    echo "REGISTRATION_SECRET=$(openssl rand -hex 32)"
    echo "SYNAPSE_BIND_IP=${SYNAPSE_BIND_IP}"
  } > "$ENVFILE"
  chmod 600 "$ENVFILE"
fi
# shellcheck disable=SC1090
set -a; . "./$ENVFILE"; set +a
# L'IP de bind suit toujours l'appelant (le reste du .env est immuable).
if grep -q "^SYNAPSE_BIND_IP=" "$ENVFILE"; then
  sed -i "s|^SYNAPSE_BIND_IP=.*|SYNAPSE_BIND_IP=${SYNAPSE_BIND_IP}|" "$ENVFILE"
else
  echo "SYNAPSE_BIND_IP=${SYNAPSE_BIND_IP}" >> "$ENVFILE"
fi

# 2) Clé de signature + log config Synapse (via `generate`, une seule fois).
if [[ ! -f "data/synapse/${SERVER_NAME}.signing.key" ]]; then
  echo "→ Synapse generate (clé de signature + squelette)"
  docker run --rm \
    -v "$HOME/$REMOTE_DIR/data/synapse:/data" \
    -e SYNAPSE_SERVER_NAME="$SERVER_NAME" \
    -e SYNAPSE_REPORT_STATS=no \
    -e UID=1000 -e GID=1000 \
    matrixdotorg/synapse:latest generate >/dev/null
fi

# 3) homeserver.yaml depuis le template versionné (réécrit à chaque passe : source de vérité = le repo).
echo "→ Écriture de homeserver.yaml"
sed \
  -e "s|__POSTGRES_PASSWORD__|${POSTGRES_PASSWORD}|g" \
  -e "s|__MACAROON_SECRET__|${MACAROON_SECRET}|g" \
  -e "s|__FORM_SECRET__|${FORM_SECRET}|g" \
  -e "s|__REGISTRATION_SECRET__|${REGISTRATION_SECRET}|g" \
  -e "s|__SYNAPSE_PUBLIC_IP__|${SYNAPSE_PUBLIC_IP}|g" \
  templates/homeserver.yaml.tmpl > data/synapse/homeserver.yaml
chmod 600 data/synapse/homeserver.yaml

# 4) Postgres d'abord — Synapse et le bridge en dépendent.
echo "→ docker-compose up postgres"
docker-compose up -d postgres
for _ in $(seq 1 30); do
  docker-compose exec -T postgres pg_isready -U matrix -d synapse >/dev/null 2>&1 && break
  sleep 2
done
# La base du bridge : initdb ne tourne que sur volume vide, donc on la crée aussi ici.
docker-compose exec -T postgres psql -U matrix -d postgres -tc \
  "SELECT 1 FROM pg_database WHERE datname='mautrix_whatsapp'" | grep -q 1 || \
  docker-compose exec -T postgres psql -U matrix -d postgres -c \
    "CREATE DATABASE mautrix_whatsapp OWNER matrix ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0" >/dev/null

# 5) Config du bridge : config amont généré par l'image + fusion de nos overrides.
if [[ ! -f data/mautrix-whatsapp/config.yaml ]]; then
  echo "→ mautrix-whatsapp : génération du config par défaut"
  docker run --rm -u 1000:1000 \
    -v "$HOME/$REMOTE_DIR/data/mautrix-whatsapp:/data" \
    dock.mau.dev/mautrix/whatsapp:${WHATSAPP_IMAGE_TAG} >/dev/null 2>&1 || true
fi

echo "→ mautrix-whatsapp : fusion des overrides"
sed \
  -e "s|__POSTGRES_PASSWORD__|${POSTGRES_PASSWORD}|g" \
  -e "s|__MATRIX_ADMIN__|${MATRIX_ADMIN}|g" \
  templates/mautrix-whatsapp-overrides.yaml.tmpl > /tmp/wa-overrides.yaml
python3 - "$HOME/$REMOTE_DIR/data/mautrix-whatsapp/config.yaml" /tmp/wa-overrides.yaml <<'PY'
import sys, yaml

base_path, over_path = sys.argv[1], sys.argv[2]
with open(base_path) as f: base = yaml.safe_load(f)
with open(over_path) as f: over = yaml.safe_load(f)

def merge(dst, src):
    for k, v in src.items():
        if isinstance(v, dict) and isinstance(dst.get(k), dict):
            merge(dst[k], v)
        else:
            dst[k] = v
    return dst

# as_token / hs_token sont générés par le bridge : ne jamais les écraser.
merge(base, over)
with open(base_path, "w") as f:
    yaml.safe_dump(base, f, sort_keys=False, allow_unicode=True, width=4096)
PY
rm -f /tmp/wa-overrides.yaml
chmod 600 data/mautrix-whatsapp/config.yaml

# 6) registration.yaml : l'image la produit au 2e lancement (pas de flag -g dans l'entrypoint).
if [[ ! -f data/mautrix-whatsapp/registration.yaml ]]; then
  echo "→ mautrix-whatsapp : génération de la registration"
  docker run --rm -u 1000:1000 \
    -v "$HOME/$REMOTE_DIR/data/mautrix-whatsapp:/data" \
    dock.mau.dev/mautrix/whatsapp:${WHATSAPP_IMAGE_TAG} >/dev/null 2>&1 || true
fi
[[ -f data/mautrix-whatsapp/registration.yaml ]] || { echo "✗ registration.yaml absent"; exit 1; }
cp data/mautrix-whatsapp/registration.yaml data/synapse/whatsapp-registration.yaml
chmod 600 data/synapse/whatsapp-registration.yaml

# 7) La pile complète.
echo "→ docker-compose up -d"
docker-compose up -d

# 8) Attente de Synapse.
echo "→ Attente du homeserver"
OK=0
for _ in $(seq 1 45); do
  if curl -fsS "http://127.0.0.1:8008/_matrix/client/versions" >/dev/null 2>&1 \
    || curl -fsS "http://${SYNAPSE_PUBLIC_IP}:8008/_matrix/client/versions" >/dev/null 2>&1; then
    OK=1; break
  fi
  sleep 2
done
[[ "$OK" == 1 ]] || { echo "✗ Synapse ne répond pas"; docker-compose logs --tail=40 synapse; exit 1; }

# 9) Utilisateur Matrix — créé une seule fois, mot de passe écrit dans CREDENTIALS.txt.
if [[ ! -f "$CREDS" ]]; then
  MATRIX_PASSWORD="$(openssl rand -base64 24)"
  echo "→ Création de l'utilisateur ${MATRIX_ADMIN}"
  docker-compose exec -T synapse register_new_matrix_user \
    -u "$MATRIX_USER" -p "$MATRIX_PASSWORD" -a \
    -c /data/homeserver.yaml "http://localhost:8008" >/dev/null
  umask 077
  cat > "$CREDS" <<EOF
# Correspondance — identifiants Matrix (NUC). Ne jamais copier dans le repo.
homeserver = http://${SYNAPSE_PUBLIC_IP}:8008
server_name = ${SERVER_NAME}
mxid        = ${MATRIX_ADMIN}
user        = ${MATRIX_USER}
password    = ${MATRIX_PASSWORD}
bot         = @whatsappbot:${SERVER_NAME}
EOF
  chmod 600 "$CREDS"
fi

echo
docker-compose ps
echo
echo "✓ Pile Matrix prête. Identifiants : ${CREDS} (chmod 600, hors repo)."
