# Phase 2 — Le chiffrement dans le client Swift

Éprouvé le 2 septembre 2026, sur le Mac de développement, contre le Relais Continuwuity de
la phase 1 (`~/.correspondance-unclic/`, `127.0.0.1:8010`). Tout le code neuf est **derrière
un drapeau de manifeste** : sans `CORRESPONDANCE_CRYPTO=1`, `Package.swift` décrit le paquet
d'avant, l'XCFramework n'est même pas téléchargé, et les 759 tests existants passent.

**Verdict** : *le chiffrement de bout en bout tient dans le client existant, pour environ
+52 Mio sur le binaire Mac et trois demi-journées de travail déjà faites.* Le déchiffrement
en amont du `/sync`, le chiffrement à l'envoi et **le partage de clés entre deux appareils du
même compte** sont prouvés en marche. Ce qui manque pour le chantier E complet est la
sauvegarde des clés, la vérification d'appareil, l'historique d'avant l'appareil, et le
partage du client avec `cc` et l'extension iOS : **6 à 9 jours**.

---

## 0. La découverte à mettre en tête : Continuwuity ne refuse rien

Le plan demandait de mesurer si le homeserver bloquait une étape des clés. **Il n'en bloque
aucune.** Toutes les routes de chiffrement de l'API cliente répondent, et les deux preuves
ci-dessous ne sont passées par aucun contournement.

| Route | Continuwuity 26.8.1 | Où c'est prouvé |
|---|---|---|
| `POST /keys/upload` | ✅ | preuve A, `requêtes keys/upload` au premier `/sync` |
| `POST /keys/query` | ✅ | preuves A et B, à chaque tour |
| `POST /keys/claim` | ✅ | preuve B — sans elle, `m.room_key.withheld` (cf. § 3) |
| `PUT /sendToDevice/{type}/{txn}` | ✅ | preuve B, le `m.room_key` qui arrive |
| `/sync` → `to_device`, `device_lists`, `device_one_time_keys_count` | ✅ | preuve B |
| `POST` / `GET /room_keys/version` (sauvegarde des clés) | ✅ `HTTP 200` | § 6 |
| `POST /keys/device_signing/upload` (vérification croisée) | ✅ `HTTP 200` | § 6 |

C'est l'exact inverse de la phase 1, où **aucun** des quatre appels `_synapse/admin` n'existait :
l'administration est propre à Synapse, le chiffrement est de la spécification, et Continuwuity
implémente la spécification. Le chiffrement n'est donc **pas** un argument pour changer de
homeserver.

---

## 1. Le choix de dépendance : `matrix-sdk-crypto-ffi`, pas le SDK d'Element X

**En deux lignes** : le paquet SPM `matrix-rust-components-swift` publie `MatrixSDKFFI`,
c'est-à-dire `matrix-sdk-ffi` — le client complet d'Element X, avec **son propre** service de
synchronisation, et qui n'expose **aucun** `OlmMachine`. L'adopter voudrait dire jeter notre
`/sync`, notre pipeline et notre modèle de conversation. `matrix-sdk-crypto-ffi` publie la
machine crypto **seule**, qu'on pilote depuis notre `/sync` existant : c'est la même
bibliothèque Rust, sans le client autour.

La vérification, plutôt que la lecture de la documentation :

```
$ for f in $(gh api repos/matrix-org/matrix-rust-sdk/contents/bindings/matrix-sdk-ffi/src --jq '.[].name'); do
    … grep -c "OlmMachine" …
  done
(aucune occurrence dans les 37 fichiers de matrix-sdk-ffi)

$ gh api repos/matrix-org/matrix-rust-components-swift/contents/Package.swift | base64 -d
let version = "26.08.11"
let url = ".../releases/download/\(version)/MatrixSDKFFI.xcframework.zip"
targets: [ .binaryTarget(name: "MatrixSDKFFI", …), .target(name: "MatrixRustSDK", …) ]
```

### La version épinglée

| | |
|---|---|
| Dépendance | `matrix-sdk-crypto-ffi`, release officielle de `matrix-org/matrix-rust-sdk` |
| Tag | **`matrix-sdk-crypto-ffi-0.17.0`** (publié le 26 mai 2026) |
| Artefact | `MatrixSDKCryptoFFI.zip`, 150 127 687 octets |
| sha256 du zip | `7d5e15e072eccb8cf105570bd50ebde9dece60b1bcef007139b4f265f2b0d75a` |
| Tranches | `macos-arm64_x86_64`, `ios-arm64`, `ios-arm64_x86_64-simulator` |

