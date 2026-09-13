#!/bin/sh
# Installe Correspondance pour Linux dans le compte de l'utilisateur — jamais
# en root, jamais hors de ~/.local :
#
#   bin/correspondance                   le binaire (statique, sans dépendance)
#   bin/correspondance-tui               l'inbox dans le terminal
#   bin/correspondance-cli               l'inbox en ligne de commande (scripts, cron, agents)
#   share/correspondance/{ui,fonts}      l'interface et ses polices
#   share/applications/…desktop          l'entrée du menu
#   share/icons/hicolor/512x512/apps/…   l'icône
#
#   ./install.sh                # installe
#   ./install.sh --uninstall    # retire tout, garde les données (~/.local/share/Correspondance)
set -eu
ICI="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$PREFIX/bin/correspondance" "$PREFIX/bin/correspondance-tui" "$PREFIX/bin/correspondance-cli" \
        "$PREFIX/share/applications/correspondance.desktop" \
        "$PREFIX/share/icons/hicolor/512x512/apps/correspondance.png"
  rm -rf "$PREFIX/share/correspondance"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$PREFIX/share/applications" 2>/dev/null || true
  echo "Correspondance retirée. Les données restent dans ~/.local/share/Correspondance et ~/.cache/Correspondance."
  exit 0
fi

mkdir -p "$PREFIX/bin" "$PREFIX/share/correspondance" "$PREFIX/share/applications" "$PREFIX/share/icons/hicolor/512x512/apps"
install -m 755 "$ICI/bin/correspondance" "$PREFIX/bin/correspondance"
for outil in correspondance-tui correspondance-cli; do
  [ -f "$ICI/bin/$outil" ] && install -m 755 "$ICI/bin/$outil" "$PREFIX/bin/$outil"
done
rm -rf "$PREFIX/share/correspondance/ui" "$PREFIX/share/correspondance/fonts"
cp -R "$ICI/share/correspondance/ui" "$ICI/share/correspondance/fonts" "$PREFIX/share/correspondance/"
install -m 644 "$ICI/share/applications/correspondance.desktop" "$PREFIX/share/applications/correspondance.desktop"
install -m 644 "$ICI/share/icons/hicolor/512x512/apps/correspondance.png" "$PREFIX/share/icons/hicolor/512x512/apps/correspondance.png"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$PREFIX/share/applications" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q "$PREFIX/share/icons/hicolor" 2>/dev/null || true

echo "✅ Correspondance installée dans $PREFIX"
case ":$PATH:" in
  *":$PREFIX/bin:"*) echo "   Lance-la : correspondance   (ou depuis le menu des applications)";;
  *) echo "   $PREFIX/bin n'est pas dans ton PATH : lance $PREFIX/bin/correspondance, ou ajoute-le.";;
esac
