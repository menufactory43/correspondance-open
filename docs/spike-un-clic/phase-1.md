# Phase 1 — Continuwuity × mautrix sur ce Mac, sans conteneur

Éprouvé le 2 septembre 2026, sur le Mac de développement (arm64, macOS 26.6.2, sans Docker,
sans Go). Tout vit sous `~/.correspondance-unclic/` ; le Relais écoute sur `127.0.0.1:8010`,
les ponts sur 29318 et 29328. Les scripts qui reproduisent sont dans `infra/relais-spike/`.

**Verdict** : *viable avec quatre changements dans l'app* — Continuwuity fait tourner l'app
telle quelle (connexion, `/sync`, Note à soi, ponts mautrix, QR) pour **46 Mo de mémoire au
lieu de 560 Mo** et **0,63 s de démarrage**, mais il n'implémente **aucun** des quatre appels
`_synapse/admin`, qu'il faut remplacer par des commandes dans le salon `#admins`.

---

## 1. Ce qui a été posé, et à quel prix

### Versions épinglées et sommes de contrôle

| Composant | Version | sha256 | Taille |
|---|---|---|---|
| Continuwuity | `v26.8.1`, commit `ab3c05dac6372ddda3d3279c59b998838094a8bc` | `a7b4dd2099dd349631b24c3f3970cb440fb9365a3aa406830995d389fae16f77` | 80 749 216 o |
| mautrix-whatsapp | `v0.2608.0` (le binaire se dit `v26.08`) | `938242a121df389706dc00e6cbdd9b6fedd267963e3eaddd2ee701c6ddeb4808` | 45 720 128 o |
| mautrix-signal | `v0.2608.0` (le binaire se dit `v26.08`) | `9d48db00fb3e7e7382d7b165a90e4952a6902d18ecf304436c29fc8cc216e586` | 86 749 648 o |
| libolm | `3.2.16`, commit `7e0c8277032e40308987257b711b38af8d77cc69` | `d946defe44adc62d706b3acde6a6904532f32abe4ef7e0096ec08d273ee07168` | 190 192 o |

Les sommes des deux ponts sont celles des `sha256sums.txt` publiés en amont ; le script
`telecharger.sh` refuse d'installer si elles diffèrent. Celles de Continuwuity et de libolm
sont celles des binaires **construits ici** — un binaire construit localement n'a pas de somme
de référence, seul le commit source en tient lieu.

### Trois surprises, toutes coûteuses

**a) Continuwuity ne publie aucun binaire macOS.** L'API des releases ne connaît que Linux :

```
$ curl -s "https://forgejo.ellis.link/api/v1/repos/continuwuation/continuwuity/releases?limit=1" | …
== v26.8.1 v26.8.1 2026-08-22T23:57:24Z prerelease False
    conduwuit-haswell-linux-amd64-maxperf   75113864
    conduwuit-linux-amd64                   97870544
    conduwuit-linux-arm64                   86160440
    conduwuit-linux-static-arm64-maxperf    68197840
    …  (huit actifs, tous Linux)
```

Sur macOS il faut donc **construire**, et les fonctionnalités par défaut supposent Linux
(`io_uring`, `systemd`, `journald`, et `jemalloc` que l'amont lui-même désactive sur Darwin).
La ligne qui marche :

```
cargo build --release --no-default-features \
  --features brotli_compression,element_hacks,gzip_compression,media_thumbnail,ring,\
url_preview,zstd_compression,bindgen-runtime,console
```

Environ 20 minutes à froid, 2,6 Go de sources et d'objets intermédiaires sous
`~/.correspondance-unclic/src/` — qu'on peut effacer après. Le `rust-toolchain.toml` épingle
Rust 1.97.1, que `rustup` installe seul. **Conséquence pour la phase 3** : la carte « sur ce
Mac » ne peut pas télécharger Continuwuity ; il faudrait qu'on construise et publie nous-mêmes
un binaire macOS arm64 dans `correspondance-releases`.

**b) Les ponts mautrix, eux, publient bien du `darwin-arm64`.** C'est la bonne nouvelle : pas
de Go à installer, pas de cgo, pas de libsignal à construire (le point que le plan redoutait le
plus).

