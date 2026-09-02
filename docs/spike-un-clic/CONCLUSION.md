# Conclusion du spike « un clic » — 2 septembre 2026

Trois phases de spike, puis la phase 4 qui en tire les conséquences dans le code, la phase 5
qui referme le chantier du chiffrement, et la phase 6 qui construit les binaires, pose les deux
cartes dans l'app et prépare la publication (`phase-1.md` à `phase-6.md`). Rien ici n'est une
lecture : tout a tourné sur ce Mac et sur le NUC, sous des dossiers à part, sans toucher la prod.

## La pile retenue : Continuwuity + ponts mautrix en binaires, SQLite/RocksDB, sans conteneur

| | Synapse + Postgres (NUC, Docker) | Pile du spike |
|---|---|---|
| Mémoire | ≈ 620 Mo | 50–110 Mo (Mac), 130–230 Mo (NUC) à deux ponts ; **75 Mo / 212 Mo à quatre** |
| Démarrage | dizaines de secondes | 0,3–0,6 s |
| Disque | — | 220–260 Mo à deux ponts, **300–320 Mo à quatre**, presque tout en binaires |
| Installation, dossier vide | bootstrap Docker | 9 s sur Mac et 23 s sur Linux à deux ponts ; 16 s et 30 s à quatre ; **14 s depuis la phase 6, ou un clic dans l'app (26 s)** — aucune question, aucun sudo |
| Réseaux | WhatsApp, Signal, Instagram, Messenger | **les quatre**, depuis la phase 4 |
| Chiffrement | possible | **fait** : salons natifs de bout en bout, sauvegarde avec phrase, appareils vérifiés ; ponts en Olm de **Go pur** depuis la phase 6, plus de libolm |
| Administration | `_synapse/admin` | **rien de compatible** : commandes dans le salon `#admins` |

Le contrepoint Synapse par `uv` n'a pas été fait : rien n'a bloqué.

## Ce qu'il fallait changer dans l'app — **fait** (phase 4)

Les quatre appels `_synapse/admin` répondent 404 chez Continuwuity. Remplacements, éprouvés
en phase 1 puis **écrits et branchés en phase 4** (`MatrixAdmin.swift`,
`MatrixClient+Admin.swift`) : le Relais se détecte une fois par session, au `M_UNRECOGNIZED`
du premier appel plutôt qu'à son nom — un nom se déguise, et un Synapse peut avoir son API
d'administration désactivée. Aucun appelant n'a changé.

| Appel | Remplacement |
|---|---|
| `isServerAdmin` | appartenance à `#admins:<serveur>` via `/joined_rooms` |
| `userExists` | `GET /_matrix/client/v3/profile/{id}` (standard, marche aussi chez Synapse) |
| `provisionUser` | `!admin users create` + `!admin users reset-password` sans `--logout` |
| `userDevices` (garde du second cc) | `!admin query users list-devices-metadata` — réponse en `Debug` Rust dans un bloc de code, à analyser |
| `makeRoomAdmin` | **aucun équivalent** ; erreur explicite « pas disponible sur ce Relais », qui renvoie au `set-pl` du bot du pont |

La couche « parler au salon d'administration » existe donc dans `CorrespondanceMatrixClient`,
avec quatorze tests sur les sorties réelles. Deux choses ne se voyaient qu'à l'exécution : le
`Debug` Rust de `list-devices-metadata` existe en forme **compacte et repliée** (Rust replie
dès que la ligne s'allonge), et son `last_seen_ts` est en **UTC** — le lire en heure locale
aurait vieilli chaque session de deux heures et désarmé la garde du second cc.

## Le coût réel du chiffrement — **le chantier E est fait** (phase 5)

Prouvé en phase 2 avec `matrix-sdk-crypto-ffi 0.17.0` derrière un drapeau de manifeste, puis
**achevé en phase 5**. Ce qui tourne aujourd'hui, sur le Relais du spike, et qui est prouvé
par deux scripts rejouables :

- **Les salons natifs sont chiffrés de bout en bout** : déchiffrement en amont du `/sync`,
  chiffrement à l'envoi, partage de clés entre appareils.
- **La sauvegarde des clés avec phrase** (`m.megolm_backup.v1.curve25519-aes-sha2`) : un
  appareil neuf, magasin vierge, avec la seule phrase, lit l'historique d'avant sa naissance.
  10 clés sur 10 réimportées. **La limite « first known index 1 » de la phase 2 a disparu.**
- **La vérification d'appareil** : signatures croisées posées sur le compte, et un appareil
  neuf marqué vérifié par la phrase, sans comparer d'émojis.
- **`cc` lit et écrit chiffré** sur macOS — « @cc ping » chiffré, « pong » stocké en
  `m.room.encrypted`, journal des tours écrit chiffré puis relu. Et quand il ne comprend pas,
  il le dit : la phase 4 avait mesuré un agent muet, indiscernable d'un agent occupé.
- **Les trois états s'affichent** : « Chiffré », « Chiffré par le pont », « En clair ». Un
  portail ne porte jamais le cadenas du bout en bout — ce qui compte, puisque l'installeur les
  pose chiffrés depuis la phase 4 et qu'un client naïf y verrait du bout en bout.
- **`CORRESPONDANCE_CHIFFREMENT=1` n'est plus requis** : un binaire construit avec la crypto
  chiffre. `=0` reste une soupape.

Poids : **+14,5 Mio** sur un DMG gzippé pour l'app, **+7,3 Mio** pour
`correspondance-agent` — qui n'est plus inchangé, contrairement à la phase 2 : lui donner la
machine crypto lui coûte 24,4 Mio bruts, et les deux binaires embarquent chacun leur copie
statique de la bibliothèque Rust. La restauration depuis la sauvegarde coûte **0,64 s** pour
douze sessions de salon, et ne grandit pas avec l'historique.

**Reste 1,5 à 2 jours** : la bibliothèque Rust pour Linux (sans elle, un `cc` de VPS reste
hors des salons chiffrés — il le dit), l'App Group iOS (sans lui l'extension de notification
affiche « Message chiffré » au lieu du texte), et les écrans de la phrase de récupération et
de la liste des appareils, que le noyau sert déjà.

