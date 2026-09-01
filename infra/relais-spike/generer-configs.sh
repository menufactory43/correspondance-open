#!/usr/bin/env bash
# Correspondance — écrit la configuration du Relais du spike. Idempotent :
# les secrets sont tirés une fois (secrets.env) et relus ensuite.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/config.sh"

mkdir -p "$RELAIS_DIR/db" "$LOG_DIR" "$RUN_DIR" \
         "$SPIKE_HOME/mautrix-whatsapp" "$SPIKE_HOME/mautrix-signal"
chmod 700 "$SPIKE_HOME"

SECRETS="$SPIKE_HOME/secrets.env"
if [[ ! -f "$SECRETS" ]]; then
  dire "génération des secrets ($SECRETS, chmod 600, hors dépôt)"
  umask 077
  {
    echo "REGISTRATION_TOKEN=$(openssl rand -hex 24)"
    echo "MATRIX_PASSWORD=$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(24)))')"
    echo "WHATSAPP_AS_TOKEN=$(openssl rand -hex 32)"
    echo "WHATSAPP_HS_TOKEN=$(openssl rand -hex 32)"
    echo "SIGNAL_AS_TOKEN=$(openssl rand -hex 32)"
    echo "SIGNAL_HS_TOKEN=$(openssl rand -hex 32)"
  } > "$SECRETS"
  chmod 600 "$SECRETS"
fi
set -a; . "$SECRETS"; set +a

# ------------------------------------------------------------ Continuwuity
# Un Relais personnel : pas de fédération, pas d'appel au réseau, un seul compte
# ouvert par jeton le temps de l'appairage.
cat > "$RELAIS_DIR/continuwuity.toml" <<EOF
# Écrit par infra/relais-spike/generer-configs.sh — contient un jeton, ne pas versionner.
[global]
server_name = "${SERVER_NAME}"
address = ["${BIND_ADDRESS}"]
port = ${RELAIS_PORT}
database_path = "${RELAIS_DIR}/db"
new_user_displayname_suffix = ""

# Le premier compte enregistré devient administrateur et rejoint #admins — c'est par
# ce salon que passent les commandes d'administration (Continuwuity n'a pas d'API HTTP
# d'administration : cf. docs/spike-un-clic/phase-1.md).
allow_registration = true
registration_token = "${REGISTRATION_TOKEN}"
yes_i_am_very_very_sure_i_want_an_open_registration_server_prone_to_abuse = false

# Relais personnel sur la machine de son propriétaire : rien ne sort.
allow_federation = false
allow_public_room_directory_over_federation = false
allow_announcements_check = false  # (allow_check_for_updates en est un alias : les deux ensemble = « duplicate field »)
trusted_servers = []

log = "info"
log_colors = false
EOF
chmod 600 "$RELAIS_DIR/continuwuity.toml"
dire "écrit $RELAIS_DIR/continuwuity.toml"

# ---------------------------------------------------------------- les ponts
# Chaque pont écrit son propre config par défaut (-e), puis on applique nos choix
# par-dessus — même mécanique que bootstrap.sh, mais sans conteneur et en SQLite.
pont() {
  local nom="$1" port="$2" as_token="$3" hs_token="$4" prefixe="$5" bot="$6"
  local dir="$SPIKE_HOME/mautrix-$nom"
  local bin="$BIN_DIR/mautrix-$nom"

  if [[ ! -f "$dir/config.yaml" ]]; then
    dire "mautrix-$nom : config par défaut"
    "$bin" -c "$dir/config.yaml" -e >/dev/null 2>&1 || true
  fi
  [[ -f "$dir/config.yaml" ]] || mourir "mautrix-$nom : config.yaml absent"

  cat > "$dir/overrides.yaml" <<EOF
homeserver:
  address: ${RELAIS_URL}
  domain: ${SERVER_NAME}
  # Continuwuity n'est pas Synapse : le pont ne doit pas tenter les extensions
  # propres à Synapse (ni l'API d'administration, ni le double puppeting par
  # jeton partagé). « standard » est la valeur qui n'en suppose aucune.
  software: standard

appservice:
  address: http://127.0.0.1:${port}
  hostname: 127.0.0.1
  port: ${port}
  id: ${nom}
  as_token: ${as_token}
  hs_token: ${hs_token}
  bot:
    username: ${bot}
    displayname: ${nom} bridge bot
  username_template: ${nom}_{{.}}

database:
  type: sqlite3-fk-wal
  uri: file:${dir}/${nom}.db?_txlock=immediate

bridge:
  command_prefix: '${prefixe}'
  personal_filtering_spaces: true
  private_chat_portal_meta: true
  permissions:
    '${SERVER_NAME}': user
    '${MATRIX_ADMIN}': admin

# Le client Swift n'a pas de machine Olm : un portail chiffré serait illisible.
encryption:
  allow: false
  default: false
  require: false

# Double puppeting : hors sujet pour le spike, et il suppose une registration
# supplémentaire chez le homeserver.
double_puppet:
  servers: {}
  secrets: {}

matrix:
  federate_rooms: false

logging:
  min_level: info
  writers:
    - type: stdout
      format: pretty-colored
EOF
  python3 "$HERE/../matrix/merge-overrides.py" "$dir/config.yaml" "$dir/overrides.yaml"
  chmod 600 "$dir/config.yaml"

  dire "mautrix-$nom : registration"
  "$bin" -c "$dir/config.yaml" -g -r "$dir/registration.yaml" >/dev/null 2>&1 || true
  [[ -f "$dir/registration.yaml" ]] || mourir "mautrix-$nom : registration.yaml absent"
  chmod 600 "$dir/registration.yaml"
}

pont whatsapp "$WHATSAPP_PORT" "$WHATSAPP_AS_TOKEN" "$WHATSAPP_HS_TOKEN" '!wa' whatsappbot
pont signal   "$SIGNAL_PORT"   "$SIGNAL_AS_TOKEN"   "$SIGNAL_HS_TOKEN"   '!signal' signalbot

dire "configurations prêtes sous $SPIKE_HOME"