```
$ gh api repos/mautrix/signal/releases --jq '.[0] | .tag_name + " | " + ([.assets[].name] | join(", "))'
v0.2608.0 | mautrix-signal-amd64, mautrix-signal-arm64, mautrix-signal-darwin-arm64, sha256sums.txt
$ ~/.correspondance-unclic/bin/mautrix-signal --version
mautrix-signal v26.08 (built at Sun, 16 Aug 2026 16:17:46 +0300 with go1.26.5)
```

C'est **la même version que les images du NUC**. Le tag `v26.08` de `docker-compose.yml`
n'existe plus comme tag Git : le schéma est passé en `vN.YYMM.PATCH` en octobre 2025, et
`v0.2608.0` est la livraison d'août 2026.

**c) Ces binaires ne sont pas autonomes : ils chargent `@rpath/libolm.3.dylib`.**

```
$ ~/.correspondance-unclic/bin/mautrix-whatsapp --version
dyld[8108]: Library not loaded: @rpath/libolm.3.dylib
  Reason: tried: '…/bin/libolm.3.dylib' (no such file),
          '/opt/homebrew/opt/libolm/lib/libolm.3.dylib' (no such file), …
$ brew info libolm
Error: No available formula with the name "libolm".
```

libolm est abandonné en amont et retiré de Homebrew. On la construit donc au tag `3.2.16` —
avec **une correction d'un caractère**, parce que la 3.2.16 ne compile pas avec Apple clang 21 :

```
include/olm/list.hh:106:13: error: cannot assign to variable 'other_pos'
                            with const-qualified type 'T *const'
```

(un `operator=` qui incrémente un `T * const` ; du code que les autres compilateurs laissaient
passer). Le `.dylib` se pose **à côté** des binaires — le rpath sonde le dossier de
l'exécutable en premier — donc rien n'est installé sur le système et Homebrew ne fait pas
partie de la pile livrée. `cmake` (fourni par Homebrew) sert à construire, comme `cargo`.
La voie propre pour le produit serait de reconstruire les ponts avec `-tags goolm` (olm
réimplémenté en Go, sans cgo) ; ce n'est pas fait ici et c'est une dette notée.

### Les scripts

```
infra/relais-spike/
  config.sh                    versions, ports, chemins ; sourcé par tous les autres
  telecharger.sh               télécharge (sha256 vérifié) ou construit, selon l'hôte
  generer-configs.sh           secrets, continuwuity.toml, configs et registrations des ponts
  start.sh / stop.sh           lancement et arrêt par PID — jamais un pkill par nom
  compte.sh                    enregistre le compte propriétaire
  enregistrer.py               l'appel /register en deux temps (UIA)
  enregistrer-appservices.sh   déclare les ponts par le salon #admins
  salon-admin.py               envoie une commande dans #admins et rend la réponse du bot
  eprouver-ponts.py            salon de gestion d'un pont : help, login qr (jamais scanné)
  matrice-admin.sh             éprouve les cinq appels d'administration, un par un
  pair.sh / appairage.py       le code d'appairage, au format de infra/matrix/pair.sh
  mesurer.sh                   mémoire, démarrage à froid, disque, taille des binaires
```

---

## 2. Le Relais répond, le compte existe, les ponts sont branchés

```
$ bash infra/relais-spike/start.sh relais
→ relais : pid 13496 — journal ~/.correspondance-unclic/logs/relais.log
→ attente du Relais sur http://127.0.0.1:8010
→ ✓ le Relais répond ({"name":"continuwuity","version":"26.8.1 (ab3c05d)"})

$ curl -s http://127.0.0.1:8010/_matrix/client/versions
{"versions":["r0.0.1",…,"v1.15","v1.16","v1.17","v1.18"],"unstable_features":{…}}
```

### Le compte propriétaire — un piège qui coûterait une heure à qui ne le sait pas

Le `registration_token` du fichier de configuration **ne marche pas sur une base neuve** :

```
$ curl -s -X POST …/register -d '{… "auth":{"type":"m.login.registration_token",
                                            "token":"<celui du .toml>", …}}'
{"flows":[{"stages":["m.login.registration_token"]}],"errcode":"M_FORBIDDEN",
 "error":"Invalid registration token"}

$ grep -a "registration token" ~/.correspondance-unclic/logs/relais.log
Open your Matrix client of choice and register an account on unclic.local using the
registration token <16 caractères> . Pick your own username and password!
The registration token you set in your configuration will not function until you
create an account using the token above.
```

