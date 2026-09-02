# Phase 4 — Les réseaux Meta, la couche `#admins` dans le client, et cc sur Continuwuity

Éprouvée le 2 septembre 2026, sur le Mac de développement (arm64, macOS 26.6.2) et sur le NUC
(`ssh nuc`, Debian 12, x86_64, sans Docker pour le spike). Tout vit sous
`~/.correspondance-unclic/` sur le Mac et `~/unclic/` sur le NUC ; l'app se construit dans
`/tmp/dd-unclic` et se lance avec `CORRESPONDANCE_HOME=unclic`. La prod n'a pas bougé : les
conteneurs `correspondance-*` du NUC, ses services `correspondance-cc` et
`correspondance-hermes`, et `~/.correspondance-agent/` sur le Mac sont intacts (contrôle par
somme, § 5).

**Verdict** : *les trois livrables sont faits et prouvés sur les deux machines.* Quatre ponts
au lieu de deux pour **16 s d'installation sur le Mac et 30 s sur le NUC** ; les cinq appels
d'administration marchent sur Synapse comme sur Continuwuity sans que l'appelant change ;
cc a été créé par la commande admin, lancé, il répond `pong`, son journal des tours s'écrit,
et une seconde activation est refusée en nommant la session distante. Trois défauts trouvés
au passage, tous corrigés : le dossier d'amorce qui ne suivait pas l'essai, une session de
vérification laissée ouverte qui bloquait l'activation suivante, et un `Debug` Rust qui existe
en deux formes.

---

## A. `mautrix-meta` dans l'installeur

### Ce que c'est, exactement

Instagram et Messenger sont le **même dépôt** (`mautrix/meta`) et le même tag, mais **deux
binaires** : depuis v26.08 un binaire ne fait plus qu'un réseau. La release en publie donc
huit actifs, et il faut prendre le bon :

```
$ curl -fsSL https://github.com/mautrix/meta/releases/download/v0.2608.0/sha256sums.txt
229586e3e629e928a7f3ec9dbc490c48125b23135c93e0bf04a7d53f2b0b4de9  mautrix-instagram-amd64
d46b1e0a4e26b324b3e4454e4b3033e892c27ec72b53b84d5a43859f39edbcfb  mautrix-instagram-arm
8d130e30b5da0f2eeef21b92327ebee283d84b7d36b3ecc6960f3a331b0f4cad  mautrix-instagram-arm64
3c3eeec90b27406601882917ea7ed40263ebae2cbfcc040452f83bb4bcf75354  mautrix-instagram-darwin-arm64
e861777b51f0e15959e66f0efc0c68b88e1bd1093b09737358b4af7dafd7e6cc  mautrix-meta-amd64
224267cd8cda9a90f275304d275cdda2e8331a5626a005ecb719d0bac73cbaf2  mautrix-meta-arm
5b76822b9ae445fb6fd644a09a12f619e4abc1216a887415d6500e65f61b64fe  mautrix-meta-arm64
1f1c2d7ae185169b779bd3d62fa40533c9ffad85ef1b2e5a19870434f9c4df11  mautrix-meta-darwin-arm64
```

`mautrix-instagram-*` est Instagram ; `mautrix-meta-*`, **sans préfixe**, est Messenger — et
il se présente sous un troisième nom :

```
$ ~/.correspondance-unclic/bin/mautrix-instagram --version
mautrix-instagram v26.08 (built at Sun, 16 Aug 2026 16:17:31 +0300 with go1.26.5)
$ ~/.correspondance-unclic/bin/mautrix-messenger --version
mautrix-facebook v26.08 (built at Sun, 16 Aug 2026 16:17:31 +0300 with go1.26.5)
```

C'est le piège de ce livrable : trois noms pour deux réseaux (`meta`, `instagram`,
`facebook`), et le binaire « nu » n'est pas celui qu'on croit. Prendre `mautrix-meta-*` pour
Instagram poserait deux fois Messenger sous deux noms, et personne ne s'en apercevrait avant
la première connexion. Le test `install-plan.sh` vérifie donc, pour chacune des trois cibles,
que le plan nomme `mautrix-instagram-<arch>` **et** `mautrix-meta-<arch>`.

Les préfixes de commande et les noms de bot sont ceux que l'app reconnaît mot pour mot
(`MatrixBridgeDescriptor`) et ceux des gabarits `infra/matrix/templates/` : `!ig` /
`instagrambot` / `instagram_{{.}}`, `!fb` / `messengerbot` / `messenger_{{.}}`. Les ports
suivent le `docker-compose.yml` de la prod : 29330 et 29331 (`PORT + 21320` et `+ 21321`,
donc déplaçables par `--port` comme les deux autres).

