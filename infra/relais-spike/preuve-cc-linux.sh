#!/usr/bin/env bash
# Phase 7a, livrable 1 — `cc` lit et écrit chiffré **sous Linux**.
#
# C'est la preuve de la phase 5 rejouée là où elle manquait : le Relais et
# l'agent sur le NUC (x86_64, Debian glibc), l'appareil A sur ce Mac, et un
# binaire `cc` **croisé depuis ce Mac** — sans Docker, sans Rust ni Swift sur
# le NUC, sans toucher à la production.
#
#   bash infra/relais-spike/preuve-cc-linux.sh
#
# Prérequis :
#   - le Relais du spike posé sur le NUC :  ssh nuc, bash install.sh --prefix ~/unclic
#   - `cc` croisé et posé :                 infra/relais/crypto-linux.sh, puis
#                                           swift build --swift-sdk x86_64-swift-linux-musl
#   - le paquet macOS construit avec CORRESPONDANCE_CRYPTO=1 dans /tmp/build-unclic-crypto
#
# Le tunnel ssh n'est là que pour que **ce Mac** parle au Relais du NUC :
# `cc`, lui, est sur place et compose 127.0.0.1:8010.
set -euo pipefail

HOTE="${HOTE:-nuc}"
PORT="${PORT:-8010}"
PREFIX_NUC="${PREFIX_NUC:-unclic}"          # relatif à $HOME du NUC
RELAIS_URL="http://127.0.0.1:$PORT"
SERVEUR="${SERVEUR:-unclic.local}"
BUILD="${BUILD:-/tmp/build-unclic-crypto/debug}"
RACINE="$(cd "$(dirname "$0")/../.." && pwd)"
B="$BUILD/preuve-chiffrement"

[ -x "$B" ] || { echo "✗ $B manquant — CORRESPONDANCE_CRYPTO=1 swift build --scratch-path /tmp/build-unclic-crypto"; exit 1; }

titre() { printf '\n### %s\n' "$*"; }
nuc() { ssh "$HOTE" "$@"; }

titre "0. le tunnel vers le Relais du NUC (pour CE Mac seulement)"
if ! curl -fsS -m 3 "$RELAIS_URL/_matrix/client/versions" >/dev/null 2>&1; then
  ssh -f -N -L "$PORT:127.0.0.1:$PORT" "$HOTE"
  for _ in $(seq 1 20); do
    curl -fsS -m 2 "$RELAIS_URL/_matrix/client/versions" >/dev/null 2>&1 && break
    sleep 1
  done
  TUNNEL_A_MOI=1
fi
curl -fsS "$RELAIS_URL/_matrix/client/versions" | head -c 120; echo

titre "1. l'agent, tel qu'il est sur le NUC"
nuc 'file ~/'"$PREFIX_NUC"'/bin/correspondance-agent; sha256sum ~/'"$PREFIX_NUC"'/bin/correspondance-agent'

# Le jeton du propriétaire vit sur le NUC : on le lit là-bas, on ne le copie pas.
JETON="$(nuc "python3 -c \"import json;print(json.load(open('\$HOME/$PREFIX_NUC/proprietaire.json'))['access_token'])\"")"
MDP_ESSAI="$(nuc "grep -m1 '^MATRIX_PASSWORD=' \$HOME/$PREFIX_NUC/secrets.env | cut -d= -f2-")"
export RELAIS_URL MATRIX_USER=essai MATRIX_PASSWORD="$MDP_ESSAI"
export PREUVE_HOME="${PREUVE_HOME:-$HOME/.correspondance-unclic/preuve-p7a}"
rm -rf "$PREUVE_HOME"

admin() { python3 "$RACINE/infra/relais-spike/salon-admin.py" "$RELAIS_URL" "$JETON" "$SERVEUR" "$1"; }

CC_PASSWORD="${CC_PASSWORD:-ccP7a$(head -c 9 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')}"

titre "2. le compte de cc, créé par la commande d'administration du Relais"
admin "!admin users create cc $CC_PASSWORD" || true
admin "!admin users reset-password cc $CC_PASSWORD"
curl -s "$RELAIS_URL/_matrix/client/v3/profile/@cc:$SERVEUR"; echo

titre "3. l'amorce de cc, SUR LE NUC, sous ~/$PREFIX_NUC/cc — jamais ~/.correspondance-agent"
nuc "mkdir -p \$HOME/$PREFIX_NUC/cc && chmod 700 \$HOME/$PREFIX_NUC/cc && umask 077 && cat > \$HOME/$PREFIX_NUC/cc/config.json <<JSON
{
  \"homeserver\": \"http://127.0.0.1:$PORT\",
  \"user\": \"cc\",
  \"password\": \"$CC_PASSWORD\",
  \"owners\": [\"@essai:$SERVEUR\"],
  \"trigger\": \"@cc\",
  \"hourlyCap\": 30
}
JSON
chmod 600 \$HOME/$PREFIX_NUC/cc/config.json
rm -f \$HOME/$PREFIX_NUC/cc/state.json; rm -rf \$HOME/$PREFIX_NUC/cc/crypto
ls -l \$HOME/$PREFIX_NUC/cc"