## Les deux cartes — **faites** (phase 6)

Une app sans Relais montrait une inbox vide, c'est-à-dire une app cassée ou une app dont on n'a
rien à attendre. Elle montre désormais **deux cartes**, parce qu'il n'y a que deux endroits où
poser un Relais. Pas de troisième carte « hébergé » : nous n'hébergeons rien. Aucune question sur
le chiffrement : il est d'office, et le proposer laisserait croire qu'on peut répondre non.

- **Sur ce Mac** : un bouton. L'app télécharge `relais-install.sh`, **confronte son sha256 au
  `SHA256SUMS` du même endroit avant d'exécuter**, lance le script en `--json` comme processus
  enfant, montre les dix étapes à mesure, et **colle le code d'appairage elle-même**. Mesuré :
  **26 s du clic à la note à soi visible, sans une seule frappe.** En dessous, « Tout retirer »,
  affiché tant que la marque de l'installeur est sur le disque — pas seulement dans les dix
  secondes qui suivent une installation.
- **Sur une machine à moi** : la commande à copier, le champ du code et les six mots.

Le champ du code reste dans Réglages › Matrix. Deux choses ne se sont vues qu'à l'exécution : la
condition d'affichage ne peut pas être « l'inbox est vide » (ce Mac a des conversations iMessage
dès le premier lancement, et l'écran n'est jamais apparu au premier essai), et « Tout retirer »
serait resté inatteignable s'il avait dépendu de la seule phase d'installation.

## libolm quitte la pile — **fait** (phase 6)

Les binaires mautrix officiels chargent encore `@rpath/libolm.3.dylib`, abandonnée amont en 2024
pour faiblesses cryptographiques et retirée de Homebrew. `infra/relais/construire.sh` reconstruit
les quatre ponts au même tag avec `-tags goolm` : `otool -L` ne nomme plus libolm, et les quatre
bots publient bien leurs clés `m.olm.v1.curve25519-aes-sha2`. Il n'y a plus de dylib à poser, à
signer, ni à notariser.

