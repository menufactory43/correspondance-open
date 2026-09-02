# Conclusion du spike « un clic » — 2 septembre 2026

Trois phases de spike, puis la phase 4 qui en tire les conséquences dans le code (`phase-1.md`
à `phase-4.md`). Rien ici n'est une lecture : tout a tourné sur ce Mac et sur le NUC, sous des
dossiers à part, sans toucher la prod.

## La pile retenue : Continuwuity + ponts mautrix en binaires, SQLite/RocksDB, sans conteneur

| | Synapse + Postgres (NUC, Docker) | Pile du spike |
|---|---|---|
| Mémoire | ≈ 620 Mo | 50–110 Mo (Mac), 130–230 Mo (NUC) à deux ponts ; **75 Mo / 212 Mo à quatre** |
| Démarrage | dizaines de secondes | 0,3–0,6 s |
| Disque | — | 220–260 Mo à deux ponts, **300–320 Mo à quatre**, presque tout en binaires |
| Installation, dossier vide | bootstrap Docker | 9 s sur Mac et 23 s sur Linux à deux ponts ; **16 s et 30 s à quatre** — une commande, aucune question, aucun sudo |
| Réseaux | WhatsApp, Signal, Instagram, Messenger | **les quatre**, depuis la phase 4 |
| Chiffrement | possible | possible : toutes les API de clés répondent |
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

## Le coût réel du chiffrement

Prouvé en phase 2 avec `matrix-sdk-crypto-ffi 0.17.0` derrière un drapeau de manifeste :
déchiffrement en amont du `/sync`, chiffrement à l'envoi, persistance, **partage de clés
entre deux appareils du même compte**, salon de gestion du pont WhatsApp chiffré et lu.
Poids : +14 Mo sur un DMG gzippé, +39 Mo sur le binaire strippé ; `correspondance-agent`
inchangé. **Reste 6 à 9 jours** pour le chantier E complet : sauvegarde des clés avec phrase,
vérification d'appareil, cc et l'extension iOS sur le même client, les trois états à
afficher. Limite connue : un appareil qui arrive après un message ne le lit pas sans
sauvegarde de clés.

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
3. **Le chantier E**, 6 à 9 jours — avec un préalable mesuré en phase 4 : les portails sont
   posés chiffrés par l'installeur, et `correspondance-agent` n'a pas de machine crypto. Une
   note à soi chiffrée le rend **sourd, sans un mot** : en clair il journalise le message en
   moins d'une seconde, chiffré il ne journalise rien. Soit l'agent gagne la même machine
   crypto que l'app (il partage déjà `MatrixClient`), soit l'écran le dit.
4. **Les deux cartes** dans l'app : « sur ce Mac » lance l'installeur en mode `--json` et colle
   le code seule ; « machine à moi » affiche la commande et le champ du code.
5. **Notarisation et DMG**, puis TestFlight.
6. **Le push** : une passerelle Sygnal chez nous, quand un utilisateur externe a un iPhone.

Non testé : la branche « Tailscale présent » de l'installeur Linux (le NUC ne l'a pas en
natif) ; aucun compte Meta, WhatsApp ou Signal n'a jamais été lié — la règle du spike
l'interdit, et la feuille qui s'ouvre et demande la session est toute la preuve possible.
Dette : libolm reconstruite à la main ; le python système du Mac n'a pas PyYAML, donc les
configurations de ponts sont écrites sans fusion de gabarit ; `UserDefaults` ne suit pas
encore `CORRESPONDANCE_HOME` (le dossier d'amorce de l'agent, lui, le suit depuis la
phase 4) ; la vue web de la feuille de connexion n'est pas remise à zéro entre deux réseaux.
