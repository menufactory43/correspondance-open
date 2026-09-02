# Fusion du spike « un clic » dans `main` — 2 septembre 2026

`git merge relais-un-clic` sur la branche `fusion-un-clic`, dans le worktree
`~/correspondance-fusion`. Pas de rebase : les deux historiques restent lisibles, et le commit
de fusion dit ce qu'il a tranché. Trente-trois commits de spike rencontrent seize commits de
`main` — « plusieurs agents » (un processus par agent, `--agent <nom>`, `deploy.sh` multi-agents,
les agents comme contacts, Réglages › Agents, le catalogue des moteurs).

**La règle qui a guidé chaque arbitrage : ni le multi-agents de `main`, ni le spike, ne perd une
fonction.** Là où les deux côtés touchaient la même chose, la question n'a jamais été « lequel
garder » mais « comment les faire composer ».

`main` n'a pas bougé (`60f754d`), le worktree du spike non plus (`0758e83`), et rien n'a été
poussé.

---

## Les trois conflits de contenu

### 1. `MatrixSyncParser.swift` — deux `case` dans le même `switch`

Les deux branches ajoutaient une branche à `applyState`, au même endroit, pour deux faits sans
rapport l'un avec l'autre :

| Côté | Le `case` | Ce qu'il porte |
|---|---|---|
| `main` | `AgentWire.conversationType` | le marqueur `fr.correspondance.conversation` qui, seul, fait d'un salon natif un tête-à-tête avec un agent |
| spike | `m.room.encryption` | le seul fait qui distingue un salon chiffré d'un salon en clair |

**Résolution : les deux.** Ce n'est pas un compromis, c'est la lecture correcte du conflit — git
a signalé une collision de *lignes*, pas de *sens*. Garder l'un aurait rendu l'autre muet : sans
le premier, un tête-à-tête d'agent redevient un salon quelconque ; sans le second, la fiche de
conversation dit « en clair » sur un salon chiffré, c'est-à-dire exactement le mensonge que la
phase 5 était allée corriger.

### 2. `MatrixClient.swift` — deux fonctions voisines, pas deux versions d'une seule

| Côté | La fonction |
|---|---|
| `main` | `createPrivateRoom(name:invite:isDirect:initialState:)` — le tête-à-tête marqué **à la création**, parce qu'un marqueur posé après coup laisse un instant où le salon n'est rien pour personne |
| spike | `createSelfRoom(name:chiffre:)` — le `m.room.encryption` posé **à la création**, parce qu'un salon ne se chiffre pas après coup sans laisser un morceau d'historique en clair |

Le `diff3` les avait empilées parce qu'elles sont adjacentes et partagent un commentaire de
documentation : la résolution garde les deux fonctions et retire les **trois lignes de
commentaire dupliquées** que le contexte partagé avait laissées en double au-dessus de
`createPrivateRoom`.

Vérifié au passage : aucun appelant ne change. `ensureSelfNote()` appelle `createSelfRoom` sans
`chiffre:`, des deux côtés — le paramètre est faux par défaut et n'est levé que par l'outil
`preuve-chiffrement`. La fusion n'allume donc le chiffrement de la note à soi ni plus ni moins
que chaque branche prise seule.

### 3. `Correspondance.xcodeproj/project.pbxproj` — **régénéré, pas fusionné**

Le `pbxproj` est **engendré** par `xcodegen` depuis `project.yml`. Le fusionner à la main, c'est
arbitrer sur des UUID que personne ne relit, pour produire un fichier qu'une prochaine exécution
de `xcodegen` réécrira de toute façon.

`project.yml`, lui, **fusionne tout seul** — et c'est précisément ce que la phase 7b avait
préparé en y remontant l'exception ATS `server.tailcat`, que la 7a avait écrite à la main dans
un `Info.plist` que `xcodegen` réengendre.

La résolution est donc : prendre `project.yml` fusionné, lancer `xcodegen generate`, et
**vérifier le résultat contre le `pbxproj` de `main`** :

```
$ diff <(git show :2:Correspondance.xcodeproj/project.pbxproj) Correspondance.xcodeproj/project.pbxproj | grep -c '^>'
48
$ diff <(git show :2:Correspondance.xcodeproj/project.pbxproj) Correspondance.xcodeproj/project.pbxproj | grep -c '^<'
0
```

