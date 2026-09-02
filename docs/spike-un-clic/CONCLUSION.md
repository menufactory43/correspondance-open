# Conclusion du spike « un clic » — 2 septembre 2026

Trois phases, chacune codée par un agent et rejouée par un vérificateur (notes en fin de
`phase-1.md`, `phase-2.md`, `phase-3.md`). Rien ici n'est une lecture : tout a tourné sur ce
Mac et sur le NUC, sous des dossiers à part, sans toucher la prod.

## La pile retenue : Continuwuity + ponts mautrix en binaires, SQLite/RocksDB, sans conteneur

| | Synapse + Postgres (NUC, Docker) | Pile du spike |
|---|---|---|
| Mémoire | ≈ 620 Mo | 50–110 Mo (Mac), 130–230 Mo (NUC), selon démarrage/repos |
| Démarrage | dizaines de secondes | 0,3–0,6 s |
| Disque | — | 220–260 Mo, presque tout en binaires |
| Installation, dossier vide | bootstrap Docker | **9 s sur Mac, 23 s sur Linux**, une commande, aucune question, aucun sudo |
| Chiffrement | possible | possible : toutes les API de clés répondent |
| Administration | `_synapse/admin` | **rien de compatible** : commandes dans le salon `#admins` |

Le contrepoint Synapse par `uv` n'a pas été fait : rien n'a bloqué.

## Ce qu'il faut changer dans l'app (une journée de Swift)

Les quatre appels `_synapse/admin` répondent 404 chez Continuwuity. Remplacements, tous
éprouvés en phase 1 :

| Appel | Remplacement |
|---|---|
| `isServerAdmin` | appartenance à `#admins:<serveur>` via `/joined_rooms` |
| `userExists` | `GET /_matrix/client/v3/profile/{id}` (standard, marche aussi chez Synapse) |
| `provisionUser` | `!admin users create` + `!admin users reset-password` sans `--logout` |
| `userDevices` (garde du second cc) | `!admin query users list-devices-metadata` — réponse en `Debug` Rust dans un bloc de code, à analyser |
| `makeRoomAdmin` | **aucun équivalent** ; à contourner par `!wa set-pl` du pont |

Il faut donc une petite couche « parler au salon d'administration » dans
`CorrespondanceMatrixClient` (`infra/relais-spike/salon-admin.py` en est le prototype).

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
2. **La couche `#admins`** dans le client, une journée.
3. **Le chantier E**, 6 à 9 jours.
4. **Les deux cartes** dans l'app : « sur ce Mac » lance l'installeur en mode `--json` et colle
   le code seule ; « machine à moi » affiche la commande et le champ du code.
5. **Notarisation et DMG**, puis TestFlight.
6. **Le push** : une passerelle Sygnal chez nous, quand un utilisateur externe a un iPhone.

Non testé : la branche « Tailscale présent » de l'installeur Linux (le NUC ne l'a pas en
natif). Dette : libolm reconstruite à la main ; le python système du Mac n'a pas PyYAML, donc
les configurations de ponts sont écrites sans fusion de gabarit.
