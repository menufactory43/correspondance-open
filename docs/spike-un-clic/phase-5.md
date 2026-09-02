# Phase 5 — Le chantier E complet

Éprouvé le 2 septembre 2026, sur le Mac de développement, contre le Relais Continuwuity que
`infra/relais/install.sh` pose sous `~/.correspondance-unclic/` (port 8010, quatre ponts,
portails chiffrés). La prod n'a pas été touchée : ni `~/.correspondance-agent/`, ni
`~/Library/Application Support/Correspondance/`, ni les conteneurs du NUC.

**Verdict** : *cinq livrables sur six sont faits et prouvés ; le sixième — l'extension de
notification iOS — est écrit et testé hors extension, et attend un App Group qui n'existe pas
encore dans le portail développeur.* La limite qui gouvernait tout le chantier depuis la
phase 2 — « first known index 1 », un appareil neuf ne lit pas le passé — **a disparu**. `cc`
n'est plus sourd. Le drapeau d'exécution est tombé. Reste **1,5 à 2 jours** : la bibliothèque
Rust pour Linux, l'App Group, et les écrans qui manquent (phrase de récupération, liste des
appareils).

| # | Livrable | État |
|---|---|---|
| 1 | `cc` lit et écrit chiffré | ✅ **prouvé** sur macOS · ❌ Linux reste en clair, recette mesurée |
| 2 | Sauvegarde des clés avec phrase | ✅ **prouvé** — 10 clés sur 10, historique d'avant l'appareil relu |
| 3 | Vérification d'appareil | ✅ **prouvé** — signatures croisées posées, appareil neuf vérifié par la phrase |
| 4 | Les trois états affichés | ✅ fiche Mac, feuille iOS, ligne des réglages ; testé |
| 5 | Extension de notification iOS | ⚠️ **code + test** ; bloqué par l'absence d'App Group |
| 6 | Le drapeau d'exécution | ✅ levé ; le drapeau de manifeste reste, et on dit pourquoi |

---

## 1. `cc` lit et écrit chiffré

### Ce qui manquait, et où il fallait le mettre

La phase 4 avait mesuré la panne : dans une note à soi chiffrée, `cc` ne journalise rien, ne
répond rien, et **ne dit pas pourquoi**. En clair il répondait en cinq secondes.

L'agent partage déjà `MatrixClient` avec l'app : tout le déchiffrement du `/sync` et le
chiffrement à l'envoi (phase 2) étaient donc déjà sous ses pieds. Il ne lui manquait que le
moteur. La difficulté est ailleurs : `CorrespondanceAgentKit` **doit rester du Foundation
pur**, parce qu'il compile sous Linux où l'XCFramework d'Apple n'existe pas. On ne peut donc
pas y importer `CorrespondanceMatrixCrypto`.

D'où la forme retenue — le kit déclare l'endroit, l'exécutable fournit la pièce :

```swift
// CorrespondanceAgentKit/AgentChiffrement.swift  — Foundation pur
public typealias AgentBranchementChiffrement =
  @Sendable (MatrixCredentials, MatrixClient) async -> String?

// correspondance-agent/AgentCrypto.swift  — sous #if canImport
static func branchement(home: URL) -> AgentBranchementChiffrement? { … }
```

```swift
// Package.swift
.executableTarget(
    name: "correspondance-agent",
    dependencies: ["CorrespondanceAgentKit", "CorrespondanceMatrixClient"]
        + (chiffrement ? ["CorrespondanceMatrixCrypto"] : [])
)
```

Deux décisions qui ne se voient qu'à l'exécution :

- **Le branchement se fait avant le premier `/sync`.** C'est ce sync-là qui publie les clés
  d'appareil (`keys/upload`). Branché après, l'agent resterait invisible pour les autres
  appareils, et personne ne lui porterait la clé du salon.
- **Le magasin vit sous le dossier d'amorce** (`~/.correspondance-agent-unclic/crypto/…`), donc
  il suit `CORRESPONDANCE_HOME` comme le reste : un essai ne touche jamais aux clés du `cc` de
  production.

### Un agent qui se tait est indiscernable d'un agent occupé

C'est le vrai enseignement de la phase 4 : la surdité n'était pas le pire, le **silence**
l'était. `Agent` compte désormais les `m.room.encrypted` qui traversent le `/sync` sans avoir
été lus, et le dit une fois par salon — pas à chaque tour, sinon le journal se remplirait de la
même phrase toutes les trente secondes.

```
⚠ !r:s : 2 message(s) chiffré(s) que je ne sais pas lire — clé de salon pas encore reçue,
  ou pas de machine crypto dans ce binaire
```

Quatre tests tiennent ça (`AgentChiffrementTests`) : le chemin du magasin, deux appareils =
deux magasins, l'alerte dite une seule fois, et nos propres envois qui ne déclenchent rien.

### La preuve

```
$ bash infra/relais-spike/preuve-cc-chiffre.sh
```

Le script crée le compte `@cc` par la commande d'administration, écrit l'amorce, ouvre une
console **et** une note à soi **toutes deux chiffrées**, lance l'agent, envoie `@cc ping`
chiffré, et regarde ce que le Relais stocke.