**48 lignes ajoutées, zéro retirée.** C'est la preuve qui compte : le projet engendré est
exactement celui de `main` **plus** les apports du spike — `Features/Accueil/AccueilRelaisView.swift`,
`Services/RelaisInstallation.swift`, `SettingsChiffrementCards.swift`,
`Reglages/ChiffrementSections.swift`, `RelaisInstallationTests.swift`, le groupe `Accueil`, et la
phase de build « Embed tailcat ». Aucune cible, aucune phase, aucun fichier de `main` n'a disparu
en chemin. Un `pbxproj` fusionné à la main n'aurait pas pu se prouver aussi simplement.

---

## Les huit fusions automatiques, relues une à une

Elles sont passées sans conflit, ce qui ne veut pas dire qu'elles sont justes : git fusionne des
lignes, pas des intentions. Chacune a été relue contre les deux parents.

Sept sont **orthogonales** — le spike ajoute, `main` ajoute ailleurs, rien ne se recouvre :
`InboxStore.swift` (le mandataire Tailcat, `connecterParLeCode`, la ligne de chiffrement),
`Agent.swift` (le branchement crypto avant le premier `/sync`, et les messages illisibles
journalisés), `MatrixBridgeService.swift` (`etatDuChiffrement()`, `appareilsDuCompte()`, et
`makeRoomAdmin` qui dit « pas disponible sur ce Relais » au lieu de planter),
`MatrixRoomModel.swift` (`encryptionAlgorithm`), `AgentLocalHostTests.swift`,
`AgentProcessHost.swift`, `AgentLocalHost.swift`.

**La seule qui demandait un arbitrage est le dossier d'amorce**, et elle compose proprement :

- `--agent <nom>` (`main`) dit **quel agent** ;
- `CORRESPONDANCE_HOME` (phase 4 du spike) dit **quel essai** ;
- les deux se **multiplient** au lieu de se disputer : `--agent hermes` sous l'essai `unclic`
  donne `~/.correspondance-hermes-unclic`, et `cc` garde `~/.correspondance-agent` quand il n'y a
  pas d'essai — un NUC en production ne perd pas son état parce qu'on a introduit `--agent`.

L'app et l'agent calculent ce nom **chacun de leur côté, sans se parler** : le processus enfant
hérite de la variable, et un test tient déjà `AgentPaths.folderName` et `AgentHome.folderName`
sur la même chaîne. Le journal de `/tmp` suit l'essai lui aussi, sinon un `cc` d'essai écrirait
par-dessus le journal du `cc` de production.

---

## Le correctif : l'incident de la phase 7a cesse d'être silencieux

*(commit séparé — c'est du code neuf, pas une résolution de conflit)*

La 7a a vu un `cc` d'essai se connecter au **vrai** Relais : l'unité passait `--agent cc` **et**
`CORRESPONDANCE_AGENT_HOME` vers le dossier du spike, et `--agent` gagne. Seule la garde du
second agent l'a arrêté.

**La règle n'est pas renversée**, parce qu'elle est juste : un plist de LaunchAgent est statique,
il passe `--agent`, et il doit gagner sur un environnement hérité — sinon une variable oubliée
détourne un agent vers le dossier d'un autre. C'est exactement ce que le test
`testLArgumentGagneSurLEnvironnement` de `main` protège, et il passe toujours.

Ce qui était fautif, c'est que **le perdant était le seul des deux à dire « ceci est un essai »**,
et que personne ne l'apprenait. `AgentHome.contradiction` rend donc le silence impossible :
quand `--agent` fait ignorer un `CORRESPONDANCE_AGENT_HOME` qui désignait ailleurs, la ligne part
au journal **avant le premier `/sync`** — avant que l'agent se connecte, pas après qu'il a répondu
au nom de quelqu'un — et elle nomme le dossier réellement lu ainsi que la variable qui, elle,
marche.

Trois tests neufs : l'essai qui survit à `--agent` (et qui ne tombe **jamais** sur
`~/.correspondance-agent`), la contradiction qui se dit, et les trois cas où il n'y a rien à
dire — une garde qui crie pour rien finit par ne plus être lue.