Les quatre ponts passent par la **même** fonction `pont()` de l'installeur : SQLite
(`sqlite3-fk-wal`), `encryption.allow/default: true` et `require: false`, `allow_key_sharing`,
`logging.writers` (sans quoi un pont mautrix n'écrit rien du tout), registration engendrée
une seule fois puis déclarée au Relais par `!admin appservices register` dans `#admins`, et un
service launchd ou systemd démarré **après** l'enregistrement.

### Preuve sur le Mac

```
$ cd ~/unclic-publication && python3 -m http.server 8020 --bind 127.0.0.1 &
$ time CORRESPONDANCE_RELEASES=http://127.0.0.1:8020 bash infra/relais/install.sh
→ mautrix-instagram ← https://github.com/mautrix/meta/releases/download/v0.2608.0/mautrix-instagram-darwin-arm64
→ mautrix-instagram : sha256 3c3eeec90b27406601882917ea7ed40263ebae2cbfcc040452f83bb4bcf75354 ✓
→ mautrix-messenger ← https://github.com/mautrix/meta/releases/download/v0.2608.0/mautrix-meta-darwin-arm64
→ mautrix-messenger : sha256 1f1c2d7ae185169b779bd3d62fa40533c9ffad85ef1b2e5a19870434f9c4df11 ✓
…
→ mautrix-instagram : configuration écrite
→ mautrix-instagram : registration engendrée
→ appservice instagram : Appservice registered with ID: instagram
→ service app.correspondance.mautrix-instagram chargé
→ mautrix-messenger : configuration écrite
→ mautrix-messenger : registration engendrée
→ appservice messenger : Appservice registered with ID: messenger
→ service app.correspondance.mautrix-messenger chargé

✓ le Relais répond, connecté comme @essai:unclic.local (/login puis /account/whoami).
  Ponts : WhatsApp 29318, Signal 29328, Instagram 29330, Messenger 29331 — portails chiffrés.
…
16,147 total
```

`help` dans le salon de gestion de chaque bot (`infra/relais-spike/eprouver-ponts.py`, qui
ouvre le salon, envoie, et lit la réponse — le QR n'est jamais scanné, aucun compte n'est
lié) :

```
$ python3 infra/relais-spike/eprouver-ponts.py http://127.0.0.1:8010 "$T" unclic.local instagrambot help
salon de gestion ouvert : !SZbkwfKIiAFJq7iawWX-w2NjnjtSU0AYkRE7zDR0JB4 (invitation de @instagrambot:unclic.local)
--- envoyé : help
Hello, I'm a Instagram bridge bot.
Use `help` for help or `login` to log in.
This room has been marked as your management room.

  (second envoi, une fois le salon marqué)
This is your management room: prefixing commands with `!ig` is not required.
…
#### Administration
**set-pl** [_user ID_] <_power level_> - Change the power level in a portal room.
**sudo** [--create] <_user ID_> <_command_> [_args..._] - Run a command as a different user.

$ … unclic.local messengerbot help
Hello, I'm a Facebook Messenger bridge bot.
  (second envoi)
This is your management room: prefixing commands with `!fb` is not required.
…
**login** [_flow ID_] - Log into the bridge
```

Note d'exploitation, déjà vue en phase 1 et confirmée ici : **un pont ne reconnaît qu'un seul
salon de gestion**, le premier où on lui parle, et le premier message d'un salon neuf reçoit
la salutation, pas l'aide. Il faut donc deux envois, et `eprouver-ponts.py` mémorise le salon.

### Preuve sur le NUC

```
$ scp infra/relais/install.sh infra/relais/uninstall.sh infra/relais-spike/eprouver-ponts.py nuc:/tmp/
$ ssh nuc 'time bash /tmp/install.sh --prefix $HOME/unclic'
…
✓ le Relais répond, connecté comme @essai:unclic.local (/login puis /account/whoami).
  Ponts : WhatsApp 29318, Signal 29328, Instagram 29330, Messenger 29331 — portails chiffrés.
  Tailscale absent. Cet installeur ne le pose PAS (ça demande sudo : …)
real	0m30,357s

$ ssh nuc 'systemctl --user list-units "correspondance-*" --no-pager --plain'
correspondance-cc.service                loaded active running   ← PROD, pas touché
correspondance-hermes.service            loaded active running   ← PROD, pas touché
correspondance-mautrix-instagram.service loaded active running
correspondance-mautrix-messenger.service loaded active running
correspondance-mautrix-signal.service    loaded active running
correspondance-mautrix-whatsapp.service  loaded active running
correspondance-relais.service            loaded active running

$ ssh nuc 'ss -ltnp | grep -E "8010|2931|2932|2933"'
LISTEN 127.0.0.1:8010   users:(("continuwuity",pid=2406469))
LISTEN 127.0.0.1:29318  users:(("mautrix-whatsap",pid=2406581))
LISTEN 127.0.0.1:29328  users:(("mautrix-signal",pid=2406655))
LISTEN 127.0.0.1:29330  users:(("mautrix-instagr",pid=2406711))
LISTEN 127.0.0.1:29331  users:(("mautrix-messeng",pid=2406771))

$ ssh nuc '… eprouver-ponts.py … instagrambot help'
This is your management room: prefixing commands with `!ig` is not required.
$ ssh nuc '… eprouver-ponts.py … messengerbot help'
This is your management room: prefixing commands with `!fb` is not required.
```

### Dans l'app

Réglages › Comptes montre désormais quatre réseaux pontés. « Connecter… » ouvre la feuille et
va **jusqu'à demander la session** ; rien n'y a été saisi, aucun compte n'a été lié.

![La feuille « Connecter Instagram »](phase-4-instagram.png)
![La feuille « Connecter Messenger »](phase-4-messenger.png)

*Un défaut d'affichage à noter, qui n'appartient pas à ce livrable : la vue web de la feuille
Messenger commence par montrer la bannière de cookies d'Instagram — la `WKWebView` n'est pas
remise à zéro entre deux réseaux. Le titre et la ligne du bas disent bien « Messenger ».*

### Mesures, à quatre ponts

| | Mac (arm64) | NUC (x86_64) |
|---|---|---|
| Temps de la commande, dossier vide | **16,1 s** (2 ponts : 9 s) | **30,4 s** (2 ponts : 23 s) |
| Disque total | 318 Mo, dont 311 de binaires | 299 Mo, dont 254 de binaires |
| Continuwuity, au repos | 24,9 Mo | 83,1 Mo |
| mautrix-whatsapp | 11,8 Mo | 30,8 Mo |
| mautrix-signal | 11,5 Mo | 31,8 Mo |
| **mautrix-instagram** | **13,7 Mo** | **31,3 Mo** |
| **mautrix-messenger** | **12,7 Mo** | **34,8 Mo** |
| **Total mémoire** | **74,6 Mo** | **211,8 Mo** |

Les deux ponts Meta coûtent donc environ **26 Mo sur le Mac, 66 Mo sur le NUC et 80 Mo de
disque** — la pile complète à quatre réseaux reste très loin des 620 Mo de Synapse + Postgres.

### Le test du plan

`infra/relais/tests/install-plan.sh` gagne treize vérifications (les binaires Meta pour les
trois cibles, le fait que Messenger n'est pas Instagram, les ports déplacés par `--port`, les
préfixes de commande, SQLite, le chiffrement des portails, `logging.writers`, et les deux
services dans le désinstalleur) :

```
$ bash infra/relais/tests/install-plan.sh
…
  ✓ prend Instagram en darwin-arm64
  ✓ prend Messenger en darwin-arm64
  ✓ déplace Instagram et Messenger aussi
Les quatre ponts, même traitement
  ✓ Instagram passe par la même fonction pont()
  ✓ Messenger passe par la même fonction pont()
  ✓ le préfixe de commande d'Instagram est celui de l'app
  ✓ le préfixe de commande de Messenger est celui de l'app
  ✓ les ponts sont en SQLite
  ✓ les portails sont chiffrés par défaut
  ✓ les ponts écrivent leur journal
  ✓ le désinstalleur retire aussi Instagram
  ✓ le désinstalleur retire aussi Messenger

Plan d'installation du Relais : tout est conforme.
```

---

## B. La couche « salon d'administration » dans le client

`Packages/CorrespondanceCore/Sources/CorrespondanceMatrixClient/MatrixAdmin.swift` (la couche,
pure) et `MatrixClient+Admin.swift` (le branchement). **Aucun appelant n'a changé** :
`MatrixBridgeService+AgentProvisioning` appelle toujours `isServerAdmin`, `userExists`,
`provisionUser`, `userDevices` ; c'est le client qui sait sur quel Relais il parle.

### La détection : le 404, pas le nom du serveur

Le plan laissait le choix entre lire `/_matrix/client/versions` et se fier au
`M_UNRECOGNIZED` du premier appel. **On a pris le 404**, et voici pourquoi :

1. **La fédération est fermée** sur un Relais personnel (`allow_federation = false`), donc
   `/_matrix/federation/v1/version` — la seule route qui porte franchement `server.name` — ne
   répond pas. `/_matrix/client/versions` ne porte aucun nom de serveur : c'est une liste de
   versions et un sac de `unstable_features`. Il faudrait donc reconnaître un serveur à la
   forme de son sac de drapeaux, ce qui casse à la première mise à jour d'amont.
2. **Un nom se déguise** : un fork, un proxy, un en-tête réécrit.
3. Surtout, **un vrai Synapse peut avoir son API d'administration désactivée**. Le nom dirait
   « Synapse » et l'appel échouerait quand même. Le nom répond à « qui es-tu » ; nous avons
   besoin de « sais-tu faire ça ».

On éprouve donc la capacité elle-même : le premier appel `_synapse/admin` de la session part
pour de vrai ; s'il revient en `M_UNRECOGNIZED` (ou en 404 nu), la session entière bascule sur
`#admins` et l'appel est **refait** par là. Coût : une requête perdue par session, une seule
fois, mémorisée dans l'acteur (`administration: RelaisAdministration?`). Rien ne se devine.

### Les cinq appels

| Appel | Synapse | Continuwuity |
|---|---|---|
| `isServerAdmin` | `GET /_synapse/admin/v1/users/{id}/admin` | résolution de `#admins:<serveur>` puis `GET /joined_rooms` — « administrateur » **est** « membre de `#admins` » |
| `userExists` | `GET /_matrix/client/v3/profile/{id}` | **le même** — API cliente standard, changement sans condition pour les deux serveurs |
| `provisionUser` | `PUT /_synapse/admin/v2/users/{id}` (`logout_devices: false`) | `!admin users create <nom> <mot de passe>`, et si le compte est là, `!admin users reset-password <nom> <mot de passe>` — **sans `--logout`** |
| `userDevices` | `GET /_synapse/admin/v2/users/{id}/devices` | `!admin query users list-devices-metadata <MXID>`, réponse en `Debug` Rust, analysée |
| `makeRoomAdmin` | `POST …/make_room_admin` | **rien** — erreur explicite `MatrixError.administrationIndisponible` |

Les commandes ont été relevées sur le Relais du spike, pas lues dans une documentation :

```
$ !admin users create --help
Usage: !admin users create <USERNAME> [PASSWORD]
  <USERNAME>  Username of the new user
  [PASSWORD]  Password of the new user, if unspecified one is generated

$ !admin users create cc
Created user @cc:unclic.local with password `…`

$ !admin users create cc          (une seconde fois)
Command failed with error:
```
Username is not available.
```

$ !admin users reset-password cc <mot de passe choisi>
Successfully reset the password for user @cc:unclic.local: `<mot de passe choisi>`

$ !admin users reset-password inconnu9 …
Command failed with error:
```
The provided user does not exist.
```
```

`create` accepte le mot de passe en second argument : sans lui le serveur en tire un que nous
ne connaîtrions pas. « Username is not available » n'est donc pas une panne mais l'aiguillage
vers `reset-password`, qui, **sans `--logout`**, laisse vivre les sessions ouvertes — l'exact
équivalent du `logout_devices: false` de Synapse, et ce qui empêche un clic sur ce Mac de tuer
un agent qui tourne ailleurs.

`makeRoomAdmin` n'a aucun équivalent (`!admin users` sait `force-demote`, jamais monter un
pouvoir). L'écran qui s'en sert, `MatrixBridgeService.withRoomPower`, ne plante plus et ne
réessaie pas dans le vide : il dit ce qui manque et par où passer.