```
### 3. cc démarre — avec la machine crypto
11:03:41 binaire : /tmp/build-unclic-crypto/…/correspondance-agent (compilé le 2 sept. 11:01)
11:03:41 chiffrement : compilé
11:03:41 connecté comme @cc:unclic.local
11:03:41 chiffrement branché — appareil 8jBhGLCJ0V, ed25519 fBKiZVCDGebBd6z0n+mNK+8KLBbGtSAzX7VOY1n+RC4
         · magasin /Users/…/.correspondance-agent-unclic/crypto/_cc_unclic_local-8jBhGLCJ0V/
11:03:41 rejoint !A19ouaRQ2GG… sur invitation de @essai:unclic.local
11:03:42 à l'écoute de « @cc » pour @essai:unclic.local — plafond 30/h

### 4. « @cc ping » ENVOYÉ CHIFFRÉ dans la note à soi
  /sync #1 (initial) — chiffrés 5 → lus 5, échecs 0 · to_device 2, clés de salon 2
    to_device brut : type=m.room.encrypted de=@cc:unclic.local algo=m.olm.v1.curve25519-aes-sha2
    to_device lu   : type=m.room_key de @cc:unclic.local     ← cc porte SA clé à l'appareil A
→ membres du salon : @cc:unclic.local, @essai:unclic.local
→ envoyé : $wP7UBIfNtGdqsUrvnHLcua9zw-Ah6wbxt-Tk0V-RCek
→ ce que le Relais stocke : type=m.room.encrypted algorithm=m.megolm.v1.aes-sha2

### 5. ce que cc en fait
11:03:47 [!A19ouaRQ2GG…] @essai:unclic.local → « ping »
11:03:53 [!A19ouaRQ2GG…] ← 18 caractères

### 6. la réponse de cc, relue en clair par l'appareil A
  ✓ @essai:unclic.local : « @cc ping »   (event $wP7UBIfNt…)
  ✓ @cc:unclic.local : « pong 👋 Je suis là. »   (event $6l2cZ_95kkWSsugOuw6Qw_W61daEJPRNCayQg-eAbo8)
→ 5 message(s) lu(s) en clair.

### 7. ce que le Relais stocke de la réponse de cc — vu sans le client
  $6l2cZ_95kkWSsugOuw6Qw_W61daEJPRNCayQg-eAbo8  type=m.room.encrypted  algorithm=m.megolm.v1.aes-sha2
    ciphertext (100 premiers) : AwgCEvABhkzdcpInJOdO9Qra8SkU6xog767MsOiNtuRsaFeYbYuDvCohCSZ1WNI27YolqDn+mHw2TanUSKZND4OO…
    contenu brut : {"algorithm": "m.megolm.v1.aes-sha2", "ciphertext": "AwgCEvAB…"}

### 8. le journal des tours, écrit chiffré dans la console
  ✓ @cc:unclic.local : [fr.correspondance.agent.journal] {"prompt":"ping","duration_ms":5994,
      "room":"!A19ouaRQ2GG…","tools":[],"agent":"cc","sender":"@essai:unclic.local"}
  ce que le Relais stocke dans la console :
    $kh6n3N-T6eVdrQOqhlFGtRDrSkTOzKeuT3esK17oguc  type=m.room.encrypted
    $gnLUTQEI8kOHsxOk1MYqvSAEoaC2G-9DpI27KmNZSE4  type=m.room.encrypted
```

Les quatre choses demandées y sont : la note à soi chiffrée, `@cc ping` → `pong`, le journal
des tours écrit (et lui aussi chiffré, puis relu), et la réponse de `cc` **stockée chiffrée**
sur le Relais, vue par une requête HTTP sans le client. Le moteur est un vrai `claude`
installé sur cette machine ; le tour a duré 5,994 s.

### Linux : `cc` y reste en clair, et voici exactement pourquoi

La question posée était : `matrix-sdk-crypto-ffi` se lie-t-il sous Linux ? **Oui.** Ce n'est
pas une déduction : la CI du dépôt amont construit le crate et engendre ses liaisons Swift sur
`ubuntu-latest` à chaque PR (`.github/workflows/bindings_ci.yml`, job `test-uniffi-codegen`,
qui appelle `xtask/src/ci.rs::check_bindings`).

| Question | Réponse vérifiée au tag `matrix-sdk-crypto-ffi-0.17.0` |
|---|---|
| `crate-type` | `["cdylib", "staticlib"]` → `libmatrix_sdk_crypto_ffi.{so,a}` sous Linux |
| uniffi | 0.31.0, feature `cli` ; un `[[bin]]` fait office de générateur |
| `build.rs` | rien d'Apple : un contournement Android gardé par `cfg`, et `vergen-gitcl` |
| dépendances Apple-only | **aucune** — zéro `target_os` / `objc` / `security-framework` dans les 4 839 lignes de `src/` |
| générateur Swift | pur Rust, il écrit du texte ; c'est `lipo`/`xcodebuild` qui sont Apple, et seulement eux |

Ce qui manque n'est donc **pas** de la cryptographie, c'est de l'empaquetage :

```bash
git checkout matrix-sdk-crypto-ffi-0.17.0
cargo build -p matrix-sdk-crypto-ffi --release        # 10 à 18 min sur 4 cœurs x86_64
cargo run -p uniffi-bindgen --release -- generate --library --language swift \
    --out-dir generated-linux target/release/libmatrix_sdk_crypto_ffi.so
# puis une cible C (headers + module.modulemap écrit à la main) + une cible Swift,
# avec .unsafeFlags(["-L…", "-lmatrix_sdk_crypto_ffi"]) — ou un artifact bundle
# staticLibrary (SE-0482) avec Swift ≥ 6.2.
```

