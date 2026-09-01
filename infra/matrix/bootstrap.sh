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
# Messenger : la même image, tag nu. C'est le binaire mautrix-facebook — un second
# conteneur, une seconde base, un second bot. Les deux réseaux de Meta ne se
# partagent plus rien depuis que chacun a son binaire.
MESSENGER_IMAGE_TAG="${MESSENGER_IMAGE_TAG:-v26.08}"
SIGNAL_IMAGE_TAG="${SIGNAL_IMAGE_TAG:-v26.08}"
# Push iOS (Sygnal). Ces trois-là ne se génèrent pas : ils viennent du portail
# Apple. On les passe en variables d'environnement à la première passe, ils
# atterrissent dans le .env du NUC et n'en bougent plus.
# Cf. docs/MATRIX-SETUP.md § « Push iOS — Sygnal ».
APNS_KEY_ID="${APNS_KEY_ID:-}"
APNS_TEAM_ID="${APNS_TEAM_ID:-}"
# sandbox = Xcode et TestFlight interne ; production = App Store.
APNS_PLATFORM="${APNS_PLATFORM:-sandbox}"

# ---------------------------------------------------------------- phase locale
if [[ "${1:-}" != "--remote" ]]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  echo "→ Copie de infra/matrix vers ${SSH_HOST}:~/${REMOTE_DIR}/"
  ssh "$SSH_HOST" "mkdir -p ~/${REMOTE_DIR}"
  scp -q -r \
    "$HERE/docker-compose.yml" \
    "$HERE/bootstrap.sh" \
    "$HERE/merge-overrides.py" \
    "$HERE/pair.sh" \
    "$HERE/templates" \
    "$HERE/initdb" \
    "$SSH_HOST:~/${REMOTE_DIR}/"
  echo "→ Application sur le NUC"
  ssh "$SSH_HOST" "SERVER_NAME='${SERVER_NAME}' SYNAPSE_BIND_IP='${SYNAPSE_BIND_IP}' SYNAPSE_PUBLIC_IP='${SYNAPSE_PUBLIC_IP}' WHATSAPP_IMAGE_TAG='${WHATSAPP_IMAGE_TAG}' META_IMAGE_TAG='${META_IMAGE_TAG}' MESSENGER_IMAGE_TAG='${MESSENGER_IMAGE_TAG}' SIGNAL_IMAGE_TAG='${SIGNAL_IMAGE_TAG}' MATRIX_USER='${MATRIX_USER}' APNS_KEY_ID='${APNS_KEY_ID}' APNS_TEAM_ID='${APNS_TEAM_ID}' APNS_PLATFORM='${APNS_PLATFORM}' bash ~/${REMOTE_DIR}/bootstrap.sh --remote"
  exit 0
fi

# ---------------------------------------------------------------- phase distante
cd "$HOME/$REMOTE_DIR"
mkdir -p data/synapse data/mautrix-whatsapp data/mautrix-meta data/mautrix-messenger data/mautrix-signal data/postgres data/sygnal secrets/apns
chmod 700 secrets secrets/apns
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

# Les jetons du double puppeting sont arrivés après les autres : un .env écrit par une passe
# plus ancienne ne les connaît pas. On les ajoute ligne par ligne, une seule fois — les
# régénérer à chaque passe casserait les ponts, qui les portent dans leur config.
ensure_env_secret() {
  local key="$1" value="$2"
  if ! grep -q "^${key}=" "$ENVFILE"; then
    echo "${key}=${value}" >> "$ENVFILE"
    export "${key}=${value}"
  fi
}
ensure_env_secret DOUBLEPUPPET_AS_TOKEN "$(openssl rand -hex 32)"
ensure_env_secret DOUBLEPUPPET_HS_TOKEN "$(openssl rand -hex 32)"
ensure_env_secret DOUBLEPUPPET_SENDER "dp$(openssl rand -hex 12)"

# Les identifiants APNs ne sont pas des secrets générés — ils viennent d'Apple.
# On les mémorise à la première passe qui les fournit, et on les relit ensuite :
# relancer le bootstrap sans les repasser ne doit pas effacer le push.
remember_env_value() {
  local key="$1" value="$2"
  if [[ -n "$value" ]]; then
    if grep -q "^${key}=" "$ENVFILE"; then
      sed -i "s|^${key}=.*|${key}=${value}|" "$ENVFILE"
    else
      echo "${key}=${value}" >> "$ENVFILE"
    fi
    export "${key}=${value}"
  fi
}
remember_env_value APNS_KEY_ID "${APNS_KEY_ID}"
remember_env_value APNS_TEAM_ID "${APNS_TEAM_ID}"
remember_env_value APNS_PLATFORM "${APNS_PLATFORM}"
set -a; . "./$ENVFILE"; set +a

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
ensure_database mautrix_messenger
ensure_database mautrix_signal

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
    -e "s|__SERVER_NAME__|${SERVER_NAME}|g" \
    -e "s|__DOUBLEPUPPET_AS_TOKEN__|${DOUBLEPUPPET_AS_TOKEN}|g" \
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
# Ici le binaire porte bien le nom du pont — pas de piège façon `ig-`/mautrix-meta.
# Même image que ci-dessus, tag nu : cette fois c'est bien Messenger qui sort du
# binaire /usr/bin/mautrix-meta (`--version` → « mautrix-facebook v26.08 »).
setup_bridge mautrix-messenger dock.mau.dev/mautrix/meta "$MESSENGER_IMAGE_TAG" \
  mautrix-messenger-overrides.yaml.tmpl messenger-registration.yaml mautrix-meta
