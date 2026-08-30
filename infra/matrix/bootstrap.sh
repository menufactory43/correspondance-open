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
# Instagram : même image que Messenger, tag préfixé `ig-`. Depuis v26.08 mautrix-meta ne fait
# plus que Messenger — Instagram est passé au binaire mautrix-instagram.
META_IMAGE_TAG="${META_IMAGE_TAG:-ig-v26.08}"

# ---------------------------------------------------------------- phase locale
if [[ "${1:-}" != "--remote" ]]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  echo "→ Copie de infra/matrix vers ${SSH_HOST}:~/${REMOTE_DIR}/"
  ssh "$SSH_HOST" "mkdir -p ~/${REMOTE_DIR}"
  scp -q -r \
    "$HERE/docker-compose.yml" \
    "$HERE/bootstrap.sh" \
    "$HERE/merge-overrides.py" \
    "$HERE/templates" \
    "$HERE/initdb" \
    "$SSH_HOST:~/${REMOTE_DIR}/"
  echo "→ Application sur le NUC"
  ssh "$SSH_HOST" "SERVER_NAME='${SERVER_NAME}' SYNAPSE_BIND_IP='${SYNAPSE_BIND_IP}' SYNAPSE_PUBLIC_IP='${SYNAPSE_PUBLIC_IP}' WHATSAPP_IMAGE_TAG='${WHATSAPP_IMAGE_TAG}' META_IMAGE_TAG='${META_IMAGE_TAG}' MATRIX_USER='${MATRIX_USER}' bash ~/${REMOTE_DIR}/bootstrap.sh --remote"
  exit 0
fi

# ---------------------------------------------------------------- phase distante
cd "$HOME/$REMOTE_DIR"
mkdir -p data/synapse data/mautrix-whatsapp data/mautrix-meta data/postgres
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

# 4) Postgres d'abord — Synapse et les bridges en dépendent.
echo "→ docker-compose up postgres"
docker-compose up -d postgres
for _ in $(seq 1 30); do
  docker-compose exec -T postgres pg_isready -U matrix -d synapse >/dev/null 2>&1 && break
  sleep 2
done

# Les bases des bridges : initdb ne tourne que sur volume vide, donc on les crée aussi ici.
ensure_database() {
  local dbname="$1"
  docker-compose exec -T postgres psql -U matrix -d postgres -tc \
    "SELECT 1 FROM pg_database WHERE datname='${dbname}'" | grep -q 1 || \
    docker-compose exec -T postgres psql -U matrix -d postgres -c \
      "CREATE DATABASE ${dbname} OWNER matrix ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0" >/dev/null
}
ensure_database mautrix_whatsapp
ensure_database mautrix_meta

# 5) Config et registration de chaque pont — même mécanique pour les deux, d'où la fonction :
#    l'image écrit son config par défaut (`-e`), on fusionne nos overrides par-dessus, puis
#    l'image produit la registration (`-g`) qu'on dépose chez Synapse.
#
#    setup_bridge <service> <image> <tag> <template-overrides> <registration> <binaire>
#
#    Le binaire est passé explicitement parce que l'image `ig-` livre mautrix-instagram
#    sous le nom /usr/bin/mautrix-meta (vérifié : `--version` → « mautrix-instagram v26.08 »).
setup_bridge() {
  local name="$1" image="$2" tag="$3" tmpl="$4" registration="$5" binary="$6"
  local dir="$HOME/$REMOTE_DIR/data/${name}"

  if [[ ! -f "${dir}/config.yaml" ]]; then
    echo "→ ${name} : génération du config par défaut"
    docker run --rm -u 1000:1000 -v "${dir}:/data" \
      --entrypoint "/usr/bin/${binary}" "${image}:${tag}" \
      -c /data/config.yaml -e >/dev/null 2>&1 || true
  fi
  [[ -f "${dir}/config.yaml" ]] || { echo "✗ ${name} : config.yaml absent"; exit 1; }

  echo "→ ${name} : fusion des overrides"
  local merged="/tmp/${name}-overrides.yaml"
  sed \
    -e "s|__POSTGRES_PASSWORD__|${POSTGRES_PASSWORD}|g" \
    -e "s|__MATRIX_ADMIN__|${MATRIX_ADMIN}|g" \
    "templates/${tmpl}" > "$merged"
  python3 merge-overrides.py "${dir}/config.yaml" "$merged"
  rm -f "$merged"
  chmod 600 "${dir}/config.yaml"

  if [[ ! -f "${dir}/registration.yaml" ]]; then
    echo "→ ${name} : génération de la registration"
    docker run --rm -u 1000:1000 -v "${dir}:/data" \
      --entrypoint "/usr/bin/${binary}" "${image}:${tag}" \
      -g -c /data/config.yaml -r /data/registration.yaml >/dev/null 2>&1 || true
  fi
  [[ -f "${dir}/registration.yaml" ]] || { echo "✗ ${name} : registration.yaml absent"; exit 1; }
  cp "${dir}/registration.yaml" "data/synapse/${registration}"
  chmod 600 "data/synapse/${registration}"
}

