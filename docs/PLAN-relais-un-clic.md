# Plan — Un Relais en un clic : ce qu'on a trouvé, ce qu'on fait, ce qu'on garde pour plus tard

Suite du chantier R de `docs/PLAN-relais-agents.md`. Écrit le 2 septembre 2026, après une
session qui partait d'une question simple : *« si un nouvel utilisateur télécharge l'app, son
Mac est-il sa dépendance ? »* La réponse est oui, et ce document dit pourquoi, ce que Beeper
fait à la place, ce que ça coûte, et dans quel ordre on s'en sort — sans aller trop loin.

---

## 1. L'état des lieux, tel que le code le dit

**Un nouvel utilisateur n'a aucun moyen d'obtenir un Relais sans terminal.**

- Le seul installeur est `infra/matrix/install.sh`, dans le dépôt privé. Il n'est pas dans
  `correspondance-releases`, qui ne porte que l'installeur de cc. Son commit (`004cb3e`) le dit
  lui-même : le plan est éprouvé en `--dry-run`, **la pose n'a jamais tourné sur une vraie
  machine**.
- Il *vérifie* les prérequis (moteur de conteneurs, Tailscale) au lieu de les poser. Le plan
  disait « c'est *son* problème, plus celui de l'app » ; c'est devenu le problème de
  l'utilisateur.