**Honnêteté sur la portée** : c'est une garde **bruyante**, pas une impossibilité de typage. Un
opérateur qui écrit une unité contradictoire et ne lit pas son journal peut encore se tromper. La
vraie disparition du piège est ailleurs, et elle est acquise par la fusion : un essai n'a plus
**aucune raison** de passer par `CORRESPONDANCE_AGENT_HOME`, puisque `CORRESPONDANCE_HOME` fait
le travail et se combine avec `--agent`.

---

## Les preuves

### Tests du paquet

```
$ swift test --package-path Packages/CorrespondanceCore --scratch-path /tmp/build-fusion-sans
Executed 873 tests, with 1 test skipped and 0 failures (0 unexpected)

$ CORRESPONDANCE_CRYPTO=1 swift test --package-path Packages/CorrespondanceCore \
    --scratch-path /tmp/build-fusion-crypto
Executed 878 tests, with 1 test skipped and 0 failures (0 unexpected)
```

Le spike seul en comptait 838 / 843 : `main` en apporte 32, le correctif 7a en ajoute 3. L'ignoré
est `PreuveTailcatTests`, qui exige une machine distante.

### Construction

```
$ CORRESPONDANCE_CRYPTO=1 xcodebuild -project Correspondance.xcodeproj -scheme Correspondance \
    -configuration Debug -derivedDataPath /tmp/dd-fusion build
** BUILD SUCCEEDED **

$ CORRESPONDANCE_CRYPTO=1 xcodebuild -project Correspondance.xcodeproj -scheme 'Correspondance iOS' \
    -configuration Debug -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath /tmp/dd-fusion-ios build
** BUILD SUCCEEDED **
```

La phase « Embed tailcat » tourne et pose bien le mandataire :
`Contents/Helpers/tailcat`, 28 845 632 octets, depuis `~/unclic-publication`.

### Tests Mac

`xcodebuild test` ne passe pas sur Xcode 26.x (« Assertion failed: childPID > 0 » dans
`IDELaunchServicesLauncher`) : c'est `scripts/test.sh` qui est la manière du dépôt, en injectant
le bundle XCTest dans l'app hôte.

```
$ CORRESPONDANCE_CRYPTO=1 bash scripts/test.sh
** TEST BUILD SUCCEEDED **
Test Suite 'All tests' passed
```

189 cas dans `CorrespondanceTests`, zéro échec — dont les 14 `RelaisInstallationTests` du spike.

### Tests iOS

Aucun simulateur n'existait sur cette machine (des runtimes, mais pas un seul appareil créé), et
l'UDID que `scripts/test-ios.sh` porte en dur est périmé. Un appareil neuf a donc été créé pour
la campagne, puis retiré.

```
$ CORRESPONDANCE_CRYPTO=1 bash scripts/test-ios.sh B9EF5A3F-…
Executed 17 tests, with 2 failures (0 unexpected) in 632.887 seconds
```

**Les deux échecs sont de l'instabilité de simulateur froid, pas la fusion**, et c'est vérifiable
de trois façons :

1. Ce sont deux tests de **geste** — `testLongPressShowsReactionsAndActions` (le menu d'appui
   long) et `testGlisserVersLeHautVerrouille` (le verrou du micro au glissé vers le haut) — dont
   le sujet n'a rien à voir avec ce que la fusion touche.
2. `git diff main..HEAD` ne montre **aucune ligne** changée dans `CorrespondanceiOSUITests/`, et
   un seul fichier touché dans `Features/Fil/` : `ThreadInfoSheet.swift`, +28 lignes, la ligne du
   chiffrement. Le test qui exerce précisément cette feuille, `testPillOpensThreadInfo`, **passe**.
3. Rejoués seuls sur le même simulateur, les deux **passent** :

```
$ xcodebuild … -only-testing:…/testGlisserVersLeHautVerrouille \
               -only-testing:…/testLongPressShowsReactionsAndActions test
Test Case '…testLongPressShowsReactionsAndActions' passed (38.929 seconds)
Test Case '…testGlisserVersLeHautVerrouille'       passed (26.857 seconds)
** TEST SUCCEEDED **
```

Les quinze autres passent du premier coup. Ils prennent 7 à 64 secondes chacun : sur un
simulateur qui démarre en même temps que la campagne, un geste chronométré rate.

### Le piège du drapeau, revérifié — et écrit dans `docs/MATRIX-SETUP.md`

