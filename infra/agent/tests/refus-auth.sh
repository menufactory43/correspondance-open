#!/bin/sh
# Éprouve **de bout en bout** qu'un refus d'authentification sort en 78.
#
#   infra/agent/tests/refus-auth.sh <chemin du binaire correspondance-agent>
#
# Pourquoi de bout en bout : les tests unitaires prouvaient chaque moitié — un
# processus qui sort en 78 n'est pas relancé, et la détection typée reconnaît un
# 403 — sans jamais vérifier la **jonction**, c'est-à-dire que l'agent, face à
# un vrai refus, sorte effectivement en 78. Il sortait en 1, et le surveillant
# le relançait huit fois.
set -eu

AGENT="${1:?usage : refus-auth.sh <binaire>}"
PORT="${PORT:-8919}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [ -n "${SERVEUR:-}" ] && kill "$SERVEUR" 2>/dev/null || true' EXIT

# Un homeserver qui refuse tout, comme Synapse devant un mauvais mot de passe.
cat > "$TMP/faux.py" <<'PY'
import http.server, json, sys

class Refus(http.server.BaseHTTPRequestHandler):
    def _repond(self):
        corps = json.dumps({
            "errcode": "M_FORBIDDEN",
            "error": "Invalid username or password",
        }).encode()
        self.send_response(403)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)

    do_GET = do_POST = do_PUT = lambda self: self._repond()

    def log_message(self, *a):
        pass

http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Refus).serve_forever()
PY

python3 "$TMP/faux.py" "$PORT" &
SERVEUR=$!
sleep 1

mkdir -p "$TMP/home"
cat > "$TMP/home/config.json" <<JSON
{"homeserver":"http://127.0.0.1:$PORT","user":"cc","password":"mauvais-mot-de-passe",
 "owners":["@essai:correspondance.essai"]}
JSON

set +e
CORRESPONDANCE_AGENT_HOME="$TMP/home" "$AGENT" run > "$TMP/sortie.txt" 2>&1
CODE=$?
set -e

echo "  sortie de l'agent :"
sed 's/^/    /' "$TMP/sortie.txt"
echo "  code de sortie : $CODE (attendu 78)"

if [ "$CODE" -eq 78 ]; then
  echo "  ✓ un refus d'authentification sort en 78 : l'app ne le relancera pas"
  exit 0
fi
echo "  ✗ le refus sort en $CODE — le surveillant le prendra pour une chute ordinaire"
exit 1
