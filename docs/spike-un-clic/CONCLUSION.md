# Conclusion du spike « un clic » — 2 septembre 2026

Trois phases de spike, puis la phase 4 qui en tire les conséquences dans le code, la phase 5
qui referme le chantier du chiffrement, la phase 6 qui construit les binaires, pose les deux
cartes dans l'app et prépare la publication, la phase 7a qui referme les trois finitions du
chiffrement et essaie Tailcat, et la phase 7b qui en fait le chemin par défaut
(`phase-1.md` à `phase-7b.md`). Rien ici n'est une lecture : tout
a tourné sur ce Mac et sur le NUC, sous des dossiers à part, sans toucher la prod.

## La pile retenue : Continuwuity + ponts mautrix en binaires, SQLite/RocksDB, sans conteneur

| | Synapse + Postgres (NUC, Docker) | Pile du spike |
|---|---|---|
| Mémoire | ≈ 620 Mo | 50–110 Mo (Mac), 130–230 Mo (NUC) à deux ponts ; **75 Mo / 212 Mo à quatre** |
| Démarrage | dizaines de secondes | 0,3–0,6 s |
| Disque | — | 220–260 Mo à deux ponts, **300–320 Mo à quatre**, presque tout en binaires |
| Installation, dossier vide | bootstrap Docker | 9 s sur Mac et 23 s sur Linux à deux ponts ; 16 s et 30 s à quatre ; **14 s depuis la phase 6, ou un clic dans l'app (26 s)** — aucune question, aucun sudo |
| Réseaux | WhatsApp, Signal, Instagram, Messenger | **les quatre**, depuis la phase 4 |
| Chiffrement | possible | **fait** : salons natifs de bout en bout, sauvegarde avec phrase, appareils vérifiés ; ponts en Olm de **Go pur** depuis la phase 6, plus de libolm ; **`cc` chiffré sous Linux depuis la phase 7a** |
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

Deux des trois finitions sont **faites en phase 7a** : la bibliothèque Rust pour Linux, et les
deux écrans. Reste l'**App Group iOS**, qui n'existe toujours pas dans le portail développeur —
sans lui l'extension de notification affiche « Message chiffré » au lieu du texte.

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

Elle finit sur « le Relais répond, connecté comme @… » puis sur le code d'appairage — qui
porte, depuis la phase 7b, le **jeton Tailcat** que l'installeur a fait publier au Relais : le
Mac s'y connecte tout seul, sans tunnel ssh, sans Tailscale et sans un sudo. L'iPhone, lui, a
encore besoin de Tailscale, et la commande le dit.
Sur ce Mac : le bouton « Installer ici » de la carte, qui fait tout et ne demande rien — et pas
de Tailcat, puisque le Relais et l'app sont sur la même machine.

## `cc` chiffré sous Linux — **fait** (phase 7a)

La phase 5 disait « la bibliothèque Rust s'y construit, il ne manque que l'empaquetage ».
L'empaquetage, c'était trois choses qui ne se devinent pas, et une chaîne qui n'existait pas.

**La question préalable, tranchée** : `infra/agent/deploy.sh` compilait `cc` **sur le NUC, dans
un conteneur Docker `swift:6.1-bookworm`** — donc sur la machine de production, avec Docker,
avec une autre version de Swift. Une chaîne croisée a été posée sur ce Mac : la chaîne Swift
**open source** 6.3.3 (celle d'Xcode ne sert pas — ses modules Foundation sont d'un autre format
que ceux du SDK, et le compilateur s'arrête sur « compiled module was created by an older
version ») et le SDK `static-linux` 0.1.0, en musl.

`infra/relais/crypto-linux.sh` construit la bibliothèque en **2 min 07 s**. Ce qui n'était pas
devinable : on ne construit que le `staticlib` (le `cdylib` réclamerait un éditeur de liens
Linux complet) ; la caisse `cc` de Rust ajoute d'elle-même `--target=x86_64-unknown-linux-musl`,
la triplette **Rust**, que zig refuse ; et musl plutôt que glibc, parce que le SDK Swift statique
est lui-même en musl — ce qui en sort est statique, donc tourne partout, le NUC en glibc 2.36
compris. Trois pièges du manifeste, chacun muet : le vérificateur de types abandonne sur le
littéral des cibles dès qu'on y ajoute une concaténation, un `let` déclaré après `Package(...)`
se lit avant d'être initialisé (« Missing or empty JSON output »), et **`CryptoKit` n'existe pas
sous Linux** — swift-crypto le remplace, même BoringSSL derrière la même API, donc un coffre
scellé sur le Mac s'ouvre sur le Linux.