Le zip n'est **pas** un paquet SPM : il ne porte pas de `Package.swift`, et ses liaisons
uniffi (`MatrixSDKCrypto.swift`, `matrix_sdk_crypto.swift`, `matrix_sdk_common.swift`,
14 805 lignes engendrées) sont à côté de l'XCFramework, pas dedans. On consomme donc
l'XCFramework par `.binaryTarget(url:checksum:)` — SPM vérifie la somme à chaque résolution —
et on **verse les trois fichiers de liaisons dans le dépôt**, sous
`Sources/MatrixSDKCrypto/`, avec la licence Apache amont. C'est ce que fait matrix-ios-sdk ;
c'est 468 Ko de code engendré qu'on ne modifie jamais.

### Le drapeau

Le drapeau est **dans le manifeste**, pas dans le code, parce que la dépendance elle-même ne
doit pas exister quand on n'en veut pas : `cc` se construit sous Linux, où un XCFramework
Apple n'a aucun sens et fait échouer la résolution.

```swift
// Packages/CorrespondanceCore/Package.swift
let chiffrement = ProcessInfo.processInfo.environment["CORRESPONDANCE_CRYPTO"] == "1"
…
] + (chiffrement ? ciblesChiffrement : [])
```

```
swift build                          → paquet d'avant, aucune dépendance binaire résolue
CORRESPONDANCE_CRYPTO=1 swift build  → + MatrixSDKCryptoFFI, MatrixSDKCrypto,
                                         CorrespondanceMatrixCrypto, preuve-chiffrement
```

Et un **second** verrou, à l'exécution, pour l'app : `CORRESPONDANCE_CHIFFREMENT=1`. Un
binaire construit avec le drapeau se comporte quand même comme avant tant qu'on ne le lui
demande pas (`MatrixChiffrement.swift`).

**Piège** : les deux configurations ne doivent pas partager le même `.build`, sinon le
`#if canImport(CorrespondanceMatrixCrypto)` reste vrai sur un module resté là de la
construction précédente. D'où `--scratch-path` séparé dans les commandes ci-dessous.

### Ce que ça pèse

Mesuré sur la **même** app, construite deux fois, `Release`, un seul commit d'écart (le
drapeau) :