```
Pas disponible sur ce Relais : me donner le pouvoir dans ce salon. Le pont y est seul au
pouvoir ; demande-le-lui dans son salon de gestion (« set-pl <mon identifiant> 100 »).
```

### L'attente de la réponse du bot, bornée

`MatrixSalonAdmin` poste la commande, puis **relit l'historique du salon** (`/messages`,
`dir=b`) plutôt que d'ouvrir un second `/sync` : l'app en tient déjà un, et deux boucles sur
le même jeton se marcheraient dessus pour rien. La réponse retenue est **le plus ancien
message du bot arrivé après le nôtre** — prendre le plus récent volerait la réponse d'une
commande suivante ; ne pas s'arrêter à notre propre event relirait l'historique et prendrait
une vieille réponse (le défaut que `salon-admin.py` évitait déjà par un marqueur de `/sync`).
Vingt secondes de délai maximum, puis `Echec.botMuet` : un Relais muet ne fige pas l'écran.

### Le `Debug` Rust existe en deux formes

C'est la surprise de ce livrable. La phase 1 avait relevé la forme **compacte** ; le même
Relais, le 2 septembre, a rendu la forme **repliée** — Rust replie son `Debug` dès que la
ligne s'allonge, et « Correspondance agent · macmini-essai » suffit à la faire déborder :

