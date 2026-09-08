# Mesure du lancement

La machine est bruyante : un lancement isolé ne prouve rien. On compare des
**variantes de la même build**, lancées en **blocs alternés** (A B C, A B C, …),
**8 fois chacune**, et on lit les **médianes**. Les variantes se déclarent dans
le code via `LaunchExperiment.isOn("nom")` (`App/LaunchExperiment.swift`) et se
choisissent par la variable d'environnement `CORR_EXP=nom1,nom2`.

## Jalons

L'app écrit dans le journal système (`subsystem == "app.correspondance.launch"`)
des jalons en millisecondes depuis la création du process :

- `didFinish` — `applicationDidFinishLaunching` (la fenêtre est construite,
  pas encore à l'écran) ; `frame1` — le tour de boucle suivant, ≈ la
  première frame (~125 ms après `didFinish`) ;
- `window` — `LaunchGate` a vu l'inbox peinte ;
- `thread-begin` — le fil commence à se construire ;
- `thread` — le fil est montré (sa queue, au lancement) ;
- `thread-full` — le reste du fil est monté au-dessus, hors champ.

`LaunchTrace.mark("…")` en ajoute un ; chaîne publique obligatoire (`NSLog`
sort en `<private>`). Lecture : `/usr/bin/log show --last 2m --style compact
--predicate 'subsystem == "app.correspondance.launch"'` (« log » nu est masqué
par le shell).

## Outils

Build Release d'abord :
`xcodebuild -scheme Correspondance -configuration Release -derivedDataPath <dossier>`.

- `launchexp.swift` — **l'outil principal.** `swiftc -O -o launchexp launchexp.swift`,
  puis `launchexp <app> <runs> base,variante1,variante1+variante2`. Lance via
  LaunchServices (comme le Dock), mesure process → fenêtre à l'écran
  (`CGWindowList`, colonne `win_cg`) et relit les jalons du journal. `+` combine
  plusieurs drapeaux dans une variante. Colonne `fil` = `thread − win_cg`.
  Une variante `nom@/chemin/Autre.app` lance une **autre build** : c'est ainsi
  qu'on compare un avant et un après dans les mêmes blocs alternés
  (`launchexp <après.app> 8 "avant@/chemin/avant.app,base"`). Colonnes `main`
  (première ligne Swift, donc le pré-`main`) et `didFin` en plus.
- `switchbench.sh <app> [runs] [count] [CORR_EXP]` — **le banc de bascule.**
  Lance l'app avec `CORR_BENCH=switch:<count>` : une fois le premier fil
  peint, le pilote intégré (`LaunchBench`, `App/LaunchExperiment.swift`) ouvre
  les `count` premiers fils de la file l'un après l'autre et journalise chaque
  latence sélection → **premier fil garni** (`BENCH switch …`, catégorie
  `bench`). La latence réelle par process se relit aussi depuis les jalons
  `EVENT select` / `EVENT shown n>0` — c'est la mesure qui vaut pour comparer
  deux builds (le résumé du pilote a changé de définition en septembre 2026).
- `launchtimer.swift` — l'ancêtre : process → fenêtre seulement, une variante.
- `wid.swift` / `widall.swift` — numéro de la fenêtre inbox, pour
  `screencapture -x -o -l <id>` (vérité écran ; blanc si la fenêtre est sur un
  autre bureau).
- `xctrace_timeline.py` / `xctrace_categories.py` — dépouillent un export
  Time Profiler : `xcrun xctrace record --template 'Time Profiler' --output t.trace
  --time-limit 4s --launch -- <app>` puis `xcrun xctrace export --input t.trace
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > t.xml`.
  Supprimer la `.trace` après export (200 Mo–1 Go). Le temps de trace n'est pas
  le temps process : se repérer aux frames, pas aux jalons.

Ne pas lancer les tests pendant une mesure (l'hôte de test s'appelle aussi
Correspondance). Les mesures tuent toute instance de l'app.

## Ce qu'on sait (août 2026, machine au calme)

- Plancher sans contenu : ~620 ms ; fenêtre avec barre latérale : ~720–760 ms.
- Fenêtre → fil : ~500 ms avant, ~210 ms après « queue d'abord » (20 messages,
  le reste au-dessus une frame plus tard) + « avatars après le fil ».