| | sans chiffrement | avec | différence |
|---|---|---|---|
| Bundle `Correspondance.app` (Release) | 18 Mo | 70 Mo | **+52 Mo** |
| Binaire `MacOS/Correspondance` | 15 475 296 o | 70 107 776 o | **+54 632 480 o (+52,1 Mio)** |
| Le même, `strip -x` | 6 594 512 o | 47 955 936 o | **+41 361 424 o (+39,4 Mio)** |
| Le même, `gzip -9` (l'ordre de grandeur du DMG) | 2 666 515 o | 17 803 473 o | **+15 136 958 o (+14,4 Mio)** |
| `MacOS/correspondance-agent` (`cc`) | 1 877 880 o | 1 877 880 o | **0** — au bit près |
| Bundle Debug | 27 Mo | 81 Mo | +54 Mo |

```
$ du -sh /tmp/dd-unclic-rel/Build/Products/Release/Correspondance.app
 18M
$ du -sh /tmp/dd-unclic-rel-crypto/Build/Products/Release/Correspondance.app
 70M
$ ls -l …/Release/Correspondance.app/Contents/MacOS/correspondance-agent   # les deux
1877880
```

L'XCFramework fait 504 Mo sur le disque, mais ce sont des bibliothèques **statiques**
(`libmatrix_sdk_crypto_ffi.a`, 203 Mo pour la tranche macOS universelle) : seul le code
appelé entre dans le binaire. Le vrai coût pour l'utilisateur est **+14 Mo de
téléchargement**, pour une app qui en pèse 2,7 aujourd'hui — elle passerait à ~18 Mo. C'est
le prix d'une machine crypto écrite en Rust ; à comparer aux 250 Mo que Beeper embarque.

`cc` est **inchangé au bit près** : c'est la preuve mécanique que le drapeau tient.

---

## 2. Ce qui est branché, et où

Trois fichiers neufs, une frontière, zéro dépendance Apple dans le client Matrix.

```
Packages/CorrespondanceCore/Sources/
  CorrespondanceMatrixClient/MatrixCrypto.swift    ← la frontière + le branchement /sync
  CorrespondanceMatrixCrypto/RustCryptoEngine.swift ← la machine Rust (drapeau seulement)
  CorrespondanceCore/Matrix/MatrixChiffrement.swift ← les deux verrous, côté app
  MatrixSDKCrypto/                                  ← les liaisons uniffi amont, versées
  preuve-chiffrement/main.swift                     ← le banc de preuve
```

**Le protocole `MatrixCryptoEngine`** vit dans `CorrespondanceMatrixClient` (Foundation pur,
compile sous Linux). L'implémentation vit ailleurs. `MatrixClient` garde un
`cryptoEngine: MatrixCryptoEngine?` **nil par défaut** : sans moteur, pas une ligne de
chiffrement ne s'exécute.

**Qui appelle qui** : le moteur ne fait *jamais* de réseau. Il rend des requêtes ; c'est
`MatrixClient` qui les poste et lui rapporte la réponse. Ça évite le cycle
« client → moteur → client » et garde le moteur testable sans serveur.

Le tour d'un `/sync`, dans l'ordre (`MatrixCrypto.swift`, `appliquerChiffrement`) :

1. `to_device`, `device_lists`, `device_one_time_keys_count` → `receiveSyncChanges` ;
2. vider les requêtes sortantes (`keys/upload`, `keys/query`, `keys/claim`, `sendToDevice`,
   `signatures/upload`) et rapporter chaque réponse à la machine ;
3. relever les salons qui portent un `m.room.encryption` ;
4. **déchiffrer chaque `m.room.encrypted` et le remplacer par son clair, dans la réponse
   `/sync` elle-même** — le reste du pipeline (`MatrixSyncParser`, la base, l'interface) ne
   voit que des `m.room.message` ordinaires et n'a pas changé d'une ligne.

À l'envoi (`sendEvent`) : si le salon est chiffré, on suit les membres, on ouvre les sessions
Olm manquantes, on partage la clé de salon, on chiffre, et on poste un `m.room.encrypted`.
`sendText` passe par `sendEvent` **seulement** quand un moteur est branché — sinon c'est le
chemin d'avant, intact.

Trois ajouts additifs ailleurs : `MatrixSyncResponse` gagne `to_device` / `device_lists` /
`device_one_time_keys_count` ; `createSelfRoom(name:chiffre:)` pose un `m.room.encryption`
**à la création** (un salon ne se chiffre pas rétroactivement) ; `MatrixBridgeService.syncOnce`
appelle `MatrixChiffrement.brancher(sur:)`, qui ne fait rien sans les deux verrous.

**La persistance** est sous le dossier de l'app, donc déplacée d'un bloc par
`CORRESPONDANCE_HOME` — un essai ne mélange jamais ses clés avec les vraies :

```
$ ls -la ~/Library/Application\ Support/Correspondance-unclic/crypto/*/
matrix-sdk-crypto.sqlite3       180224
matrix-sdk-crypto.sqlite3-shm    32768
matrix-sdk-crypto.sqlite3-wal   144232
```

### Les tests

```
$ swift test --package-path Packages/CorrespondanceCore
	 Executed 759 tests, with 0 failures (0 unexpected) in 3.324 seconds

$ CORRESPONDANCE_CRYPTO=1 swift test --package-path Packages/CorrespondanceCore \
    --scratch-path /tmp/build-unclic-crypto
	 Executed 764 tests, with 0 failures (0 unexpected) in 1.649 seconds
```

759 → 764 : les cinq du moteur (identité, `keys/upload` d'une machine neuve, persistance du
magasin, deux magasins pour deux sessions, traduction des requêtes).

---

## 3. Deux pièges qui coûtent une soirée chacun

Ils ne sont écrits nulle part et se manifestent **à l'autre bout**, jamais chez l'appelant.

**a) `getMissingSessions` avant `shareRoomKey`.** Sans l'appel `keys/claim` qui ouvre les
sessions Olm 1:1, la machine ne peut chiffrer la clé pour personne — et au lieu d'échouer,
elle envoie poliment un `m.room_key.withheld`. Le message part, il paraît normal, et l'autre
appareil ne le lira **jamais**. C'est ce que le journal du second appareil a fini par dire :

```
to_device brut : type=m.room_key.withheld de=@essai:unclic.local algo=m.megolm.v1.aes-sha2
```

La documentation du binding le dit en une ligne perdue :
*« This method should be called every time before a call to share_room_key(). »*

**b) `to_device` s'envoie sous `messages`, se reçoit sous `events`.** Deux emballages
différents, deux échecs différents :

```
✗ http(status: 400, errcode: "M_BAD_JSON",
       message: "deserialization failed: missing field `messages`")
```

à l'envoi (la machine rend la carte des destinataires toute nue, `/sendToDevice` la veut sous
`messages`) ; et à la réception, `receiveSyncChanges` attend la **section `to_device` du
`/sync` entière** (`{"events":[…]}`), pas le tableau nu — un tableau lui fait rendre une
erreur de désérialisation *silencieuse du point de vue de l'appelant*, et la clé de salon
n'est jamais extraite. Symptôme : `to_device 1, clés de salon 0`, et rien dans le journal.

Les deux sont corrigés et commentés à l'endroit du code où ils se sont produits.

---

## 4. Preuve A — la Note à soi chiffrée, l'app relancée, le message relu