```
$ !admin query users list-devices-metadata @cc:unclic.local
Query completed in 1.033416ms:

```rs
[
    Device {
        device_id: "rTrhsKJG4B",
        display_name: Some(
            "Correspondance agent · macmini-essai",
        ),
        last_seen_ip: Some(
            "127.0.0.1",
        ),
        last_seen_ts: Some(
            2026-09-02T08:16:50.153,
        ),
    },
]
```
```

Un analyseur écrit sur la seule sortie de la phase 1 aurait rendu une liste vide **en
silence**, et la garde du second cc aurait laissé démarrer un doublon. `MatrixSessionsRust`
aplatit donc le texte avant de le lire, et les deux formes sont dans les tests, mot pour mot.

**Et l'horodatage est en UTC**, mesuré et non supposé : le Relais a écrit
`2026-09-02T08:16:50.153` pour une connexion faite à `10:16:50+02:00`. Le lire en heure locale
vieillirait chaque session de deux heures — au-delà de la fenêtre de quinze minutes — et la
garde ne verrait plus jamais personne.

### Les tests

Le client Matrix n'avait aucun faux réseau : ses tests portent sur des fonctions pures
(`MatrixURLBuildingTests`, `PusherTests`). On garde cet esprit — l'analyse et la décision sont
pures — et on ajoute le strict minimum : un protocole `MatrixAdminTransport` (quatre
méthodes) et un `FauxSalonAdmin` qui rejoue une conversation.

