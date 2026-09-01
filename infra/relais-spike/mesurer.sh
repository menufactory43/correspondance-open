#!/usr/bin/env bash
# Correspondance — les mesures du spike : mémoire, démarrage à froid, disque,
# taille des binaires. À lancer sur une pile qui tourne depuis au moins 5 minutes.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/config.sh"

echo "## Mémoire résidente (ps -o rss, en Ko) et âge du processus"
printf '%-20s %8s %10s %8s\n' processus RSS_Ko âge CPU
for n in relais mautrix-whatsapp mautrix-signal; do
  [[ -f "$RUN_DIR/$n.pid" ]] || continue
  p="$(cat "$RUN_DIR/$n.pid")"
  ps -o rss=,etime=,%cpu= -p "$p" 2>/dev/null \
    | awk -v n="$n" '{printf "%-20s %8s %10s %8s\n", n, $1, $2, $3}'
done

echo
echo "## Taille des binaires"
ls -l "$BIN_DIR" | awk 'NR>1 {printf "%-24s %10d octets\n", $NF, $5}'

echo
echo "## Disque"
du -sh "$RELAIS_DIR/db" "$SPIKE_HOME/mautrix-whatsapp" "$SPIKE_HOME/mautrix-signal" \
       "$BIN_DIR" 2>/dev/null
echo -n "total hors sources et journaux : "
du -sh --exclude=src --exclude=logs "$SPIKE_HOME" 2>/dev/null \
  || { du -sk "$SPIKE_HOME/relais" "$SPIKE_HOME/bin" "$SPIKE_HOME/mautrix-whatsapp" \
         "$SPIKE_HOME/mautrix-signal" 2>/dev/null | awk '{t+=$1} END {printf "%.0f Mo\n", t/1024}'; }

echo
echo "## Démarrage à froid du Relais (base déjà peuplée)"
bash "$HERE/stop.sh" >/dev/null 2>&1
DEBUT="$(python3 -c 'import time; print(time.time())')"
bash "$HERE/start.sh" relais >/dev/null 2>&1
FIN="$(python3 -c 'import time; print(time.time())')"
python3 -c "print(f'{float('$FIN') - float('$DEBUT'):.2f} s jusqu\'à la première réponse de /_matrix/client/versions')"
bash "$HERE/start.sh" ponts >/dev/null 2>&1
echo "les ponts sont relancés"