Éprouvé sur le NUC, sans Docker, sans Rust ni Swift là-bas : `@cc ping` chiffré depuis ce Mac,
`pong` rendu par le `cc` de Linux, stocké en `m.room.encrypted` / `m.megolm.v1.aes-sha2`, vu par
HTTP sans le client. **87,7 Mio** dépouillé, **39,7 Mio** de RSS.

Une erreur a servi de garde : l'unité passait `--agent cc` **et** `CORRESPONDANCE_AGENT_HOME`,
or `--agent` gagne, donc `cc` a lu l'amorce de la production et s'est connecté au vrai Relais.
C'est la garde du second agent qui l'a arrêté net, en nommant le pid du vrai `cc`.

## Les deux écrans du chiffrement — **faits** (phase 7a)

Ce qui manquait n'était pas de la cryptographie mais une décision : **quoi montrer à la première
connexion d'un appareil ?** Elle ne se lit dans aucun fait pris seul — c'est la rencontre de ce
que le Relais héberge (`GET /room_keys/version`) et de ce que cette machine-ci connaît. Sans
sauvegarde, on en propose une ; une sauvegarde que cet appareil ignore, c'est un appareil neuf ;
les deux d'accord, il n'y a plus rien à faire. `ModeleChiffrement` porte ces états dans
`CorrespondanceCore`, éprouvé sans Relais — dix-neuf tests, dont celui qui tient la garde qui
compte : `sonder()` tourne à chaque apparition de l'écran, et sans elle un rafraîchissement
effacerait douze mots que personne n'a recopiés, en laissant sur le Relais une sauvegarde à
jamais fermée.

Trois choix se disent à l'écran plutôt que de se cacher : la sauvegarde ne naît qu'à « je l'ai
notée » (créée avant, elle serait impossible à rouvrir) ; la phrase est gardée au Trousseau de
cette machine, sinon « Revoir » serait un bouton qui ment ; et le mot de passe du compte ne part
**que** si le Relais le réclame. La liste des appareils recolle le serveur (nom, dernière
activité) et la machine crypto (vérifié ou non), d'où un troisième état — « état inconnu » — qui
n'est pas « non vérifié ».

Éprouvé sur le Relais du spike, écran allumé : six captures, dont la déconnexion menée jusqu'au
bout — le Relais réclame le mot de passe, l'appareil disparaît, et son jeton répond depuis
`M_UNKNOWN_TOKEN`.

## Tailcat : joindre le Relais sans Tailscale ni tunnel ssh — **essayé** (7a), **par défaut** (7b)

Un Relais posé sur une machine à soi n'écoute que sur `127.0.0.1`, et c'est ce qu'il faut. Le
joindre demandait Tailscale (un compte, un tailnet, une extension système) ou `ssh -N -L` (un
terminal). Tailcat prend le plan de données de Tailscale — WireGuard, traversée de NAT, DERP en
repli — **sans son plan de contrôle**.

Le code d'appairage porte l'« addrblob » du Relais dans un champ facultatif, l'app lance
`tailcat socks` en processus enfant et bascule tout son trafic Matrix dessus avant le `/login`.
**Prouvé par `lsof`** : l'app n'a qu'une connexion TCP, vers le mandataire local ; rien ne va au
NUC en direct, et il n'y a pas de tunnel ssh. Coût : `/sync` médian **44 ms** contre 32 ms par
ssh, et **rien de mesurable** sur un média de 5 Mio.

**Pour l'iPhone, deux murs**, tous deux découverts par le compilateur : `Process` n'existe pas
sur iOS (une app n'y lance pas de processus enfant — il faudrait embarquer tailcat par
`gomobile bind`, avec le runtime Go dans le bundle, 10 à 15 Mio par tranche) et
`kCFNetworkProxiesSOCKS*` y est marqué indisponible. D'où `#if os(macOS)` plutôt qu'un code qui
compilerait et ne ferait rien.

**Décidé le 2 septembre 2026 : Tailcat par défaut** (phase 7b). L'installeur Linux le pose —
archive amont v0.4.0 épinglée et vérifiée avant d'être dépliée, clé persistante dans le dossier
du Relais, service `correspondance-tailcat` devant le port du homeserver — et met son jeton dans
le code d'appairage. L'app l'embarque (`Contents/Helpers/tailcat`, construit par
`construire.sh --quoi tailcat` au même tag, signé séparément avec l'app), le lance quand le code
porte un jeton, le relance s'il tombe, et l'arrête avec la session comme à la fermeture. **Le
message « Tailscale absent, il faudrait sudo » disparaît** : ce n'est plus vrai pour le Mac.
Tailscale devient un repli — et reste le seul chemin de l'iPhone.