```
$ swift test --filter "MatrixSalonAdmin|MatrixSessionsRust"
Test Case 'testResoudLAliasDuSalonEtNeLeRedemandePas' passed
Test Case 'testAdministrateurCestEtreMembreDuSalonAdmins' passed
Test Case 'testLaReponseEstCelleDeNotreCommandeEtPasDuneAutre' passed
Test Case 'testUnRelaisMuetLeveAuLieuDAttendreIndefiniment' passed
Test Case 'testUnRefusDuBotEstUneErreurEtPasUneReponse' passed
Test Case 'testLesCommandesSontEcritesMotPourMot' passed
Test Case 'testSeulUneRouteInconnueFaitBasculerSurLeSalonAdmin' passed
Test Case 'testMakeRoomAdminDitFranchementQueCeNestPasDisponible' passed
Test Case 'testLaSortieCompacteDeLaPhase1SeLit' passed
Test Case 'testLaSortieRepliéeSeLitPareil' passed
Test Case 'testAucuneSessionRendUneListeVide' passed
Test Case 'testPlusieursSessionsEtUnNomAbsent' passed
Test Case 'testLHorodatageEstLuEnUTC' passed
Test Case 'testLeResultatAlimenteLaGardeDuSecondCC' passed
	 Executed 14 tests, with 0 failures
```

Le dernier est celui qui compte : il prend la sortie réelle, la fait analyser, et donne le
résultat à `AgentSessions.elsewhere` — la garde telle qu'elle existe, fenêtre de quinze
minutes comprise. Vue il y a trois minutes depuis une autre machine → `« umbrel (vu il y a
3 min) »` ; la même session vue de cette machine → `nil` ; au-delà de quinze minutes → `nil`.

La suite complète, avec et sans le drapeau du chiffrement, et la cible Mac :

```
$ swift test --package-path Packages/CorrespondanceCore
	 Executed 773 tests, with 0 failures (0 unexpected) in 3.498 seconds
$ CORRESPONDANCE_CRYPTO=1 swift test --package-path Packages/CorrespondanceCore \
    --scratch-path /tmp/build-unclic-crypto
	 Executed 778 tests, with 0 failures (0 unexpected) in 1.470 seconds
$ xcodebuild -project Correspondance.xcodeproj -scheme Correspondance \
    -configuration Debug -derivedDataPath /tmp/dd-unclic build
** BUILD SUCCEEDED **
$ xcodebuild test … -only-testing:CorrespondanceTests/AgentLocalHostTests
** TEST SUCCEEDED **   (20 cas)
```

---

## C. La preuve cc

### Le correctif : le dossier d'amorce suit `CORRESPONDANCE_HOME`

`docs/MATRIX-SETUP.md` signalait le piège sans le corriger : « Activer sur ce Mac » écrivait
l'amorce dans `~/.correspondance-agent/`, et `CORRESPONDANCE_HOME` ne le déplaçait pas — il ne
déplaçait que les données et le Trousseau de l'app. Le conseil était de **sauter l'étape**.

