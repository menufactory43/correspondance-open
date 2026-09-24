# Dessins du site

Les animations et les petits dessins de `site/` sont écrits en code avec
[anidoodle](https://github.com/alexgreensh/anidoodle) (Apache 2.0) : aucune image source,
le même fichier redonne les mêmes pixels à chaque rendu. Les règles communes à tous les
dessins sont dans `STYLE.md`.

| Fichier | Rendu | Où sur le site |
|---|---|---|
| `corresp.ts` | boucle 8 s : huit réseaux → une liste | `#inbox` → `img/anim/corresp.*` |
| `cagent.ts` | boucle 8 s : cc rejoint le fil, propose, vous validez | `#agents` → `img/anim/cagent.*` |
| `cprivacy.ts` | boucle 8 s, encre claire : iPhone ↔ Relais ↔ réseaux | `#confidentialite` → `img/anim/cprivacy.*` |
| `cspot.ts` | 17 dessins fixes, un par frame (0–16) | cartes `.cap` → `img/spots/*.webp` |

## Régénérer

```bash
node ~/.claude/skills/anidoodle/engine/tools/scaffold.mjs /tmp/dessins
cp -R tools/dessins/src/* /tmp/dessins/src/
cd /tmp/dessins && npm install && npx playwright-core install chromium

node tools/render.mjs corresp --out out/corresp.webm --width 1200   # idem cagent, cprivacy
node tools/gate.mjs corresp                                         # déterminisme, contrat, temps morts
node tools/still.mjs cspot --frame 0 --scale 2 --out out/marketplace.png

# Safari ne lit la transparence qu'en HEVC :
ffmpeg -c:v libvpx-vp9 -i out/corresp.webm -c:v hevc_videotoolbox -q:v 40 -alpha_quality 0.5 \
  -tag:v hvc1 -allow_sw 1 out/corresp.mov   # qualité constante : 3 à 4 fois plus léger qu'un débit fixe
# Dessins des cartes : 128 px (64 px affichés en Retina)
cwebp -q 90 -resize 128 128 out/marketplace.png -o marketplace.webp
```

Ordre des frames de `cspot` : marketplace, commerce, famille, message-delicat, groupe,
traduction, assistant, tracking, reponse-rapide, post-it, focus, barre-menus, themes,
partager, iphone, traduction-appareil, incognito.