# Synapse ne relit ses registrations qu'au démarrage : si l'une d'elles change (nouveau pont),
# `up -d` seul le laisse tourner sans la connaître — le bot reste « invité » à jamais.
registrations_fingerprint() { cat data/synapse/*-registration.yaml 2>/dev/null | md5sum; }
REG_BEFORE="$(registrations_fingerprint)"

setup_bridge mautrix-whatsapp dock.mau.dev/mautrix/whatsapp "$WHATSAPP_IMAGE_TAG" \
  mautrix-whatsapp-overrides.yaml.tmpl whatsapp-registration.yaml mautrix-whatsapp
setup_bridge mautrix-meta dock.mau.dev/mautrix/meta "$META_IMAGE_TAG" \
  mautrix-meta-overrides.yaml.tmpl meta-registration.yaml mautrix-meta

# 6) La pile complète.
echo "→ docker-compose up -d"
docker-compose up -d

# 7) Attente de Synapse.
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

# Registrations changées, ou un pont qui se plaint de son as_token : Synapse doit redémarrer,
# puis les ponts derrière lui (ils s'arrêtent net quand le jeton est refusé).
NEED_SYNAPSE_RESTART=0
[[ "$(registrations_fingerprint)" != "$REG_BEFORE" ]] && NEED_SYNAPSE_RESTART=1
for svc in mautrix-whatsapp mautrix-meta; do
  docker-compose logs --tail=30 "$svc" 2>/dev/null | grep -q "as_token was not accepted" && NEED_SYNAPSE_RESTART=1
done
if [[ "$NEED_SYNAPSE_RESTART" == 1 ]]; then
  echo "→ Registrations modifiées : redémarrage de Synapse puis des ponts"
  docker-compose restart synapse >/dev/null
  for _ in $(seq 1 45); do
    curl -fsS "http://127.0.0.1:8008/_matrix/client/versions" >/dev/null 2>&1 && break
    sleep 2
  done
  docker-compose restart mautrix-whatsapp mautrix-meta >/dev/null
fi

# 8) Utilisateur Matrix — créé une seule fois, mot de passe écrit dans CREDENTIALS.txt.
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
EOF
  chmod 600 "$CREDS"
fi

# Un CREDENTIALS.txt écrit par une passe plus ancienne ignore les bots ajoutés depuis :
# on complète ligne par ligne, sans jamais réécrire le fichier — le mot de passe est
# la seule chose qu'on ne saurait pas régénérer.
add_credentials_line() {
  local key="$1" value="$2"
  grep -q "^${key}[[:space:]]*=" "$CREDS" || printf '%-13s = %s\n' "$key" "$value" >> "$CREDS"
}
add_credentials_line "bot_whatsapp" "@whatsappbot:${SERVER_NAME}"
add_credentials_line "bot_instagram" "@instagrambot:${SERVER_NAME}"

echo
docker-compose ps
echo
echo "✓ Pile Matrix prête (WhatsApp + Instagram). Identifiants : ${CREDS} (chmod 600, hors repo)."
