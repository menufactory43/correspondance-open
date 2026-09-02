#!/bin/bash
# Déploie l'agent sur une machine Linux : construction **croisée depuis ce Mac**,
# binaire dans ~/.local/bin, puis toutes les unités `correspondance-<agent>` qui
# tournent sont relancées. Un binaire, N agents : cc, hermes, claude… partagent
# ~/.local/bin/correspondance-agent, posé par l'installeur (`install.sh`), et
# chacun a son unité et son amorce.
#
#   infra/agent/deploy.sh                  # construit, installe, relance
#   SSH_HOST=autre infra/agent/deploy.sh
#   infra/agent/deploy.sh --publie         # ne construit pas : prend le binaire
#                                          # de la release publiée (celui que
#                                          # les autres installent)
#
# **Ce qui a changé, et pourquoi.** Ce script construisait dans un conteneur
# Swift **sur le NUC** : il fallait Docker là-bas, 4 Gio de sources y montaient
# à chaque fois, et le binaire déployé ne ressemblait à rien de publié — glibc,
# non dépouillé, sans la machine crypto. La chaîne croisée existe maintenant
# (`infra/agent/construire.sh` : SDK statique musl, 24 s, aucun conteneur), donc
# on déploie **exactement ce qu'on publie**. C'est la bascule que la conclusion
# du spike demandait, et elle a un effet de bord précieux : ce qui tourne chez
# nous est ce que les autres installent, aux mêmes octets près.
#
# Ce script ne crée rien : pas d'unité, pas d'amorce — c'est le travail de
# l'installeur. Il remplace le binaire et relance ce qui existe.
set -euo pipefail

SSH_HOST="${SSH_HOST:-nuc}"
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
PUBLICATION="${CORRESPONDANCE_PUBLICATION:-$HOME/unclic-publication}"
RELEASES="${CORRESPONDANCE_RELEASES:-https://github.com/menufactory43/correspondance-releases/releases/latest/download}"
BINAIRE="$PUBLICATION/correspondance-agent-linux-x86_64"
DEPUIS_LA_RELEASE=0
[ "${1:-}" = "--publie" ] && DEPUIS_LA_RELEASE=1

if [ "$DEPUIS_LA_RELEASE" = 1 ]; then
  BINAIRE="$(mktemp -d)/correspondance-agent-linux-x86_64"
  echo "→ Binaire de la release publiée"
  curl -fsSL "$RELEASES/correspondance-agent-linux-x86_64" -o "$BINAIRE"
else
  echo "→ Construction croisée depuis ce Mac"
  bash "$HERE/infra/agent/construire.sh" --quoi linux
fi
[ -f "$BINAIRE" ] || { echo "!! pas de binaire à déployer : $BINAIRE" >&2; exit 1; }

# L'architecture de la cible décide : déposer un x86_64 sur un Raspberry ne
# donne pas une erreur lisible, il donne « Exec format error » au démarrage de
# l'unité, trois écrans plus loin.
ARCH="$(ssh "$SSH_HOST" 'uname -m')"
[ "$ARCH" = "x86_64" ] || {
  echo "!! $SSH_HOST est en $ARCH ; ce script ne croise que x86_64 pour l'instant." >&2
  echo "   (la tranche arm64 demande la .a Rust pour aarch64-unknown-linux-musl)" >&2
  exit 1
}

echo "→ Dépôt sur ${SSH_HOST} ($(wc -c < "$BINAIRE" | tr -d ' ') o)"
scp -q "$BINAIRE" "$SSH_HOST:/tmp/correspondance-agent.neuf"

ssh "$SSH_HOST" bash -s <<'REMOTE'
set -euo pipefail
mkdir -p ~/.local/bin
chmod 755 /tmp/correspondance-agent.neuf
# On remplace par `mv` dans le même système de fichiers : un binaire à moitié
# copié qu'une unité relance est pire qu'un binaire vieux d'un jour.
mv -f /tmp/correspondance-agent.neuf ~/.local/bin/correspondance-agent

# Les unités d'agent **qui tournent** — pas une liste en dur, et pas les unités
# désactivées : relancer une vieille `correspondance-agent` d'avant les noms
# d'agent lançait un second cc sur le même compte (vu en vrai).
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
