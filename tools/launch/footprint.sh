#!/usr/bin/env bash
# L'empreinte mémoire de l'app, seconde par seconde après un lancement, par
# catégorie (`footprint`). Même protocole que le lancement : la même build,
# plusieurs fois, et on lit ce qui se répète.
#
#   tools/launch/footprint.sh <app> [secondes=14]
#
# Ce qu'on regarde : IOSurface (photos et portraits décodés, tenus par les
# couches), CoreAnimation et « CG raster data » (les bulles rasterisées),
# MALLOC_SMALL (le tas : graphe SwiftUI, modèles, fermetures). Le total se
# stabilise vers 7 s, quand le fil entier est monté et les portraits arrivés.
set -euo pipefail
APP="$1"; SECS="${2:-14}"
pkill -x Correspondance || true
sleep 2
open -a "$APP"
for t in $(seq 1 "$SECS"); do
  sleep 1
  PID="$(pgrep -x Correspondance | head -1)" || continue
  footprint -p "$PID" 2>/dev/null | awk -v t="$t" '
    /Footprint:/ { tot = $5 " " $6 }
    /IOSurface$/ { io = $1 $2 }
    /CoreAnimation$/ { ca = $1 $2 }
    /CG raster data$/ { cg = $1 $2 }
    /MALLOC_SMALL$/ { ms = $1 $2 }
    END { printf "t=%2ss total %-8s IOSurface=%-7s CA=%-7s CGraster=%-7s MALLOC_SMALL=%s\n", t, tot, io, ca, cg, ms }'
done