Continuwuity tire un jeton d'amorçage à usage unique et ne le dit **que dans son journal**.
`compte.sh` le relit là où il est écrit :

```
$ bash infra/relais-spike/compte.sh
→ jeton d'amorçage relevé dans le journal du Relais
→ enregistrement de @essai:unclic.local (jeton d'enregistrement)
→ ✓ @essai:unclic.local enregistré — session dans /Users/…/proprietaire.json
```

Le premier compte enregistré devient administrateur du serveur et rejoint `#admins` de
lui-même : c'est ce qui remplace `register_new_matrix_user -a`.

Deux autres réglages ont fait échouer le démarrage avant d'être retirés, et méritent d'être
notés parce que rien ne les documente :

- `allow_check_for_updates` est un **alias** de `allow_announcements_check` — les deux
  ensemble donnent `There was a problem with your configuration file: duplicate field`.
- `default_room_version = "10"` empêche le serveur de démarrer sur une base neuve :
  `m.room.create event incorrectly omits 'creator' field` → `Critical error starting server:
  Forbidden: Event is not authorized.` Il crée son salon d'administration au format v11+.

### Les appservices — un message, pas un fichier

```
$ bash infra/relais-spike/enregistrer-appservices.sh
→ enregistrement de l'appservice whatsapp
{"auteur": "@conduit:unclic.local", "reponse": "Appservice registered with ID: whatsapp"}
→ enregistrement de l'appservice signal
{"auteur": "@conduit:unclic.local", "reponse": "Appservice registered with ID: signal"}
→ vérification
{"auteur": "@conduit:unclic.local", "reponse": "Appservices (2): signal, whatsapp"}
```

Aucun redémarrage : Continuwuity prend la registration en compte à chaud, là où Synapse ne
relit ses `app_service_config_files` qu'au boot (tout le paragraphe `NEED_SYNAPSE_RESTART` de
`bootstrap.sh` devient inutile).

### Les ponts répondent, et rendent leur QR

```
$ python3 infra/relais-spike/eprouver-ponts.py … whatsappbot "help"
salon de gestion ouvert : !vuPZxny91ilD999pNZRFXxPWRA1Zgq8ggdorX_qfN6A
--- envoyé : help
Hello, I'm a WhatsApp bridge bot.
Use `help` for help or `login` to log in.
This room has been marked as your management room.

$ python3 infra/relais-spike/eprouver-ponts.py … whatsappbot "login qr"
--- envoyé : login qr
Scan the QR code with the WhatsApp mobile app to log in
[m.image] https://wa.me/settings/linked_devices#2@O3RHHFoGIA624ZMWygiZVqGyNc7DTnzPKpD8…
          — url mxc://unclic.local/S4eOZz5GLRtOwWWIiiU8eCTnMWHj3nt4 (NON SCANNÉ, volontairement)

$ python3 infra/relais-spike/eprouver-ponts.py … signalbot "login"
--- envoyé : login
Scan the QR code on your Signal app to log in
[m.image] sgnl://linkdevice?pub_key=BX27eMiqGbSB3nOiTpISXM0eZXf57Cp61SK1ioMlfZUe&uuid=…
          — url mxc://unclic.local/RyTpBeVSfjtJwDcelmOQZiaMdkptQ9TR (NON SCANNÉ, volontairement)
```

Les deux QR ont été **affichés et annulés** (`!wa cancel`) — aucun compte WhatsApp ou Signal
n'a été lié, le pont du NUC est intact. L'image est passée par le dépôt média de Continuwuity
(`mxc://unclic.local/…`), ce qui prouve au passage que l'upload de média marche.

`mautrix-signal` s'est lancé sans rien construire : le binaire `darwin-arm64` amont embarque
déjà `libsignal_ffi`. Le coût que le plan redoutait (libsignal en cgo) est **nul** ici.

Un piège de comportement, à retenir pour l'app : **un pont ne reconnaît qu'un seul salon de
gestion**, le premier où on lui parle. En ouvrir un second fait répondre « use `!wa help` »
sans jamais exécuter la commande. `eprouver-ponts.py` mémorise donc le salon.

---

## 3. La matrice de compatibilité — testée, pas lue

Sortie intégrale de `bash infra/relais-spike/matrice-admin.sh` :

