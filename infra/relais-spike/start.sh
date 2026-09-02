#!/usr/bin/env bash
# Correspondance — démarre le Relais du spike (Continuwuity + les deux ponts).
#
#   infra/relais-spike/start.sh            # tout
#   infra/relais-spike/start.sh relais     # le homeserver seul
#
# Rien n'écoute ailleurs que sur 127.0.0.1. Les PID vivent dans $RUN_DIR : stop.sh
# ne tue que ceux-là — jamais un processus de la prod.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/config.sh"
QUOI="${1:-tout}"

mkdir -p "$RUN_DIR" "$LOG_DIR"

vivant() { [[ -f "$RUN_DIR/$1.pid" ]] && kill -0 "$(cat "$RUN_DIR/$1.pid")" 2>/dev/null; }

port_libre() {
  local p="$1"
  if lsof -i ":$p" -sTCP:LISTEN -P -n >/dev/null 2>&1; then
    mourir "le port $p est déjà pris — lsof -i :$p"
  fi
}

lancer() {
  local nom="$1"; shift
  if vivant "$nom"; then dire "$nom déjà en marche (pid $(cat "$RUN_DIR/$nom.pid"))"; return; fi
  "$@" >>"$LOG_DIR/$nom.log" 2>&1 &
  echo $! > "$RUN_DIR/$nom.pid"
  dire "$nom : pid $! — journal $LOG_DIR/$nom.log"
}

if [[ "$QUOI" == "tout" || "$QUOI" == "relais" ]]; then
  vivant relais || port_libre "$RELAIS_PORT"
  lancer relais "$BIN_DIR/continuwuity" -c "$RELAIS_DIR/continuwuity.toml"
  dire "attente du Relais sur $RELAIS_URL"
  for _ in $(seq 1 60); do
    curl -fsS "$RELAIS_URL/_matrix/client/versions" >/dev/null 2>&1 && break
    sleep 0.5
  done
  curl -fsS "$RELAIS_URL/_matrix/client/versions" >/dev/null 2>&1 \
    || { tail -20 "$LOG_DIR/relais.log" >&2; mourir "le Relais ne répond pas"; }
  dire "✓ le Relais répond ($(curl -fsS "$RELAIS_URL/_continuwuity/server_version"))"
fi

if [[ "$QUOI" == "tout" || "$QUOI" == "ponts" ]]; then
  for p in whatsapp signal; do
    eval "port=\$$(echo "$p" | tr 'a-z' 'A-Z')_PORT"
    vivant "mautrix-$p" || port_libre "$port"
    lancer "mautrix-$p" "$BIN_DIR/mautrix-$p" -c "$SPIKE_HOME/mautrix-$p/config.yaml"
  done
fi
