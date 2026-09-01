#!/bin/sh
# Installe l'agent « cc » sur cette machine, à partir du jeton d'amorce que
# l'app a affiché.
#
#   curl -fsSL https://correspondance.app/agent/install.sh | sh -s -- <jeton>
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
RELEASES="${CORRESPONDANCE_RELEASES:-https://github.com/meffysto/correspondance/releases/latest/download}"
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

echo
echo "✓ $USER_NAME installé. Vérifie ses moteurs : $BIN_DIR/correspondance-agent doctor --agent $AGENT"
echo "  Puis, depuis l'app : @$AGENT ping dans ta note à soi."
