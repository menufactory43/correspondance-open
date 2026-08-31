#!/bin/bash
# Déploie l'agent « cc » sur le NUC : sources → build Linux dans le conteneur
# Swift → binaire dans ~/.local/bin → unité systemd utilisateur relancée.
#
#   infra/agent/deploy.sh            # build + install + restart
#   SSH_HOST=autre infra/agent/deploy.sh
#
# Prérequis sur le NUC : docker, Claude Code loggé (`claude` dans ~/.local/bin),
# `loginctl enable-linger`, et ~/.correspondance-agent/config.json (créé une
# fois à la main — il contient le mot de passe du compte Matrix du bot).
set -euo pipefail

SSH_HOST="${SSH_HOST:-nuc}"
SWIFT_IMAGE="${SWIFT_IMAGE:-swift:6.1-bookworm}"
REMOTE_SRC="correspondance-agent-src"
HERE="$(cd "$(dirname "$0")/../.." && pwd)"

echo "→ Sources vers ${SSH_HOST}:~/${REMOTE_SRC}/"
rsync -a --delete --exclude .build --exclude '*.xcodeproj' \
  "$HERE/Packages/CorrespondanceCore/" "$SSH_HOST:~/${REMOTE_SRC}/"
scp -q "$HERE/infra/agent/correspondance-agent.service" "$SSH_HOST:~/${REMOTE_SRC}/correspondance-agent.service"

echo "→ Build Linux (${SWIFT_IMAGE}) et installation"
ssh "$SSH_HOST" REMOTE_SRC="$REMOTE_SRC" SWIFT_IMAGE="$SWIFT_IMAGE" bash -s <<'REMOTE'
set -euo pipefail
cd ~/"$REMOTE_SRC"
docker run --rm -v "$PWD":/src -v correspondance-agent-build:/src/.build -w /src "$SWIFT_IMAGE" \
  swift build --product correspondance-agent -c release --static-swift-stdlib 2>&1 \
  | grep -E "error:|Build complete|Linking" || true
mkdir -p ~/.local/bin ~/.config/systemd/user
# Le binaire sort du volume Docker via un conteneur jetable, puis change de
# propriétaire par une copie : `chown` n'est pas à nous.
docker run --rm -v correspondance-agent-build:/b -v "$HOME/.local/bin":/out "$SWIFT_IMAGE" \
  cp /b/release/correspondance-agent /out/correspondance-agent.new
cp ~/.local/bin/correspondance-agent.new ~/.local/bin/correspondance-agent.tmp
rm -f ~/.local/bin/correspondance-agent.new
mv -f ~/.local/bin/correspondance-agent.tmp ~/.local/bin/correspondance-agent
chmod 755 ~/.local/bin/correspondance-agent
[ -f ~/.correspondance-agent/config.json ] || { echo "!! ~/.correspondance-agent/config.json absent — crée-le d'abord (correspondance-agent init)"; exit 1; }
cp correspondance-agent.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now correspondance-agent >/dev/null
systemctl --user restart correspondance-agent
sleep 3
systemctl --user --no-pager --lines=6 status correspondance-agent || true
REMOTE
echo "✓ déployé — journal : ssh $SSH_HOST journalctl --user -u correspondance-agent -f"