Une commande rejoue tout :

```
$ bash infra/relais-spike/preuve-chiffrement.sh
```

### A.1 — le salon est créé chiffré, le message part chiffré

```
### PREUVE A — 1. l'appareil A crée la Note à soi CHIFFRÉE et y écrit
→ session neuve : @essai:unclic.local / appareil qktaC6kqcC
→ machine crypto : magasin /Users/…/.correspondance-unclic/preuve/appareilA/crypto
  curve25519 5Qg54Y2/VEG8kWLUW7TIlGdulnQb+2ONS/RW+dut5D0 · ed25519 5SoEg2DzLe7hHzonKYwATwPPDF6Q85yQB3YB+HW/ApI
  /sync #1 (initial) — chiffrés 7 → lus 0, échecs 7 · to_device 0, clés de salon 0 · requêtes keys/upload,keys/query
  /sync #2 (initial) — chiffrés 7 → lus 0, échecs 7 · to_device 0, clés de salon 0 · requêtes keys/query
→ salon créé, chiffré à la création : !G-D7hSxuiT0e92UJHTivXB9Z8iS7c86vcbJeuDQ9ZjM
  m.room.encryption = m.megolm.v1.aes-sha2
→ membres du salon : @essai:unclic.local
→ envoyé : $zCyI1vaUaiGZHqr1twirZTuE4DUNfq6y9T8fLLt-VeY
→ ce que le Relais stocke : type=m.room.encrypted algorithm=m.megolm.v1.aes-sha2
  ciphertext (100 premiers) : AwgAEsABljIgOgp9g/wJY1IPuPAYkho1PiBmcT8rRv1mtZ8bQq3XZBTr1ApMCtYSLXY1s2F5R+EPH8lo3WuMG/mWOraZid6fYduU…
```

Le premier `/sync` publie les clés d'appareil (`keys/upload`) : c'est l'étape 2 du plan, faite.
Les « chiffrés 7 → lus 0 » de ce tour sont les messages d'**autres** salons chiffrés, restés
d'essais précédents ; le compteur du journal porte sur tous les salons.

### A.2 — ce que le Relais stocke, vu sans le client

```
### PREUVE A — 2. ce que le Relais stocke vraiment, vu sans le client
$ curl … /rooms/!G-D7hS…/state/m.room.encryption/
{
    "algorithm": "m.megolm.v1.aes-sha2"
}
```

### A.3 — un **processus neuf** relit

Pas un second `sync()` dans le même programme : un processus séparé, qui rouvre la session
par le jeton enregistré et le magasin de clés du disque. C'est exactement « l'app relancée ».

```
### PREUVE A — 3. processus NEUF (« l'app relancée »), même appareil, même magasin
→ session reprise : @essai:unclic.local / appareil qktaC6kqcC
  curve25519 5Qg54Y2/… · ed25519 5SoEg2DzL…            ← la même identité qu'au tour 1
  /sync #1 (initial) — chiffrés 8 → lus 1, échecs 7 · to_device 0, clés de salon 0 · requêtes keys/query
  …
→ journal du dernier /sync : chiffrés 8 → lus 1, échecs 7 · to_device 0, clés de salon 0
→ salons que le client sait chiffrés : !G-D7hSxuiT0e92UJHTivXB9Z8iS7c86vcbJeuDQ9ZjM, …
  ✓ @essai:unclic.local : « Preuve A : ce message part chiffré dans la Note à soi. »   (event $zCyI1vaUaiGZHqr1twirZTuE4DUNfq6y9T8fLLt-VeY)
→ 1 message(s) lu(s) en clair.
```

`chiffrés 1 → lus 1` sur ce salon : un `m.room.encrypted` est arrivé par le `/sync` et en est
ressorti en clair, en amont du pipeline. C'est la ligne de journal que le plan demandait.

### A.4 — et dans l'app, pour de vrai

Le salon « Note à soi » que **l'app elle-même** avait créé en phase 1 a été rendu chiffré
(`m.room.encryption` posé), puis un message y a été envoyé chiffré. L'app, construite avec le
drapeau et lancée avec les deux verrous, l'affiche en clair :

```
$ CORRESPONDANCE_CRYPTO=1 xcodebuild -project Correspondance.xcodeproj -scheme Correspondance \
    -configuration Debug -derivedDataPath /tmp/dd-unclic-crypto build
** BUILD SUCCEEDED **
$ CORRESPONDANCE_HOME=unclic CORRESPONDANCE_CHIFFREMENT=1 \
    /tmp/dd-unclic-crypto/Build/Products/Debug/Correspondance.app/Contents/MacOS/Correspondance &
$ … preuve-chiffrement chiffrer-salon appareilA '!9xY9-0cI0Rqp6Hbr-eCP_a0ATaVwK4__R5fh4E1yTz4'
→ !9xY9…  : m.room.encryption = m.megolm.v1.aes-sha2
$ … preuve-chiffrement envoyer appareilA '!9xY9…' "Preuve phase 2 : ce message est chiffré de bout en bout, et l'app le lit."
→ ce que le Relais stocke : type=m.room.encrypted algorithm=m.megolm.v1.aes-sha2
```