- Côté app, Réglages › Matrix ne propose que « Connecter un Relais » (coller un code
  d'appairage) ou trois champs à la main. L'écran à trois cartes du plan n'existe pas.
  « Préparer la commande » concerne cc et suppose un Relais déjà là.
- L'iPhone est un client Matrix pur : sans Relais il ne sert à rien, et un Relais sur le Mac
  meurt avec le Mac (plus de `/sync`, plus de push, cc muet). iMessage reste natif au Mac dans
  tous les cas — c'est une dépendance au Mac allumé qu'aucun Relais ne lève.

**Pourquoi le chantier R a glissé.** Tout a été éprouvé contre le NUC, où le Relais existe
depuis le début : « créer un Relais » n'a jamais été sur le chemin critique d'un test. Le
journal des commits montre où est allé l'effort — cc, sa garde, ses sessions, sa fenêtre. Et
la règle « l'app ne fait tourner aucun serveur » a été lue comme « l'app n'a rien à faire »,
alors que le plan lui donnait les cartes et la phrase franche.

**Les autres marches avant une inbox qui vit sur l'iPhone**, par impact :

| # | Marche | État |
|---|---|---|
| 1 | Créer le Relais | script non publié, jamais éprouvé, prérequis à la charge de l'utilisateur |
| 2 | Tailscale sur l'iPhone | manuel, irréductible tant que le Relais n'est pas public (décision 6 de `PRODUCT.md`) — **l'iPhone seulement** : depuis la phase 7b, le Mac joint le Relais par Tailcat, que l'installeur pose et que l'app embarque |
| 3 | Push | Sygnal exige **notre** clé APNs ; le bootstrap la prend en variable, mode sandbox |
| 4 | iMessage sur iPhone | non décidé ; exige le Mac allumé quel que soit le plan |
| 5 | Distribuer l'app | ni DMG notarisé ni TestFlight ; l'app se lance depuis Xcode |
| 6 | Chiffrement | prévu v2 ; `encryption.allow: false` dans les quatre modèles de ponts, la base du NUC est en clair |

Lier les réseaux (QR WhatsApp, lien Signal, session Instagram/Messenger) est **déjà en un
clic** dans l'app — le plan disait que c'était là le vrai « clé en main », et c'est fait.

---

## 2. Décisions prises dans la session

1. **On n'héberge jamais de Relais pour les autres.** L'utilisateur le crée, sur son Mac ou
   sur une machine à lui. La carte « hébergé par nous » disparaît de l'écran d'accueil. C'est
   la question 1 « À trancher » de `PLAN-relais-agents.md`, tranchée.
2. **Le chiffrement reste en première ligne** malgré ça, parce qu'un script qui pose des
   conversations personnelles chez un tiers doit poser un Relais déjà chiffré. Nuance
   importante, § 4 : ce que le chiffrement protège ici est moins qu'on ne croit.
3. **Deux cartes, pas trois** : *sur ce Mac* / *sur une machine à moi*. Chacune dit sa vérité
   (« ton iPhone ne reçoit rien quand ce Mac dort » ; « le Mac s'y connecte tout seul, l'iPhone
   a encore besoin de Tailscale, un NUC chez toi est plus sûr qu'un serveur loué »).
4. **Pas de case « veux-tu chiffrer ? »** Là où c'est possible, c'est le défaut. Les vrais
   choix de l'utilisateur sont : où vit le Relais (R), la phrase de sauvegarde des clés et la
   vérification d'appareil (E), quels salons cc peut lire et quel moteur (A).
5. **On ne va pas trop loin.** Le plan disait « deux portes, dix utilisateurs, puis on
   voit ». On s'y tient : § 5 est le minimum, § 6 est ce qu'on garde en réserve.

---

## 3. Ce que Beeper fait — inspection du bundle 4.3.73 sur ce Mac

| Ce qu'on a regardé | Ce qu'on a vu |
|---|---|
| `Contents/Resources` | pas de homeserver, pas de binaire mautrix, pas de Docker |
| `beeper_client_sdk_napi_binding.node` (145 Mo) | **tous** les ponts mautrix en Go (whatsmeow, signal, meta, telegram, slack, discord, gmessages, twitter, linkedin) compilés dans **une** bibliothèque native chargée dans le processus Electron ; symboles `LocalBridge`, `bridgev2` |
| `~/Library/Application Support/BeeperTexts` | `local-whatsapp/megabridge.db`, `local-signal/megabridge.db` : un SQLite par pont local, session et clés d'appareil lié sur le Mac |
| `platform-imessage/darwin-arm64/IMessage.node` | iMessage par module natif, sans Messages.app |
| journaux | 408 appels vers `https://matrix.beeper.com/`, « hungryserv, @…:beeper.com : CONNECTED », `sygnal.beeper.com` pour le push |
| taille | 548 Mo le bundle |

**Conclusion.** Chez Beeper, « pont local » veut dire *la connexion à WhatsApp part de ton
appareil* ; les messages, eux, transitent par leur homeserver cloud (hungryserv, un par
utilisateur), et l'iPhone lit ce cloud, jamais le Mac. Un pont local ne vit que tant que
l'app est ouverte ; leur réponse au Mac fermé est un pont cloud payant. Leur « un clic »
repose entièrement sur le serveur chez eux — la porte qu'on a fermée.

**Ce qu'on peut reprendre** : les ponts comme binaires ou bibliothèque *sans conteneur*, un
SQLite chacun, lancés et surveillés par l'app comme cc l'est. **Ce que Beeper n'a pas eu à
résoudre et que nous devons résoudre** : poser le homeserver chez l'utilisateur.

---

## 4. Sécurité : ce que le chiffrement protège vraiment, et ce qui compte plus

« Inviolable » n'existe pas. Le niveau atteignable est celui d'un Beeper auto-hébergé ou
d'Element + mautrix : chiffré en transit (Tailscale = WireGuard, déjà), chiffré au repos,
machine possédée par l'utilisateur, aucun port public.

**Ce qu'aucun réglage n'enlève**

- **Le pont lit en clair, par construction.** C'est un appareil lié WhatsApp/Signal : il
  déchiffre pour traduire, sur la même machine que le Relais. Le E2EE app ↔ Relais ne le
  concerne pas. Toute architecture à ponts a cette frontière ; la machine du Relais *est* la
  frontière de confiance.
- WhatsApp, Meta, Signal voient ce qu'ils voient déjà.
- Un VPS est physiquement chez un hébergeur (disque, mémoire d'un conteneur). Le disque
  chiffré protège à froid, pas à chaud. Un NUC à la maison est plus sûr, et l'app peut le dire.

**Ce que le chiffrement protège vraiment**

- Les salons natifs (note à soi, salons d'agents, état de conversation) : le Relais ne voit
  que du chiffré.
- La base sur le disque : avec le chiffrement des portails côté ponts, Synapse stocke du
  chiffré ; une sauvegarde qui fuit ou un disque volé ne livrent pas l'historique.
  Aujourd'hui `encryption.allow: false` partout et la base du NUC est en clair.

**Ce qui est plus grand que le chiffrement, dans ce projet précis**

- **cc envoie les conversations à un moteur en ligne** (API Claude, Codex…). C'est le plus
  gros flux de données personnelles hors machine, et le E2EE n'y change rien : cc est un
  appareil vérifié. Les bornes réelles : palier d'outils, portée par salon, plafond de tours.
  « cc lit ce salon » doit être un choix par conversation, **éteint par défaut sur les
  portails**.
- **L'injection par message** : un contact peut donner des instructions à cc. La règle du MCP
  (contenu non fiable ; pas d'envoi dans le même tour qu'une lecture) vaut pour cc.
- **Chaîne d'approvisionnement** : images et binaires épinglés (bien), sans somme de contrôle
  vérifiée (à faire).
- Un agent en pleine permission sur la machine des conversations est un accès plus large
  qu'une faille réseau ; ses trois bornes comptent autant que le chiffrement.

**Petit mais à faire** : le champ « ou à la main » avec mot de passe disparaît une fois
l'appairage éprouvé ; sauvegarde des clés protégée par une phrase (sinon un iPhone perdu perd
l'historique) ; la passerelle push, si elle est chez nous, voit *qui reçoit et quand* — à
écrire dans la politique de confidentialité.

**La phrase tenable pour l'app** : *« tes conversations ne quittent ta machine que pour les
réseaux qui les ont déjà, et pour les agents que tu as autorisés, salon par salon »*.

---

## 5. Le minimum pour un premier utilisateur externe (≈ 5 jours)

Le plan disait « pas avant dix utilisateurs ». Ces dix-là ont une machine à eux par
définition ; la carte « sur ce Mac » n'est pas nécessaire pour eux.

1. **Publier l'installeur distant** (2 j). `infra/matrix/install.sh` part dans
   `correspondance-releases` à côté de celui de cc. Sur Linux il **pose** ce dont il a besoin
   au lieu de le vérifier — et depuis la phase 7b, ce n'est plus ni Docker ni Tailscale mais
   **Tailcat** : pas de compte, pas de tailnet, pas de sudo. Le code d'appairage porte son
   jeton, et le Mac s'y connecte tout seul. Il finit sur une preuve (« le Relais répond ») et le code
   d'appairage — jamais « installé » sans preuve, leçon de l'installeur de cc. **Éprouvé une
   fois sur un VPS vierge**, ce qui n'a jamais été fait.
2. **Chiffrement des portails** (1 h + test). `encryption.allow/default: true` dans les quatre
   modèles de ponts ; vérifier que l'app lit encore les salons. Le E2EE complet côté app
   (`CorrespondanceCrypto`, 5–8 j) reste au plan, il ne bloque pas un premier utilisateur.
3. **L'écran d'accueil** (1 j). Sans Relais, le champ du code d'appairage devient l'écran
   d'accueil, avec la commande à copier à côté et la phrase qui dit la vérité qui reste :
   « le Mac s'y connecte tout seul ; l'iPhone a encore besoin de Tailscale ». La carte
   « sur ce Mac » est présente mais dit « bientôt » — ou demande OrbStack, franchement.
4. **Un DMG notarisé** (1 j). Sans, personne ne teste.

Le NUC ne bouge pas. Le push attend qu'un utilisateur externe ait un iPhone.

---

## 6. En réserve — quand quelqu'un le demande

### R2 — La carte « sur ce Mac » sans Docker

Poser Docker en silence sur un Mac est impossible (OrbStack/Docker Desktop : installeur
graphique + mot de passe admin ; Homebrew aussi). La pile Mac doit se passer de conteneurs :

- **Ponts** : binaires Go épinglés, un SQLite chacun, processus enfants de l'app (comme cc)
  ou agents launchd. Rien à inventer.
- **Homeserver** : Synapse par `uv` (installe son Python sans droits admin) + SQLite, dans
  `~/Library/Application Support/Correspondance/Relais`, en agent launchd pour survivre à la
  fermeture de l'app. Postgres disparaît. Sygnal disparaît si la passerelle est chez nous.
- **Tailscale** reste manuel (App Store) **sur l'iPhone** ; la carte l'explique. Sur le Mac,
  il n'est plus nécessaire : Tailcat est embarqué dans l'app depuis la phase 7b, et une app
  iPhone ne peut pas en faire autant (`Process` n'existe pas, et CFNetwork n'y offre pas de
  mandataire SOCKS — cf. `docs/spike-un-clic/phase-7a.md` § 3).
- Téléchargé une fois à l'installation (~250 Mo : Python + Synapse 150, quatre ponts 100),
  **le bundle ne grossit pas**.

Poids et vitesse, mesurés sur le NUC le 2 sept. 2026 (`docker stats`) :

| Composant | Mémoire | CPU au repos |
|---|---|---|
| Synapse, 1 utilisateur (Postgres) | 340 Mo | 0,5 % |
| Synapse d'essai, vide | 120 Mo | 0,2 % |
| Postgres | 220 Mo → 0 avec SQLite | |
| mautrix whatsapp / meta / messenger | 12–30 Mo chacun | 0 % |
| mautrix signal | 62 Mo | 0 % |
| Sygnal | 39 Mo → 0 si chez nous | |

Attendu sur un Mac : 300–450 Mo hors de l'app, en processus séparés. L'app ne change pas
(même `/sync`, adresse `127.0.0.1`, latence en baisse). Bundle Correspondance : 49 Mo en
Debug, contre 548 Mo pour Beeper. Le coût visible : le téléchargement initial et quelques
secondes au premier démarrage.

### R3 — Un homeserver plus léger que Synapse (spike d'une demi-journée)

Continuwuity (ex-conduwuit) est un binaire Rust de ~30 Mo qui démarre en une seconde et
annonce le support des application services — ce que `PLAN-relais-agents.md` refusait aux
mono-binaires. **À éprouver, pas à lire** : brancher mautrix-whatsapp dessus sur le Relais
d'essai. Si ça tient, le Relais devient cinq binaires et ~200 Mo, sur Mac comme sur Linux,
et le bootstrap Docker du NUC peut disparaître à terme. Sinon, Synapse par `uv` reste la voie.

### Un seul DMG, quoi qu'il arrive

- **Pile embarquée** : les cinq binaires dans le bundle, signés et notarisés avec lui (comme
  Beeper embarque ffmpeg). DMG ≈ 200 Mo au lieu de 49. Rien à télécharger, la carte « sur ce
  Mac » marche hors ligne, la version du Relais est celle de l'app. Possible seulement si le
  homeserver est un binaire (Continuwuity) : Synapse et son Python ne se mettent pas
  proprement dans un bundle notarisé.
- **Pile téléchargée au premier clic** : DMG à 49 Mo, 150–250 Mo tirés à la demande,
  épinglés par version et somme de contrôle. La voie si on garde Synapse.
- La carte « machine à moi » n'a pas de DMG : la commande télécharge les mêmes binaires sur la
  machine distante. Un seul dépôt de releases porte l'app et la pile.

### R4 — Distribution par catalogues

Le public réel d'un Relais chez soi est celui d'Umbrel, Start9, Home Assistant (le NUC en
fait tourner). Une app Umbrel/Start9 pose le Relais en un clic sur leur boîte, sans SSH. Des
hébergeurs à bouton (PikaPods, Elestio) déploient une image facturée à l'utilisateur, machine
à lui contractuellement — élargit un peu, mais Tailscale iPhone reste, sauf Relais public
(vrai domaine + certificat = chantier de plus).

### R5 — Déménager

Un Relais commencé sur le Mac qui part sur une machine à soi : même pile → copie de dossier ;
Synapse SQLite → Postgres : outil d'export. À promettre sur la carte seulement quand ça existe.

### P — Push

Une seule passerelle Sygnal chez nous, notre clé APNs, pour tous les Relais. Ce n'est pas
héberger un Relais : elle ne voit qu'un identifiant de salon et un compteur. Embarquer la clé
dans l'installeur est exclu (elle deviendrait publique). À écrire dans la politique de
confidentialité.

---

## 7. La posture, écrite noir sur blanc

**Ce n'est pas une app pour madame tout le monde tant que le serveur est chez
l'utilisateur.** Madame tout le monde n'installera pas Tailscale sur son iPhone, ne louera
pas un serveur, ne laissera pas son Mac allumé. Beeper est grand public *parce que* le serveur
est chez eux ; aucune astuce d'installation ne contourne ça. Le public visé est celui qui a
déjà une machine allumée et sait pourquoi — réel, fidèle, petit. Le code d'appairage et le
chiffrement sont conçus pour qu'une porte « hébergé » puisse s'ouvrir plus tard sans rien
refaire ; on ne l'ouvre pas, et on n'écrit pas « grand public » sur le produit.
