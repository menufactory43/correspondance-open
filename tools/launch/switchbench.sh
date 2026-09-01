#!/bin/zsh
# switchbench.sh <app> [runs] [count] [CORR_EXP]
# Lance l'app avec CORR_BENCH=switch:<count> (le pilote intégré ouvre les
# <count> premiers fils de la file, un par un, et journalise chaque latence
# sélection → fil montré), attend, puis relit le journal. Médiane par run.
set -u
APP=$1; RUNS=${2:-3}; COUNT=${3:-12}; EXP=${4:-}
for run in $(seq 1 $RUNS); do
  pkill -x Correspondance 2>/dev/null; sleep 1.5
  START=$(date "+%Y-%m-%d %H:%M:%S")
  if [ -n "$EXP" ]; then
    open -n --env CORR_BENCH=switch:$COUNT --env CORR_EXP=$EXP "$APP"
  else
    open -n --env CORR_BENCH=switch:$COUNT "$APP"
  fi
  sleep $((6 + COUNT))
  pkill -x Correspondance 2>/dev/null; sleep 0.5
  /usr/bin/log show --start "$START" --style compact --predicate 'subsystem == "app.correspondance.launch" AND category == "bench"' 2>/dev/null \
    | grep -o "BENCH switch-summary.*" | sed "s/^/run $run (${EXP:-base}): /"
done