- Sans effet mesurable (±30 ms, testés et retirés) : menu contextuel seulement
  au survol, geste d'arrivée seulement sur le dernier message, `.alert`/`.help`/
  `.onHover`/accessibilité par bulle, préchauffage de la détection de liens.
  La détection de liens pèse ~30 ms au total.
- Ce qui reste : ~100 ms de construction/rendu de la queue, et le settle
  AppKit après la fenêtre (`layoutIfNeeded` → `NSHostingView.minSize`).
- Séquence réelle d'un lancement calme : `didFinish` ≈ 550 → `frame1` ≈ 675
  → fenêtre visible ≈ 710 → porte 710 → première bulle 717 → fil ≈ 900. La
  porte ne laisse rien du fil passer avant la première frame (vérifié par
  jalons ; les bulles « pré-fenêtre » qu'on voit sous Instruments sont un
  artefact de `xctrace --launch`).
- Avant `didFinish` (~550 ms) : chargement du process ~110, init SwiftUI et
  menu ~80 — dont ~45 ms de `dlopen(WritingToolsUILibraryCore)` déclenché par
  AppKit pour le menu Édition, sans interrupteur connu —, construction de la
  fenêtre ~350 (toolbar, `NSHostingView.minSize`, lignes de la `List` en
  hauteur automatique, premier rendu).
- La restauration d'état AppKit (`NSPersistentUIRestorer`) coûtait ~50 ms
  pour ne rien restaurer : désactivée (`ApplePersistenceIgnoreState`, domaine
  volatil). Le cadre de fenêtre et les largeurs de colonnes viennent des
  préférences et survivent — vérifié par un quit propre.

## Septembre 2026 — ce qui a été mesuré, gardé, écarté

Bruit de mesure : deux variantes **identiques** en blocs alternés (8 runs)
diffèrent de ±20 ms à fenêtre. Rien sous 25 ms n'est un résultat.

Gardé (A/B avant/après, 8 × 2, même minute) :
- **Un seul item de barre** pour les trois boutons d'action au lieu d'un
  `ToolbarItemGroup` (trois vues hôtes) : ~25 ms à fenêtre et au fil.
- **Release locale en `ONLY_ACTIVE_ARCH`** : la tranche x86_64 du binaire
  universel coûtait ~20 ms avant `main` (173 → 150). L'archive reste universelle.
- **Bascule de fil** (latence réelle sélection → fil garni, 12 fils) :
  médiane 135–155 ms → ~74 ms, p90 155–180 → ~110. Trois causes : le
  `backfill` d'un petit salon retenait l'ouverture derrière le Relais (il
  se fait désormais en fond quand le magasin a déjà quelque chose à montrer) ;
  le menu contextuel de CHAQUE ligne recalculait les propositions de rappel
  via `Calendar` à chaque passe (mémoïsées à la minute) ; le fichier des
  brouillons se réécrivait à l'identique à chaque bascule.
- **Index Contacts** : reparcouru entier — photos réécrites sur disque — à
  chaque lancement (~200 ms CPU hors fil principal, en concurrence avec la
  première frame). Le jeton d'historique de `CNContactStore` décide désormais.