```
Relais : http://127.0.0.1:8010 — {"name":"continuwuity","version":"26.8.1 (ab3c05d)"}
Propriétaire : @essai:unclic.local

### 1. suis-je administrateur ? (MatrixClient.isServerAdmin)
$ curl -s -X GET "$RELAIS/_synapse/admin/v1/users/@essai:unclic.local/admin"
HTTP 404
{"errcode":"M_UNRECOGNIZED","error":"not found :("}

### 2. ce compte existe-t-il ? (MatrixClient.userExists)
$ curl -s -X GET "$RELAIS/_synapse/admin/v2/users/@cc:unclic.local"
HTTP 404
{"errcode":"M_UNRECOGNIZED","error":"not found :("}

### 3. créer le compte d'un agent (MatrixClient.provisionUser)
$ curl -s -X PUT "$RELAIS/_synapse/admin/v2/users/@cc:unclic.local" -d '{"password":…}'
HTTP 404
{"errcode":"M_UNRECOGNIZED","error":"not found :("}

### équivalent Continuwuity : !admin users create-user cc
{"auteur": "@conduit:unclic.local", "reponse": "|  INFO | command | Created new user account
 for @cc:unclic.local |\n\nCreated user @cc:unclic.local with password `<mot de passe tiré par le serveur>`"}

### 4. les sessions d'un compte (MatrixClient.userDevices — la garde du second cc)
$ curl -s -X GET "$RELAIS/_synapse/admin/v2/users/@cc:unclic.local/devices"
HTTP 404
{"errcode":"M_UNRECOGNIZED","error":"not found :("}

### équivalent Continuwuity : !admin query users list-devices-metadata @cc:unclic.local
{"auteur": "@conduit:unclic.local", "reponse": "Query completed in 294.375µs:\n\n```rs\n[]\n```"}

### 5. me donner le pouvoir dans un salon (MatrixClient.makeRoomAdmin)
$ curl -s -X POST "$RELAIS/_synapse/admin/v1/rooms/!jYUdN8v…/make_room_admin" -d '{"user_id":…}'
HTTP 404
{"errcode":"M_UNRECOGNIZED","error":"not found :("}

### 6. l'API d'administration que Continuwuity a vraiment (pour mémoire)
$ curl -s -X GET "$RELAIS/_continuwuity/admin/rooms/list"
HTTP 200
{"rooms":["!A7CdxZqmLu6…","!abCUNkIpHiE…","!jYUdN8veYEy…","!uYNeDz2iw5C…","!vuPZxny91il…","!y7nzvlQE60M…"]}

### le compte a-t-il été créé par la commande admin ?
HTTP 200 {"displayname":"cc"}
```

Et les compléments, une fois le MXID complet donné et une session ouverte pour `@cc` :

```
$ !admin users reset-password cc <mot-de-passe-choisi>
Successfully reset the password for user @cc:unclic.local: `<mot-de-passe-choisi>`

$ curl -s -X POST …/login -d '{"type":"m.login.password","identifier":{"type":"m.id.user",
      "user":"cc"},"password":"<mot-de-passe-choisi>","initial_device_display_name":"cc sur le Mac du spike"}'
{"user_id":"@cc:unclic.local","access_token":"…","home_server":"unclic.local","device_id":"yvWPihBJlI"}

$ !admin query users list-devices-metadata @cc:unclic.local
Query completed in 7.375µs:
```rs
[
    Device {
        device_id: "yvWPihBJlI",
        display_name: Some("cc sur le Mac du spike"),
        last_seen_ip: Some("127.0.0.1"),
        last_seen_ts: Some(2026-09-01T22:49:06.935),
    },
]
```

$ !admin users reset-password cc <un-autre>   # puis, à nouveau :
$ !admin query users list-devices-metadata @cc:unclic.local
[ Device { device_id: "yvWPihBJlI", … } ]      ← la session a survécu

$ !admin users make-user-admin @cc:unclic.local
@cc:unclic.local has been granted admin privileges.

$ !admin rooms moderation --help
Commands: ban-room, ban-list-of-rooms, unban-room, list-banned-rooms
$ !admin users --help
Commands: create, issue-token, reset-password, get-email, …, force-demote,
          make-user-admin, put-room-tag, …            ← rien qui **monte** un pouvoir
```

### La matrice

