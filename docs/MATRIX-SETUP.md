# Matrix, WhatsApp, Instagram, Messenger & Signal — installation, usage, dépannage

Correspondance parle WhatsApp, Instagram, Messenger et Signal par des ponts : un homeserver
**Synapse** privé et les bridges **mautrix**, tous sur le NUC, joints depuis le Mac par Tailscale.
Seul iMessage reste natif et ne passe pas par là.

```
                                                 ┌─► mautrix-whatsapp  ──► WhatsApp
                                                 ├─► mautrix-instagram ──► Instagram DM
Mac (Correspondance) ──Tailscale──► Synapse ─────┤
                       100.64.0.7:8008       ├─► mautrix-facebook  ──► Messenger
                                                 └─► mautrix-signal    ──► Signal
```

Un seul `/sync` côté app pour les quatre ponts (même homeserver), mais **un salon de gestion par
pont** : `@whatsappbot`, `@instagrambot`, `@messengerbot` et `@signalbot` ne se parlent pas.

### Par où le Mac joint le Relais

Le schéma ci-dessus est celui de **la prod** : le NUC, Synapse, Docker, et Tailscale pour
traverser. Le Relais « un clic » (`infra/relais/install.sh`, `docs/spike-un-clic/`) prend un
autre chemin depuis la phase 7b, et c'est celui qui sera livré :

| | Prod (ce document) | Relais un clic |
|---|---|---|
| Depuis le Mac | Tailscale (compte, tailnet, extension système) | **Tailcat** — WireGuard sans plan de contrôle : ni compte, ni tailnet, ni démon privilégié, ni sudo |
| Ce que l'utilisateur pose | Tailscale, à la main, avec sudo | rien : l'installeur pose Tailcat sur le Relais, l'app l'embarque |
| Ce qui porte l'adresse | une IP `100.x` à recopier | le code d'appairage, qui porte le jeton |
| Depuis l'iPhone | Tailscale | **Tailscale encore** : `Process` n'existe pas sur iOS et CFNetwork n'y offre pas de mandataire SOCKS (`docs/spike-un-clic/phase-7a.md` § 3) |

Un homeserver n'écoute que sur `127.0.0.1` dans les deux cas — un homeserver ouvert sur
l'Internet est une porte. Ce qui change, c'est ce qu'il faut monter pour le traverser.

## Essayer de bout en bout, sans rien risquer

Tout ce qui suit tourne **à côté** de la prod, jamais dedans : un Synapse d'essai sur le
port 8009, un jeu de données et une session à part. Ton Relais, tes conversations et tes
ponts ne sont touchés à aucune étape. Compter vingt minutes.

Deux isolations, et elles sont indépendantes :

| | Prod | Essai |
| --- | --- | --- |
| Relais | `correspondance.local`, port 8008, avec les ponts | `correspondance.essai`, port 8009, Synapse seul |
| Projet Docker | `correspondance-matrix` | `correspondance-essai` |
| Données de l'app | `~/Library/Application Support/Correspondance` | `…/Correspondance-essai` |
| Session (Trousseau) | `app.correspondance.matrix` | `app.correspondance.matrix.essai` |

**Pas de ponts dans l'essai, exprès** : un pont mautrix est une session d'appareil lié, un
second pont sur le même compte WhatsApp débrancherait le vrai. Rien de ce qu'on éprouve
ici n'en a besoin.

### 1. Monter le Relais d'essai

```bash
infra/matrix/essai/essai.sh --dry-run up   # facultatif : montre sans rien faire
infra/matrix/essai/essai.sh up
```

**Ce que tu dois voir** : la configuration générée, les conteneurs `correspondance-essai-*`
qui démarrent, « prêt », les comptes `@essai` (propriétaire) et `@cc` (bot), puis un code
`correspondance://relais/…` avec six mots de vérification.

**Si le Relais d'essai tourne ailleurs que l'app** (sur le NUC, par exemple) : il ne publie
son port que sur `127.0.0.1`, exprès — un Relais d'essai n'a rien à faire sur le réseau. Il
faut donc un tunnel, à laisser ouvert pendant tout l'essai :

```bash
ssh -N -L 8009:127.0.0.1:8009 nuc     # dans un terminal à part
```

Le code d'appairage émis sur le NUC contient déjà `http://127.0.0.1:8009` : côté Mac, une
fois le tunnel ouvert, il est juste.

Si `docker` n'est pas là, le script s'arrête et le dit. La prod n'est pas touchée : toutes
les commandes portent `-p correspondance-essai` (vérifié par
`infra/matrix/tests/essai-isolation.sh`).

### 2. Lancer l'app sur le jeu d'essai

```bash
CORRESPONDANCE_HOME=essai open -a Correspondance
```

Depuis Xcode : Product › Scheme › Edit Scheme › Run › Arguments › Environment Variables,
`CORRESPONDANCE_HOME` = `essai`.

**Le piège qui fait perdre une heure** : deux copies du dépôt (`main` et un worktree)
partagent le même DerivedData. Un build sur l'une écrase le binaire de l'autre, et on lance
alors une app **qui n'a pas le code qu'on teste** — sans que rien ne le signale. Donne un
DerivedData à la branche :

```bash
xcodebuild -project Correspondance.xcodeproj -scheme Correspondance \
  -configuration Debug -derivedDataPath /tmp/dd-essai build
open /tmp/dd-essai/Build/Products/Debug/Correspondance.app --env CORRESPONDANCE_HOME=essai
```

Au moindre doute sur ce qui tourne : `ls -l` sur le binaire et compare l'heure au build.

**Ce que tu dois voir** : une inbox **vide**, et dans Réglages › Matrix un encart « Essai »
qui nomme le jeu de données. Si tu vois tes vraies conversations, la variable n'est pas
passée — ferme l'app et recommence, ne va pas plus loin.

### 3. S'appairer

Réglages › Matrix › **Connecter un Relais** : colle le code de l'étape 1.

**Ce que tu dois voir** : les six mots affichés sous le champ, **identiques** à ceux du
terminal ; puis « Synchronisé avec le Relais », et **une conversation « Note à soi »** dans
l'inbox. L'app la crée à l'appairage : un Relais neuf n'a aucune conversation, et sans elle
il n'y aurait nulle part où parler à cc.

Si les mots diffèrent, tu appaires autre chose que ce que tu viens d'installer — n'y va pas.

### 4. Activer cc

Réglages › Agent › **Sur ce Mac** › « Activer sur ce Mac ».

**Ce que tu dois voir** : « démarré, il n'a pas encore publié son premier status », qui
passe à « actif — cc répond tant que Correspondance est ouverte » dans la minute.

cc tourne **dans l'app**, comme processus enfant : il redémarre s'il tombe, il s'arrête
quand tu quittes Correspondance. Il n'y a plus ni approbation macOS ni Éléments d'ouverture
— l'enquête qui a mené à ce choix est dans `docs/AGENT.md`, § « Pourquoi cc ne tourne pas
en LaunchAgent ».

« Actif » n'est jamais une lecture d'un drapeau : il faut le binaire dans le bundle, le
processus vivant, l'amorce sur le disque **et** un status récent. Les autres états ont
chacun leur sortie — « l'amorce n'est pas sur le disque » → *Réparer* ; « muet depuis… » →
le journal ; « cette build n'embarque pas l'agent » → *Pourquoi ?*.

Puis, dans la note à soi : `@cc ping`. **Ce que tu dois voir** : une réponse en moins d'une
minute, et un tour de plus dans « Derniers tours ». Le journal de l'agent s'ouvre depuis les
réglages, ou `tail -f /tmp/correspondance-cc.log`.

