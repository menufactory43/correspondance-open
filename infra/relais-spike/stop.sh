#!/usr/bin/env bash
# Correspondance — arrête le Relais du spike, et lui seul : chaque PID vient de
# $RUN_DIR, écrit par start.sh. Aucun `pkill` par nom, qui frapperait la prod.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/config.sh"

[[ -d "$RUN_DIR" ]] || { dire "rien à arrêter"; exit 0; }
for f in "$RUN_DIR"/*.pid; do
  [[ -e "$f" ]] || continue
  nom="$(basename "$f" .pid)"; pid="$(cat "$f")"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$pid" 2>/dev/null && { alerte "$nom ne s'arrête pas — SIGKILL"; kill -9 "$pid"; }
    dire "$nom arrêté (pid $pid)"
  else
    dire "$nom déjà arrêté"
  fi
  rm -f "$f"
done