| Ce que l'app fait aujourd'hui | Continuwuity 26.8.1 | Équivalent | Ce qu'il faut changer |
|---|---|---|---|
| `GET /_synapse/admin/v1/users/{moi}/admin` — `isServerAdmin` | **404** | aucun endpoint ; « je suis admin » = *je suis membre de `#admins`* | `MatrixClient.isServerAdmin` : sur 404, résoudre `#admins:<serveur>` par `GET /directory/room/…` et vérifier l'appartenance par `GET /joined_rooms`. Vrai/faux sans deviner. |
| `GET /_synapse/admin/v2/users/{id}` — `userExists` | **404** | `GET /_matrix/client/v3/profile/{id}` → `200 {"displayname":"cc"}` | `MatrixClient.userExists` : basculer sur `/profile`, qui est de l'API cliente standard et marche aussi chez Synapse. **Changement sans condition, pour les deux serveurs.** |
| `PUT /_synapse/admin/v2/users/{id}` — `provisionUser` | **404** | `!admin users create <nom>` puis `!admin users reset-password <nom> <mot de passe>` | `MatrixClient.provisionUser` : un chemin « salon d'administration » qui poste la commande dans `#admins` et lit la réponse du bot. `reset-password` **sans** `--logout` conserve les sessions — c'est l'exact équivalent de `logout_devices: false`, vérifié ci-dessus. Le mot de passe est bien choisi par l'appelant. |
| `GET /_synapse/admin/v2/users/{id}/devices` — `userDevices`, la garde du second cc (commit `60c600a`) | **404** | `!admin query users list-devices-metadata <MXID>` | `MatrixClient.userDevices` : même chemin, **mais la réponse est du `Debug` Rust dans un bloc de code, pas du JSON**. Il faut un analyseur de `Device { device_id: "…", display_name: Some("…"), last_seen_ts: Some(2026-09-01T22:49:06.935) }`. `last_seen_ts` et `display_name` y sont : la garde peut tenir. C'est le changement le plus laid des quatre. |
| `POST /_synapse/admin/v1/rooms/{id}/make_room_admin` — `makeRoomAdmin` | **404** | **aucun** | `!admin users` n'a que `force-demote` (qui *descend*) et `force-join-room`. Il faut renoncer : dans un portail, demander le pouvoir au bot du pont (`!wa set-pl @moi:… 100`, que mautrix expose) plutôt qu'au homeserver. À défaut, « inviter dans un groupe où le pont ne m'a rien accordé » reste indisponible sur Continuwuity — c'est la seule perte de fonction franche. |
| `register_new_matrix_user` (bootstrap) | sans objet | `/register` + jeton d'**amorçage lu dans le journal** ; le premier compte est admin | `infra/matrix/pair.sh` et l'installeur : le chemin « docker exec register_new_matrix_user » devient « lire le jeton du journal, appeler `/register` », et la repose de mot de passe passe par `#admins`. Fait dans `infra/relais-spike/compte.sh` et `pair.sh`. |

**Le point d'architecture** : tout ce que Synapse offre en HTTP, Continuwuity l'offre en
**messages Matrix dans `#admins`**. Son API HTTP d'administration se limite à deux routes
(`GET /_continuwuity/admin/rooms/list`, `PUT /_continuwuity/admin/rooms/{id}/ban`). L'app a
donc besoin d'une petite couche « parler au salon d'administration » — envoyer, attendre la
réponse du bot du serveur, la lire — dont `infra/relais-spike/salon-admin.py` est le prototype
en 90 lignes. C'est faisable, et c'est un travail d'une journée côté Swift, pas d'une semaine.

Rien de tout cela n'est sur le chemin de l'usage normal : la connexion, `/sync`, l'envoi, la
Note à soi, les portails et les ponts n'appellent **aucun** `_synapse/admin`. Seuls « Activer
cc », « suis-je admin ? » et la garde du second cc en dépendent.

---

## 4. L'app, connectée

Construction depuis ce worktree, DerivedData isolé :

```
$ xcodebuild -project Correspondance.xcodeproj -scheme Correspondance \
    -configuration Debug -derivedDataPath /tmp/dd-unclic build
…
** BUILD SUCCEEDED **
```

Code d'appairage, au format exact de `infra/matrix/pair.sh` :