**Le dossier d'amorce suit l'essai** (corrigé en phase 4 du spike « un clic » ; avant, il ne
le suivait pas et il fallait sauter cette étape). « Activer sur ce Mac » écrit l'amorce de
`cc` dans `~/.correspondance-agent/`, et sous `CORRESPONDANCE_HOME=unclic` dans
`~/.correspondance-agent-unclic/` — le même suffixe que le dossier de données et que
l'entrée du Trousseau. L'agent, lancé par l'app, hérite de la variable et recalcule le même
chemin ; le journal suit aussi (`/tmp/correspondance-cc-unclic.log`). Le cc de production
n'est donc jamais touché par un essai. Pour le vérifier :

```bash
ls ~/.correspondance-agent/config.json 2>/dev/null && echo "un cc de production vit ici"
ls ~/.correspondance-agent-unclic/config.json 2>/dev/null && echo "et celui de l'essai, là"
```

### 5. Brancher `correspondance-mcp` dans Claude Desktop

```bash
swift build --package-path Packages/CorrespondanceCore --product correspondance-mcp -c release
swift build --package-path Packages/CorrespondanceCore --product correspondance-mcp -c release --show-bin-path
```

Dans `~/Library/Application Support/Claude/claude_desktop_config.json` :

```json
{
  "mcpServers": {
    "correspondance-essai": {
      "command": "/CHEMIN/RENDU/PAR/show-bin-path/correspondance-mcp",
      "env": {
        "CORRESPONDANCE_MCP_CONFIG": "/Users/TOI/.correspondance-agent/config.json"
      }
    }
  }
}
```

Vérifie d'abord en ligne de commande — c'est plus rapide qu'un redémarrage de Claude :

```bash
CORRESPONDANCE_MCP_CONFIG=~/.correspondance-agent/config.json   /CHEMIN/correspondance-mcp --doctor
```

**Ce que tu dois voir** : `✓ connecté comme @cc:correspondance.essai — N conversation(s)`,
puis `envoi : aucune conversation autorisée (on propose des brouillons)`.

Redémarre Claude Desktop, puis demande-lui : « qu'est-ce qui attend une réponse ? », « lis
la conversation !… », « prépare une réponse ». **Ce que tu dois voir** : la file, les
messages encadrés par un avertissement disant que c'est de la donnée, et un brouillon qui
apparaît dans l'app **sans que rien ne parte**. Demande-lui d'envoyer pour de bon : il doit
**refuser** et renvoyer vers `draft_reply`.

Pour autoriser l'envoi dans une conversation précise, ajoute à `env` :
`"CORRESPONDANCE_MCP_SEND": "!salon:correspondance.essai"`.

### 6. Tout effacer

```bash
infra/matrix/essai/essai.sh destroy
rm -rf ~/Library/Application\ Support/Correspondance-essai
```

Puis, dans Trousseau d'accès, supprimer l'entrée **`app.correspondance.matrix.essai`** —
celle sans suffixe est ta vraie session, ne la touche pas. Et si tu as activé cc :
Réglages › Agent › « Désactiver », ou `rm -rf ~/.correspondance-agent`.

`destroy` n'agit que sur le projet `correspondance-essai` : la prod est hors de portée par
construction, pas par prudence.

### Ce qui n'a jamais tourné

