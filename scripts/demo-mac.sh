#!/bin/zsh
# Lance Correspondance sur Mac en démonstration : aucune donnée réelle, rien
# n'est lu ni écrit chez l'utilisateur, rien ne part. Pour les captures.
#
#   scripts/demo-mac.sh                                   # inbox de démonstration
#   scripts/demo-mac.sh --mode focus --theme encreDeNuit  # Focus, thème sombre
#   scripts/demo-mac.sh --select "Vacances 2026" --capture demo-groupe
#
# Options : --mode inbox|focus · --theme papier|dune|clairDeLune|encreDeNuit|vieuxBureau|cireEtChene
#           --select "<titre du fil>" · --capture <nom> (écrit docs/screens/<nom>.png) · --no-build
#
# Deux pièges rencontrés : lancé directement par son binaire depuis un shell,
# l'app n'a pas de session graphique et n'ouvre pas de fenêtre — d'où `open` ;
# et AppKit lit les arguments par paires, un mot orphelin passe pour un fichier
# à ouvrir et court-circuite la fenêtre par défaut — d'où `-CorrespondanceDemo 1`.
# Le mode et le thème passent par leurs clés de préférences : le domaine des
# arguments prime, et rien n'est écrit dans les réglages de l'utilisateur.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE=inbox; THEME=""; SELECT=""; CAPTURE=""; BUILD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --theme) THEME="$2"; shift 2 ;;
    --select) SELECT="$2"; shift 2 ;;
    --capture) CAPTURE="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    *) echo "option inconnue : $1"; exit 2 ;;
  esac
done
if [ "$BUILD" = 1 ]; then
  xcodegen generate >/dev/null
  CORRESPONDANCE_CRYPTO=1 xcodebuild -project Correspondance.xcodeproj -scheme Correspondance -configuration Debug \
    -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
fi
DD=$(xcodebuild -project Correspondance.xcodeproj -scheme Correspondance -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR =/{print $3}')
APP="$DD/Correspondance.app"
pkill -f "$APP/Contents/MacOS/Correspondance" 2>/dev/null || true
sleep 1
ARGS=(-CorrespondanceDemo 1 -correspondance.inboxMode "$MODE" -correspondance.networkFilter "")
[ -n "$THEME" ] && ARGS+=(-correspondance.theme "$THEME")
[ -n "$SELECT" ] && ARGS+=(-CorrespondanceDemoSelect "$SELECT")
open -n -a "$APP" --args "${ARGS[@]}"
# `open` vient d'inscrire cette copie auprès de LaunchServices : on l'en
# retire, pour que Réglages Système › Accès disque ne voie que /Applications.
sleep 1; scripts/desinscrire-doublons.sh >/dev/null 2>&1 || true
echo "→ démonstration lancée (mode $MODE${THEME:+, thème $THEME}${SELECT:+, fil « $SELECT »})"
if [ -n "$CAPTURE" ]; then
  swift scripts/park-mouse.swift
  sleep 6
  WID=$(swift scripts/window-id.swift)
  [ "$WID" != "0" ] || { echo "✗ pas de fenêtre"; exit 1; }
  mkdir -p docs/screens
  screencapture -x -o -l"$WID" "docs/screens/$CAPTURE.png"
  echo "→ capture : docs/screens/$CAPTURE.png"
fi