```
$ bash infra/relais-spike/pair.sh
→ mot de passe reposé pour @essai:unclic.local (sessions conservées)

  Relais prêt. Dans Correspondance : « Connecter un Relais », puis colle ce code.

  correspondance://relais/eyJleHAiOjE3ODgzMDM5ODcs… (tronqué : il porte un mot de passe)

  Vérification (six mots) : usine marée dune chêne zeste encre
  Il périme dans 15 minutes. Il contient un mot de passe : ne le poste nulle part.
```

Lancement et collage :

```
$ open /tmp/dd-unclic/Build/Products/Debug/Correspondance.app --env CORRESPONDANCE_HOME=unclic
```

Réglages › Serveur Matrix, le code collé dans « Connecter un Relais » :

![L'app connectée au Relais du spike](app-connectee.png)

*« Correspondance-unclic » (jeu de données à part), « Matrix connecté (@essai:unclic.local) »,
« Synchronisé avec le Relais ». L'app n'a rien décodé de travers : le `RelayPairingCode` du
script Python et celui du Swift s'entendent au bit près.*

La **Note à soi** est apparue dans l'inbox, créée par l'app sur le Relais :

```
$ curl -s -H "Authorization: Bearer $T" …/joined_rooms  # puis le nom de chaque salon
!9xY9-0cI0Rqp6Hbr-eCP_a0ATaVwK4__R5fh4E1yTz4  Note à soi
!y7nzvlQE60MhOH9GGNtrsZ005LvsT4ReSAEyqpiCmrw  unclic.local Admin Room
…
```

Un message posté **hors de l'app**, par une autre session du même compte, revient dans l'app
par son `/sync` :

```
$ curl -s -X PUT …/rooms/%219xY9…/send/m.room.message/preuve… \
    -d '{"msgtype":"m.text","body":"Preuve phase 1 : posté hors de l app, relu par son /sync."}'
{"event_id":"$nncn91GYjJ3QI5eXxT4xR9J-RCK1DAJr1qcLDkW_00k"}
```

![La Note à soi dans l'inbox](note-a-soi.png)

Et après un arrêt/relance complet du Relais (celui de la mesure de démarrage à froid), l'app
reprend son `/sync` toute seule, sans intervention :

![Après redémarrage du Relais](note-a-soi-apres-redemarrage.png)

**Ce qui n'a pas pu être automatisé.** Le pilotage AppleScript de la liste des conversations
n'aboutit pas : `set selected of row 2` et le clic aux coordonnées atteignent bien l'élément
(`static text NÀ, Note à soi, … of row 2 of outline 1`) mais la sélection ne bouge pas dans la
`List` SwiftUI. Le champ du code, lui, n'accepte que la **frappe** — un `set value` de
l'accessibilité remplit l'affichage sans mettre à jour le `@State`, et le bouton « Connecter »
reste grisé. C'est une note d'automatisation, pas un défaut de l'app. La preuve « un message
posté dans la Note à soi revient par `/sync` » a donc été faite par l'aperçu de la
conversation, qui est la même boucle serveur → `/sync` → interface.

**Étape 6 (cc sur ce Relais) : non faite**, faute de temps. Le nécessaire est mesuré plus
haut : `@cc:unclic.local` a été créé, sa session ouverte, et la garde des sessions a été
éprouvée par la commande d'administration — c'est-à-dire que **la garde ne passe pas telle
quelle** (appel 4 en 404) et demande le changement décrit dans la matrice.

**Prudence prod.** Avant de lancer l'app, tous les drapeaux de reprise de l'agent ont été
vérifiés à zéro (`defaults read app.correspondance.Correspondance | grep agent` → tous
`.voulu = 0`), donc `AgentLocalHost.resume` n'a rien relancé et `~/.correspondance-agent/` n'a
pas été touché. Une seconde instance de l'app, celle de `/tmp/dd-main`, s'est retrouvée lancée
au même moment (effet de bord probable de `open` passant par LaunchServices) ; elle a été
arrêtée aussitôt.

---

## 5. Les mesures

```
$ bash infra/relais-spike/mesurer.sh
## Mémoire résidente (ps -o rss, en Ko) et âge du processus
processus              RSS_Ko       âge      CPU
relais                  24704      13:58      0.0
mautrix-whatsapp         7440      13:03      0.0
mautrix-signal          14080      13:03      0.0

## Taille des binaires
continuwuity               80749216 octets
libolm.3.dylib               190192 octets
mautrix-signal             86749648 octets
mautrix-whatsapp           45720128 octets

## Disque
1.2M	…/relais/db
880K	…/mautrix-whatsapp
640K	…/mautrix-signal
218M	…/bin
total hors sources et journaux : 220 Mo

## Démarrage à froid du Relais (base déjà peuplée)
0.63 s jusqu'à la première réponse de /_matrix/client/versions
```

### Face à la référence NUC

| | NUC, Docker (référence du plan) | Ce spike, binaires sur macOS |
|---|---|---|
| Homeserver, 1 utilisateur | Synapse 340 Mo + Postgres 220 Mo = **560 Mo** | Continuwuity **24 Mo**, base RocksDB comprise |
| Homeserver vide | Synapse d'essai 120 Mo | — |
| Pont WhatsApp | 12–30 Mo | **7,4 Mo** |
| Pont Signal | 62 Mo | **14 Mo** |
| **Total de la pile** | ≈ 620 Mo | **46 Mo** |
| Démarrage | Synapse : dizaines de secondes | **0,63 s** |
| Disque, hors historique | — | **220 Mo**, dont 218 Mo de binaires |
| Base de données | Postgres, un conteneur, un mot de passe | RocksDB dans un dossier ; SQLite pour chaque pont |

La prévision du plan (« 300–450 Mo hors de l'app ») était **six à dix fois trop pessimiste**.
La pile tient dans 46 Mo, soit un dixième de ce que Beeper embarque rien qu'en bundle.

Deux nuances honnêtes : (1) ce Relais n'a qu'un compte, aucun portail réel et aucun historique
— la mémoire montera avec les salons pontés ; (2) `ps -o rss` sur macOS ne compte pas les
pages mappées non résidentes de RocksDB, donc les 24 Mo sont un plancher, pas un plafond.

---

## 6. Le contrepoint Synapse par `uv` : pas fait, et pourquoi

Le plan le prévoyait « si Continuwuity échoue sur un point bloquant ». Rien n'a bloqué :
l'app se connecte, synchronise, crée sa Note à soi, et les deux ponts tournent. Le seul manque
franc — `make_room_admin` — ne justifie pas de reposer 560 Mo de Synapse et Postgres pour une
fonction de dépannage dans les groupes pontés. Le contrepoint reste à faire si la phase 2
(chiffrement) découvre une incompatibilité de Continuwuity avec les clés de salon.

---

## 7. Ce qui reste à décider avant la phase 3

1. **Publier un binaire macOS arm64 de Continuwuity** dans `correspondance-releases`, construit
   par nous depuis le tag épinglé — sans quoi la carte « sur ce Mac » demande 20 minutes de
   `cargo` à l'utilisateur. Sur Linux, la release amont suffit.
2. **libolm** : soit on publie aussi le `.dylib` (190 Ko, à côté des binaires), soit on
   reconstruit les ponts avec `-tags goolm` et le problème disparaît. La seconde voie est la
   bonne pour un produit.
3. **La couche « salon d'administration »** dans `CorrespondanceMatrixClient` : quatre appels
   à doubler, dont un analyseur de `Debug` Rust. Une journée.
4. **`make_room_admin`** : accepter la perte, ou passer par `!wa set-pl` du pont.

---

## Rejouer les preuves

```
cd ~/correspondance-un-clic
bash infra/relais-spike/telecharger.sh          # ~20 min à froid sur macOS (cargo)
bash infra/relais-spike/generer-configs.sh
bash infra/relais-spike/start.sh
bash infra/relais-spike/compte.sh
bash infra/relais-spike/enregistrer-appservices.sh
curl -s http://127.0.0.1:8010/_matrix/client/versions
bash infra/relais-spike/matrice-admin.sh
bash infra/relais-spike/mesurer.sh
bash infra/relais-spike/pair.sh                 # puis coller le code dans l'app
xcodebuild -project Correspondance.xcodeproj -scheme Correspondance \
  -configuration Debug -derivedDataPath /tmp/dd-unclic build
open /tmp/dd-unclic/Build/Products/Debug/Correspondance.app --env CORRESPONDANCE_HOME=unclic
bash infra/relais-spike/stop.sh                 # aucun processus laissé derrière
```
