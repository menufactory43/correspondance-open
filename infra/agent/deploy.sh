#!/bin/bash
# Déploie l'agent depuis les sources sur une machine Linux : sources → build
# dans le conteneur Swift → binaire dans ~/.local/bin → **toutes** les unités
# `correspondance-<agent>` relancées. Un binaire, N agents : cc, hermes,
# claude… partagent ~/.local/bin/correspondance-agent, posé par l'installeur
# (`install.sh`), et chacun a son unité et son amorce.
#
#   infra/agent/deploy.sh            # build + install + restart
#   SSH_HOST=autre infra/agent/deploy.sh
#
# Prérequis là-bas : docker, et au moins un agent installé par `install.sh`.
# Ce script ne crée rien : pas d'unité, pas d'amorce — c'est le travail de
# l'installeur. Il remplace le binaire et relance ce qui existe.
set -euo pipefail

SSH_HOST="${SSH_HOST:-nuc}"
SWIFT_IMAGE="${SWIFT_IMAGE:-swift:6.1-bookworm}"
REMOTE_SRC="correspondance-agent-src"
HERE="$(cd "$(dirname "$0")/../.." && pwd)"

echo "→ Sources vers ${SSH_HOST}:~/${REMOTE_SRC}/"
rsync -a --delete --exclude .build --exclude '*.xcodeproj' \
  "$HERE/Packages/CorrespondanceCore/" "$SSH_HOST:~/${REMOTE_SRC}/"

echo "→ Build Linux (${SWIFT_IMAGE}), installation, relance des agents"
ssh "$SSH_HOST" REMOTE_SRC="$REMOTE_SRC" SWIFT_IMAGE="$SWIFT_IMAGE" bash -s <<'REMOTE'
set -euo pipefail
cd ~/"$REMOTE_SRC"
docker run --rm -v "$PWD":/src -v correspondance-agent-build:/src/.build -w /src "$SWIFT_IMAGE" \
  swift build --product correspondance-agent -c release --static-swift-stdlib 2>&1 \
  | grep -E "error:|Build complete|Linking" || true
docker run --rm -v correspondance-agent-build:/b "$SWIFT_IMAGE" test -x /b/release/correspondance-agent \
  || { echo "!! pas de binaire : la compilation a échoué (voir les erreurs ci-dessus)"; exit 1; }
mkdir -p ~/.local/bin
# Le binaire sort du volume Docker via un conteneur jetable, puis change de
# propriétaire par une copie : `chown` n'est pas à nous.
docker run --rm -v correspondance-agent-build:/b -v "$HOME/.local/bin":/out "$SWIFT_IMAGE" \
  cp /b/release/correspondance-agent /out/correspondance-agent.new
cp ~/.local/bin/correspondance-agent.new ~/.local/bin/correspondance-agent.tmp
rm -f ~/.local/bin/correspondance-agent.new
mv -f ~/.local/bin/correspondance-agent.tmp ~/.local/bin/correspondance-agent
chmod 755 ~/.local/bin/correspondance-agent

# Les unités d'agent **qui tournent** — pas une liste en dur, et pas les
# unités désactivées : relancer une vieille `correspondance-agent` d'avant
# les noms d'agent lançait un second cc sur le même compte (vu en vrai).
UNITS=$(systemctl --user list-units 'correspondance-*.service' --state=active --no-legend 2>/dev/null | awk '{print $1}')
[ -n "$UNITS" ] || { echo "!! aucun agent en marche (correspondance-*.service) : installe-en un d'abord (install.sh)"; exit 1; }
for unit in $UNITS; do
  systemctl --user restart "$unit"
done
sleep 4
for unit in $UNITS; do
  agent="${unit#correspondance-}"; agent="${agent%.service}"
  if systemctl --user is-active --quiet "$unit"; then
    echo "✓ $agent — $(journalctl --user -u "$unit" --no-pager -n 20 | grep -oE 'compilé le .*\)' | tail -1)"
  else
    echo "✗ $agent — l'unité ne tourne pas : journalctl --user -u $unit -n 30"
  fi
done
REMOTE
echo "✓ déployé — journal d'un agent : ssh $SSH_HOST journalctl --user -u correspondance-<agent> -f"