![La Note à soi chiffrée, lue par l'app](app-note-chiffree.png)

*La ligne d'inbox de la « Note à soi », dans l'app, à 01:35 : « Preuve phase 2 : ce message
est chiffré d… ». Le Relais ne stocke qu'un `m.room.encrypted` ; l'app affiche le texte.
Aucun autre écran n'a changé. (Capture recadrée sur cette ligne : le reste de l'inbox est de
l'iMessage local, qui n'a rien à voir avec la preuve.)*

**Ce que l'app n'affiche pas** : le salon de gestion d'un pont n'est pas une conversation de
l'inbox — `MatrixBridgeService` le tient dans `managementRoomIDs` et s'en sert pour l'état des
ponts et le QR, pas pour le fil. C'est un choix antérieur à cette phase ; la preuve du `help`
chiffré est donc au § 5, faite par le **même** `MatrixClient`.

**Prudence prod.** Une première tentative de lancement par `open … --env CORRESPONDANCE_HOME=unclic`
a été faite ; les conversations visibles à l'écran (iMessage local) sont les mêmes quel que
soit le jeu de données, ce qui a d'abord fait croire à une fuite. Vérifié ensuite : la session
Matrix, la base et le magasin de clés étaient bien sous `Correspondance-unclic`, et
`~/.correspondance-agent/` n'a pas été touché (tous les drapeaux `.voulu` à zéro, `agents.voulus`
vide). Pour lever le doute, les lancements suivants passent par l'exécutable avec
l'environnement en préfixe, jamais par `open --env`.

---

## 5. Preuve B — une seconde session du même compte reçoit la clé

C'est la preuve qui compte : le cache local ne prouve rien, le **partage de clés** si. Une
seconde session, un `device_id` différent, un magasin de clés **vierge**.

### B.1 — elle ne lit rien, et c'est normal

```
### PREUVE B — 1. une SECONDE session du même compte, magasin vierge : elle ne lit rien
→ session neuve : @essai:unclic.local / appareil 184dIvi0KR
→ machine crypto : magasin /Users/…/preuve/appareilB/crypto
  curve25519 TiHmr9k8bpaYR/hq3HRti3MZ70aSaEshWDWms0/61RQ · ed25519 0T+aEtBwiTksCajppXADcq6Uh/LZLpHhfTGoCTHw5N0
  /sync #1 (initial) — chiffrés 8 → lus 0, échecs 8 · to_device 0, clés de salon 0 · requêtes keys/upload,keys/query
  …
  ✗ resté chiffré : $zCyI1vaUaiGZHqr1twirZTuE4DUNfq6y9T8fLLt-VeY
→ aucun message lisible.
```

Contrôle négatif propre : même compte, même jeton d'accès possible, et pourtant **illisible**.
Le Relais n'a rien à donner.

### B.2 — l'appareil A réécrit ; sa machine voit le nouvel appareil

```
### PREUVE B — 2. l'appareil A réécrit : sa machine voit le nouvel appareil et lui porte la clé
→ session reprise : @essai:unclic.local / appareil qktaC6kqcC
→ salon !G-D7hSxuiT0e92UJHTivXB9Z8iS7c86vcbJeuDQ9ZjM — chiffré ? true
→ membres du salon : @essai:unclic.local
→ envoyé : $UkbjTw86a_ZGhZP292taaHAiG8bSdeR-R8q5QLtlg3I
→ ce que le Relais stocke : type=m.room.encrypted algorithm=m.megolm.v1.aes-sha2
```

### B.3 — la seconde session lit

```
### PREUVE B — 3. la seconde session relit : la clé de salon est arrivée
→ session reprise : @essai:unclic.local / appareil 184dIvi0KR
  /sync #1 (initial) — chiffrés 9 → lus 1, échecs 8 · to_device 1, clés de salon 1 · requêtes keys/upload,keys/query
    to_device brut : type=m.room.encrypted de=@essai:unclic.local algo=m.olm.v1.curve25519-aes-sha2
    to_device lu   : type=m.room_key de @essai:unclic.local
    (note : déchiffrer : Megolm(error: "The message was encrypted using an unknown message index,
                                        first known index 1, index of the message 0"))
→ journal du dernier /sync : chiffrés 9 → lus 1, échecs 8 · to_device 0, clés de salon 0
  ✗ resté chiffré : $zCyI1vaUaiGZHqr1twirZTuE4DUNfq6y9T8fLLt-VeY
  ✓ @essai:unclic.local : « Preuve B : envoyé par A, à lire par la seconde session. »   (event $UkbjTw86a_ZGhZP292taaHAiG8bSdeR-R8q5QLtlg3I)
→ 1 message(s) lu(s) en clair.
```

