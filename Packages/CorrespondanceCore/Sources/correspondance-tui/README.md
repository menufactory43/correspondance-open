# Correspondance dans le terminal

La même inbox que le Mac, l'iPhone et Linux — Focus, Inbox, rappels, demandes,
propositions de « cc » — dans un terminal. Aucune logique n'est réécrite : la TUI
lit et écrit le **même magasin** que le serveur Linux (`CorrespondanceRelayStore`,
porté de l'iPhone) et les fonctions pures de Core. Elle ne fait que dessiner.

```bash
swift build --package-path Packages/CorrespondanceCore --product correspondance-tui
Packages/CorrespondanceCore/.build/debug/correspondance-tui --demo   # sans Relais
Packages/CorrespondanceCore/.build/debug/correspondance-tui          # sa propre session
```

| Option | Effet |
| --- | --- |
| `--partager` | la session et la base de l'app installée sur la machine (sinon : dossier `terminal`, session à part) |
| `--demo [DOSSIER]` | les fixtures `/sync` de l'iPhone, sans réseau |
| `--sans-images` | jamais d'images |
| `--sans-souris` | la souris reste au terminal (sélection native) |

Le journal du magasin part dans `<données>/terminal.log` : sur la sortie d'erreur,
il barbouillerait l'écran.

`?` dans la TUI donne tous les raccourcis. L'essentiel : `1` Focus, `2` Inbox,
`n`/`p`/`a` suivante, précédente, archiver ; `j`/`k` messages ; `i` écrire ;
`r` répondre ; `+` réagir ; `/` chercher.

## Pourquoi c'est fluide

Les pratiques de Ghostty et Kitty, appliquées côté application :

- **Rendu différentiel.** On dessine une grille de cellules, on la compare à la
  précédente, on n'écrit que ce qui change. Descendre d'un message : ~50 octets.
- **Sortie synchronisée** (mode 2026). Chaque image est encadrée par
  `CSI ?2026 h/l` : le terminal l'applique d'un bloc, sans déchirure. Le mode est
  sondé au lancement (DECRQM) et coupé là où il n'existe pas.
- **Un `write` par image**, dans un tampon réutilisé ; stylo SGR et position du
  curseur suivis pour ne rien réémettre d'inutile ; DECAWM coupé.
- **Rafraîchissement observé.** L'image se dessine dans `withObservationTracking` :
  seules les propriétés du magasin *lues pour dessiner* réveillent l'écran. Les
  réveils sont fusionnés, plafonnés à 120 Hz, et il n'y a aucun réveil au repos.
- **Entrée sur un fil dédié**, bloqué dans `poll` : une touche est traitée dans la
  milliseconde, zéro CPU quand personne ne tape.
- **Mise en page en cache** par groupe de messages et par largeur : un fil de
  mille messages se coupe en lignes une fois, puis seul le groupe modifié se refait.
- **Largeur Unicode par graphème** (mode 2027) : emoji composés, drapeaux,
  idéogrammes ne décalent jamais la grille.

## Le terminal, à fond

- **Protocole clavier Kitty** (`CSI >1u`) : Échap sans délai, Maj+Entrée pour une
  nouvelle ligne, ^I distinct de Tab. Ailleurs, repli sur le clavier historique
  (Échap attend 25 ms).
- **Images** par le protocole graphique Kitty (Kitty, Ghostty, WezTerm) avec
  **placeholders Unicode** : une image est une suite de cellules `U+10EEEE` dont la
  couleur porte l'identifiant. Elle défile, se coupe au bord, passe sous une
  fenêtre surgissante, sans commande de plus. Les vignettes PNG (Kitty n'accepte
  que le PNG) se font une fois, dans un cache disque : ImageIO et AVFoundation sur
  macOS, `vipsthumbnail`/`magick`/`ffmpeg` sous Linux. Transmission par fichier en
  local, en ligne (base64 par morceaux) derrière SSH.
- **Liens cliquables** (OSC 8), **copie** dans le presse-papiers même en SSH
  (OSC 52), **notifications** portées par le terminal (OSC 99 chez Kitty, OSC 9
  ailleurs) — seulement quand le terminal n'a pas le focus (événements de focus,
  mode 1004).
- **Collage entre crochets** : coller du texte ne déclenche aucun raccourci ;
  glisser un fichier dans la fenêtre le joint au message.
- **Souris** SGR : molette, clic sur une conversation ou un message.
- `^Z` suspend proprement, `^L` repeint tout, le titre de la fenêtre porte le
  nombre de non-lus.

## Architecture

| Cible | Rôle |
| --- | --- |
| `CorrespondanceTerminal` | le moteur, sans rien savoir des conversations : mode brut, lecture des touches, grille, rendu, largeur Unicode, éditeur de ligne, images Kitty. Testé (`CorrespondanceTerminalTests`). |
| `CorrespondanceRelayStore` | le magasin de l'iPhone, partagé avec `correspondance-linux`. |
| `correspondance-tui` | l'app : état d'écran, mise en page du fil, vues, raccourcis. |

Ce que la TUI ne fait pas (encore) : iMessage (il vit dans l'app Mac, pas dans
Core), l'enregistrement de vocaux, la fusion de contacts (lue, pas décidée — comme
sur l'iPhone), les messages programmés depuis le composer.
