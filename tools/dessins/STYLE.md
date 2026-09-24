# La main « Correspondance » — règles communes à tous les dessins de la page

But : que chaque dessin de la landing semble fait par la même personne, et qu'il cohabite avec
un site net (Inter, fond blanc #fff / #f7f6f3, cartes #efede8, accent rouille #8a3f2b).

- Médium : encre + lavis léger. Plume `INK_M` (exportée par src/canvas-core/corresp.ts), encre `INK` #111114.
- Couleur : lavis seulement, alpha 0.35 à 0.6. Palette : RUST #8a3f2b, RUST_SOFT #f4e9e4, et les
  couleurs réseaux du site (imsg #34c759, signal #3a76f0, wa #25d366, ig #e1306c, msg #0084ff,
  x #111114, slack #4a154b). Rouge pastille BADGE #d8412f. Rien d'autre.
- Traits : contour principal w 1.6 à 2.2 (à 1x d'un format ~1200 px de large ; proportionnel sinon),
  détails w 0.8 à 1.2. Pas de hachures de remplissage, pas de dégradés.
- Texte : jamais de police ni de vrai mot ; des lignes ondulées `scribble()` remplacent le texte.
  Exception : une ou deux lettres dessinées (drafting.ts `letter`) si indispensable.
- Fond transparent, pas de papier (`g.paper` interdit) : la page fournit le fond.
- Pas de logos de marques : réseaux = couleur + forme de bulle.
- Composition centrée, marges généreuses, un seul sujet par dessin.
- Section sombre (#111114) : même main, encre claire #f4f1ea au lieu de INK, lavis identiques.