La chaîne complète est visible : un `m.room.encrypted` **d'appareil à appareil** (algorithme
Olm) arrive, la machine le déchiffre et en tire un `m.room_key` (`clés de salon 1`), et le
message du salon devient lisible.

### La vérification d'appareil est-elle exigée ?

**Non, et c'est un choix explicite du spike**, pas un hasard. La clé part vers *tous* les
appareils du compte parce que `RustCryptoEngine` demande :

```swift
static let reglagesDeSalon = EncryptionSettings(
  algorithm: .megolmV1AesSha2, rotationPeriod: 604_800, rotationPeriodMsgs: 100,
  historyVisibility: .joined,
  onlyAllowTrustedDevices: false,      // ← sans ça : m.room_key.withheld
  errorOnVerifiedUserProblem: false
)
static let reglagesDeLecture = DecryptionSettings(senderDeviceTrustRequirement: .untrusted)
```

Le chemin minimal si l'on remonte ce niveau (ce que MSC4153 recommande) est :
`bootstrapCrossSigning()` sur le premier appareil → la clé maîtresse dans le *secret storage*
protégé par une phrase → chaque nouvel appareil se signe par `verifyDevice(userId:deviceId:)`
après une vérification SAS ou QR (`startSasVerification`, `startQrVerification`, tout est dans
le binding). C'est du travail d'interface, pas de protocole : compté dans l'estimation du § 7.

### La limite honnête : l'historique d'avant l'appareil