C'est corrigé, pas contourné. `AgentHome.folderName` (côté agent) et `AgentPaths.folderName`
(côté app — l'app ne peut pas dépendre de l'AgentKit, `Process` n'existe pas sur iOS)
appliquent le même suffixe que le dossier de données : `CORRESPONDANCE_HOME=unclic` →
`~/.correspondance-agent-unclic/`, `~/.correspondance-hermes-unclic/`, et le journal
`/tmp/correspondance-cc.unclic.log`. L'agent est un **processus enfant** de l'app : il hérite
de la variable et recalcule le même chemin sans que personne ne le lui dise. `AgentHome.resolve`
retire le suffixe avant de relire le nom de l'agent dans le dossier, sinon
`.correspondance-agent-unclic` fabriquerait un agent nommé « agent-unclic ». Un test tient les
deux calculs ensemble sur trois environnements et deux agents.

### La preuve

L'app construite depuis ce worktree, copiée sous un **identifiant de bundle à part**
(`com.correspondance.app.unclic`) : c'est la seule façon d'automatiser une fenêtre quand une
autre instance de Correspondance tourne déjà sur la machine — macOS active par identifiant de
bundle, et `set frontmost` donnait systématiquement la fenêtre de l'autre.

```
$ CORRESPONDANCE_HOME=unclic /tmp/p4/Correspondance-unclic.app/Contents/MacOS/Correspondance
```

Code d'appairage collé, « Matrix live · aucun fil bridgé », « Synchronisé avec le Relais ».
Puis Réglages › Agent. Avant toute action, l'écran dit **« l'amorce de cc n'est pas sur le
disque »** — alors que `~/.correspondance-agent/config.json` existe bel et bien sur cette
machine, pour le cc de production. C'est déjà le correctif qui parle.

« Activer cc » ouvre la console ; « Réparer » crée le compte, pose l'amorce et lance le
processus. Le compte a été créé **par la commande admin** — il n'existait pas avant :

```
$ curl -s http://127.0.0.1:8010/_matrix/client/v3/profile/@cc:unclic.local   (avant)
{"errcode":"M_NOT_FOUND","error":"This user's profile could not be fetched."}

$ ls -la ~/.correspondance-agent-unclic/                                      (après)
-rw-------  146  config.json
-rw-------  238  state.json

$ cat /tmp/correspondance-cc.unclic.log
10:37:03 binaire : /tmp/p4/Correspondance-unclic.app/Contents/MacOS/correspondance-agent
10:37:03 connecté comme @cc:unclic.local
10:37:03 console trouvée : !N20Gy0u_Yt0FGixG2JEY0oP1IWqra1afM5rxTB2V52Y
10:37:03 à l'écoute de « @cc » pour @essai:unclic.local — plafond 30/h
10:37:04 moteurs : cc tourne sur macbook-pro-de-meffysto depuis 10 h 37 · moteur claude
         · prêts : claude, claude-code-acp
```

![cc actif sur ce Mac](phase-4-cc-actif.png)

Le moteur ne manque pas : `claude` 2.1.258 est installé et connecté sur cette machine, donc
le tour est un vrai tour, pas une simulation.

```
10:40:57 [!OE-lGe…] @essai:unclic.local → « ping »
10:41:02 [!OE-lGe…] ← 4 caractères
```

![`@cc ping` dans la note à soi, et `pong`](phase-4-note-a-soi.png)

Et le journal des tours s'écrit :

![Derniers tours : ping, 6 s, 10:41](phase-4-tours.png)

### La garde du second cc

Une session de `@cc` ouverte depuis « ailleurs » (`initial_device_display_name:
"Correspondance agent · umbrel"`), l'amorce retirée pour retomber sur « Réparer », et la garde
refuse **en nommant la session** — la lecture passe par `#admins` et par l'analyseur de
`Debug` Rust :

![La garde refuse la seconde activation](phase-4-garde.png)

> cc tourne déjà sur **umbrel** (vu il y a 9 s). Deux agents sur le même compte répondraient
> deux fois — arrête celui-là d'abord. Si c'est déjà fait, le Relais met jusqu'à un quart
> d'heure à le voir disparaître.

### Un défaut trouvé là, et corrigé

Au premier essai, la garde a refusé en nommant `« Correspondance (Mac) »` — une machine qui
n'existe pas. `MatrixBridgeService.credentialsWork` ouvre une session jetable sur le compte de
l'agent pour vérifier que les identifiants marchent (« la seule preuve qui vaille »), et **ne
la refermait pas**. À l'activation suivante, la garde voyait cette session, vivante et pas de
cette machine, et l'app se bloquait elle-même en accusant un fantôme. Un `await essai.logout()`
suffit ; après correction, le compte ne porte plus qu'une session :

```
$ !admin query users list-devices-metadata @cc:unclic.local
[ Device { device_id: "nnaDjdE3rI",
           display_name: Some("Correspondance agent · macbook-pro-de-meffysto"), … } ]
```

### La note à soi chiffrée : cc ne la lit pas — mesuré

Donnée pour la phase 5. La note à soi a été rendue chiffrée par le banc de preuve de la
phase 2 (drapeau levé), puis un `@cc ping` y a été envoyé **chiffré** :

```
$ CORRESPONDANCE_CRYPTO=1 swift build … --product preuve-chiffrement
$ preuve-chiffrement chiffrer-salon appareilA '!OE-lGe…'
→ !OE-lGe… : m.room.encryption = m.megolm.v1.aes-sha2
→ membres : @cc:unclic.local, @essai:unclic.local

$ preuve-chiffrement envoyer appareilA '!OE-lGe…' "@cc ping chiffré"     # 10:44:56
→ salon !OE-lGe… — chiffré ? true
→ envoyé : $tUqb_TB_M38ej54NatVBoeEgmpV-yz1u65TeYZD7Ix4
→ ce que le Relais stocke : type=m.room.encrypted algorithm=m.megolm.v1.aes-sha2
  ciphertext (100 premiers) : AwgAEpABh+JWr1EurTgDs0tOB1Bj01nlYlIjahFHP117vBSJ2a/EHuej…

$ tail -3 /tmp/correspondance-cc.unclic.log     # à 10:45:56, puis à 10:47
10:43:30 à l'écoute de « @cc » pour @essai:unclic.local — plafond 30/h
10:43:31 moteurs : cc tourne sur macbook-pro-de-meffysto depuis 10 h 43 · moteur claude …
                                                    ← rien après. Aucun tour.
```

**La mesure** : en clair, cc journalise le message reçu en **moins d'une seconde** (10:40:57 →
10:41:02 pour la réponse). Chiffré, **rien**, ni à une minute ni à deux : pas de tour, pas de
réponse, pas même une trace d'erreur. `correspondance-agent` n'embarque pas la machine crypto
(elle est derrière le drapeau de manifeste, et la phase 2 notait déjà « `correspondance-agent`
inchangé »), donc il ne voit qu'un `m.room.encrypted` qu'il ignore — silencieusement.