Deux frictions connues, mineures : le `ModuleMapTemplate.modulemap` d'uniffi 0.31 émet
inconditionnellement `use "Darwin"` (à retirer si clang rechigne — le modulemap tient en cinq
lignes), et le code engendré utilise `Data`/`Date`/`NSLock`, tous fournis par
swift-corelibs-foundation. L'artefact publié `MatrixSDKCryptoFFI.zip` est en revanche
**inutilisable** sous Linux : c'est un XCFramework de tranches Apple, et son `Sources/` ne
contient même pas le `.modulemap`. Il faut régénérer, pas réutiliser.

**Ça n'a pas été fait dans cette phase, et c'est délibéré.** Le NUC n'a ni Rust ni toolchain
Swift ; il fait tourner la production (36 conteneurs, `correspondance-cc` et
`correspondance-hermes` vivants), et y lancer une heure de `cargo` à quatre cœurs aurait
affamé des services qui n'ont rien demandé. Le Mac n'a pas Docker. Poser la chaîne complète
(rustup, build, empaquetage SwiftPM, cible Linux du paquet, épinglage et sha256) est un
chantier d'une demi-journée à faire sur une machine de build dédiée — pas sur une machine de
production, à la fin d'une phase.

**Conséquence pratique, à écrire dans l'app** : un `cc` qui tourne sur un Linux (le NUC, un
VPS) ne lit pas les salons chiffrés. Il le dit maintenant — au démarrage
(`chiffrement : absent de ce binaire — je ne lirai pas les salons chiffrés`) et devant chaque
message qu'il ne comprend pas. C'est la différence entre une limite et une panne.

---

## 2. La sauvegarde des clés avec phrase

### Ce qui disparaît

Phase 2, preuve B, la ligne qui bornait tout le chantier :

```
Megolm(error: "The message was encrypted using an unknown message index,
               first known index 1, index of the message 0")
```

Un appareil neuf ne lit pas ce qui précède sa naissance. C'est le comportement voulu de
Megolm ; la sauvegarde des clés est ce qui le corrige.

### Le mécanisme, et le détail qui décide de tout

`BackupRecoveryKey.newFromPassphrase(phrase)` dérive la clé **et tire un sel au hasard**. Ce
sel et le nombre de tours PBKDF (500 000) partent dans `auth_data` de
`POST /room_keys/version`. Sans eux, aucun autre appareil ne pourrait redériver la même clé :
la phrase ne servirait à rien, et la sauvegarde serait un coffre dont on a jeté la serrure.

```
$ bash infra/relais-spike/preuve-sauvegarde.sh

### 2. l'appareil A crée la sauvegarde depuis la phrase
  phrase : « marée dune chêne zeste encre usine »
→ sauvegarde créée, version 1187
→ ce que le Relais annonce : version=1187 public_key=0CbR49AQv7kBdTg8eiidOFqR9NPRpVaE4BBO00K9h2Y
  private_key_salt=DqPqrb2SOrwGvt0Z9Ty6KxynSbm0LsJB iterations=500000

### 3. ce que le Relais héberge, vu sans le client
{
    "algorithm": "m.megolm_backup.v1.curve25519-aes-sha2",
    "auth_data": {
        "private_key_iterations": 500000,
        "private_key_algorithm": "m.pbkdf2",
        "public_key": "0CbR49AQv7kBdTg8eiidOFqR9NPRpVaE4BBO00K9h2Y",
        "private_key_salt": "DqPqrb2SOrwGvt0Z9Ty6KxynSbm0LsJB",
        "signatures": {}
    },
    "count": 10,
    "etag": "1198",
    "version": "1187"
}
  et les clés elles-mêmes :
    !7HZfwtfXXUgq4mexF5xS7Lw37rZZ53Jz9XSs2jiZWQw : 1 session(s)
      9OfGEm5I+YZzBGP5GAfEJyjoCwZkppdLULf589yFBIc first_message_index=0
      session_data (chiffrée par la clé de sauvegarde) :
        {"ephemeral": "mQPnDOA5nGpu4R44SPKNL2SRtSoMH0Q50cU+1900jmI", "ciphertext": "xjZKRYsCmv2d…
```

### Le contrôle négatif, puis la preuve

```
### 4. CONTRÔLE NÉGATIF — un appareil NEUF, magasin vierge : il ne lit rien
→ session neuve : @essai:unclic.local / appareil 83Q10rdtHa
  /sync #1 (initial) — chiffrés 15 → lus 0, échecs 15 · to_device 0, clés de salon 0
    (note : déchiffrer : MissingRoomKey(error: "Can't find the room key to decrypt the event…"))
  ✗ resté chiffré : $Hi0LEkNxtFrTuzWRSHLwIpCfIobbzmabPyBBshvP20M
→ aucun message lisible.

### 5. la phrase, et rien d'autre
→ clés réimportées : 10 sur 10

### 6. le même appareil neuf relit — l'historique d'avant sa naissance
  /sync #4 (initial) — chiffrés 15 → lus 15, échecs 0
  ✓ @essai:unclic.local : « Message écrit avant la naissance de l'appareil neuf. »
     (event $Hi0LEkNxtFrTuzWRSHLwIpCfIobbzmabPyBBshvP20M)
→ 1 message(s) lu(s) en clair.

### 7. une phrase fausse est refusée avant tout téléchargement
✗ decoding("sauvegarde : cette phrase ne correspond pas à celle du Relais")
```

Le même `event_id` : illisible avant, lisible après, sur le même appareil. Et la phrase fausse
est refusée en comparant la clé publique redérivée à celle que le Relais annonce — **avant**
de télécharger : sinon on rendrait « zéro clé importée », ce qui ressemble à une sauvegarde
vide et envoie chercher au mauvais endroit.