`first known index 1, index of the message 0` : la clé partagée à B ne couvre **que** les
messages à partir de son arrivée. Le premier message reste illisible pour lui, pour toujours.
C'est le comportement voulu de Megolm ; le rendre lisible, c'est exactement ce que servent la
**sauvegarde des clés** et le partage d'historique (MSC3061). Sans elles, un iPhone ajouté ne
voit pas le passé — le plan le disait déjà (« un iPhone perdu perd l'historique »), on le
mesure maintenant.

---

## 6. Le pont WhatsApp chiffré, et `help` qui se lit encore

`infra/relais-spike/generer-configs.sh` :

```yaml
encryption:
  allow: true
  default: true
  require: false          # exiger le chiffrement ferait taire le pont pour un client sans machine crypto
  allow_key_sharing: true
  verification_levels:
    receive: unverified
    send: unverified
    share: unverified
```

`CHIFFREMENT_PONTS=0` rend la configuration d'avant, pour comparer. Vérification dans le
`config.yaml` effectif, après fusion :

```
$ python3 -c "import yaml; print(yaml.safe_dump(yaml.safe_load(open('…/mautrix-whatsapp/config.yaml'))['encryption']))"
allow: true
allow_key_sharing: true
default: true
pickle_key: …
require: false
rotation: {messages: 100, milliseconds: 604800000, …}
verification_levels: {receive: unverified, send: unverified, share: unverified}
```

Le salon de gestion existait déjà, en clair (un pont n'en reconnaît qu'un — phase 1) : on y a
posé `m.room.encryption`, puis parlé.

```
$ … preuve-chiffrement chiffrer-salon appareilA '!vuPZxny91il…'
→ !vuPZxny91il… : m.room.encryption = m.megolm.v1.aes-sha2
→ membres : @essai:unclic.local, @whatsappbot:unclic.local

$ … preuve-chiffrement envoyer appareilA '!vuPZxny91il…' "help"
→ salon !vuPZxny91il… — chiffré ? true
→ envoyé : $eC_j_LcbcLm7RCAJTG9srmAVXLgNQa-LtADz19ZF0jE
→ ce que le Relais stocke : type=m.room.encrypted algorithm=m.megolm.v1.aes-sha2

$ … preuve-chiffrement lire appareilA '!vuPZxny91il…'
  ✓ @whatsappbot:unclic.local : « … **set-pl** [_user ID_] <_power level_> - Change the power
    level in a portal room. **sudo** [--create] <_user ID_> <_command_> … **sync**
    <group/groups/contacts> - Sync data from WhatsApp. »
→ 24 message(s) lu(s) en clair.
```

Le pont a bien reçu la clé, lu la commande chiffrée, et répondu. **Au premier essai il ne
l'avait pas** :

```
  ✓ @whatsappbot:unclic.local : « ⚠️ Your message was not bridged: the bridge hasn't received
    the decryption keys. The bridge will retry for 22 seconds »
```

parce que le bot venait de redémarrer et n'avait pas encore publié ses clés d'appareil ; le
second envoi, une fois `keys/query` revenu avec `@whatsappbot:unclic.local → QFPxqfPx5W`, est
passé. **À retenir pour l'app** : après un redémarrage du pont, le premier message chiffré
peut être perdu — il faudra soit attendre que le bot ait publié ses clés, soit réessayer.

**Piège d'exploitation** : `mautrix … -g -r registration.yaml` **retire de nouveaux jetons**
dans `config.yaml`. Relancer `generer-configs.sh` sur une pile déjà enregistrée faisait
répondre le pont `The as_token was not accepted` jusqu'à ré-enregistrement de l'appservice.
Le script ne régénère plus la registration si elle existe.

### Ce que le chiffrement du pont ne protège pas

Rien de nouveau, mais il faut le redire ici : le pont **déchiffre par construction**, sur la
machine du Relais, parce que c'est un appareil lié WhatsApp. `encryption.default: true`
protège la base du homeserver au repos et le trajet app ↔ Relais — pas WhatsApp, pas Meta,
pas la mémoire du pont (`docs/PLAN-relais-un-clic.md` § 4).

### Continuwuity et le reste des routes de clés

```
$ curl -X POST …/room_keys/version -d '{"algorithm":"m.megolm_backup.v1.curve25519-aes-sha2",
                                        "auth_data":{"public_key":"abcdefg"}}'
HTTP 200
{"version":"1879"}
$ curl …/room_keys/version
HTTP 200
{"algorithm":"m.megolm_backup.v1.curve25519-aes-sha2","auth_data":{"public_key":"abcdefg"},
 "count":0,"etag":"1880","version":"1879"}
$ curl -X POST …/keys/device_signing/upload -d '{}'
HTTP 200
{}
$ curl …/user/@essai:unclic.local/account_data/m.secret_storage.default_key
HTTP 404 {"errcode":"M_NOT_FOUND","error":"Data not found."}   ← rien n'y est encore, la route existe
```

(La version d'essai `1879` a été supprimée, `HTTP 200`.)

---

## 7. Ce qui reste pour le chantier E, et combien de jours

### Fait (≈ 1,5 jour, celui de cette phase)

- La dépendance choisie, épinglée, vérifiée par somme, derrière un drapeau qui laisse `cc` et
  la cible Mac de production **identiques au bit près**.
- Envoi des clés d'appareil, `to_device`, réception des clés de salon, déchiffrement en amont
  du pipeline, chiffrement à l'envoi, persistance sous le dossier de l'app.
- Le partage de clés entre deux appareils du même compte, prouvé.
- Les portails et le salon de gestion chiffrés côté pont, `help` qui se lit.

### Reste

| Chantier | Ce que c'est | Jours |
|---|---|---|
| **Sauvegarde des clés avec phrase** | `bootstrapCrossSigning`, *secret storage* 4S, `backupRoomKeys` / `importRoomKeysFromBackup`, l'écran « note ta phrase de récupération » et celui qui la redemande sur un appareil neuf. C'est **le** chantier qui décide si un iPhone ajouté voit le passé. Les routes serveur répondent (§ 6). | **2** |
| **Vérification d'appareil** | SAS (les émojis) et QR entre le Mac et l'iPhone ; remonter `onlyAllowTrustedDevices` et `TrustRequirement` ; la liste « mes appareils » et le bouton « vérifier ». | **1,5** |
| **`cc` et l'extension de notification iOS** | Les deux ouvrent leur **propre** session, donc leur propre machine crypto. Pour `cc` sous Linux : soit on construit `matrix-sdk-crypto-ffi` pour Linux (le crate existe, il faut le publier nous-mêmes), soit on met Pantalaimon devant, soit `cc` reste hors des salons chiffrés. Pour l'extension iOS : le magasin est un SQLite dans le conteneur partagé, **deux processus qui l'ouvrent en même temps** — c'est le vrai risque, et il se règle par un verrou de fichier. | **2** |
| **Les trois états à l'écran** | « chiffré » (natif, Megolm de bout en bout), « chiffré par le pont » (le pont déchiffre, c'est écrit), « en clair ». Plus l'écusson `shieldState` que la machine rend déjà à chaque déchiffrement, et la bulle « clé pas encore reçue » au lieu d'un message qui manque. | **1** |
| **Le passage à l'échelle** | Chiffrer les salons existants sans casser l'historique ; le premier message perdu après un redémarrage du pont ; la rotation des clés sur des fils à fort trafic ; le coût mémoire de la machine sur iPhone. | **1,5** |
| **Le poids** | Décider si +14 Mo de téléchargement passent, et si l'iPhone les prend aussi. | 0,5 |

**Total : 6 à 9 jours**, selon ce qu'on tranche sur `cc` (le point le plus cher, et le seul
qui puisse doubler). La fourchette basse suppose qu'on accepte `cc` hors des salons chiffrés
dans un premier temps — ce qui est cohérent avec `docs/PLAN-relais-agents.md`, qui note
Pantalaimon en repli.

