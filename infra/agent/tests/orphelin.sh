#!/bin/sh
# Éprouve pour de vrai que l'agent meurt quand son parent est tué brutalement.
#
# Un parent (sh) lance l'agent avec --watch-parent, on tue le parent par
# SIGKILL — ce que fait `pkill`, un « Forcer à quitter » ou un crash — et on
# regarde si l'enfant s'en va tout seul.
set -eu
AGENT="$1"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Une amorce bidon : l'agent échouera à se connecter, mais il aura démarré sa
# surveillance avant — c'est elle qu'on éprouve, pas la connexion.
mkdir -p "$TMP/home"
cat > "$TMP/home/config.json" <<'JSON'
{"homeserver":"http://127.0.0.1:9","user":"cc","password":"x","owners":["@g:s"]}
JSON

# Le parent : un shell qui lance l'agent et attend.
CORRESPONDANCE_AGENT_HOME="$TMP/home" sh -c "
  '$AGENT' run --watch-parent \$\$ > '$TMP/agent.log' 2>&1 &
  echo \$! > '$TMP/enfant.pid'
  sleep 60
" &
PARENT=$!
sleep 3

ENFANT="$(cat "$TMP/enfant.pid" 2>/dev/null || echo "")"
[ -n "$ENFANT" ] || { echo "✗ l'agent n'a pas démarré"; cat "$TMP/agent.log" 2>/dev/null; exit 1; }
kill -0 "$ENFANT" 2>/dev/null || { echo "✗ l'agent n'était déjà plus là avant le test"; cat "$TMP/agent.log"; exit 1; }
echo "  ✓ l'agent tourne (pid $ENFANT), surveillance annoncée :"
grep -m1 "surveillance du parent" "$TMP/agent.log" | sed 's/^/    /' || echo "    (pas de ligne)"

echo "  → SIGKILL sur le parent ($PARENT) — ni signal ni chance de faire le ménage"
kill -9 "$PARENT" 2>/dev/null || true

for i in $(seq 1 15); do
  kill -0 "$ENFANT" 2>/dev/null || { echo "  ✓ l'agent s'est arrêté tout seul (après ${i} s)"; exit 0; }
  sleep 1
done

echo "  ✗ l'agent a SURVÉCU à la mort de son parent — l'invariant est cassé"
kill -9 "$ENFANT" 2>/dev/null || true
exit 1