### Quatre pièges, chacun muet

**a) `PUT /room_keys/keys` veut la version en paramètre.** La machine la donne dans son enum
`Request.keysBackup(requestId, version, rooms)` ; notre traduction la jetait. Sans elle, le
serveur répond à côté et rien n'est sauvegardé. `MatrixCryptoRequest` porte désormais un
`version`, et une requête `keysBackup` sans version **échoue chez nous**, avec un test.

**b) La carte des salons se poste sous `rooms`.** Exactement le même piège que `to_device` en
phase 2 : la machine rend la carte toute nue.

```
✗ http(status: 400, errcode: "M_BAD_JSON",
       message: "deserialization failed: missing field `rooms` at line 1 column 3683")
```

**c) `importRoomKeysFromBackup` n'importe pas la réponse du serveur.** Sa documentation le dit
en une ligne : *« the decryption step is skipped and should be performed by the caller »*. Ce
qu'il attend est un **tableau de clés déjà déchiffrées**, du format de `exportRoomKeys`. Passer
la réponse telle quelle donne :

```
✗ Json(message: "invalid type: map, expected a sequence at line 1 column 0")
```

— une erreur qui ne dit pas qu'il manque une étape entière. C'est à l'appelant de dérouler
chaque `session_data` avec `BackupRecoveryKey.decryptV1(ephemeralKey:mac:ciphertext:)`, puis de
recoller `room_id` et `session_id`, que la clé sauvegardée ne porte pas (c'est la carte qui les
portait).

**d) Continuwuity ne rend pas la version la plus récente.** Mesuré : quatre versions existaient
sur le compte ; `GET /room_keys/version` en a nommé une **différente à chaque tour**, dans le
désordre (835, 779, 1125, 1068, 1011), alors qu'il refuse d'écrire ailleurs que dans la
dernière créée :

```
✗ http(status: 400, errcode: "M_INVALID_PARAM",
       message: "You may only manipulate the most recently created version of the backup.")
```

Remplacer une sauvegarde exige donc de les retirer **toutes**, pas seulement celle qu'il
nomme. Une seule suppression laisse un compte où la sauvegarde échoue à chaque envoi, sans un
mot. `creerSauvegarde(phrase:remplacerLExistante:)` les draine, et refuse par défaut d'écraser
une sauvegarde existante — la remplacer rend l'ancienne illisible, ça se demande.

---

## 3. La vérification d'appareil

### Les signatures croisées

```
### 8. les signatures croisées, posées par l'appareil A
→ clés de signature croisée posées sur le compte
  maîtresse    : ed25519:9hHUOLabtAg2MgApbFUB69+AVVXjqQWs/GGR3scC3YY
  self-signing : ed25519:vsyagJm6E5wyAIC8T9Ara4sMGro1nfJBNt2wpUgXlm8
  user-signing : ed25519:zo7AUau/ox33tydk7sa5qQqNmIH98xha0vt/36jyIVA
  master_keys de @essai:unclic.local       : ['ed25519:9hHUOLabtAg2MgApbFUB69+AVVXjqQWs/GGR3scC3YY']
  self_signing_keys de @essai:unclic.local : ['ed25519:vsyagJm6E5wyAIC8T9Ara4sMGro1nfJBNt2wpUgXlm8']
  user_signing_keys de @essai:unclic.local : ['ed25519:zo7AUau/ox33tydk7sa5qQqNmIH98xha0vt/36jyIVA']
```

La seconde ligne compte : elle vient d'un `POST /keys/query` fait par `curl`, sans le client.
Les clés sont bien sur le compte, pas seulement dans la machine locale.

**Le piège** : la phase 2 concluait que `POST /keys/device_signing/upload` « répond 200 » —
elle l'avait éprouvé avec un corps vide sur un compte vierge. Dès que le compte porte des clés
de signature, remplacer la maîtresse revient à remplacer l'identité du compte, et le serveur
répond `401` avec un défi d'authentification interactive :

```
✗ http(status: 401, errcode: nil, message: nil)
```

`televerserLesClesDeSignature` rejoue donc la requête avec `m.login.password` et la `session`
du défi — d'où `MatrixClient.dernierCorpsDErreur`, parce que `MatrixError.http` ne porte que
le code et le message, et que tout ce qui compte est dans le corps.

### « Vérifié par la phrase », sans comparer d'émojis

Un appareil neuf devient vérifié en **reprenant les clés privées de signature** dans un coffre
déposé en account data, scellé par une clé dérivée de la même phrase que la sauvegarde (le
même sel, publié dans `auth_data` — une seule phrase à retenir), puis re-dérivée par
`HKDF<SHA256>` avec un `info` qui nomme l'usage : se servir directement de la clé de sauvegarde
pour chiffrer autre chose serait employer un même secret à deux fins.