**Ce que ça veut dire pour la phase 5** : le jour où les portails passent en
`encryption.default: true` — ce que l'installeur fait *déjà* pour les quatre ponts — **cc
devient sourd**, sans une ligne d'alerte. Ce n'est pas une option du chantier E, c'est un
préalable : soit `correspondance-agent` gagne la même machine crypto que l'app (il partage
déjà `MatrixClient`, le drapeau suffirait, au prix du poids du binaire), soit la note à soi et
la console restent en clair et il faut le dire à l'écran. Et il faudra un **message** quand
un salon est illisible : un agent qui se tait est aujourd'hui indiscernable d'un agent occupé.

---

## 5. La prod n'a pas bougé

```
$ shasum -a 256 ~/.correspondance-agent/config.json    (avant, puis après)
2540d388b59cfc01263a44514b76041c0d6a6f41968ac6f92dd16915803ffc0b   ← identique
$ ssh nuc 'systemctl --user list-units "correspondance-*"'
correspondance-cc.service      loaded active running     ← toujours vivant
correspondance-hermes.service  loaded active running     ← toujours vivant
```

Le Mac fait tourner une autre instance de Correspondance (celle du dépôt principal) : elle n'a
été ni arrêtée ni touchée. L'instance du spike a un identifiant de bundle à part, ses données
sous `Correspondance-unclic`, son Trousseau suffixé, et désormais son dossier d'agent.

---

## 6. Ce qui reste

1. **`UserDefaults` ne suit pas l'essai.** Le drapeau « cc est voulu sur ce Mac »
   (`AgentLocalHost.wantedKey`) vit dans `UserDefaults.standard`, dont le domaine est
   l'identifiant de bundle — partagé entre l'app de production et un essai lancé depuis le même
   bundle. Ici le problème ne s'est pas posé (l'app du spike a son propre identifiant), mais un
   `CORRESPONDANCE_HOME=…` sur l'app normale partage encore ce drapeau. À suffixer comme le
   reste.