titre "4. la console de cc et la note à soi, toutes deux CHIFFRÉES (depuis ce Mac)"
CONSOLE=$("$B" console appareilA cc "@cc:$SERVEUR" | tee /dev/stderr | sed -n 's/^CONSOLE=//p')
SALON=$("$B" envoyer appareilA --nouveau "Note à soi de la phase 7a — le cc de Linux." | tee /dev/stderr | sed -n 's/^SALON=//p')
"$B" inviter appareilA "$SALON" "@cc:$SERVEUR"
echo "CONSOLE=$CONSOLE"
echo "SALON=$SALON"

titre "5. cc démarre SUR LE NUC — avec la machine crypto"
# Une unité systemd utilisateur à côté des autres du spike.
#
# **Pas de `--agent cc` dans l'ExecStart, et c'est le point qui a failli coûter
# cher.** `AgentHome.resolve` donne la priorité à `--agent` sur
# `CORRESPONDANCE_AGENT_HOME` — c'est écrit, et c'est juste pour un plist
# statique. Mais les deux ensemble font gagner `--agent`, donc `cc` a lu
# `~/.correspondance-agent/config.json`, c'est-à-dire **l'amorce de la
# production** : il s'est connecté au vrai Relais, y a vu le status du vrai cc,
# et a refusé de démarrer — la garde du second agent a fait exactement son
# travail, et c'est elle qui a révélé l'erreur. Le seul reste était un dossier
# `crypto/` dans le dossier de production, effacé.
#
# La variable seule suffit : `resolve` relit le nom du dossier (`unclic/cc` →
# « cc »), donc le déclencheur reste `@cc`.
nuc "mkdir -p \$HOME/.config/systemd/user && cat > \$HOME/.config/systemd/user/unclic-cc.service <<UNIT
[Unit]
Description=Correspondance (spike un-clic) — agent cc chiffré
After=network-online.target

[Service]
Environment=CORRESPONDANCE_AGENT_HOME=%h/$PREFIX_NUC/cc
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=%h/$PREFIX_NUC/bin/correspondance-agent run
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user restart unclic-cc.service
sleep 6
journalctl --user -u unclic-cc --since '-2 min' --no-pager | tail -20"

titre "6. « @cc ping » ENVOYÉ CHIFFRÉ dans la note à soi"
sleep 4
"$B" envoyer appareilA "$SALON" "@cc ping"

titre "7. ce que cc en fait, vu dans son journal systemd"
for _ in $(seq 1 45); do
  nuc "journalctl --user -u unclic-cc --since '-5 min' --no-pager" 2>/dev/null | grep -q "←" && break
  sleep 2
done
nuc "journalctl --user -u unclic-cc --since '-5 min' --no-pager | tail -20"

titre "8. la réponse de cc, relue EN CLAIR par l'appareil A (ce Mac)"
"$B" lire appareilA "$SALON"

titre "9. ce que le Relais du NUC stocke de la réponse — vu par HTTP, sans le client"
python3 - "$RELAIS_URL" "$JETON" "$SALON" <<'PY'
import json, sys, urllib.parse, urllib.request
url, jeton, salon = sys.argv[1:4]
req = urllib.request.Request(
    f"{url}/_matrix/client/v3/rooms/{urllib.parse.quote(salon)}/messages?dir=b&limit=20",
    headers={"Authorization": f"Bearer {jeton}"})
vu = False
for e in json.load(urllib.request.urlopen(req))["chunk"]:
    if e.get("sender", "").startswith("@cc:"):
        vu = True
        print(f"  {e['event_id']}  type={e['type']}  algorithm={e.get('content', {}).get('algorithm', '—')}")
        c = e.get("content", {}).get("ciphertext", "")
        if c:
            print(f"    ciphertext (100 premiers) : {c[:100]}…")
        print(f"    contenu brut : {json.dumps(e.get('content', {}))[:200]}")
if not vu:
    print("  (rien de @cc — la preuve échoue ici)")
PY

titre "10. le journal des tours, écrit chiffré dans la console"
"$B" lire appareilA "$CONSOLE"

echo
echo "✓ preuve terminée. Arrêter cc :  ssh $HOTE systemctl --user stop unclic-cc"
[ "${TUNNEL_A_MOI:-}" = 1 ] && echo "  (un tunnel ssh -L $PORT a été ouvert par ce script : pkill -f 'ssh -f -N -L $PORT')"
exit 0