```
### 10. le coffre : l'appareil A y dépose ses clés de signature, scellées par la phrase
→ clés de signature croisée déposées, chiffrées par la phrase
  ce que le Relais en voit :
    hkdf-sha256+aes-gcm : Lzkv4ZiuJL4dYLXiC1B0YsZ3wdjpOqwOc7oUCIopra4ueSnTbK3UX8DFZ/IQF3cL49KddRHtinJbNy0AdHabPXJaDF…

### 11. l'appareil neuf reprend les clés du coffre avec la phrase
→ chiffrement : actif · cet appareil : vérifié · sauvegarde : faite

### 12. l'écran « mes appareils », vu par l'appareil A
  Zmys4n6hoq  Preuve chiffrement · appareilNeuf  — vérifié      ← celui du § 11
  TsqcZ2Qn7D (moi)  Preuve chiffrement · appareilA  — vérifié
  AIhdfPSZE9  Preuve chiffrement · appareilNeuf  — non vérifié  ← appareils d'essais antérieurs
  2Rr90vp0UM  Preuve chiffrement · appareilNeuf  — non vérifié
  83Q10rdtHa  Preuve chiffrement · appareilNeuf  — non vérifié
```

L'appareil neuf est vu **vérifié par l'autre appareil**, pas seulement par lui-même : c'est ce
qui prouve que la signature a bien été téléversée et relue.

Un détail qui aurait fait mentir l'écran : la signature ne se voit pas tant qu'un `keys/query`
ne l'a pas rapportée. Sans un second tour après `verifyDevice`, un appareil qui vient de se
signer se disait « non vérifié » à lui-même. Et `etatDuChiffrement` retient **deux** façons
d'être vérifié — porter la signature, ou détenir les clés privées qui signent les autres :
ne regarder que la première fait dire « non vérifié » à l'appareil qui signe tout le monde.

### Ce que le coffre n'est pas