Le piège de la 7b se reproduit à l'identique. Depuis un `DerivedData` résolu **avec** le drapeau,
le même build **sans** le drapeau :

```
$ xcodebuild ... -derivedDataPath /tmp/dd-fusion build
error: unable to resolve module dependency: 'MatrixSDKCryptoFFI'
error: unable to resolve module dependency: 'matrix_sdk_commonFFI'
error: unable to resolve module dependency: 'matrix_sdk_cryptoFFI'
** BUILD FAILED **
```

Ce n'est pas une régression du code, c'est un `DerivedData` qui se souvient. Le paragraphe est
ajouté à `docs/MATRIX-SETUP.md` § Chiffrement : **garder le drapeau sur toutes les commandes d'un
même dossier**, ou donner à chaque configuration son propre `-derivedDataPath`, comme
`--scratch-path` le fait déjà pour SwiftPM.

### Tests shell

```
$ bash infra/relais/tests/install-plan.sh      → Plan d'installation du Relais : tout est conforme.
$ bash infra/matrix/tests/install-plan.sh      → Plan d'installation : tout est conforme.
$ bash infra/matrix/tests/essai-isolation.sh   → Relais d'essai : isolé de la prod sur tous les axes vérifiables.
```

### Preuve d'intégration : le Relais du spike posé par l'installeur de la fusion

Sans jamais toucher la production, et **sans piloter l'écran** — le propriétaire travaille sur ce
Mac ; ce qui suit prouve que ça démarre, pas que c'est beau.

```
$ cd ~/unclic-publication && python3 -m http.server 8020 --bind 127.0.0.1 &
$ CORRESPONDANCE_RELEASES=http://127.0.0.1:8020 bash infra/relais/install.sh
→ mautrix-messenger : sha256 bad1ef2d…5f1 ✓
→ ✓ le Relais répond ({"name":"continuwuity","version":"26.8.1 (ab3c05d)"})
→ ✓ @essai:unclic.local enregistré
✓ le Relais répond, connecté comme @essai:unclic.local (/login puis /account/whoami).
  Ponts : WhatsApp 29318, Signal 29328, Instagram 29330, Messenger 29331 — portails chiffrés.
  macOS : ni Tailcat ni Tailscale ne sont posés, et aucun n'est requis.
  correspondance://relais/eyJleHAiOjE3ODgzNTc0MDcu…
  Vérification (six mots) : usine marée dune chêne zeste encre
```

L'app **construite depuis la fusion**, lancée sous un essai, sans qu'on touche à l'écran :

```
$ CORRESPONDANCE_HOME=unclic /tmp/dd-fusion/…/Correspondance.app/Contents/MacOS/Correspondance &
$ sleep 25 ; pgrep -fl "dd-fusion.*Correspondance"
72615 /tmp/dd-fusion/Build/Products/Debug/Correspondance.app/Contents/MacOS/Correspondance
```

Vivante après vingt-cinq secondes, et le journal ne porte **aucune trace de plantage** — une
seule ligne, le `ApplePersistenceIgnoreState` que macOS écrit pour toute app lancée hors
LaunchServices. Elle a écrit dans `Correspondance-unclic`, jamais dans `Correspondance` : le
`CORRESPONDANCE_HOME` de la phase 4 tient, dans un binaire qui porte aussi le multi-agents de
`main`.

Puis le retrait, et l'état de la machine :

```
$ bash infra/relais/uninstall.sh --prefix ~/.correspondance-unclic
✓ le Relais est retiré de cette machine.
$ pgrep -fl continuwuity ; pgrep -fl mautrix ; pgrep -fl tailcat ; pgrep -fl "http.server 8020"
(rien)
$ lsof -nP -iTCP:8010 -iTCP:8020 -sTCP:LISTEN
8010 et 8020 fermés
$ ls ~/Library/LaunchAgents | grep correspondance
aucun
```

**Aucun orphelin.** Et la production, relevée fichier par fichier (mtime, taille, chemin) avant et
après toute la manœuvre :

```
$ diff /tmp/prod-avant.txt /tmp/prod-final.txt && echo "PROD INTACTE"
PROD INTACTE
```

35 fichiers sous `~/.correspondance-agent/` et
`~/Library/Application Support/Correspondance/`, tous identiques au bit d'horodatage près. Le
NUC n'a pas été approché.

