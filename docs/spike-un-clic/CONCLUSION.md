# Conclusion du spike « un clic » — 2 septembre 2026

Trois phases de spike, puis la phase 4 qui en tire les conséquences dans le code, puis la
phase 5 qui referme le chantier du chiffrement (`phase-1.md` à `phase-5.md`). Rien ici n'est
une lecture : tout a tourné sur ce Mac et sur le NUC, sous des dossiers à part, sans toucher
la prod.

## La pile retenue : Continuwuity + ponts mautrix en binaires, SQLite/RocksDB, sans conteneur

| | Synapse + Postgres (NUC, Docker) | Pile du spike |
|---|---|---|
| Mémoire | ≈ 620 Mo | 50–110 Mo (Mac), 130–230 Mo (NUC) à deux ponts ; **75 Mo / 212 Mo à quatre** |
| Démarrage | dizaines de secondes | 0,3–0,6 s |
| Disque | — | 220–260 Mo à deux ponts, **300–320 Mo à quatre**, presque tout en binaires |
| Installation, dossier vide | bootstrap Docker | 9 s sur Mac et 23 s sur Linux à deux ponts ; **16 s et 30 s à quatre** — une commande, aucune question, aucun sudo |
| Réseaux | WhatsApp, Signal, Instagram, Messenger | **les quatre**, depuis la phase 4 |
| Chiffrement | possible | **fait** : salons natifs de bout en bout, sauvegarde avec phrase, appareils vérifiés |
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

## La commande telle qu'un utilisateur la verra

Sur une machine à lui (Linux, x86_64 ou arm64) :

```
curl -fsSLO https://github.com/…/correspondance-releases/releases/latest/download/relais-install.sh
bash relais-install.sh
```

Elle finit sur « le Relais répond, connecté comme @… » puis sur le code d'appairage. Si
Tailscale manque, elle le dit et donne les deux commandes sudo ; elle ne les fait pas.
Sur ce Mac : la même commande, ou le bouton de la carte quand il existera.

## Ce qui reste avant un DMG

1. **Publier deux binaires macOS que nous construisons** : Continuwuity arm64 (aucune release
   amont, ~20 min de cargo par version) et `libolm.3.dylib` (ou reconstruire les ponts avec
   `-tags goolm`). C'est le vrai bloqueur de la carte « sur ce Mac ». Linux n'a besoin de rien.
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
4. **Les deux cartes** dans l'app : « sur ce Mac » lance l'installeur en mode `--json` et colle
   le code seule ; « machine à moi » affiche la commande et le champ du code.
5. **Notarisation et DMG**, puis TestFlight.
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
Dette : libolm reconstruite à la main ; le python système du Mac n'a pas PyYAML, donc les
configurations de ponts sont écrites sans fusion de gabarit ; `UserDefaults` ne suit pas
encore `CORRESPONDANCE_HOME` (le dossier d'amorce de l'agent, lui, le suit depuis la
phase 4) ; la vue web de la feuille de connexion n'est pas remise à zéro entre deux réseaux ;
le coffre qui porte les clés de signature à un appareil neuf est **le nôtre**, pas le stockage
secret de la spécification (4S) — Element ne le lira pas, et le rendre interopérable coûte une
demi-journée ; les deux binaires du bundle embarquent chacun leur copie statique de la
bibliothèque Rust, là où un `.dylib` partagé économiserait ~15 Mio.