**Ce n'est pas le stockage secret de la spécification (4S, `m.secret_storage.v1.aes-hmac-sha2`).**
C'est le nôtre : même endroit (l'account data), même propriété (le Relais ne peut pas
l'ouvrir), mais Element ne saura pas le lire, et nous ne saurons pas lire le sien. Le rendre
interopérable demande AES-256-CTR + HMAC-SHA-256 sur une clé dérivée par PBKDF2-SHA512, les
entrées `m.secret_storage.key.<id>` / `m.secret_storage.default_key`, et les secrets
`m.cross_signing.master` / `self_signing` / `user_signing` : **une demi-journée**, à faire le
jour où quelqu'un veut ouvrir son compte dans Element. C'est écrit à l'endroit du code.

### Le partage de clés reste `.untrusted`, et l'écran le dit

`DecryptionSettings(senderDeviceTrustRequirement: .untrusted)` et
`onlyAllowTrustedDevices: false` : décision de la phase 2, tenue. Remonter ce niveau tant que
la vérification n'est pas offerte partout rendrait l'inbox aveugle sur ses propres messages.
La ligne des réglages ne le tait pas :

```
chiffrement : actif · cet appareil : non vérifié · sauvegarde : faite
  — la vérification n'est pas encore exigée pour lire
```

---

## 4. Les trois états affichés

### Le fait devait d'abord traverser le `/sync`

Ni `MatrixSyncParser`, ni `MatrixRoomModel`, ni `StoredRoom.State`, ni `Conversation` ne
connaissaient `m.room.encryption`. La fiche aurait dit « en clair » sur un salon chiffré — le
mensonge inverse de celui qu'on redoutait. Le champ est maintenant relevé dans `applyState`,
persisté (JSON, donc migration gratuite) et porté jusqu'à `Conversation.encryptionAlgorithm`.
Un salon ne se déchiffre jamais : on ne remet jamais ce champ à `nil`.

### Un portail ne montre jamais le cadenas du bout en bout

C'est **le** cas qui compte, parce que depuis la phase 4 l'installeur pose les quatre ponts
avec `encryption.default: true` : les portails **sont** chiffrés, et un client naïf y mettrait
un cadenas plein. Ce serait faux — le pont est un appareil du salon, il déchiffre pour
traduire, c'est sa fonction.

| Cas | Libellé | Pictogramme |
|---|---|---|
| Salon natif + `m.room.encryption` | « Chiffré » | `lock.fill` |
| Portail de pont + `m.room.encryption` | « **Chiffré par le pont** » | `lock.open.fill` |
| Portail en clair | « En clair » | `arrow.triangle.swap` |
| Salon natif en clair | « En clair » | `lock.open` |

`ConfidentialiteAffichee` (noyau, donc le Mac et l'iPhone disent le même mot) porte le libellé,
le pictogramme et la phrase franche. Pour un portail chiffré :

> Le salon est chiffré jusqu'au pont, et le pont le déchiffre pour traduire vers ce réseau :
> c'est sa fonction. Ce n'est donc pas du bout en bout.

Sept tests, dont une boucle sur les quatre réseaux qui échoue si l'un d'eux obtient
`lock.fill`, et un test qui vérifie que l'algorithme survit au stockage — sinon la fiche
dirait « en clair » jusqu'au prochain event d'état, c'est-à-dire peut-être jamais.

Où c'est affiché : `ConversationInfoCard` (Mac — la pilule de barre d'outils **et** la fenêtre
détachée, une seule vue), `ThreadInfoSheet` (iOS, sous l'en-tête), et une ligne
« Chiffrement » dans `SettingsMatrixPane`.

**Pas de capture d'écran dans ce rapport.** L'écran de la machine était verrouillé pendant la
phase : `screencapture` ne rend qu'une image entièrement noire (5 184 000 pixels, aucun au-dessus
du noir), et une capture d'écran noire ne prouve rien. Les deux cibles compilent
(`BUILD SUCCEEDED`, Mac et iOS), la logique affichée est testée dans le noyau, et le
comportement d'exécution du chiffrement est prouvé par `preuve-chiffrement`, qui emploie **le
même** `MatrixClient` que l'app. C'est ce qui manque à ce rapport, et ça se rejoue en une
minute écran allumé (§ Rejouer, étape 7).

---

## 5. L'extension de notification iOS

### Ce qui est fait

Le push n'apporte que `room_id` et `event_id` (`format: event_id_only`, décision antérieure et
bonne : le Relais n'a rien à comprendre du contenu). L'extension va chercher l'événement — et
ce que le Relais rend peut être un `m.room.encrypted`. Elle affichait alors « Nouveau
message », **c'est-à-dire exactement le même texte qu'un Relais injoignable**.

Trois changements :

1. `MatrixClient.dechiffrerEvenement(_:salon:)` — déchiffre un événement isolé, sans `/sync`
   (l'extension vit trente secondes et n'a pas de modèle). L'enveloppe fait foi : `sender`,
   `event_id` et l'horodatage sont recollés, parce que la machine ne les rend pas et qu'une
   notification sans expéditeur ne sait plus qui a écrit.
2. `PushNotification.resolve` déchiffre, et quand la clé manque affiche
   **« Message chiffré — ouvre Correspondance pour le lire »** au lieu du repli générique. Ce
   n'est pas la même panne, et le dire évite de chercher au mauvais endroit.
3. `NotificationService` branche `MatrixChiffrement` sur le magasin partagé avant de résoudre.

### Le magasin partagé, et le piège qui a failli coûter cher

L'extension est un autre processus, avec son propre bac à sable : le magasin de l'app lui est
invisible. Le seul chemin qui les réunit est le conteneur d'un App Group, d'où
`CorrespondanceHome.sharedDirectory()`.

**Sur macOS hors bac à sable, `containerURL(forSecurityApplicationGroupIdentifier:)` rend un
chemin pour un identifiant de groupe inventé.** Vérifié :

```
XCTAssertEqual failed:
  ("file:///Users/…/Library/Group%20Containers/group.qui.nexiste.pas/Correspondance/")
  is not equal to ("file:///Users/…/Library/Application%20Support/Correspondance/")
```

Ce n'est donc **pas** une preuve d'entitlement. S'y fier aurait déplacé le magasin de clés de
l'app Mac dans `~/Library/Group Containers/…`, laissant les clés existantes sur place,
orphelines — l'historique chiffré perdu, sans un mot. Le partage ne vaut que pour iOS, où
l'extension existe et où le conteneur exige l'entitlement. Un test tient la garde, et dit à
quelle condition on pourrait la relâcher.

### Ce qui reste, et pourquoi

**L'App Group `group.com.correspondance` n'existe pas.** Les trois fichiers `.entitlements` du
dépôt portent depuis longtemps le même commentaire : « le groupe doit être créé dans le portail
développeur… à rétablir une fois le groupe créé ». Aucun
`com.apple.security.application-groups` nulle part (zéro occurrence dans le `pbxproj` et les
entitlements). Sans lui :

- `sharedDirectory()` retombe sur le dossier de l'app — rien ne change, rien ne casse ;
- l'extension ne trouve pas le magasin et affiche « Message chiffré », **ce qui est la
  vérité**, pas un silence ;
- accessoirement, `SharedRelayState.mutedRoomIDs()` rend déjà toujours un ensemble vide, donc
  la seconde garde du muet est inopérante depuis le début — un défaut préexistant que ce
  travail a mis en lumière.

**Et le simulateur ne réveille pas de `UNNotificationServiceExtension`** : il n'y a pas de
push. Le chemin de déchiffrement est donc éprouvé **hors extension**, par sept tests
(`PushDechiffrementTests`) qui couvrent l'événement chiffré rendu en clair avec son enveloppe,
la clé manquante qui rend `nil` plutôt que de deviner, l'événement en clair qui traverse
intact, l'absence de machine crypto, et le repli qui nomme la vraie cause.

**Reste, pour clore ce livrable** : créer le groupe dans le portail (dix minutes), le remettre
dans les trois entitlements, régénérer les profils, et éprouver sur un iPhone réel avec Sygnal
— **une demi-journée**, dont l'essentiel est de l'administration Apple. Plus une vérification
qu'on a anticipée sans pouvoir la mesurer : deux processus ouvrent le même SQLite. Le WAL le
supporte (verrous de fichier), et l'extension ne fait que **lire** des clés, jamais d'envoi —
c'est ce qui rend la cohabitation tenable, mais ça se mesure sur un vrai appareil.

---

## 6. Le drapeau

**`CORRESPONDANCE_CHIFFREMENT=1` n'est plus requis.** Il existait parce que le chantier était
commencé et pas fini : on voulait un binaire capable de chiffrer qui se comporte quand même
comme avant. Le garder maintenant livrerait une app dont le chiffrement est éteint chez tout
le monde. Un binaire construit avec la crypto chiffre.

```swift
public static var demande: Bool {
  disponible && ProcessInfo.processInfo.environment[variable] != "0"
}
```

`=0` reste lu comme **soupape** — revenir au comportement d'avant sans reconstruire — pour
l'app comme pour `cc` (`AgentCrypto.eteintParLEnvironnement`), et l'écran des réglages le dit
quand elle est tirée.

**Le drapeau de manifeste reste**, et pour une raison précise : `matrix-sdk-crypto-ffi` n'est
publié qu'en XCFramework Apple, et `correspondance-agent` se construit aussi pour Linux. Il
tombera le jour où la bibliothèque Linux existe (§ 1).

Documenté dans `docs/MATRIX-SETUP.md` § Chiffrement : le drapeau, la table de ce que le
chiffrement couvre réellement (salons natifs / portails / `cc` macOS / `cc` Linux / extension
iOS), la phrase de récupération, les deux pièges d'exploitation de Continuwuity, et où vit le
magasin.

---

## Mesures

### Le poids

Deux constructions `Release` de la **même** app, un seul commit d'écart n'ayant que le drapeau
comme différence de contenu.

| | sans chiffrement | avec | différence |
|---|---|---|---|
| Bundle `Correspondance.app` | 19 Mo | 95 Mo | **+76 Mo** |
| `MacOS/Correspondance` | 15 603 344 o | 70 470 064 o | **+54 866 720 o (+52,3 Mio)** |
| — le même, `strip -x` | 6 673 456 o | 48 172 400 o | +41 498 944 o (+39,6 Mio) |
| — le même, `gzip -9` (ordre de grandeur du DMG) | 2 691 778 o | 17 880 249 o | **+15 188 471 o (+14,5 Mio)** |
| `MacOS/correspondance-agent` | 2 004 440 o | 27 559 192 o | **+25 554 752 o (+24,4 Mio)** |
| — le même, `strip -x` | 1 155 672 o | 21 079 016 o | +19 923 344 o (+19,0 Mio) |
| — le même, `gzip -9` | 427 146 o | 8 103 663 o | **+7 676 517 o (+7,3 Mio)** |

**C'est la nouvelle de la phase.** En phase 2, `correspondance-agent` était inchangé *au bit
près* — c'était la preuve mécanique que le drapeau tenait. Il ne l'est plus : lui donner la
machine crypto lui coûte 24,4 Mio bruts, 7,3 Mio compressés. Le bundle passe de 19 à 95 Mo
parce que **les deux** binaires embarquent désormais leur propre copie statique de la
bibliothèque Rust — c'est le prix d'un agent qui est un exécutable séparé et non une
bibliothèque partagée. Le téléchargement, lui, monte d'environ 22 Mio compressés au total
(15 + 7), pour une app qui en pesait 2,7.

Si ce chiffre devient gênant, la piste est connue et n'a pas été prise ici : faire de la
machine crypto un `.dylib` embarqué dans le bundle et lié par les deux binaires — une seule
copie, ~15 Mio économisés, au prix d'un `@rpath` et d'une signature de plus.

### Le temps de la première synchronisation

Appareil **neuf** (session et magasin effacés), contre le Relais du spike, dix-sept salons dont
neuf chiffrés :

| Étape | Temps réel |
|---|---|
| Première synchronisation, sans restauration (4 tours de `/sync`, publication des clés d'appareil) | **4,56 s** |
| Restauration depuis la sauvegarde (12 clés : `GET /room_keys/keys`, 12 `decryptV1`, import) | **0,64 s** |
| Synchronisation complète après restauration (4 tours, 15 events déchiffrés) | **6,09 s** |

Le coût de la sauvegarde est donc **de l'ordre de la demi-seconde** pour douze sessions de
salon. Les 4 à 6 secondes sont dominées par deux `/sync` à `timeout=3000` du banc de preuve,
pas par la cryptographie : l'app, elle, fait un seul `/sync` initial. Ce qu'on peut affirmer :
la restauration ne s'apercevra pas au démarrage, et elle ne grandit pas avec l'historique — une
clé par session de salon, pas par message.

---

## Ce qui est fait, ce qui reste

### Fait

- `cc` lit et écrit chiffré sur macOS, avec son propre magasin sous son dossier d'amorce, et
  **dit** quand il ne comprend pas.
- La sauvegarde des clés avec phrase : création, téléversement, restauration sur un appareil
  neuf, refus d'une phrase fausse. La limite « first known index 1 » a disparu.
- Les signatures croisées, l'authentification interactive quand le compte en a déjà, la liste
  des appareils avec leur état, et un appareil neuf vérifié par la phrase.
- Les trois états dans la fiche Mac, la feuille iOS et les réglages ; un portail ne porte jamais
  le cadenas plein.
- Le déchiffrement dans l'extension de notification, et le repli qui nomme la vraie cause.
- Le drapeau d'exécution levé, le drapeau de manifeste expliqué.
- 798 tests sans drapeau, 803 avec ; les deux cibles Xcode compilent.

### Reste — **1,5 à 2 jours**

| Chantier | Ce que c'est | Jours |
|---|---|---|
| **La bibliothèque Rust pour Linux** | `cargo build` + `uniffi-bindgen` + empaquetage SwiftPM, sur une machine de build (pas le NUC), version épinglée et sha256. Sans elle, `cc` sur un VPS reste hors des salons chiffrés — il le dit, mais c'est une perte de fonction. | **0,5** |
| **L'App Group** | Le créer dans le portail, le remettre dans les trois entitlements, régénérer les profils, éprouver sur un iPhone réel avec Sygnal. Répare aussi la garde du muet, inopérante depuis le début. | **0,5** |
| **Les écrans qui manquent** | « Note ta phrase de récupération » (générée, affichée une fois, revisible), « J'ai déjà une phrase » sur un appareil neuf, et la liste « mes appareils » avec un bouton « vérifier ». Le noyau les sert déjà (`etatDuChiffrement`, `appareilsDuCompte`, `creerSauvegarde`, `rejoindreSauvegarde`) ; c'est du SwiftUI. | **0,5 à 1** |
| **4S, si interopérabilité** | Le coffre standard, pour qu'Element ouvre le même compte. À faire le jour où quelqu'un le demande, pas avant. | (0,5) |

### Non éprouvé, et il faut le dire

- **Aucune capture d'écran** : l'écran de la machine était verrouillé (§ 4).
- **`cc` sur Linux avec chiffrement** : la bibliothèque n'est pas construite.
- **L'extension de notification en conditions réelles** : ni App Group, ni push au simulateur.
- **Deux processus sur le même magasin SQLite** : raisonné (WAL, lecture seule côté extension),
  pas mesuré.
- **La rotation des clés sur un fil à fort trafic** et **le coût mémoire de la machine sur
  iPhone** restent des questions ouvertes de la phase 2, non abordées ici.

---

## Rejouer

```bash
cd ~/correspondance-un-clic

# 1. Les tests, dans les deux configurations. Scratch séparés — obligatoire.
swift test --package-path Packages/CorrespondanceCore                       # 798
CORRESPONDANCE_CRYPTO=1 swift test --package-path Packages/CorrespondanceCore \
  --scratch-path /tmp/build-unclic-crypto                                   # 803
#   Piège : un `.build` resté d'une configuration précédente fait planter le
#   binaire de test (signal 6, sans message). `rm -rf Packages/CorrespondanceCore/.build`.

# 2. Les deux cibles Xcode.
xcodebuild -project Correspondance.xcodeproj -scheme Correspondance \
  -configuration Debug -derivedDataPath /tmp/dd-unclic build
xcodebuild -project Correspondance.xcodeproj -scheme "Correspondance iOS" \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/dd-unclic build

# 3. Le Relais du spike.
cd ~/unclic-publication && python3 -m http.server 8020 --bind 127.0.0.1 &
cd ~/correspondance-un-clic
CORRESPONDANCE_RELEASES=http://127.0.0.1:8020 bash infra/relais/install.sh

# 4. Le paquet avec la crypto (l'agent en fait partie).
CORRESPONDANCE_CRYPTO=1 swift build --package-path Packages/CorrespondanceCore \
  --scratch-path /tmp/build-unclic-crypto

# 5. Livrable 1 — cc lit et écrit chiffré.
bash infra/relais-spike/preuve-cc-chiffre.sh

# 6. Livrables 2 et 3 — sauvegarde avec phrase, vérification d'appareil.
bash infra/relais-spike/preuve-sauvegarde.sh

# 7. Livrable 4 — les écrans (à faire écran ALLUMÉ, sinon la capture est noire).
CORRESPONDANCE_CRYPTO=1 xcodebuild -project Correspondance.xcodeproj \
  -scheme Correspondance -configuration Debug -derivedDataPath /tmp/dd-unclic-crypto build
mkdir -p /tmp/p5app && cp -R /tmp/dd-unclic-crypto/Build/Products/Debug/Correspondance.app \
  /tmp/p5app/Correspondance-unclic.app
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.correspondance.app.unclic" \
  /tmp/p5app/Correspondance-unclic.app/Contents/Info.plist
codesign --force --deep -s - /tmp/p5app/Correspondance-unclic.app
bash infra/relais-spike/pair.sh          # le code d'appairage, valable 15 minutes
CORRESPONDANCE_HOME=unclic /tmp/p5app/Correspondance-unclic.app/Contents/MacOS/Correspondance &
#   Réglages › Serveur Matrix, coller le code → la ligne « Chiffrement » s'affiche.
#   Ouvrir une conversation, sa pilule de titre → « Confidentialité ».

# 8. Le poids.
xcodebuild -project Correspondance.xcodeproj -scheme Correspondance \
  -configuration Release -derivedDataPath /tmp/dd-unclic-rel build
CORRESPONDANCE_CRYPTO=1 xcodebuild -project Correspondance.xcodeproj -scheme Correspondance \
  -configuration Release -derivedDataPath /tmp/dd-unclic-rel-crypto build
ls -l /tmp/dd-unclic-rel{,-crypto}/Build/Products/Release/Correspondance.app/Contents/MacOS/

# 9. Tout retirer.
bash infra/relais/uninstall.sh --prefix ~/.correspondance-unclic
pkill -f "http.server 8020"
rm -rf ~/.correspondance-agent-unclic /tmp/p5app /tmp/correspondance-cc.unclic.log
```

---

## Vérification (2 sept. 2026, vérificateur)

Rejoué après `rm -rf .build` : 798 tests sans drapeau, 803 avec, 0 échec. Relais du spike
reposé par l'installeur, puis `preuve-cc-chiffre.sh` : la note à soi et la console sont
chiffrées, `@cc ping` part chiffré, le journal du tour de cc (prompt `ping`, 5,4 s) est relu en
clair par le client et stocké en `m.room.encrypted` sur le Relais, vu par HTTP. Ma relecture
filtrée n'a pas isolé la ligne « pong » que le rapport § 6 montre ; le journal du tour prouve
que cc a lu le message chiffré et répondu. `preuve-sauvegarde.sh` : clés de signature
déposées dans le coffre scellé par la phrase, appareil neuf qui les reprend et devient vérifié ;
le contrôle négatif (même événement illisible sans la phrase, 10 clés sur 10 réimportées avec)
est au § 6–7 du rapport. Tout retiré, aucun orphelin, `~/.correspondance-agent/config.json`
au même sha256. L'app Correspondance qui tourne pendant la vérification est celle de la prod
(DerivedData par défaut), pas touchée. Phase acceptée, avec les trois restes nommés par le
rapport : bibliothèque Rust pour cc-Linux, App Group iOS, écrans de la phrase et des appareils.