Trois surprises : **`CGO_ENABLED=0` ne marche pas** (goolm retire libolm mais `mattn/go-sqlite3`
et `go.mau.fi/webp` restent en cgo — croiser vers Linux demande donc `zig cc`) ; **Signal ne se
croise pas** sans conteneur (libsignal est du Rust lié statiquement, 33 min de construction pour
l'hôte, et il faut `protoc`) ; et **Continuwuity n'est pas reproductible au bit près** — même
taille, même version, 3,5 Mio d'octets différents, parce que le chemin du dossier de construction
est embarqué. La somme est donc relevée à chaque construction, jamais supposée.

## La commande telle qu'un utilisateur la verra

Sur une machine à lui (Linux, x86_64 ou arm64) :

```
curl -fsSLO https://github.com/…/correspondance-releases/releases/latest/download/relais-install.sh
bash relais-install.sh
```

Elle finit sur « le Relais répond, connecté comme @… » puis sur le code d'appairage. Si
Tailscale manque, elle le dit et donne les deux commandes sudo ; elle ne les fait pas.
Sur ce Mac : le bouton « Installer ici » de la carte, qui fait tout et ne demande rien.

## Ce qui reste avant un DMG

1. ~~Publier deux binaires macOS que nous construisons~~ — **construits en phase 6**, et il y en
   a huit plutôt que deux plus une dylib : Continuwuity arm64 (12 min de cargo) et les quatre
   ponts goolm macOS, plus trois ponts Linux amd64 croisés au passage. **410 Mio** en tout, prêts
   dans `~/unclic-publication/` avec leur `SHA256SUMS`. Ce qui reste est la publication
   elle-même : `infra/relais/publier.sh --dry-run` montre les commandes `gh release` qu'elle
   exécuterait, et **rien n'a été poussé** — c'est une décision du propriétaire. Manque
   `mautrix-signal-linux-amd64`, qui demande un conteneur Linux.
2. ~~La couche `#admins` dans le client~~ — **faite en phase 4**.
3. ~~Le chantier E~~ — **fait en phase 5**, sauf trois finitions (1,5 à 2 jours) :
   - **la bibliothèque Rust pour Linux.** `matrix-sdk-crypto-ffi` s'y construit — la CI amont
     le fait sur `ubuntu-latest` à chaque PR —, mais l'artefact publié est un XCFramework
     Apple : il faut régénérer (`cargo build` + `uniffi-bindgen`, 10 à 18 min sur 4 cœurs) et
     empaqueter pour SwiftPM. À faire sur une machine de build, pas sur le NUC de production ;
   - **l'App Group `group.com.correspondance`**, qui n'existe toujours pas dans le portail
     développeur — il bloque l'extension de notification, et rend déjà inopérante la seconde
     garde du muet ;
   - **les écrans** de la phrase de récupération et de la liste des appareils.
4. ~~Les deux cartes~~ — **faites en phase 6**, avec l'installeur en mode `--json`.
5. **Signature, notarisation et DMG**, puis TestFlight. Une identité Developer ID existe sur la
   machine de construction. Mesuré en phase 6, parce que c'était une vraie question : un binaire
   ad-hoc portant `com.apple.quarantine` est **tué au `exec`, en silence, code 137** — mais ni
   `curl` ni `URLSession` ne posent cet attribut (seuls les téléchargeurs qui passent par
   LaunchServices le font), donc la carte « Sur ce Mac » n'est **pas** bloquée aujourd'hui. Ça ne
   dispense pas de signer : `spctl -a -t exec` rejette déjà ces binaires, et un bac à sable ou un
   durcissement de macOS ferait tout tomber d'un coup, en silence. Piège à trancher : un binaire
   nu ne peut pas être agrafé (`stapler` n'agrafe que des paquets), donc le ticket reste en ligne.
6. **Le push** : une passerelle Sygnal chez nous, quand un utilisateur externe a un iPhone.

Non testé : la branche « Tailscale présent » de l'installeur Linux (le NUC ne l'a pas en
natif) ; aucun compte Meta, WhatsApp ou Signal n'a jamais été lié — la règle du spike
l'interdit, et la feuille qui s'ouvre et demande la session est toute la preuve possible ;
`cc` chiffré **sous Linux** ; l'extension de notification en conditions réelles (ni App Group,
ni push au simulateur) ; et les captures d'écran de la phase 5 — l'écran de la machine était
verrouillé, et une capture noire ne prouve rien.

Trois pièges de la phase 5, qui ne se voient qu'à l'exécution et valent pour tout Relais
Continuwuity : `PUT /room_keys/keys` veut la version en paramètre **et** la carte des salons
sous `rooms` ; `importRoomKeysFromBackup` attend des clés **déjà déchiffrées**, pas la réponse
du serveur ; et `GET /room_keys/version` ne rend pas la version la plus récente alors que le
serveur refuse d'écrire ailleurs — remplacer une sauvegarde exige de les retirer toutes.
Dette : ~~libolm reconstruite à la main~~ (elle a disparu en phase 6) ; `install.sh` garde les
ponts amont pour Linux, faute d'avoir posé les nôtres sur une machine Linux ; le python système du Mac n'a pas PyYAML, donc les
configurations de ponts sont écrites sans fusion de gabarit ; `UserDefaults` ne suit pas
encore `CORRESPONDANCE_HOME` (le dossier d'amorce de l'agent, lui, le suit depuis la
phase 4) ; la vue web de la feuille de connexion n'est pas remise à zéro entre deux réseaux ;
le coffre qui porte les clés de signature à un appareil neuf est **le nôtre**, pas le stockage
secret de la spécification (4S) — Element ne le lira pas, et le rendre interopérable coûte une
demi-journée ; les deux binaires du bundle embarquent chacun leur copie statique de la
bibliothèque Rust, là où un `.dylib` partagé économiserait ~15 Mio.