Le squelette est éprouvé (`infra/matrix/tests/essai-isolation.sh`, 24 contrôles : les
quatre isolations, l'absence de pont, la garde du projet sur chaque commande docker,
l'effacement). **La pose elle-même n'a jamais tourné** : aucun `essai.sh up` n'a démarré un
Synapse pour de bon depuis ce dépôt. À découvrir la première fois — la génération de
`homeserver.yaml` et son passage à Postgres, le temps de démarrage réel, et la création des
comptes par `register_new_matrix_user` dans ce conteneur-là.

## Installer un Relais ailleurs (`install.sh`)

Le montage décrit plus bas est celui du NUC de meffysto, avec ses adresses. Pour poser un
Relais **ailleurs** — sur un Mac, sur une machine Linux, sur un VPS — il y a une commande :

```bash
infra/matrix/install.sh --target this-mac
infra/matrix/install.sh --target linux
infra/matrix/install.sh --target ssh --host nuc
infra/matrix/install.sh --target ssh --host vps --dry-run   # montre sans rien faire
```

Elle enchaîne : prérequis (moteur de conteneurs, Tailscale) → Synapse et les ponts →
adaptateur ACP épinglé → **code d'appairage**. L'app le lit dans « Connecter un Relais »,
et six mots permettent de vérifier qu'on appaire bien cette machine-là.

`install.sh` **ne remplace pas `bootstrap.sh`** : il l'appelle. `bootstrap.sh` tourne en
production et reste la pièce qui pose Synapse et les ponts ; `install.sh` fait ce qu'il ne
faisait pas — détecter l'hôte, poser les prérequis, épingler l'adaptateur, finir sur le
code d'appairage.

### Ce qui est vérifié, et ce qui ne l'est pas

**Vérifié, et rejouable** : `infra/matrix/tests/install-plan.sh` éprouve le plan produit
pour les trois cibles (18 contrôles) — que la pile est posée localement ou par SSH selon la
cible, que la version de l'adaptateur est épinglée, que le code d'appairage vient en
dernier, qu'une cible inconnue ou un `--target ssh` sans `--host` sont refusés. `pair.sh`
est éprouvé sur ses refus (jeton illisible, jeton périmé).

**Jamais tourné sur une vraie machine** : l'installation complète. Ni `--target this-mac`,
ni `--target linux`, ni `--target ssh` n'ont posé un Synapse pour de bon depuis ce script.
Ce qui reste à découvrir la première fois, et qu'il faudra corriger sur pièces :

- l'installation du moteur de conteneurs sur un Mac vierge (le script s'arrête et dit quoi
  installer — il ne l'installe pas tout seul, exprès) ;
- `bootstrap.sh --remote` exécuté sur macOS : il a été écrit pour Debian, et
  `docker-compose` 1.29 y est supposé ;
- l'adresse publique quand Tailscale n'est pas là (il faut alors `PUBLIC_URL=`) ;
- la création du compte propriétaire par `pair.sh` quand le compte existe déjà — le chemin
  de repose du mot de passe n'a jamais été emprunté.

Autrement dit : le squelette et les décisions sont éprouvés, la pose ne l'est pas. À faire
tourner une première fois sur une machine jetable avant de le donner à quelqu'un.

## 0. Ce qui tourne déjà, et où

Sur le NUC (`ssh nuc`, user `meff`, **pas de sudo**, `docker-compose` 1.29 — jamais `docker compose`) :

| Conteneur | Image | Rôle |
| --- | --- | --- |
| `correspondance-synapse` | `matrixdotorg/synapse` | homeserver, `server_name: correspondance.local` |
| `correspondance-postgres` | `postgres:16-alpine` | base de Synapse et des bridges |
| `correspondance-mautrix-whatsapp` | `dock.mau.dev/mautrix/whatsapp:v26.08` | pont WhatsApp (tag **épinglé**) |
| `correspondance-mautrix-meta` | `dock.mau.dev/mautrix/meta:ig-v26.08` | pont Instagram (tag **épinglé**, préfixe `ig-`) |
| `correspondance-mautrix-messenger` | `dock.mau.dev/mautrix/meta:v26.08` | pont Messenger (tag **épinglé**, **sans** `ig-`) |
| `correspondance-mautrix-signal` | `dock.mau.dev/mautrix/signal:v26.08` | pont Signal (tag **épinglé**) |

Depuis la v26.08, `mautrix-meta` ne fait plus que Messenger : Instagram est passé au binaire
`mautrix-instagram`, publié sur **la même image Docker** avec un tag préfixé `ig-`. Dans cette
variante le binaire s'appelle toujours `/usr/bin/mautrix-meta`, mais `--version` répond bien
« mautrix-instagram v26.08 » : l'entrypoint standard `/docker-run.sh` fonctionne tel quel.

D'où **deux conteneurs de la même image** : `:ig-v26.08` pour Instagram, `:v26.08` pour Messenger
(où `/usr/bin/mautrix-meta --version` répond « mautrix-facebook v26.08 »). Deux bases Postgres
(`mautrix_meta`, `mautrix_messenger`), deux ports d'appservice (29330, 29331), deux bots. Les deux
réseaux de Meta ne partagent plus rien : se connecter à l'un ne connecte pas l'autre.

L'ancien `network.mode` (`facebook` / `messenger` / `facebook-tor`) **n'existe plus** en v26.08 —
le binaire décide du réseau, le config ne garde qu'un `network.tor` booléen. Rien à choisir donc,
mais quatre *flows* de connexion côté bot (voir § 2 ter).

Tout vit dans `~/correspondance-matrix/` : configs générées, données, et `CREDENTIALS.txt`
(chmod 600) qui contient le mot de passe du compte `@meffysto:correspondance.local`. Ce fichier ne
quitte jamais le NUC et n'est pas versionné.

Les sources d'infra sont dans `infra/matrix/` (compose, templates, `bootstrap.sh`). Le script est
idempotent : `./infra/matrix/bootstrap.sh` depuis le Mac recopie et réapplique tout sans dégât.

Chaque pont a sa base Postgres (`mautrix_whatsapp`, `mautrix_meta`) et sa registration côté
Synapse (`whatsapp-registration.yaml`, `meta-registration.yaml`). `bootstrap.sh` les installe par
la même fonction `setup_bridge` : config par défaut → fusion des overlays du repo → registration.

### Pourquoi `127.0.0.1:8008` mais un accès en `100.64.0.7:8008`

Tailscale tourne sur le NUC en **userspace-networking** : il n'y a aucune interface `tailscale0`,
donc l'IP `100.64.0.7` n'est pas assignable en `bind`. `tailscaled` relaie lui-même le trafic
entrant du tailnet vers le `127.0.0.1` de l'hôte. Synapse écoute donc en loopback
(`ports: 127.0.0.1:8008->8008`) et reste joignable depuis n'importe quelle machine du tailnet en
`http://relais.exemple.ts.net:8008`, sans jamais être exposé sur le LAN 192.168. C'est voulu : ne pas
« corriger » ce bind en `0.0.0.0`.

Vérification depuis le Mac :

```sh
curl -s http://relais.exemple.ts.net:8008/_matrix/client/versions | head -c 120
```

## 1. Connexion dans l'app

**Correspondance › Réglages › Matrix** :

1. **Homeserver** : `http://relais.exemple.ts.net:8008` (pré-rempli).
2. **Identifiant** : `meffysto` (pré-rempli). Le MXID complet est `@meffysto:correspondance.local`.
3. **Mot de passe** : celui de `~/correspondance-matrix/CREDENTIALS.txt` sur le NUC.
4. **Connexion**. L'app ping d'abord le homeserver — un mot de passe n'est jamais envoyé à une
   mauvaise adresse.

Le jeton d'accès part dans le **Trousseau** (jamais dans UserDefaults, jamais dans le repo). La
ligne « État » affiche ensuite le MXID connecté et le décompte des fils par réseau
(« 12 WhatsApp · 3 Instagram »). **Déconnecter Matrix** révoque le jeton côté serveur, vide le Trousseau et le cache disque des conversations.

### Chiffrement

> Écrit à la phase 5 du spike « un clic » (`docs/spike-un-clic/phase-5.md`). Sur le Relais
> **historique** (Synapse du NUC), rien de tout ceci n'est allumé : ses salons de bridge sont
> créés non chiffrés (`encryption.allow: false`). Ce qui suit décrit le Relais que
> `infra/relais/install.sh` pose, où les portails sont chiffrés par défaut.

**Un seul drapeau, et il est dans le manifeste.** `CORRESPONDANCE_CRYPTO=1` à la construction
ajoute `matrix-sdk-crypto-ffi` (XCFramework Apple, version épinglée et vérifiée par somme) et
les cibles qui vont avec. Sans lui, le paquet est celui d'avant : aucune dépendance binaire
résolue, et `correspondance-agent` se construit sous Linux, où l'XCFramework n'existe pas.

```
swift build                                   # sans chiffrement
CORRESPONDANCE_CRYPTO=1 swift build \
  --scratch-path /tmp/build-crypto            # avec
```

Le `--scratch-path` séparé n'est pas une coquetterie : les deux configurations qui partagent un
`.build` laissent un module de la précédente traîner, et le `#if canImport` reste vrai.

**Le drapeau se garde partout, y compris sur `xcodebuild`.** Un `DerivedData` résolu une fois
avec `CORRESPONDANCE_CRYPTO=1` ne se reconstruit plus sans lui : la résolution du paquet y a
inscrit les cibles binaires, et le build suivant s'arrête sur `unable to resolve module
dependency: 'MatrixSDKCryptoFFI'` — trois fois, plus une par cible. Ce n'est pas une régression
du code, c'est un `DerivedData` qui se souvient. Deux issues : reposer le drapeau sur **toutes**
les commandes de ce dossier (`build`, `test`, `build-for-testing`, `scripts/test.sh`,
`scripts/test-ios.sh`), ou donner à chaque configuration son propre `-derivedDataPath`, comme
`--scratch-path` le fait pour SwiftPM. Mesuré à la phase 7b, revu à la fusion.

**`CORRESPONDANCE_CHIFFREMENT=1` n'est plus requis.** Il l'était pendant que le chantier était
commencé et pas fini ; le garder livrerait une app dont le chiffrement est éteint chez tout le
monde. Un binaire construit avec la crypto chiffre. `CORRESPONDANCE_CHIFFREMENT=0` reste lu
comme **soupape** — revenir au comportement d'avant sans reconstruire — pour l'app comme pour
`cc`, et l'écran des réglages le dit quand elle est tirée.

**Ce que le chiffrement couvre.**

| | |
|---|---|
| Salons natifs (note à soi, console d'agent, ateliers) | chiffrés de bout en bout, Megolm |
| Portails de ponts | chiffrés **jusqu'au pont**, qui déchiffre pour traduire — jamais du bout en bout, et la fiche de conversation le dit |
| `correspondance-agent` sur macOS | lit et écrit chiffré ; magasin sous `~/.correspondance-agent[-essai]/crypto/` |
| `correspondance-agent` sur Linux | **en clair** : la bibliothèque Rust n'est pas encore construite pour Linux (recette dans `phase-5.md`) |
| Extension de notification iOS | déchiffre, **si** l'App Group `group.com.correspondance` existe ; sinon elle affiche « Message chiffré — ouvre Correspondance » |

**La phrase de récupération.** La sauvegarde des clés (`m.megolm_backup.v1.curve25519-aes-sha2`)
se crée depuis une phrase ; le sel et le nombre de tours PBKDF partent dans `auth_data`, ce qui
permet à un appareil neuf de redériver la même clé avec la seule phrase et de lire l'historique
d'avant sa création. Sans elle, un appareil ajouté ne voit pas le passé — c'est le comportement
de Megolm, pas un défaut.

Deux pièges d'exploitation, mesurés :

- **Continuwuity ne rend pas la version la plus récente** à `GET /room_keys/version`, alors
  qu'il n'autorise à écrire que dans la dernière créée. Remplacer une sauvegarde exige donc de
  retirer **toutes** les versions, pas seulement celle qu'il nomme.
- **`POST /keys/device_signing/upload` ne passe sans authentification que sur un compte
  vierge.** Dès qu'il porte des clés de signature, il faut le mot de passe (authentification
  interactive) : remplacer la clé maîtresse, c'est remplacer l'identité du compte.

**Le magasin de clés** vit sous le dossier de données de l'app (donc déplacé d'un bloc par
`CORRESPONDANCE_HOME`), et sous le conteneur d'App Group sur iOS quand il existe. Le perdre,
c'est perdre l'historique chiffré de cet appareil — sauf si la sauvegarde est faite.

## 2. Connecter WhatsApp — le QR

Une fois Matrix connecté, **Réglages › Matrix › Connecter WhatsApp…**.

Ce qui se passe : l'app ouvre (ou retrouve) le DM de gestion avec `@whatsappbot:correspondance.local`,
y envoie `login qr`, puis interroge le salon jusqu'à voir la réponse du bot. Le bot poste un
`m.image` ; l'app le télécharge par l'endpoint **média authentifié**
`/_matrix/client/v1/media/download/…` (`Authorization: Bearer …` — obligatoire depuis Matrix 1.11,
avec repli sur l'ancien `/_matrix/media/v3/download` pour les Synapse plus vieux) et l'affiche dans
la feuille.

Sur le téléphone : **WhatsApp › Réglages › Appareils liés › Lier un appareil**, puis scanner.

- Le QR n'est valable que quelques dizaines de secondes ; le bot en renvoie un nouveau tant que le
  login n'a pas abouti. Le bouton **Relancer** de la feuille redemande un QR au bot.
- Au succès, le bot annonce « Successfully logged in » et le backfill démarre : les conversations
  WhatsApp apparaissent dans l'inbox au fil des `/sync`. Le premier remplissage prend quelques minutes.
- **Fermer** la feuille arrête l'interrogation, mais **n'annule pas** un login en cours côté bridge.
  Pour l'annuler franchement, envoyer `cancel` au bot (voir plus bas).

### Repli : code d'appairage (`login phone`)

Si le QR est refusé (caméra capricieuse, écran illisible, WhatsApp qui boude), mautrix-whatsapp
v26.08 accepte l'appairage par numéro. Dans le DM avec `@whatsappbot`, envoyer :

```
login phone +33612345678
```

Le bot répond un code à 8 caractères, à saisir dans **WhatsApp › Appareils liés › Lier avec un
numéro de téléphone**. La feuille de l'app affiche ce code si elle est ouverte ; sinon, Element Web
pointé sur `http://relais.exemple.ts.net:8008` fait très bien l'affaire pour dialoguer avec le bot.

### Ouvrir un fil vers un numéro

`NewConversationSheet` (WhatsApp sélectionnable seulement si Matrix est connecté) envoie au bot la
commande `pm +33612345678`. Le bot crée le portail et le salon arrive au `/sync` suivant.

## 2 bis. Connecter Instagram — la fenêtre de connexion

Meta n'offre aucun appairage par QR pour les DM Instagram : `mautrix-instagram` se connecte avec
les cookies d'une session de navigateur déjà ouverte. C'est le seul flow que le bridge expose
(`login` → étape `fi.mau.meta.cookies`). Côté app, personne n'a à voir un cookie pour autant.

**Réglages › Matrix › Connecter Instagram…** ouvre la feuille : l'app envoie `login` à
`@instagrambot:correspondance.local`, et affiche **le vrai formulaire instagram.com** dans une
`WKWebView` intégrée. On s'y connecte normalement — identifiant, mot de passe, 2FA, captcha
éventuel. Dès que la session existe, l'app lit les cookies du navigateur intégré, en fabrique
l'objet JSON attendu et l'envoie au bot. Le statut passe par « Connecte-toi à Instagram dans la
fenêtre. » puis « Session récupérée, envoi au pont… ».

Ce que la fenêtre garantit :

- **Magasin de données non persistant et dédié** (`WKWebsiteDataStore.nonPersistent()`) : la
  session Safari de l'utilisateur n'est ni lue ni polluée, et rien ne reste sur le disque à la
  fermeture de la feuille. La session vit désormais côté pont, c'est son travail.
- **User-Agent Safari macOS** : Instagram sert une page dégradée à un WebKit nu.
- Les cookies ne sont **ni journalisés ni stockés** par l'app ; le message envoyé au salon de
  gestion est **rédigé** par le bot juste après lecture.

Les cinq clés que le bot réclame — `sessionid`, `csrftoken`, `ds_user_id`, `mid`, `ig_did` — sont
toutes posées par instagram.com au cours d'une connexion normale ; `rur`, `shbid` et `shbts`
partent en plus quand elles existent. La détection attend `sessionid` + `ds_user_id` +
`csrftoken` : avant ce trio, on est encore dans le formulaire ou la 2FA.

Au succès, le bot répond « Logged in as <nom> (<id>) » et le backfill démarre. Les échecs sont
explicites : `Missing some keys: [...]`, `Failed to parse input as JSON`,
`Login failed: Challenge/Checkpoint/Consent required` (Instagram demande une vérification — la
faire sur le site officiel, puis **Relancer**).

### Repli : coller les cookies à la main

Si Meta finit par bloquer le navigateur intégré (page blanche, refus persistant), la feuille
garde un volet replié **« Coller des cookies… »**. Dans un navigateur connecté à instagram.com :

1. Outils de développement (⌥⌘I) → onglet **Application** (Chrome) / **Stockage** (Firefox).
2. **Cookies** → `https://www.instagram.com`.
3. Relever `sessionid`, `csrftoken`, `ds_user_id`, `mid`, `ig_did`.
4. Coller un objet JSON, puis **Envoyer** :

```json
{"sessionid":"…","csrftoken":"…","ds_user_id":"…","mid":"…","ig_did":"…"}
```

Une commande **cURL** copiée depuis l'onglet Réseau (« Copy as cURL ») fait aussi l'affaire : le
bot en extrait l'entête `Cookie` tout seul.

### Ouvrir un fil Instagram

Les ghosts Instagram sont des **identifiants numériques Meta**, pas des pseudos : `pm <pseudo>`
échoue. `NewConversationSheet` accepte donc les deux écritures — un identifiant numérique part
directement en `pm <id>`, un pseudo passe d'abord par `search <pseudo>`, dont l'app lit la réponse
du bot (`` `17841400000000001` / Malo ``) pour en tirer l'ID.

## 2 ter. Connecter Messenger — la même fenêtre, sur facebook.com

Même contrainte que pour Instagram, même vue : `mautrix-facebook` ne se connecte qu'avec les
cookies d'une session de navigateur. **Réglages › Comptes › Messenger › Connecter…** ouvre la
feuille, qui charge **le vrai formulaire facebook.com** (`https://www.facebook.com/login/`) dans la
même `WKWebView` non persistante — e-mail, mot de passe, 2FA, captcha éventuel. C'est le même
`BridgeWebLoginView` que pour Instagram, à un profil près (`BridgeSessionCookies.Profile`) : URL de
connexion, domaine accepté, liste des cookies.

Une différence de taille avec Instagram : **`mautrix-facebook` expose quatre flows de connexion**
(`facebook`, `messenger`, `messenger-lite`, `messenger-lite-android`). bridgev2 ne choisit tout
seul que quand un pont n'en a qu'un ; sinon il répond « Please specify a login flow » et n'ouvre
rien du tout. L'app envoie donc **`login facebook`** — le flow par cookies de facebook.com, celui
que la fenêtre alimente. (Le descripteur porte ce choix : `MatrixBridgeDescriptor.webLoginFlowID`.)

Les cookies obligatoires, tels que `FBRequiredCookies` les liste dans `pkg/messagix/cookies` de
mautrix/meta, sont **trois** : `c_user` (l'identifiant du compte), `xs` (la session) et `datr`
(l'empreinte du navigateur, sans laquelle Meta juge la session suspecte). `sb`, `fr`, `presence`,
`wd`, `oo` et `dpr` partent en plus quand ils existent, sans jamais bloquer. ⚠️ La page
docs.mau.fi range `sb` avec les indispensables et oublie `datr` : c'est le **code** qui refuse, et
c'est lui qu'on suit.

Au succès, le bot répond « Logged in as <nom> (<id>) » et le backfill démarre. Les échecs
parlent : `Missing cookies: [datr]`, `Failed to parse input as JSON`, `Login failed: …`.

Le repli **« Coller des cookies… »** existe ici aussi : relever `c_user`, `xs` et `datr` sur
`https://www.facebook.com` dans les outils de développement, puis coller

```json
{"c_user":"…","xs":"…","datr":"…"}
```

### Ouvrir un fil Messenger

Comme Instagram : les ghosts sont des **identifiants numériques Meta** (`@messenger_<id>`), pas des
noms. `NewConversationSheet` accepte les deux écritures — un identifiant numérique part en
`pm <id>`, un nom passe d'abord par `search <nom>`. ⚠️ Un identifiant Facebook fait quinze
chiffres, soit la longueur d'un E.164 maximal : le parseur refuse explicitement d'y voir un numéro
(`MatrixSyncParser.networkMayCarryPhoneNumbers`), sans quoi un fil Messenger fusionnerait avec le
contact qui porterait ce numéro.

## 2 quater. Connecter Signal — le QR, et ce qu'on laisse derrière

`mautrix-signal` se lie comme **appareil secondaire**, exactement comme Signal Desktop.
**Réglages › Matrix › Connecter Signal…** envoie `login` à `@signalbot`, qui renvoie un QR ;
il se scanne depuis **Signal (téléphone) › Réglages › Appareils liés › Lier un nouvel appareil**.
Le pont apparaît ensuite sous le nom **Correspondance** dans cette liste.

Contrairement à WhatsApp, il n'y a **pas de repli par code d'appairage** : `login phone` n'existe
pas côté mautrix-signal, et l'app ne le propose donc jamais. L'enregistrement en appareil
*primaire* n'est plus supporté non plus — il faut un compte Signal déjà actif sur un téléphone.

### Ce que la bascule depuis signal-cli a coûté

Signal ne conserve **aucun historique côté serveur** : le pont ne voit que les messages postérieurs
au scan du QR, et aucun `backfill` n'y changera rien (c'est pourquoi le template d'overrides n'en
active pas). Concrètement :

- **L'historique d'avant la liaison n'apparaît plus dans l'app.** Il n'est pas détruit pour autant :
  l'ancien cache de signal-cli dort toujours dans
  `~/Library/Application Support/Correspondance/signal-conversations.json`, avec ses pièces jointes.
  Rien ne le lit plus ; il se supprime à la main, quand on est sûr de ne plus le vouloir.
- **Non-lus, épingles, sourdines et fusions de contacts Signal repartent de zéro** : ils indexaient
  des identifiants (`signal:+336…`, `signal-group:<base64>`) que les salons Matrix remplacent. Une
  migration jouée une seule fois au premier lancement les purge, et dissout une fusion à laquelle
  il ne reste qu'un membre — le repérage de doublons la reproposera.
- **Le timer des messages éphémères ne se règle plus depuis l'app.** mautrix-signal applique les
  timers reçus, mais ne sait pas en poser : ça se fait sur le téléphone, et se propage.
- Une fois tout vérifié, l'appareil lié `signal-cli` peut être révoqué depuis le téléphone, et
  `brew uninstall signal-cli` n'a plus d'inconvénient.

### Ouvrir un fil Signal

Signal se compose par numéro : `pm +33612345678` au bot (`!signal pm …` hors salon de gestion).
Attention, l'identité interne d'un correspondant est un **UUID ACI**, pas son numéro — c'est lui
qu'on lit dans les MXID de ghosts (`@signal_2f9d4c60-…`). L'app ne le prend jamais pour une adresse
composable, donc un fil Signal ne fusionne avec une fiche du carnet d'adresses que lorsque le pont
a réellement exposé un numéro.

## 2 quinquies. Double puppeting — que mes messages du téléphone restent les miens

Un pont mautrix, seul, ne connaît qu'un compte Matrix par correspondant : le **ghost**
(`@whatsapp_…`, `@instagram_…`, `@signal_…`). Y compris pour moi. Un message envoyé depuis
l'app officielle sur le téléphone remonte donc signé `@instagram_<mon id>:correspondance.local`,
et Correspondance — qui décide « c'est moi » par `event.sender == selfUserID`, exactement comme
Beeper — l'affiche à gauche, comme s'il venait d'en face.

Le **double puppeting** corrige ça côté serveur : le pont reçoit le droit d'écrire au nom de mon
vrai MXID `@meffysto:correspondance.local`, et repose mes propres messages sous ce compte. Rien à
changer dans l'app.

On utilise la **méthode par appservice** (celle que documente
`docs.mau.fi/bridges/general/double-puppeting.html`), la seule qui ne demande ni jeton d'accès
collé à la main ni renouvellement :

- `bootstrap.sh` génère une fois pour toutes trois valeurs dans `~/correspondance-matrix/.env`
  (`DOUBLEPUPPET_AS_TOKEN`, `DOUBLEPUPPET_HS_TOKEN`, `DOUBLEPUPPET_SENDER`) et écrit
  `data/synapse/doublepuppet-registration.yaml` (chmod 600) : une registration **sans `url`** —
  Synapse ne la rappelle jamais — dont le namespace `users` couvre `@.*:correspondance\.local`
  en **non exclusif**, pour ne voler aucun MXID aux ponts.
- `homeserver.yaml` la déclare dans `app_service_config_files`, à côté des trois registrations
  de ponts. Comme pour elles, Synapse ne relit ce fichier qu'au démarrage : `bootstrap.sh`
  redémarre le homeserver puis les ponts dès que l'empreinte des registrations bouge.
- Chaque pont reçoit dans son `config.yaml` le bloc `double_puppet` avec
  `secrets: {correspondance.local: "as_token:<le même jeton>"}`. Les jetons vivent dans le `.env`
  et les configs du NUC ; les templates du repo n'en portent que le placeholder
  `__DOUBLEPUPPET_AS_TOKEN__`.

Aucun rescan de QR ni recollage de cookies : le compte déjà lié en profite dès le redémarrage du
pont. Pour le vérifier, envoyer **`ping-matrix`** au bot (`!wa` / `!ig` / `!signal` hors salon de
gestion). La réponse attendue, mot pour mot :

```
Confirmed valid access token for @meffysto:correspondance.local (appservice double puppeting)
```

Un jeton refusé répondrait `M_UNKNOWN_TOKEN` — signe que Synapse n'a pas rechargé la registration
(`docker-compose restart synapse`, puis les ponts).

**Ce que ça ne fait pas** : les messages déjà en base ne changent pas d'expéditeur. Seuls les
envois postérieurs à l'activation sont attribués à mon compte. L'historique bridgé garde ses
ghosts, et rien ne le réécrira.

### Revenir en arrière

1. Retirer le bloc `double_puppet` des trois templates
   `infra/matrix/templates/mautrix-{whatsapp,meta,signal}-overrides.yaml.tmpl`.
2. Retirer `- /data/doublepuppet-registration.yaml` de `app_service_config_files` dans
   `infra/matrix/templates/homeserver.yaml.tmpl`.
3. Retirer le bloc d'écriture de `doublepuppet-registration.yaml` de `infra/matrix/bootstrap.sh`,
   puis sur le NUC :
   `rm ~/correspondance-matrix/data/synapse/doublepuppet-registration.yaml`.
4. `./infra/matrix/bootstrap.sh`, puis
   `docker-compose restart synapse mautrix-whatsapp mautrix-meta mautrix-signal`.

La fusion des overrides n'enlève jamais une clé : le bloc `double_puppet` resté dans les
`config.yaml` des ponts se vide à la main (ou en supprimant le `config.yaml`, que `bootstrap.sh`
régénère). C'est aussi pourquoi `merge-overrides.py` comprend un `__remplacer__: true` — sans lui,
la map `double_puppet.secrets` garderait à jamais l'`example.com: as_token:foobar` que les configs
mautrix livrent en exemple.

## 3. Dépannage

Toutes les commandes ci-dessous se lancent depuis `~/correspondance-matrix/` sur le NUC
(`ssh nuc`, puis `cd ~/correspondance-matrix`).

```sh
docker-compose ps                        # les 5 services doivent être Up
docker-compose logs -f mautrix-whatsapp  # le journal du pont WhatsApp, en direct
docker-compose logs -f mautrix-meta      # celui d'Instagram
docker-compose logs -f mautrix-messenger # celui de Messenger
docker-compose logs -f mautrix-signal    # celui de Signal
docker-compose logs --tail=200 synapse   # le homeserver
docker-compose restart mautrix-meta      # redémarrer un pont seul
docker-compose up -d                     # tout relancer (idempotent)
```

### Un geste part et ne fait rien (correction, suppression)

Les ponts bridgev2 **refusent en silence** ce qui sort de leurs bornes : ni notice
dans le salon, ni accusé d'échec, rien dans le journal en `info`. La correction
part, Synapse la garde, l'app l'applique chez elle — et le réseau ne bouge pas.
La bulle est alors juste chez nous, ce qui est pire qu'un échec visible.

Ce que le pont accepte est écrit dans chaque salon, dans l'état
`com.beeper.room_features` (`edit: 2` = pleinement porté, `edit_max_age` et
`delete_max_age` en secondes) :

```sh
ROOM='!xxxx:correspondance.local'
docker exec correspondance-postgres psql -U matrix -d synapse -tAc \
  "select j.json from current_state_events c join event_json j using(event_id)
   where c.room_id='$ROOM' and c.type='com.beeper.room_features';" | python3 -m json.tool
```

Relevé le 2026-09-02 — à relire après chaque montée de version d'un pont, c'est
de là que vient `Domain/NetworkCapabilities.swift` :

| Réseau | Corriger | Supprimer pour tout le monde | Texte max |
| --- | --- | --- | --- |
| Messenger / Instagram | 15 min, 5 fois | sans limite | 20 000 |
| WhatsApp | 15 min | 48 h | 65 536 |
| Signal | 24 h, 10 fois | 24 h | 2 000 |

Pour savoir si une correction précise est passée, la base du pont fait foi :
`edit_count` reste à 0 quand elle a été jetée.

```sh
docker exec correspondance-postgres psql -U matrix -d mautrix_messenger -tAc \
  "select id, edit_count from message where mxid='\$eventID';"
```

**Commandes utiles à envoyer au bot WhatsApp** (dans le DM avec `@whatsappbot`, depuis l'app ou
Element ; hors salon de gestion, les préfixer de `!wa`) :

| Commande | Effet |
| --- | --- |
| `help` | liste complète des commandes de la version installée |
| `login qr` | nouveau QR |
| `login phone <numéro>` | code d'appairage |
| `cancel` | annule le login en cours (à faire si un QR traîne) |
| `logout` | déconnecte le compte WhatsApp du pont |
| `ping` | état de la connexion WhatsApp |
| `sync space` / `backfill` | reconstruit les portails / rejoue l'historique |

**Commandes du bot Signal** (DM avec `@signalbot`, préfixe `!signal` hors salon de gestion) :

| Commande | Effet |
| --- | --- |
| `help` | liste complète des commandes de la version installée |
| `login` | nouveau QR à scanner depuis Appareils liés (pas de `login phone` ici) |
| `logout` | délie le pont du compte Signal |
| `ping` | état de la connexion |
| `pm <numéro>` | ouvre un fil vers un numéro E.164 |
| `sync` | reconstruit les portails et les contacts |

**Commandes du bot Messenger** : les mêmes, dans le DM avec `@messengerbot`, préfixe **`!fb`** —
à ceci près que `login` veut son flow : `login facebook`.

**Commandes du bot Instagram** (DM avec `@instagrambot`, préfixe `!ig` hors salon de gestion) :

| Commande | Effet |
| --- | --- |
| `help` | liste complète des commandes de la version installée |
| `login` | démarre le flow cookies (un seul flow : pas de nom à préciser) |
| `cancel` | annule le login en cours |
| `logout` | déconnecte le compte Instagram du pont |
| `ping` | état de la connexion |
| `search <pseudo>` | cherche un compte, renvoie `` `id` / Nom `` |
| `start-chat <id>` (alias `pm`) | ouvre un DM vers un **identifiant numérique** |
| `create-group` | crée un groupe à partir du salon courant |

**Réinitialiser un login qui ne marche plus** : `cancel`, puis `logout`, puis `login qr`. Si le pont
reste bloqué, `docker-compose restart mautrix-whatsapp` puis un nouveau `login qr` — le pont
reprend son état depuis Postgres, rien n'est perdu.

**Symptômes fréquents**

| Symptôme | Piste |
| --- | --- |
| Réglages affiche une erreur de transport | le NUC ou Tailscale est tombé : tester `curl …/_matrix/client/versions` |
| Connexion refusée (`M_FORBIDDEN`) | mauvais mot de passe — relire `CREDENTIALS.txt` sur le NUC |
| La feuille QR tourne sans image | le bot n'a pas répondu : `docker-compose logs -f mautrix-whatsapp` |
| QR téléchargé mais vide / erreur 401 | jeton expiré : Déconnecter Matrix puis se reconnecter |
| Fils WhatsApp absents après le scan | backfill en cours ; sinon `sync space` puis `backfill` au bot |
| Titres de conversation en `!salon:…` ou `@whatsapp_lid-…` | le displayname n'est pas encore arrivé ; il se corrige au `/sync` suivant. Les ghosts sont des **LID** depuis v26.08 : aucun numéro n'est déductible d'un MXID |
| Instagram : « Missing some keys » | un des cinq cookies obligatoires manque — relire `sessionid`, `csrftoken`, `ds_user_id`, `mid`, `ig_did` |
| Instagram : « Challenge/Checkpoint required » | Meta veut une vérification : la faire sur instagram.com, puis relancer `login` |
| Instagram : « Got logged out immediately » | cookies périmés (déconnexion côté navigateur) — se reconnecter sur instagram.com et recopier |
| Instagram : aucun avatar dans l'inbox | attendu : Instagram n'expose pas de numéro, donc rien à rapprocher du carnet d'adresses. Les initiales font office |
| Messenger : « Please specify a login flow » | le pont a quatre flows et l'app n'en a nommé aucun — vérifier `MatrixBridgeDescriptor.messenger.webLoginFlowID` (`facebook`) |
| Messenger : « Missing cookies: [datr] » | `datr` n'a pas été récolté : se déconnecter de facebook.com dans la fenêtre, recharger la page d'accueil, puis se reconnecter |
| Messenger : le bot ne répond pas | tag d'image : `dock.mau.dev/mautrix/meta:v26.08` **sans** `ig-` (le `ig-` livrerait un second Instagram sur la base Messenger) |
| `mautrix-meta` redémarre en boucle (`as_token was not accepted`) | Synapse n'a pas rechargé `meta-registration.yaml` : `docker-compose restart synapse` puis `docker-compose restart mautrix-meta` |

**Ne jamais** passer une image mautrix en `latest` sans relire le code : le passage aux ghosts LID
en v26.08 a changé le format des MXID que le client analyse, et la même version a sorti Instagram
de `mautrix-meta`. Côté Instagram, penser aussi au préfixe : `ig-v26.08`, jamais `v26.08` — et
l'inverse pour Messenger, `v26.08` nu, jamais `ig-`. Les deux tags se ressemblent assez pour qu'une
inversion passe inaperçue jusqu'au premier `login`.

## 3 bis. Notifications — la passerelle push

L'iPhone ne peut pas tenir un `/sync` en permanence : c'est APNs qui le réveille. Entre le Relais et
APNs il faut un passe-plat qui parle les deux langues — **Sygnal**, le pousseur de matrix.org.

Le chemin complet, dans l'ordre : l'app iOS déclare son pusher au Relais
(`POST /_matrix/client/v3/pushers/set`, un `app_id`, `pushkey` = jeton APNs **en base64**, Sygnal le
décode ainsi) → le Relais, quand une push rule dit « notifie », appelle
`https://push.fauconnier.app/_matrix/push/v1/notify` → Sygnal signe un push APNs avec la clé `.p8` →
l'iPhone se réveille → l'extension de service va lire l'événement et écrit
« Alice · WhatsApp : On se voit demain ? ».

### Une passerelle, publique, pour tous les Relais

Décision du propriétaire, 2 sept. 2026. Jusque-là l'URL du pusher était `http://sygnal:5000/…` — un
nom de service Docker qui ne résout que sur le réseau `matrix` du NUC. Conséquence : la passerelle
n'était joignable que par le Relais du propriétaire, et **un Relais Continuwuity posé chez quelqu'un
d'autre** par `infra/relais/install.sh` n'avait aucun push. Embarquer la clé APNs dans l'installeur
est exclu — elle deviendrait publique, et n'importe qui pourrait pousser vers n'importe quel
Correspondance.

Il n'y a donc qu'une passerelle, chez nous, et tous les Relais l'appellent. **Ce n'est pas héberger
un Relais** : elle ne voit qu'un identifiant de salon, un identifiant d'événement et un compteur de
non-lus — jamais l'expéditeur, jamais le texte, jamais rien du contenu (`format: event_id_only`,
décision 7 de `PRODUCT.md`, celle qui survivra à l'E2EE). Le muet reste appliqué côté Relais : un
salon muet a une push rule `actions: []`, donc le Relais n'appelle même pas la passerelle.

**À écrire dans la politique de confidentialité**, avant toute mise à disposition publique, et dans
ces termes :

> Pour vous réveiller quand un message arrive, votre Relais envoie à notre passerelle de
> notification (`push.fauconnier.app`, hébergée par l'éditeur de Correspondance) l'identifiant
> technique du salon concerné, l'identifiant de l'événement, votre nombre de messages non lus et le
> jeton de notification de votre appareil. Ni le texte du message, ni le nom de son expéditeur, ni
> aucune pièce jointe ne transitent par cette passerelle : votre appareil va lire le message
> lui-même, directement auprès de votre Relais. Ces données ne sont pas conservées — elles sont
> relayées à Apple (APNs) puis effacées. Les salons que vous mettez en sourdine ne produisent aucun
> appel à la passerelle.

Le nom `push.fauconnier.app` est une **valeur de configuration**, pas une constante du produit : il
apparaît dans `PushRegistration.defaultGateway` (surchargeable par `CORRESPONDANCE_PUSH_GATEWAY`),
dans `PUSH_GATEWAY_HOST` du bootstrap, et dans la route DNS du tunnel. C'est un domaine que le
propriétaire possède déjà, en attendant celui de Correspondance ; le jour venu, ces trois endroits
changent et rien d'autre.

### Les deux environnements APNs

APNs a deux mondes séparés, et **un jeton obtenu dans l'un ne vaut rien dans l'autre** — l'erreur est
silencieuse (`BadDeviceToken`). Tant que la passerelle était privée on pouvait basculer un réglage
global entre une build Xcode et l'App Store ; une passerelle publique doit servir les deux à la fois.
`sygnal.yaml` déclare donc **deux apps**, même clé `.p8`, même `topic` (qui n'est pas l'`app_id` mais
l'identifiant de bundle) :

| `app_id` | `platform` | qui l'utilise |
|----------|-----------|---------------|
| `com.correspondance.ios` | `production` | App Store, TestFlight (toute build Release) |
| `com.correspondance.ios.dev` | `sandbox` | builds lancées depuis Xcode (`Debug`) |

C'est **l'app** qui choisit, par son `app_id`, dans `PushRegistration.pusherAppID` — un `#if DEBUG`
et non un réglage de build à part. Raison : `DEBUG` est posé par la configuration Debug, exactement
celle qu'Xcode installe sur un appareil, avec un profil de développement, donc
`aps-environment: development`, donc un jeton de sandbox. Release est signée à l'export
`app-store-connect`, où Xcode réécrit `aps-environment` en `production`. Les deux bascules sont
tirées par le même levier ; un réglage séparé pourrait dériver de la signature, `DEBUG` ne le peut
pas. Vérification sur l'IPA, sans le reconstruire :

```sh
unzip -q build/release/ios/export/Correspondance.ipa -d /tmp/ipa
codesign -d --entitlements :- /tmp/ipa/Payload/Correspondance.app | grep -A1 aps-environment
# → <key>aps-environment</key><string>production</string>
```

Le fichier `CorrespondanceiOS/CorrespondanceiOS.entitlements` reste à `development` : c'est la valeur
des builds de développement, et Xcode la remplace à l'export. Ne pas la forcer à `production` — une
build Debug ne s'installerait plus.

### Ce qu'il faut faire chez Apple, une fois

1. **developer.apple.com › Certificates, Identifiers & Profiles › Keys › +**
2. Cocher **Apple Push Notifications service (APNs)**, nommer la clé (« Correspondance push »),
   **Continue**, **Register**.
3. **Download** : le fichier `AuthKey_XXXXXXXXXX.p8`. Apple ne le redonne **jamais** — s'il est
   perdu, il faut révoquer la clé et en refaire une.
4. Noter le **Key ID** (les dix caractères de `AuthKey_XXXXXXXXXX.p8`) et le **Team ID**
   (en haut à droite du portail, ou dans Membership). **Le Key ID doit être celui de CE fichier** :
   renommer la clé en `apns.p8` fait perdre le seul endroit où les deux étaient liés, et un Key ID
   qui ne correspond pas au `.p8` donne un `403 InvalidProviderToken` d'APNs — clé valide, team
   valide, et rien qui parte.
5. Sur l'identifiant d'app `com.correspondance.ios` : cocher la capacité **Push Notifications**.

### Ce qu'il faut faire sur le NUC, une fois

```sh
# 1) Déposer la clé — hors du dépôt, hors de data/, chmod 600.
ssh nuc 'mkdir -p ~/correspondance-matrix/secrets/apns && chmod 700 ~/correspondance-matrix/secrets ~/correspondance-matrix/secrets/apns'
scp AuthKey_XXXXXXXXXX.p8 nuc:~/correspondance-matrix/secrets/apns/apns.p8
ssh nuc 'chmod 600 ~/correspondance-matrix/secrets/apns/apns.p8'

# 2) Rejouer le bootstrap en lui donnant les identifiants. Ils atterrissent dans
#    le .env du NUC : les passes suivantes n'ont plus besoin de les repasser.
#    Il n'y a plus de APNS_PLATFORM — les deux environnements sont servis.
APNS_KEY_ID=XXXXXXXXXX APNS_TEAM_ID=AKMNXGVVGX \
  PUSH_TUNNEL_TOKEN='<jeton du tunnel>' \
  ./infra/matrix/bootstrap.sh
```

### Le tunnel qui rend la passerelle publique

Le NUC n'a ni 80 ni 443 libres (Umbrel les tient) et il est derrière une box. Un tunnel Cloudflare
sort en HTTPS et n'ouvre rien : `cloudflared` établit la connexion **depuis** le NUC.

```sh
# Sur le Mac, une fois. Le tunnel est « géré à distance » : son ingress est
# stocké chez Cloudflare, pas dans un fichier du NUC.
cloudflared tunnel create correspondance-push
cloudflared tunnel route dns correspondance-push push.fauconnier.app
cloudflared tunnel token correspondance-push     # → le jeton, à passer au bootstrap
```

L'ingress restreint la passerelle à **deux chemins**, et rend 404 sur tout le reste — la surface
publique se limite à ce qui doit exister :

| chemin | service |
|--------|---------|
| `^/_matrix/push/v1/notify$` | `http://sygnal:5000` |
| `^/health$` | `http://sygnal:5000` |
| tout le reste | `http_status:404` |

Le conteneur `cloudflared-push` du `docker-compose.yml` est sous le profil `push` : `docker-compose
up -d` ne le démarre pas tout seul (sans jeton il tournerait en boucle d'échec), le bootstrap le
lance avec `--profile push` quand `PUSH_TUNNEL_TOKEN` existe. Il est sur le réseau `matrix` et rien
d'autre : il ne peut joindre que Sygnal, jamais Synapse ni Postgres. Le jeton vaut un accès — il vit
dans le `.env` du NUC (chmod 600), jamais dans le dépôt.

### Ce qu'il faut du côté d'un Relais Continuwuity

**Rien.** Vérifié dans le code de Continuwuity 26.8.1 (`src/service/pusher/mod.rs`), parce que la
question se posait : il n'existe aucune liste d'autorisation d'URL de passerelle, `set_pusher` ne
valide que la forme (URL analysable, schéma `http` ou `https`), et `allow_federation = false` ne
coupe pas le push — le garde de la fédération est en aval, dans `federation/execute.rs`, et le push
part par un client HTTP distinct (`services.client.pusher`).

Le seul vrai garde est `ip_range_denylist`, dont le défaut contient `100.64.0.0/10` — la plage CGNAT
de Tailscale. Une passerelle sur une adresse `100.x` ou en LAN serait **refusée**, à l'enregistrement
si l'URL porte l'IP et à l'envoi dans tous les cas (le test est refait sur l'IP réellement
connectée). C'est précisément pourquoi la passerelle est un nom public en HTTPS et non l'adresse
Tailscale du NUC. Le tout est écrit en commentaire dans `infra/relais/install.sh`, à côté du `.toml`.

Piège annexe, non documenté chez eux : `send_request` retire `notification_push_path` de l'URL
déclarée avant que ruma ne le rajoute. L'URL du pusher **doit** finir par `/_matrix/push/v1/notify`.

### Vérifier

```sh
# La passerelle est-elle publique, et est-ce bien Sygnal qui répond ?
curl -s -w '\nHTTP %{http_code}\n' https://push.fauconnier.app/health
# → corps vide, HTTP 200

curl -s -w '\nHTTP %{http_code}\n' -X POST -d '{}' https://push.fauconnier.app/_matrix/push/v1/notify
# → « Invalid notification: expecting object in 'notification' key », HTTP 400.
#   C'est du Sygnal, pas une page Cloudflare : la chaîne entière est debout.

# Le reste de la surface est fermé.
curl -s -o /dev/null -w '%{http_code}\n' https://push.fauconnier.app/
# → 404

# Une notification fabriquée à la main, avec un pushkey bidon.
curl -s -X POST -H 'Content-Type: application/json' https://push.fauconnier.app/_matrix/push/v1/notify \
  -d '{"notification":{"event_id":"$bidon","room_id":"!bidon:correspondance.local","counts":{"unread":1},
       "devices":[{"app_id":"com.correspondance.ios","pushkey":"0000","data":{"format":"event_id_only"}}]}}'
# → un app_id inconnu rend {"rejected": [...]} et HTTP 200 ; un app_id connu va
#   VRAIMENT chez Apple, et son verdict remonte dans le journal de Sygnal.

# Que raconte Sygnal ?
ssh nuc 'cd correspondance-matrix && docker-compose logs -f --tail=40 sygnal'

# Le pusher est-il déclaré côté Relais ? (jeton d'accès de l'app, cf. CREDENTIALS.txt)
curl -sS -H "Authorization: Bearer $TOKEN" http://100.64.0.7:8008/_matrix/client/v3/pushers | python3 -m json.tool
# → data.url = https://push.fauconnier.app/_matrix/push/v1/notify
```

### Dépannage

| Symptôme | Cause probable |
|----------|----------------|
| `403 InvalidProviderToken` dans les logs Sygnal, et une 502 rendue à l'appelant | d'abord vérifier que `sygnal.yaml` porte le vrai `key_id` et non un `__APNS_KEY_ID__` ou `${APNS_KEY_ID}` resté en clair (c'est arrivé le 2 sept. 2026 : `grep -n key_id data/sygnal/sygnal.yaml`). Sinon : le `key_id` du `.env` ne correspond pas au `.p8` déposé, ou la clé a été révoquée, ou elle n'a pas la capacité APNs. Pour isoler Sygnal, signer un jeton à la main avec la clé et appeler APNs avec un device token bidon : `BadDeviceToken` = clé acceptée. La clé et le `team_id` peuvent être parfaitement valides par ailleurs |
| `no app configured` | l'`app_id` du pusher ne correspond à aucune clé sous `apps:` dans `sygnal.yaml` |
| `BadDeviceToken` | environnement croisé : jeton de sandbox envoyé à l'app_id de production (ou l'inverse), ou jeton d'un autre bundle |
| `TopicDisallowed` | `topic:` n'est pas exactement l'identifiant de bundle de l'app |
| Une page Cloudflare au lieu d'une réponse Sygnal | le conteneur `cloudflared-push` est arrêté, ou l'ingress ne pointe plus sur `http://sygnal:5000` |
| 404 sur un chemin légitime | l'ingress ne connaît que `/_matrix/push/v1/notify` et `/health` ; en ajouter un est un changement côté Cloudflare |
| Sygnal redémarre en boucle | `secrets/apns/apns.p8` absent, illisible, ou `key_id`/`team_id` encore en placeholder |
| Rien n'arrive, et Sygnal n'est jamais appelé | le salon est **muet** (push rule `actions: []`) — c'est le comportement voulu |
| Le simulateur ne reçoit rien | normal : un simulateur n'a pas de jeton APNs. `xcrun simctl push <UDID> com.correspondance.ios payload.apns` sert à exercer l'extension, pas le chemin réseau |

## 4. Migrer vers un VPS

Le NUC est un point de départ, pas une fin : il faut que la machine soit joignable pour recevoir les
messages. Le déménagement vers un VPS ne change rien au code Swift — seule l'URL du homeserver bouge.

1. **Nom de domaine** : choisir un vrai `server_name` (`matrix.exemple.fr`) plutôt que
   `correspondance.local`. Attention : `server_name` **n'est pas renommable** après coup ; le plus
   simple est de repartir d'une pile neuve et de relier WhatsApp à nouveau (`login qr`), quitte à
   perdre l'historique déjà bridgé.
2. **Provisionner** le VPS (Debian 12, Docker), puis rejouer l'infra :
   `SSH_HOST=vps SERVER_NAME=matrix.exemple.fr SYNAPSE_BIND_IP=127.0.0.1 SYNAPSE_PUBLIC_IP=<ip> ./infra/matrix/bootstrap.sh`
3. **TLS** : sur un VPS les ports 80/443 sont libres — mettre Caddy ou nginx devant Synapse
   (`reverse_proxy 127.0.0.1:8008`), certificat Let's Encrypt, et servir
   `/.well-known/matrix/server` + `/.well-known/matrix/client`. Le homeserver devient alors
   `https://matrix.exemple.fr` dans Réglages. Ne jamais exposer 8008 en clair sur Internet.
4. **Ou garder Tailscale** : installer tailscale sur le VPS et continuer à joindre le homeserver par
   son IP 100.x. Zéro TLS à gérer, zéro port ouvert — c'est l'option la plus sobre tant que
   Correspondance reste mono-utilisateur.
5. **Reprendre les données** (si on garde le même `server_name`) : arrêter la pile, `pg_dump` de
   Postgres, copier `data/synapse`, `data/mautrix-whatsapp` et `data/mautrix-meta`, restaurer côté
   VPS, relancer. Les ponts reprennent leur session sans rescanner ni recoller de cookies.
6. Côté Mac : Réglages › Matrix › Déconnecter, puis se reconnecter sur la nouvelle URL.