2. **La vue web de la feuille de connexion n'est pas remise à zéro entre deux réseaux** :
   ouvrir Messenger après Instagram montre d'abord la bannière d'Instagram.
3. **Aucun compte Meta n'a été lié**, et ce n'est pas prévu : la règle du spike l'interdit. La
   feuille s'ouvre et demande la session, c'est toute la preuve possible sans risquer de
   débrancher le vrai pont du NUC.
4. **La branche « Tailscale présent »** de l'installeur Linux reste non éprouvée (le NUC ne
   l'a pas), comme en phase 3.
5. **`makeRoomAdmin` est une perte de fonction franche** sur Continuwuity. Le contournement
   (`set-pl` demandé au bot du pont) est écrit dans le message d'erreur, pas encore dans le
   code : personne ne l'automatise.
6. **La détection coûte une requête perdue par session.** C'est le prix assumé de ne rien
   deviner ; si un jour ça gêne, elle se mémorise déjà par session et pourrait se persister.

---

## Rejouer

```bash
# A — l'installeur
bash infra/relais/tests/install-plan.sh
cd ~/unclic-publication && python3 -m http.server 8020 --bind 127.0.0.1 &
CORRESPONDANCE_RELEASES=http://127.0.0.1:8020 bash infra/relais/install.sh
T=$(python3 -c 'import json;print(json.load(open("'$HOME'/.correspondance-unclic/proprietaire.json"))["access_token"])')
python3 infra/relais-spike/eprouver-ponts.py http://127.0.0.1:8010 "$T" unclic.local instagrambot help
python3 infra/relais-spike/eprouver-ponts.py http://127.0.0.1:8010 "$T" unclic.local messengerbot help
scp infra/relais/install.sh infra/relais/uninstall.sh infra/relais-spike/eprouver-ponts.py nuc:/tmp/
ssh nuc 'bash /tmp/install.sh --prefix $HOME/unclic'

# B — la couche #admins
swift test --package-path Packages/CorrespondanceCore --filter "MatrixSalonAdmin|MatrixSessionsRust"
swift test --package-path Packages/CorrespondanceCore
CORRESPONDANCE_CRYPTO=1 swift test --package-path Packages/CorrespondanceCore \
  --scratch-path /tmp/build-unclic-crypto
xcodebuild -project Correspondance.xcodeproj -scheme Correspondance \
  -configuration Debug -derivedDataPath /tmp/dd-unclic build

# C — cc
xcodebuild test -project Correspondance.xcodeproj -scheme Correspondance \
  -derivedDataPath /tmp/dd-unclic -only-testing:CorrespondanceTests/AgentLocalHostTests
CORRESPONDANCE_HOME=unclic /tmp/dd-unclic/Build/Products/Debug/Correspondance.app/Contents/MacOS/Correspondance
#   (une seule instance de Correspondance à la fois, sinon copier le bundle et changer
#    son CFBundleIdentifier — sans quoi l'automatisation pilote l'autre fenêtre)
#   Réglages › Serveur Matrix, coller le code ; Réglages › Agent, « Activer cc » puis « Réparer »

# tout retirer
bash infra/relais/uninstall.sh --prefix ~/.correspondance-unclic
ssh nuc 'bash /tmp/uninstall.sh --prefix $HOME/unclic'
rm -rf ~/.correspondance-agent-unclic /tmp/p4 /tmp/correspondance-cc.unclic.log
```

---

## Vérification (2 sept. 2026, vérificateur)

Rejoué : `swift test` (773 sans drapeau, 778 avec, 14 tests de la couche `#admins` sur les
sorties réelles), `install-plan.sh` conforme ; l'installeur à quatre ponts depuis un préfixe
vide sur le Mac (13 s, six sha256 vérifiés, `@instagrambot` et `@messengerbot` répondent
« Hello, I'm a … bridge bot », 179 Mo de RSS au démarrage pour cinq processus) et sur le NUC
(31 s, « connecté comme @essai », ~330 Mo au démarrage — même écart démarrage/repos que les
phases précédentes ; les deux bots Meta y ont répondu lors de la phase, ma relecture par
filtre n'a pas capté leur ligne et je m'en remets au rapport § 2 pour ce point). Retrait
complet des deux côtés, `correspondance-cc` et `-hermes` toujours actifs, 36 conteneurs
inchangés, aucun orphelin. Capture `phase-4-cc-actif.png` : cc actif sur le Relais du spike
avec le moteur claude. Phase acceptée. À retenir pour la phase 5 : les portails sont posés
chiffrés et cc n'a pas de machine crypto — il est sourd, sans un mot, dans une note à soi
chiffrée.
