#!/bin/sh
# Installe l'agent « cc » sur cette machine, à partir du jeton d'amorce que
# l'app a affiché.
#
#   curl -fsSL https://github.com/menufactory43/correspondance-releases/releases/latest/download/install.sh \
#     -o /tmp/correspondance-install.sh && sh /tmp/correspondance-install.sh <jeton>
#
# Pas de `curl | sh` : un domaine absent y fait un script vide, et `sh` d'un
# script vide sort en 0 — la commande disait « installé » sans rien faire.
#
# Ce qu'il fait, dans cet ordre : lire le jeton, refuser s'il a expiré, poser
# l'amorce en 0600, installer le binaire, poser le service (systemd utilisateur
# sous Linux, launchd sous macOS), démarrer.
#
# Le jeton contient un mot de passe : il se colle dans un terminal, jamais dans
# une conversation. Il périme en dix minutes.
set -eu

TOKEN="${1:-}"
[ -n "$TOKEN" ] || { echo "usage : install.sh <jeton d'amorce>" >&2; exit 2; }

AGENT="${CORRESPONDANCE_AGENT:-cc}"
if [ "$AGENT" = "cc" ]; then HOME_DIR="$HOME/.correspondance-agent"; else HOME_DIR="$HOME/.correspondance-$AGENT"; fi
BIN_DIR="$HOME/.local/bin"
RELEASES="${CORRESPONDANCE_RELEASES:-https://github.com/menufactory43/correspondance-releases/releases/latest/download}"
# La version de l'adaptateur ACP est épinglée : le régime de permission par
# défaut d'un adaptateur change d'une version à l'autre (cf. docs/SPIKE-acp.md).
ACP_PACKAGE="${CORRESPONDANCE_ACP:-@zed-industries/claude-code-acp@0.16.2}"

decode() {
  # base64url → JSON, sans dépendre de jq (une machine fraîche ne l'a pas).
  # Un jeton abîmé (copié à moitié, recollé par un client de messagerie) doit
  # le dire en une phrase, pas cracher une trace Python.
  python3 - "$1" <<'PY' 2>/dev/null
import base64, json, sys
try:
    t = sys.argv[1].replace('-', '+').replace('_', '/')
    t += '=' * (-len(t) % 4)
    print(json.dumps(json.loads(base64.b64decode(t))))
except Exception:
    sys.exit(1)
PY
}

field() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$2"; }

command -v python3 >/dev/null 2>&1 || { echo "!! python3 est nécessaire pour lire le jeton" >&2; exit 1; }

JSON="$(decode "$TOKEN")" || { echo "!! jeton illisible" >&2; exit 1; }
VERSION="$(field "$JSON" v)"
[ "$VERSION" = "1" ] || { echo "!! jeton en version $VERSION — mets l'installeur à jour" >&2; exit 1; }

EXP="$(field "$JSON" exp)"
NOW="$(date +%s)"
if [ "$(printf '%.0f' "$EXP")" -lt "$NOW" ]; then
  echo "!! ce jeton a expiré — reprends-en un dans l'app (Réglages › Agent › Ajouter un hôte)" >&2
  exit 1
fi

HOMESERVER="$(field "$JSON" homeserver)"
USER_NAME="$(field "$JSON" user)"
PASSWORD="$(field "$JSON" password)"
OWNER="$(field "$JSON" owner)"

# Le Relais est-il joignable d'ici ? Le jeton porte l'adresse telle que l'app
# la voit — un nom Tailscale, par exemple — et cette machine ne la voit pas
# forcément. Trouvé en vrai : sur la machine du Relais lui-même, le nom
# MagicDNS n'existait pas, et cc redémarrait toutes les dix secondes. On
# vérifie avant d'écrire, et si un Synapse répond ici même sous le **même nom
# de serveur**, c'est lui — vérifié, pas supposé.
SERVER_NAME="${OWNER#*:}"
server_name_at() { curl -fsS -m 5 "$1/_matrix/key/v2/server" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("server_name",""))' 2>/dev/null; }
echo "→ Relais : $HOMESERVER"
if [ "$(server_name_at "$HOMESERVER")" = "$SERVER_NAME" ]; then
  :
elif [ "$(server_name_at http://127.0.0.1:8008)" = "$SERVER_NAME" ]; then
  echo "   injoignable à cette adresse d'ici, mais le Relais « $SERVER_NAME » tourne sur cette machine : http://127.0.0.1:8008"
  HOMESERVER="http://127.0.0.1:8008"
else
  echo "!! cette machine ne joint pas le Relais « $SERVER_NAME » à $HOMESERVER (ni sur 127.0.0.1:8008)." >&2
  echo "   Rien n'est installé. Si le Relais est joint par Tailscale, installe Tailscale ici d'abord." >&2
  exit 1
fi

echo "→ Amorce dans $HOME_DIR"
mkdir -p "$HOME_DIR"
chmod 700 "$HOME_DIR"
umask 077
cat > "$HOME_DIR/config.json" <<JSONEOF
{
  "homeserver": "$HOMESERVER",
  "user": "$USER_NAME",
  "password": "$PASSWORD",
  "owners": ["$OWNER"]
}
JSONEOF
chmod 600 "$HOME_DIR/config.json"