Ce qu'il faut continuer de dire : **qui détient le jeton joint le Relais.** C'est le même régime
que le mot de passe que le code d'appairage porte déjà, donc pas une régression ; mais un code
d'appairage est désormais une clé de réseau en plus d'être une clé de compte, et il périme
toujours en quinze minutes. Un « tout retirer » emporte la clé, donc les jetons déjà émis.

## Ce qui reste avant un DMG

1. ~~Publier deux binaires macOS que nous construisons~~ — **construits en phase 6**, et il y en
   a huit plutôt que deux plus une dylib : Continuwuity arm64 (12 min de cargo) et les quatre
   ponts goolm macOS, plus trois ponts Linux amd64 croisés au passage. **410 Mio** en tout, prêts
   dans `~/unclic-publication/` avec leur `SHA256SUMS`. Ce qui reste est la publication
   elle-même : `infra/relais/publier.sh --dry-run` montre les commandes `gh release` qu'elle
   exécuterait, et **rien n'a été poussé** — c'est une décision du propriétaire. Manque
   `mautrix-signal-linux-amd64`, qui demande un conteneur Linux.
2. ~~La couche `#admins` dans le client~~ — **faite en phase 4**.
3. ~~Le chantier E~~ — **fait en phase 5**, et ses trois finitions **en phase 7a**, sauf une :
   - ~~la bibliothèque Rust pour Linux~~ — **faite** : `infra/relais/crypto-linux.sh`, 2 min 07 s,
     et `cc` croisé depuis ce Mac tourne chiffré sur le NUC. Reste à basculer
     `infra/agent/deploy.sh` de « Docker sur le NUC » à « croisé sur la machine de construction »,
     et à faire la tranche `arm64` (même recette) ;
   - **l'App Group `group.com.correspondance`**, qui n'existe toujours pas dans le portail
     développeur — il bloque l'extension de notification, et rend déjà inopérante la seconde
     garde du muet ;
   - ~~les écrans~~ — **faits**, sur Mac et sur iPhone.
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
7. ~~Décider de Tailcat~~ — **décidé et fait en phase 7b** : par défaut sur Linux, embarqué et
   signé dans l'app. Reste la tranche iPhone (`gomobile bind`, et une façon de composer sans
   SOCKS), dont le coût est à chiffrer avant de s'engager.

Non testé : la branche « Tailscale présent » de l'installeur Linux (le NUC ne l'a pas en
natif — la branche « Tailcat seul », elle, est éprouvée) ; aucun compte Meta, WhatsApp ou Signal n'a jamais été lié — la règle du spike
l'interdit, et la feuille qui s'ouvre et demande la session est toute la preuve possible ;
l'extension de notification en conditions réelles (ni App Group, ni push au simulateur) ; les
captures d'écran de la phase 5 — l'écran de la machine était verrouillé, et une capture noire ne
prouve rien ; et les deux écrans du chiffrement **sur iPhone** — la cible construit, mais l'écran
ne s'ouvre qu'une session liée, et appairer un simulateur au Relais du spike pour une capture n'a
pas été fait.

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

## Publication (2 sept. 2026, 16 h 30)

Publié : `relais-2026.09.02` sur `menufactory43/correspondance-releases`, 15 fichiers. Les six
binaires macOS sont signés Developer ID (runtime durci, horodatés), **notarisés** (soumission e19dc248, acceptée, ticket en ligne) — le
profil `notarytool` s'appelle `notarisation` dans le Trousseau (équipe AKMNXGVVGX), le même que mes autres apps ;
il sert tel quel. **Règle apprise en publiant** : `releases/latest` ne sert que la release la plus
récente, et l'installeur de cc y lit `install.sh` et `SHA256SUMS` — publier le Relais seul a
rendu 404 à cc pendant vingt minutes. Une release porte donc désormais **tout le produit** : les
fichiers de cc sont repris dans la release du Relais, avec des sommes fusionnées (et la somme
de `install.sh` corrigée : celle de `v0.1.0` était déjà fausse). `publier.sh` doit reprendre
les fichiers de l'agent à chaque publication ; c'est à faire dans le script.
