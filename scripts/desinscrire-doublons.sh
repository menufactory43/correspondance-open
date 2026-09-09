#!/bin/zsh
# Ne laisse à LaunchServices qu'UNE Correspondance : celle de /Applications.
#
# Chaque build (DerivedData, build/, un export, un dossier temporaire d'agent)
# inscrit sa copie sous le même identifiant, et le registre garde même celles
# qui n'existent plus. Réglages Système › Accès complet au disque valide alors
# la case sur n'importe laquelle — une copie de test au sceau cassé, ou un
# chemin mort, et la case retombe sans un mot. On lit le registre (pas Spotlight,
# qui ne voit que ce qui existe), on désinscrit tout ce qui n'est pas
# /Applications, chemins morts compris, et on réinscrit /Applications.
# Une copie relancée se réinscrira : ce script se relance après.
#
#   scripts/desinscrire-doublons.sh
set -euo pipefail
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
ID=app.correspondance.Correspondance
GARDE=/Applications/Correspondance.app

# Les chemins inscrits sous notre identifiant : dans le dump, `path:` précède
# `identifier:` de quelques lignes.
chemins=$("$LSREGISTER" -dump 2>/dev/null | awk -v id="$ID" '
  /^[[:space:]]*path:/ { sub(/^[[:space:]]*path:[[:space:]]*/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); p=$0 }
  /^[[:space:]]*identifier:/ { sub(/^[[:space:]]*identifier:[[:space:]]*/, ""); if ($0 == id && p != "") print p }
' | sort -u)

n=0
while IFS= read -r app; do
  [[ -n "$app" && "$app" != "$GARDE" ]] || continue
  # Un chemin disparu se désinscrit comme un autre : `-u` ne le vérifie pas.
  "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
  printf "  %s  %s\n" "$([[ -d "$app" ]] && echo "désinscrit " || echo "chemin mort")" "$app"
  n=$((n+1))
done <<< "$chemins"

if [[ -d "$GARDE" ]]; then
  "$LSREGISTER" -f "$GARDE" >/dev/null 2>&1 || true
  echo "  garde       $GARDE"
fi
echo "$n copie(s) écartée(s)."