### La décision qui reste, et qui n'est pas technique

Le plan le dit : le plus gros flux de données personnelles hors machine n'est pas le réseau,
c'est **`cc` qui envoie les conversations à un moteur en ligne**. Chiffrer les salons ne
change rien à ça. Si `cc` doit lire des salons chiffrés, il faut lui donner une machine
crypto — c'est-à-dire faire de `cc` un appareil vérifié, et donc décider *explicitement* que
l'agent voit le clair. Ce choix mérite d'être écrit avant d'être codé.

---

## Rejouer les preuves

```bash
cd ~/correspondance-un-clic

# 1. Le drapeau éteint : rien n'a changé.
swift build --package-path Packages/CorrespondanceCore
swift test  --package-path Packages/CorrespondanceCore          # 759 tests

# 2. Le drapeau levé (dossier de construction SÉPARÉ, cf. § 1).
CORRESPONDANCE_CRYPTO=1 swift build --package-path Packages/CorrespondanceCore \
  --scratch-path /tmp/build-unclic-crypto
CORRESPONDANCE_CRYPTO=1 swift test  --package-path Packages/CorrespondanceCore \
  --scratch-path /tmp/build-unclic-crypto                       # 764 tests

# 3. Le Relais du spike.
bash infra/relais-spike/start.sh

# 4. Les preuves A et B, d'un coup (magasins de clés remis à neuf à chaque exécution).
bash infra/relais-spike/preuve-chiffrement.sh

# 5. Le pont chiffré, et help qui se lit.
bash infra/relais-spike/stop.sh
bash infra/relais-spike/generer-configs.sh                      # encryption.allow/default: true
bash infra/relais-spike/start.sh
set -a; . ~/.correspondance-unclic/secrets.env; set +a
export RELAIS_URL=http://127.0.0.1:8010 MATRIX_USER=essai \
       PREUVE_HOME=$HOME/.correspondance-unclic/preuve
B=/tmp/build-unclic-crypto/debug/preuve-chiffrement
G=$(cat ~/.correspondance-unclic/gestion-whatsappbot.txt)
$B chiffrer-salon appareilA "$G"
$B envoyer        appareilA "$G" "help"      # deux fois si le pont vient de redémarrer
$B lire           appareilA "$G"

# 6. Le poids.
xcodebuild -project Correspondance.xcodeproj -scheme Correspondance \
  -configuration Release -derivedDataPath /tmp/dd-unclic-rel build
CORRESPONDANCE_CRYPTO=1 xcodebuild -project Correspondance.xcodeproj -scheme Correspondance \
  -configuration Release -derivedDataPath /tmp/dd-unclic-rel-crypto build
ls -l /tmp/dd-unclic-rel{,-crypto}/Build/Products/Release/Correspondance.app/Contents/MacOS/Correspondance
ls -l /tmp/dd-unclic-rel{,-crypto}/Build/Products/Release/Correspondance.app/Contents/MacOS/correspondance-agent

# 7. L'app, avec les deux verrous. JAMAIS `open --env` : l'environnement en préfixe.
CORRESPONDANCE_CRYPTO=1 xcodebuild -project Correspondance.xcodeproj -scheme Correspondance \
  -configuration Debug -derivedDataPath /tmp/dd-unclic-crypto build
CORRESPONDANCE_HOME=unclic CORRESPONDANCE_CHIFFREMENT=1 \
  /tmp/dd-unclic-crypto/Build/Products/Debug/Correspondance.app/Contents/MacOS/Correspondance &

# 8. Ranger.
bash infra/relais-spike/stop.sh
```

---

## Vérification (2 sept. 2026, vérificateur)

Rejoué : `swift test` sans drapeau (759 tests, 0 échec), avec `CORRESPONDANCE_CRYPTO=1` et
scratch séparé (764, 0 échec), puis `preuve-chiffrement.sh` contre le Relais du spike : le
Relais stocke un `m.room.encrypted` (megolm), la seconde session reçoit la clé par `to_device`
(`m.olm.v1` → `m.room_key`) et lit le message envoyé par la première. Les 15 échecs de
déchiffrement du sync initial sont les messages des essais précédents, antérieurs à l'appareil
— la limite « index 1 / message 0 » du rapport, attendue. Capture `app-note-chiffree.png`
cohérente. Aucun orphelin. Phase acceptée.