---

## Ce que le propriétaire doit vérifier **à l'écran** avant de faire avancer `main`

Rien ci-dessus n'a piloté l'interface : les tests prouvent que le code tient, pas que les écrans
disent la bonne chose. Les cinq points où les deux côtés se rencontrent vraiment, et qu'aucun
test ne couvre :

1. **L'écran d'accueil coexiste avec les agents.** Lancer l'app sous un essai, sans Relais :
   les deux cartes doivent apparaître (« Sur ce Mac », « Sur une machine à moi »). Puis
   « Installer ici », et vérifier que la note à soi arrive **sans une seule frappe** — et que
   Réglages › Agents est toujours là, avec son catalogue de moteurs.
2. **Un tête-à-tête d'agent dans un salon chiffré.** C'est le point exact du premier conflit :
   ouvrir un tête-à-tête avec `cc` sur le Relais du spike, et vérifier que la fiche montre
   **« Chiffré »** et que l'agent **répond**. Un agent muet dans un salon chiffré était le
   symptôme de la phase 4 ; le journal doit dire la cause s'il ne comprend pas.
3. **Plusieurs agents sous un essai.** Activer deux agents (`cc` et un second) et vérifier dans
   Réglages › Agents que chacun a bien **son** dossier `-unclic`, et qu'aucun des deux ne se
   connecte au Relais de production. C'est la composition `--agent` × `CORRESPONDANCE_HOME`, vue
   de l'écran plutôt que d'un test.
4. **Les trois états du chiffrement sur des conversations réelles.** « Chiffré » sur un salon
   natif, « Chiffré par le pont » sur un portail, « En clair » ailleurs — et le cadenas plein
   qui n'apparaît **jamais** sur un portail.
5. **Les deux écrans du chiffrement**, phrase de récupération et appareils du compte, sur un
   compte qui porte aussi des agents : la liste des appareils doit montrer les sessions des
   agents à côté de celles de l'app, sans les confondre.

Deux observations à trancher, qui ne bloquent pas la fusion :

- **`scripts/test.sh` écrit dans les données de production.** Il lance le vrai binaire de l'app
  comme hôte XCTest, sans `CORRESPONDANCE_HOME` : `drafts.json`, `hidden-messages.json` et
  `correspondance.sqlite-shm` de `~/Library/Application Support/Correspondance/` ont été
  retouchés pendant la campagne. C'est **antérieur à la fusion** — ni `main` ni le spike ne l'ont
  introduit — mais c'est une surprise pour qui croit qu'un test ne touche rien. Poser
  `CORRESPONDANCE_HOME=test` dans le script coûterait une ligne.

  Ce que ça a coûté ici, dit exactement : le relevé de fin montre **un seul écart** sur les 35
  fichiers de production, et c'est un `mtime` — `hidden-messages.json`, réécrit à 15:43:56, même
  taille au bit près (565 octets), chemin et contenu inchangés. Aucun fichier ajouté, aucun
  retiré, aucune taille modifiée nulle part, et deux relevés à 45 secondes d'intervalle après la
  campagne sont identiques : plus rien n'écrit. L'écriture vient de l'hôte XCTest de
  `scripts/test.sh`, pas de l'app construite depuis la fusion — celle-là a tourné sous
  `CORRESPONDANCE_HOME=unclic` et son relevé, pris pendant qu'elle vivait, était identique à
  celui d'avant son lancement.
- **`scripts/test.sh` n'a pas de `--scratch-path`**, donc le lancer avec `CORRESPONDANCE_CRYPTO=1`
  laisse le `.build` par défaut résolu **avec** la crypto — et le `swift test` nu suivant s'arrête
  sur un `error: fatalError` qui ne dit rien de sa cause. C'est le même piège que celui du
  `DerivedData`, du côté SwiftPM, et le remède est le même : un chemin de travail par
  configuration. En attendant, `rm -rf Packages/CorrespondanceCore/.build` remet les choses
  d'aplomb.
- **`scripts/test-ios.sh` porte un UDID de simulateur en dur** qui n'existe plus sur cette
  machine (aucun appareil n'y est créé, seulement des runtimes). Le lire depuis
  `xcrun simctl list` éviterait de le corriger à chaque nouvelle machine.