echo "→ Binaire dans $BIN_DIR"
mkdir -p "$BIN_DIR"
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)  ASSET=correspondance-agent-linux-x86_64 ;;
  Linux-aarch64) ASSET=correspondance-agent-linux-arm64 ;;
  Darwin-arm64)  ASSET=correspondance-agent-macos-arm64 ;;
  Darwin-x86_64) ASSET=correspondance-agent-macos-x86_64 ;;
  *) echo "!! machine non prévue : $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac
if curl -fsSL "$RELEASES/$ASSET" -o "$BIN_DIR/correspondance-agent.tmp"; then
  chmod 755 "$BIN_DIR/correspondance-agent.tmp"
  mv -f "$BIN_DIR/correspondance-agent.tmp" "$BIN_DIR/correspondance-agent"
else
  rm -f "$BIN_DIR/correspondance-agent.tmp"
  echo "!! binaire introuvable ($RELEASES/$ASSET)" >&2
  exit 1
fi

# L'adaptateur ACP est posé par l'installation, jamais cherché au lancement.
# S'il manque, l'agent répond quand même par la CLI (FallbackBackend) — on le
# dit plutôt que d'échouer.
if command -v npm >/dev/null 2>&1; then
  echo "→ Adaptateur ACP ($ACP_PACKAGE)"
  npm install -g "$ACP_PACKAGE" >/dev/null 2>&1 || echo "   (échec — cc répondra par la CLI)"
else
  echo "   node/npm absents : cc répondra par la CLI (`claude`)"
fi

echo "→ Service"
case "$(uname -s)" in
  Linux)
    mkdir -p "$HOME/.config/systemd/user"
    # L'unité d'avant l'installeur s'appelait « correspondance-agent » et lançait
    # cc sans --agent. Laissée en place, elle redémarrerait au boot à côté de la
    # nouvelle : deux cc, dont un qui refuse de démarrer toutes les dix secondes.
    if [ "$AGENT" = "cc" ] && systemctl --user cat correspondance-agent.service >/dev/null 2>&1; then
      echo "   (ancienne unité correspondance-agent trouvée : arrêtée et désactivée)"
      systemctl --user disable --now correspondance-agent.service >/dev/null 2>&1 || true
    fi
    UNIT="$HOME/.config/systemd/user/correspondance-$AGENT.service"
    cat > "$UNIT" <<UNITEOF
[Unit]
Description=Correspondance — agent $AGENT
After=network-online.target

[Service]
ExecStart=$BIN_DIR/correspondance-agent run --agent $AGENT
Restart=always
RestartSec=10
Environment=PATH=$BIN_DIR:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
UNITEOF
    systemctl --user daemon-reload
    systemctl --user enable --now "correspondance-$AGENT.service"
    # Sans linger, le service meurt à la déconnexion SSH — c'est le piège
    # classique d'un agent « 24/7 » qui s'arrête dès qu'on ferme le terminal.
    loginctl enable-linger "$(id -un)" 2>/dev/null || \
      echo "   (pense à : sudo loginctl enable-linger $(id -un))"
    echo "→ Journal : journalctl --user -u correspondance-$AGENT -f"
    ;;
  Darwin)
    PLIST="$HOME/Library/LaunchAgents/app.correspondance.agent.$AGENT.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>app.correspondance.agent.$AGENT</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BIN_DIR/correspondance-agent</string>
		<string>run</string>
		<string>--agent</string>
		<string>$AGENT</string>
	</array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>StandardOutPath</key><string>/tmp/correspondance-$AGENT.log</string>
	<key>StandardErrorPath</key><string>/tmp/correspondance-$AGENT.log</string>
</dict>
</plist>
PLISTEOF
    launchctl bootout "gui/$(id -u)/app.correspondance.agent.$AGENT" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "→ Journal : tail -f /tmp/correspondance-$AGENT.log"
    ;;
  *) echo "!! système non prévu" >&2; exit 1 ;;
esac

# La preuve, pas la promesse : on attend que l'agent dise « connecté comme »
# dans son journal. Sans ça, « installé » voudrait dire « fichiers posés ».
echo "→ Attente du premier signe de vie (30 s au plus)"
VU=""
i=0
while [ $i -lt 15 ]; do
  case "$(uname -s)" in
    Linux) LOG="$(journalctl --user -u "correspondance-$AGENT" --since '-2 min' --no-pager 2>/dev/null || true)" ;;
    *)     LOG="$(cat "/tmp/correspondance-$AGENT.log" 2>/dev/null || true)" ;;
  esac
  case "$LOG" in
    *"connecté comme"*) VU=oui; break ;;
    *"identifiants refusés"*|*"M_FORBIDDEN"*) echo "!! le Relais refuse les identifiants du jeton — reprends-en un dans l'app" >&2; exit 1 ;;
    *"tourne déjà"*|*"un autre agent"*) echo "!! un autre $USER_NAME tourne ailleurs et celui-ci refuse de démarrer — arrête l'autre d'abord (dans l'app : Arrêter)" >&2; exit 1 ;;
  esac
  sleep 2; i=$((i+1))
done
if [ -z "$VU" ]; then
  echo "!! $USER_NAME est installé mais ne s'est pas connecté en 30 s — journal :" >&2
  printf '%s\n' "$LOG" | tail -12 >&2
  exit 1
fi

echo
echo "✓ $USER_NAME est connecté au Relais depuis cette machine ($(hostname -s 2>/dev/null || hostname))."
echo "  Depuis l'app : @$AGENT ping dans ta note à soi. Moteurs : $BIN_DIR/correspondance-agent doctor --agent $AGENT"