Écarté (aucun gain hors bruit) : précharger WritingToolsUI hors fil principal
(`dlopen` en tâche détachée — l'objc runtime sérialise de toute façon) ;
`defaultSize` égale au cadre sauvegardé ; supprimer les `.commands`.
Écarté pour cause de régression visible : poser la barre d'outils après la
première frame (−60 ms à fenêtre, mais les items apparaissent après coup et le
fil, lui, n'arrive pas plus tôt).

Ce qui reste, par ordre : ~150 ms de pré-`main` (exec, dyld, validation de
signature, métadonnées) ; ~340 ms de construction AppKit/SwiftUI de la fenêtre
(menus ~60, `NSSplitViewController` et tailles minimales ~50, cadre restauré et
premier layout ~75, barre ~35, `NSThemeFrame` ~55) ; le fil ~60 après la
fenêtre. Le plancher observé d'une app SwiftUI à `NavigationSplitView` sur
cette machine est ~470 ms à `didFinish` — un rebond de Dock, pas un demi.


## Septembre 2026 (suite) — défilement et montage du fil

Mesuré au `sample` (1 ms) sur un groupe Signal de 300 messages, geste
trackpad synthétique de 8 s (phases began/changed/ended, `scratchpad/scroll`).

- **Défilement saccadé** : fil principal occupé à 93 % pendant le geste, dont
  ~55 % à REMESURER tout le contenu du `ScrollView` à chaque frame (cache de
  `ScrollViewLayoutComputer` manqué → cent cinquante rangées, alignement
  `.bubbleBottom` compris, trois fois par frame : rendu, `NSHostingView.minSize`,
  alignement des overlays). Cause : `.scrollPosition($position)` sur un
  `@State` dans `KeepScrolledToBottom` — SwiftUI y écrit à chaque frame, et
  chaque écriture invalidait le graphe. Réparé par une boîte hors graphe
  (`ScrollPositionBox`). Seconde cause, plus petite : les bulles allumaient
  leur rangée de survol en passant sous le curseur immobile (menu AppKit,
  popover, animation) — coupé pendant le geste (`ThreadScrolling`). Après :
  44 % d'occupation, le reste est le test de survol de SwiftUI à chaque frame
  (~8 %, incompressible sans toucher aux `.onHover`/`.help` des bulles).
- **Lancement, montage du fil** (`thread` → `thread-full`, ~680 ms sur le fil
  principal, fenêtre visible mais gelée) : 146 ms de `NLLanguageRecognizer`
  (bouton Traduire, dont 60 ms de chargement du modèle CoreNLP) et 78 ms de
  `NSDataDetector`, tous deux par bulle, sur le fil principal. Désormais
  préchauffés sur un autre cœur dès que les messages sont connus
  (`ThreadPrewarm`, `LinkedText.prewarm`, modèle CoreNLP dans `LaunchWarmup`),
  et le reste du fil monte par paliers de 40 bulles, une frame entre deux,
  au lieu d'un bloc. Ce qui reste : ~3 ms par bulle de construction SwiftUI
  (corps, ~15 modificateurs, `Text` attribué) — à mesurer modificateur par
  modificateur sur 130 rangées, pas sur la queue de 20.

## Septembre 2026 (suite) — la page Focus tourne

La page Focus montait ses cent vingt paragraphes d'un bloc, page blanche
pendant ce temps — sans la queue d'abord ni le préchauffage du fil Inbox.
Elle a désormais les deux (`FocusTranscriptView`, mêmes bornes que
`ThreadMetrics`), et les mêmes jalons `EVENT select` / `EVENT shown` : le
banc de bascule se lance en Focus avec `--args -correspondance.inboxMode focus`.

Mesuré avant/après, 8 blocs alternés × 12 bascules, en Focus, latence réelle
sélection → page montrée (médiane des médianes par run, médiane des p90) :

| | médiane | p90 |
|---|---|---|
| avant | ~85 ms | ~305 ms |
| après | ~92 ms | ~199 ms |

La médiane ne bouge pas (bruit : ±20 ms) — un fil court se montre aussi vite
entier que par sa queue. Ce sont les fils longs qui gagnent : ~100 ms au p90.
La bascule elle-même se joue autrement (nom d'abord, paragraphes 50 ms
après, glissement), ce que le banc ne voit pas.


## Septembre 2026 — le lancement à froid

Mesuré cache disque vidé (`sudo purge`) : fenêtre à 1,8 s contre 0,7 s tiède.
L'écart est presque entièrement de l'attente disque sur le fil principal
(8 985 défauts de page fichier à froid contre 3 260 tiède, template App Launch,
table `virtual-memory`) : 1,5 s dans le cache partagé dyld (SwiftUI 360 ms,
AppKit 180, SwiftUICore 130, objc 110 — les classes et catégories que le premier
écran fait réaliser), 250 ms dans notre binaire et les fichiers mappés (SF
Symbols, Apple Color Emoji, ICU). Le `dlopen(WritingToolsUI)` du menu Édition
monte à 220 ms. Nos propres fonctions n'y sont presque pour rien.

Ce qu'on contrôle : l'ordre des fonctions dans `__text`. Touchées au lancement
puis dispersées sur 34 Mo, elles coûtaient ~500 pages lues une à une ;
`ORDER_FILE` (project.yml, Release) les range côte à côte. `orderfile.py`
régénère `launch.order` depuis une trace App Launch symbolisée (froide, puis
tiède) — à refaire quand le premier écran change de forme, pas à chaque commit :
une fonction absente du fichier n'est qu'un avertissement muet de l'éditeur de
liens. Mesuré entre deux builds fraîches, blocs alternés 8 × 2 : `main` −40 ms,
fenêtre −110 à −160 ms tiède ; à froid, 3 paires seulement (une boîte de mot
de passe par `purge`), médianes 2 071 → 1 950 ms, dans le bruit d'une machine
chargée. Attention à comparer des builds du même âge : une build lancée depuis
des jours a ses caches de lancement et part avec ~100 ms d'avance sur une
build fraîche, et le tout premier lancement d'un binaire neuf paie Gatekeeper
(4 s).

Ce qui reste, hors de portée du code : la pagination des frameworks Apple que
le premier écran touche. Le seul levier serait un premier écran qui en touche
moins (liste seule, fil et composeur montés après la première image) — la
variante « barre d'outils après la première frame » a déjà été écartée pour
régression visible.

## Septembre 2026 — l'empreinte mémoire

`footprint.sh <app>` relève l'empreinte physique par catégorie chaque seconde
après le lancement. Sur un vrai fil (150 messages montés, une centaine de
portraits, une dizaine de photos et de cartes), la build du 8 septembre
tenait à **391–415 Mo** dès la septième seconde, dont 164 Mo d'IOSurface,
46 de CoreAnimation, 20 de CG raster, 130 de MALLOC_SMALL. Sur un Mac à
8 Go, c'est ce qui évinçait le cache disque et rendait chaque lancement
« froid » (cf. section précédente).

Ce que les IOSurface étaient — trouvé en parcourant l'arbre de couches
d'une instance vivante sous lldb (`CGImageGetWidth` sur `layer.contents`) :
88 portraits de **1024 × 1024 px** derrière des disques de 26 points, un de
3638 × 3638 (53 Mo à lui seul), des cartes Instagram et X à leur taille de
fichier. `PlatformImage(data:)` livrait la photo entière à SwiftUI, qui la
gardait telle quelle. Deux changements :

- **Les portraits se décodent à la taille du disque** (`AttachmentThumbnailStore.portrait`,
  ImageIO avec `kCGImageSourceThumbnailMaxPixelSize` = 3 × la taille en
  points), dans le même cache que les vignettes, désormais **borné en octets**
  (64 Mo) et non plus en nombre (240 vignettes pouvaient faire 400 Mo).
- **Les photos et tuiles loin hors champ lâchent leur vignette**
  (`viewportProximity`, CorrespondanceUI) : une sentinelle AppKit en fond de
  chaque image écoute les bornes du `NSClipView` et ne parle qu'au
  franchissement de deux hauteurs d'écran ; le rectangle garde sa taille, la
  page ne bouge pas, la photo revient du cache ou du disque avant d'être à
  l'écran. Hors de tout défilement (fiche, panneau), la sentinelle dit
  « près » et rien ne change.

Résultat, même protocole, même fil : **236 Mo** stables (IOSurface 1 Mo,
CoreAnimation 44, CG raster 17, MALLOC_SMALL 126), soit **−40 %**. Vérifié
à l'écran : portraits nets dans la liste et le fil, photos et cartes en place
après un long défilement vers le haut, 243 Mo après ce défilement.

Et le chrono ? Fenêtre → fil, blocs alternés 8 × 4 sur une machine qui n'a
jamais été calme (charge 3 à 10) : build corrigée 296–369 ms, la même avec les
deux changements désactivés par drapeau 320–349, la build témoin d'avant 336 ;
l'écart change de signe d'une série à l'autre, donc rien de mesurable. La
build installée depuis des jours faisait 207–250 : c'est l'âge du binaire
(caches de lancement), pas le code — comparer des builds du même âge.

Ce qui reste, et pourquoi : MALLOC_SMALL est pour l'essentiel le graphe
SwiftUI des 150 messages montés (éléments typés, listes de vues, fermetures)
et 80 poignées réseau de 120 Ko (`CProtocol.COptions`, Network.framework) ;
CoreAnimation et CG raster sont les bulles de texte rasterisées, visibles ou
non — c'est le prix de la pile non paresseuse, assumé (cf. `ThreadView`).

## Septembre 2026 — l'iPhone qui chauffe

Mesuré sur un iPhone 16 Pro branché, build de développement, `xctrace record
--device … --template 'Time Profiler' --attach Correspondance`, l'app pilotée
par argent (un fil long, six défilements, retour, second fil, retour, repos).
Attention : le runner d'argent interroge l'arbre d'accessibilité et pèse à
lui seul ~20 % d'un cœur ; le repos se mesure **sans** automatisation.

Ce qui chauffait, par ordre :

- **L'index de la feuille de partage réécrit à chaque `/sync`**
  (`ecrireIndexDuPartage`, RelayStore+Partage) : pour chaque groupe, les
  visages décodés en pleine résolution, la mosaïque composée, encodée en PNG,
  puis jetée parce que la boîte avait déjà le fichier. 1,8 s de CPU sur
  80 s d'usage, et au repos un pic de 450 ms à chaque `/sync` — c'est-à-dire
  toutes les quelques secondes dès qu'un salon bouge. Désormais : une
  empreinte de la liste, et rien n'est réécrit si elle n'a pas changé ; un
  visage déjà dans la boîte n'est pas recomposé ; les visages sont réduits
  avant la mosaïque.
- **Les portraits décodés en pleine résolution** dans la liste, le fil et la
  fiche, recréés à chaque recyclage de rangée (les piles y sont paresseuses) :
  même correctif que le Mac, `AttachmentThumbnailStore.portrait`, et la vue
  naît avec le portrait déjà en cache (pas de tâche, pas de décodage).
- **Les mosaïques de l'inbox** composées puis passées par un PNG réencodé et
  redécodé : `AvatarMosaic.composeImage` rend l'image directement, gardée
  sous la clé de la mosaïque.
- **`conversations` réécrite à chaque `/sync`** même à l'identique : toutes
  les rangées recréées. Réassignée seulement si la liste change.

Résultat, même parcours piloté (80 s actifs) : le travail d'images passe de
1,8 s de CPU à zéro (PNG 736 → 0 ms, mosaïques 1 177 → 0, JPEG 347 → 58) ;
au repos sans automatisation, **1,8 % → 0,2 % d'un cœur** sur 60 s, le seul
reste étant le `/sync` lui-même (~100 ms par retour). Le fil principal
pendant le défilement ne bouge pas (15 s sur 80) : c'est SwiftUI qui place
et dessine, plus le runner d'argent.

Et le `/sync` lui-même, après ça : la boucle demande désormais un filtre sans
présence (`MatrixBridgeService.liveSyncFilter`) — personne ne la lisait, et
chaque fantôme de pont qui changeait d'état réveillait le long-poll ; le
Relais garde une réponse vide pour lui et continue d'attendre. Et la ligne
d'inbox de chaque salon (`lastListedMessage`) se trouve par un parcours, plus
par un tri de tous ses messages : `conversations()` passe de 67 à 14 ms par
retour de `/sync` sur l'iPhone. Ce qui reste par retour utile : l'index du
partage quand la liste a vraiment changé (~50 ms), et le `/sync` lui-même.
