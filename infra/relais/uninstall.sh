#!/usr/bin/env bash
# Correspondance — retire le Relais posé par install.sh : les services d'abord,
# le dossier ensuite. Rien d'autre.
#
#   bash uninstall.sh [--prefix DOSSIER] [--garder-donnees]
#
# Il refuse d'effacer un dossier qui ne porte pas la marque écrite par
# l'installeur : on ne veut pas d'un `rm -rf` sur un chemin mal tapé, et encore
# moins sur ~/.correspondance-agent/ ou sur le dossier de l'app.
#
# La clé Tailcat vit dans ce dossier (et pas dans ~/.config/tailcat/keys/) :
# l'effacer ici suffit, et le jeton des codes déjà émis meurt avec elle — ce qui
# est ce qu'on veut d'un « tout retirer ».
set -euo pipefail

PREFIX="${CORRESPONDANCE_RELAIS_PREFIX:-$HOME/.correspondance-unclic}"
GARDER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift ;;
    --garder-donnees) GARDER=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "!! option inconnue : $1" >&2; exit 2 ;;
  esac
  shift
done

dire() { printf '→ %s\n' "$*"; }

case "$(uname -s)" in
  Darwin)
    # `relais` est le superviseur : le sortir emporte le Relais et les ponts (il
    # tue ses enfants sur SIGTERM). Les autres labels sont ceux d'avant le
    # superviseur — un agent par service ; on les retire s'ils traînent encore.
    for nom in relais tailcat mautrix-whatsapp mautrix-signal mautrix-instagram mautrix-messenger mautrix-twitter mautrix-slack; do
      label="app.correspondance.$nom"
      plist="$HOME/Library/LaunchAgents/$label.plist"
      if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
        dire "service $label déchargé"
      fi
      [ -f "$plist" ] && { rm -f "$plist"; dire "$plist retiré"; }
    done
    ;;
  Linux)
    for nom in relais tailcat mautrix-whatsapp mautrix-signal mautrix-instagram mautrix-messenger mautrix-twitter mautrix-slack; do
      unite="$HOME/.config/systemd/user/correspondance-$nom.service"
      if systemctl --user cat "correspondance-$nom.service" >/dev/null 2>&1; then
        systemctl --user disable --now "correspondance-$nom.service" >/dev/null 2>&1 || true
        dire "service correspondance-$nom arrêté et désactivé"
      fi
      [ -f "$unite" ] && { rm -f "$unite"; dire "$unite retiré"; }
    done
    systemctl --user daemon-reload
    # Le linger sert peut-être à d'autres services de cet utilisateur : on n'y touche pas.
    ;;
esac

if [ "$GARDER" = 1 ]; then
  dire "dossier $PREFIX conservé (--garder-donnees)"
  exit 0
fi

if [ ! -f "$PREFIX/.correspondance-relais" ]; then
  echo "!! $PREFIX ne porte pas la marque .correspondance-relais — rien n'est effacé." >&2
  echo "   (les services, eux, ont bien été retirés)" >&2
  exit 1
fi
rm -rf "$PREFIX"
dire "$PREFIX effacé"
echo "✓ le Relais est retiré de cette machine."
