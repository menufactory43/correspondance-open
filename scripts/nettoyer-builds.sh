#!/bin/zsh
# Jette ce que les constructions accumulent et que rien ne lit après coup.
#
# Le 2 septembre, `build/` pesait 5,3 Go pour un DMG de 47 Mo : quatre
# DerivedData (Mac, iOS, iOS appareil, et un `dd-ios` orphelin d'un ancien
# script), une « app précédente » gardée à la main, et les xcarchive. Rien de
# tout ça n'est suivi par git, et tout se reconstruit — un DerivedData jeté
# coûte une compilation complète à la prochaine release, c'est tout.
#
# On garde ce qui est livrable ou ce qui sert à le vérifier : le dernier DMG,
# le dernier .ipa, les xcarchive (ils portent les dSYM des versions publiées)
# et les exports.
#
#   scripts/nettoyer-builds.sh          # DerivedData + reliquats
#   scripts/nettoyer-builds.sh --tout   # + les .build SwiftPM du paquet
#                                       #   (swift test et l'agent embarqué
#                                       #   reconstruiront tout, ~10 min)
set -euo pipefail
cd "$(dirname "$0")/.."

avant=$(du -sk build Packages/CorrespondanceCore/.build* 2>/dev/null | awk '{s+=$1} END{print s}')

cibles=(
  build/release/dd
  build/release/dd-ios
  build/release/ios/dd
  build/release/ios/dd-device
  build/release/app-precedente
)
if [[ "${1:-}" == "--tout" ]]; then
  cibles+=(Packages/CorrespondanceCore/.build Packages/CorrespondanceCore/.build-agent)
fi

for c in $cibles; do
  [[ -e "$c" ]] || continue
  printf "  jette %-45s %s\n" "$c" "$(du -sh "$c" | cut -f1)"
  rm -rf "$c"
done

# Et LaunchServices ne connaît plus que /Applications : sinon Réglages Système
# peut valider l'accès disque sur une copie jetée.
scripts/desinscrire-doublons.sh

apres=$(du -sk build Packages/CorrespondanceCore/.build* 2>/dev/null | awk '{s+=$1} END{print s}')
printf "%.1f Go → %.1f Go\n" $((avant/1048576.0)) $((apres/1048576.0))
