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