setup_bridge mautrix-signal dock.mau.dev/mautrix/signal "$SIGNAL_IMAGE_TAG" \
  mautrix-signal-overrides.yaml.tmpl signal-registration.yaml mautrix-signal

# Double puppeting « par appservice » (docs.mau.fi/bridges/general/double-puppeting.html) :
# une registration sans `url`, que Synapse ne rappelle jamais, mais dont l'`as_token` autorise
# son porteur à écrire au nom de n'importe quel compte local. Les ponts s'en servent pour poser
# mes messages envoyés depuis le téléphone sous mon MXID plutôt que sous mon propre ghost.
# Réécrite à chaque passe comme les autres configs, mais depuis des jetons stables (.env).
echo "→ Écriture de doublepuppet-registration.yaml"
SERVER_NAME_REGEX="${SERVER_NAME//./\\.}"
cat > data/synapse/doublepuppet-registration.yaml <<EOF
# Généré par infra/matrix/bootstrap.sh — contient des jetons, ne jamais versionner.
id: doublepuppet
url: null
as_token: ${DOUBLEPUPPET_AS_TOKEN}
hs_token: ${DOUBLEPUPPET_HS_TOKEN}
sender_localpart: ${DOUBLEPUPPET_SENDER}
rate_limited: false
namespaces:
  users:
    - regex: '@.*:${SERVER_NAME_REGEX}'
      exclusive: false
EOF
chmod 600 data/synapse/doublepuppet-registration.yaml

# 6) Sygnal — la config, et le verdict sur la clé APNs.
#    Le service reste déclaré même sans clé : docker-compose le redémarrera en
#    boucle, ce qui est un signal plus honnête qu'un push silencieusement absent.
echo "→ Écriture de sygnal.yaml"
sed \
  -e "s|__APNS_KEY_ID__|${APNS_KEY_ID:-__APNS_KEY_ID__}|g" \
  -e "s|__APNS_TEAM_ID__|${APNS_TEAM_ID:-__APNS_TEAM_ID__}|g" \
  -e "s|__APNS_PLATFORM__|${APNS_PLATFORM:-sandbox}|g" \
  templates/sygnal.yaml.tmpl > data/sygnal/sygnal.yaml
chmod 600 data/sygnal/sygnal.yaml

APNS_READY=1
[[ -f "secrets/apns/apns.p8" ]] || { echo "⚠ secrets/apns/apns.p8 absent — le push iOS ne partira pas."; APNS_READY=0; }
[[ -n "${APNS_KEY_ID:-}" ]] || { echo "⚠ APNS_KEY_ID non renseigné — voir docs/MATRIX-SETUP.md."; APNS_READY=0; }
[[ -n "${APNS_TEAM_ID:-}" ]] || { echo "⚠ APNS_TEAM_ID non renseigné — voir docs/MATRIX-SETUP.md."; APNS_READY=0; }

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

# Registrations changées, ou un pont qui se plaint de son as_token : Synapse doit redémarrer,
# puis les ponts derrière lui (ils s'arrêtent net quand le jeton est refusé).
NEED_SYNAPSE_RESTART=0
[[ "$(registrations_fingerprint)" != "$REG_BEFORE" ]] && NEED_SYNAPSE_RESTART=1
for svc in mautrix-whatsapp mautrix-meta mautrix-messenger mautrix-signal; do
  docker-compose logs --tail=30 "$svc" 2>/dev/null | grep -q "as_token was not accepted" && NEED_SYNAPSE_RESTART=1
done
if [[ "$NEED_SYNAPSE_RESTART" == 1 ]]; then
  echo "→ Registrations modifiées : redémarrage de Synapse puis des ponts"
  docker-compose restart synapse >/dev/null
  for _ in $(seq 1 45); do
    curl -fsS "http://127.0.0.1:8008/_matrix/client/versions" >/dev/null 2>&1 && break
    sleep 2
  done
  docker-compose restart mautrix-whatsapp mautrix-meta mautrix-messenger mautrix-signal >/dev/null
fi

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
add_credentials_line "bot_messenger" "@messengerbot:${SERVER_NAME}"
add_credentials_line "bot_signal" "@signalbot:${SERVER_NAME}"

# 10) Sygnal répond-il ? Depuis le réseau Docker uniquement : rien n'est publié.
if [[ "$APNS_READY" == 1 ]]; then
  SYGNAL_OK=0
  for _ in $(seq 1 15); do
    if docker-compose exec -T synapse curl -fsS "http://sygnal:5000/health" >/dev/null 2>&1; then
      SYGNAL_OK=1; break
    fi
    sleep 2
  done
  if [[ "$SYGNAL_OK" == 1 ]]; then
    echo "✓ Sygnal répond à Synapse (http://sygnal:5000/health)"
  else
    echo "⚠ Sygnal ne répond pas — docker-compose logs sygnal"
  fi
fi

echo
docker-compose ps
echo
echo "✓ Pile Matrix prête (WhatsApp + Instagram + Messenger + Signal). Identifiants : ${CREDS} (chmod 600, hors repo)."
if [[ "$APNS_READY" == 1 ]]; then
  echo "✓ Push iOS : Sygnal armé pour com.correspondance.ios (${APNS_PLATFORM})."
else
  echo "⚠ Push iOS : Sygnal démarré sans clé APNs utilisable — voir docs/MATRIX-SETUP.md § « Push iOS — Sygnal »."
fi
