# Plan — Correspondance multi-réseaux via Matrix (mautrix)

Objectif produit : une inbox unique (iMessage, Signal, WhatsApp, Instagram, Messenger) dont la
différenciation est l'UI — mode **Focus** hérité d'iA Writer. macOS d'abord, iOS ensuite.

## Architecture cible

```
 iMessage ─── chat.db + Apple Events (natif Mac, inchangé)
 WhatsApp ─── mautrix-whatsapp ─┐
 Instagram ┐                    ├─ Synapse (NUC, Tailscale) ── Matrix CS-API ── MatrixService (Swift)
 Messenger ┴ mautrix-meta ──────┤                                                     │
 Signal ───── mautrix-signal ───┘                                                 InboxStore
```

- **Homeserver** : Synapse (meilleur support mautrix, doc la plus riche). Postgres 16.
- **Hébergement** : NUC `umbrel` (Debian 12, Docker 20.10, `docker-compose` 1.29 — pas de plugin v2 → fichier
  compose **v3.x**, commandes `docker-compose`). SSH : `ssh nuc` (user `meff`, membre du groupe docker,
  **pas de sudo sans mot de passe**). IP Tailscale `100.64.0.7`. Ports 80/443 pris par Umbrel :
  Synapse écoute sur `100.64.0.7:8008` (jamais 0.0.0.0 — le NUC est sur le LAN maison).
- **Client Swift** : REST Matrix Client-Server v1.x via `URLSession` (actor `MatrixClient`), pas matrix-rust-sdk.
  Raison : homeserver privé sur Tailscale, salons de bridge non chiffrés (`encryption.allow: false`), donc
  E2EE inutile ; zéro dépendance binaire ; même code sur iOS. Long-poll `GET /sync?timeout=30000`.
- **Un réseau = un bridge**, identifié par salon via l'event d'état `m.bridge` / `uk.half-shot.bridge`
  (`content.protocol.id` ∈ `whatsapp`, `instagram`, `facebook`, `signal`).
- **Token** d'accès Matrix dans le Trousseau (Keychain), jamais dans UserDefaults ni le repo.

## Itération 1 (cette passe) — Infra + WhatsApp

### 1. Infra sur le NUC — `infra/matrix/` (versionné, secrets exclus)
- `docker-compose.yml` (v3.8) : `synapse` (matrixdotorg/synapse), `postgres:16-alpine`, `mautrix-whatsapp`
  (`dock.mau.dev/mautrix/whatsapp:v26.08` — tag épinglé, jamais `latest` : le passage aux ghosts LID en v26.08
  change le format des MXID que le client parse).
- `homeserver.yaml` : `server_name: correspondance.local`, `enable_registration: false`,
  `app_service_config_files: [/data/whatsapp-registration.yaml]`, rate-limits relevés pour l'appservice,
  `presence.enabled: false`, listener HTTP 8008 sans TLS.
- `mautrix-whatsapp/config.yaml` : `homeserver.address: http://synapse:8008`, `appservice.address: http://mautrix-whatsapp:29318`,
  `bridge.permissions: { "@meffysto:correspondance.local": admin }`, `encryption.allow: false`,
  `backfill` activé (historique initial), `personal_filtering_spaces: true`.
- Script `infra/matrix/bootstrap.sh` (idempotent, exécuté via `ssh nuc`) : crée `~/correspondance-matrix/`, génère
  les configs à partir des templates, `generate` les registrations, `docker-compose up -d`, crée l'utilisateur
  `meffysto` via `register_new_matrix_user` avec mot de passe généré et affiché **une seule fois**.
- Vérification : `curl http://relais.exemple.ts.net:8008/_matrix/client/versions` répond ; `docker-compose ps` → 3 services up.
- **Bind réel** : Tailscale tourne sur le NUC en `userspace-networking` (aucune interface `tailscale0`), donc
  `100.64.0.7` n'est pas assignable en bind. `tailscaled` relaie le trafic entrant du tailnet vers `127.0.0.1`
  de l'hôte : Synapse écoute sur `127.0.0.1:8008` et reste joignable en `http://relais.exemple.ts.net:8008` depuis le
  tailnet, sans jamais être exposé sur le LAN 192.168.

### 2. Domaine
- `MessageNetwork` : ajouter `.whatsapp` (labelFR "WhatsApp", `systemImage` adapté). Prévoir `.instagram`, `.messenger`
  dans l'enum dès maintenant **uniquement** si ça ne force pas de code mort dans l'UI ; sinon les ajouter plus tard.
- `Conversation.transportKey` = room ID Matrix pour les réseaux bridgés. `isGroup` = salon avec >2 membres hors bot/ghosts.

### 3. Services Swift — `Services/Matrix/`
- `MatrixClient` (actor) : `login(password:)`, `whoami`, `sync(since:timeout:)`, `roomMessages(roomID:from:dir:limit:)`,
  `sendText(roomID:body:)` avec `txnId` idempotent, `sendImage` (upload `/_matrix/media/v3/upload` puis `m.image`),
  `roomState(roomID:type:)`, `createDM(with:)`. Erreurs typées `MatrixError` (LocalizedError, FR).
- `MatrixCredentialStore` : Keychain (homeserver URL, user ID, access token, device ID).
- `MatrixBridgeService` (actor) : maintient le `next_batch`, construit `[Conversation]` + `[ChatMessage]` par salon à partir
  du sync, résout le réseau par `m.bridge`.
  **Ghosts LID** : depuis mautrix-whatsapp v26.08 tous les ghosts (DM compris) sont des LID — les MXID valent
  `@whatsapp_lid-<id>:correspondance.local`, plus `@whatsapp_<numéro>`. Ne jamais extraire un numéro du MXID.
  Résolution du contact, dans l'ordre : `displayname` du `m.room.member`, nom du salon, puis les champs numéro
  éventuellement exposés par l'état de bridge (`m.bridge` / `fi.mau.bridge`, extras `fi.mau.whatsapp.*` /
  `com.beeper.*`). Un numéro trouvé améliore le titre et permet le rapprochement `ContactDirectory` ; son absence
  ne doit rien casser (on retombe sur le displayname).
  Cache disque (`MatrixConversationCache`) sur le modèle de `SignalConversationCache`.
- Attachements : `m.image`/`m.file` → téléchargement `/_matrix/client/v1/media/download` (avec token) dans
  `~/Library/Caches/Correspondance/matrix/`, réutilise `MessageAttachment`.

### 4. Intégration `InboxStore`
- `start()` : si credentials présents → `MatrixBridgeService.start()` ; fusion des conversations `.whatsapp` dans `conversations`
  (même logique que la fusion Signal ~L676-720, sans écraser iMessage/Signal).
- `startLiveSync()` : la boucle `/sync` remplace le poll pour les réseaux Matrix ; push des nouveaux messages dans `messages`
  si la conversation est sélectionnée.
- `sendDraft()` : `case .whatsapp` → `MatrixBridgeService.send(roomID:text:attachments:)` avec message `isPending` optimiste.
- Nouveau `matrixStatusFR` affiché dans Réglages.

### 5. UI
- Réglages : section « Matrix » (URL homeserver pré-remplie `http://relais.exemple.ts.net:8008`, identifiant, mot de passe,
  bouton Connexion / Déconnexion, statut).
- Réglages : bouton « Connecter WhatsApp » → envoie `login qr` au bot `@whatsappbot:correspondance.local` dans le DM
  de gestion, affiche l'image QR reçue (m.image du bot) dans une feuille, rafraîchit jusqu'au message de succès.
  Replis documentés : `login phone <numéro>` (code d'appairage, supporté depuis v26.08 en plus du QR) et
  Element Web pointé sur le homeserver.
- Inbox + Focus : `ConversationRowView`/`MessageBubbleView` affichent WhatsApp avec l'icône réseau — **aucune** régression
  visuelle du mode Focus (`FocusConversationView`). Respecter `Design/` (Theme, WritingTheme, Typography, Spacing).
- `NewConversationSheet` : WhatsApp sélectionnable seulement si Matrix est connecté ; création via commande bot
  `pm <numéro>` (mautrix-whatsapp) puis ouverture du salon retourné.

### 6. Tests
- `CorrespondanceTests` : parsing d'un payload `/sync` fixture (salons, m.bridge, messages, ghosts) → `[Conversation]`/`[ChatMessage]` ;
  détection réseau ; idempotence `txnId` ; `Conversation.hasPlaceholderTitle` sur les titres WhatsApp.
- `xcodebuild test` vert. Swift 6 strict concurrency : pas de `@unchecked Sendable` gratuit.

### Livrables attendus de l'agent
1. Conteneurs up sur le NUC, `versions` répond, utilisateur `meffysto` créé (mot de passe dans `~/correspondance-matrix/CREDENTIALS.txt`
   côté NUC, chmod 600, **pas** dans le repo).
2. `xcodegen generate` + `xcodebuild build` + `xcodebuild test` verts.
3. `docs/MATRIX-SETUP.md` : comment connecter, scanner le QR, dépanner (`docker-compose logs -f mautrix-whatsapp`), migrer vers un VPS.
4. Commits atomiques (infra / domaine / services / store / UI / tests), aucun secret.

### Hors périmètre (itérations suivantes)
- ~~It. 2 : Instagram~~ **faite** : `mautrix-instagram` (image `dock.mau.dev/mautrix/meta:ig-v26.08`, préfixe `ig-`,
  binaire `mautrix-instagram` depuis v26.08). Ce que la passe a apporté : un `MatrixBridgeDescriptor` par pont
  (bot, préfixe de commande, préfixe de ghost, `protocol.id`, flow de login), un salon de gestion **par pont** dans
  `MatrixBridgeService`, et un flux de login générique (`startLogin` / `loginStep`) — QR pour WhatsApp, cookies pour
  Instagram. `protocol.id` vaut le `BeeperBridgeType` de mautrix : `whatsappgo`, `instagramgo`.
- It. 2 bis : Messenger via `mautrix-meta` (le vrai, sans préfixe) — un descripteur de plus, rien d'autre à bouger.
- ~~It. 3 : mautrix-signal~~ **faite** : `mautrix-signal:v26.08`, descripteur `.signal` (bot `@signalbot`,
  préfixe `!signal`, ghosts `@signal_<UUID ACI>`, `protocol.id` = `signal` sans forme en `-go`), et
  suppression de `SignalBridge.swift`, `SignalConversationCache`, `SignalAttachmentStore`,
  `SignalCatchUp` — près de 2 000 lignes. Parité atteinte sauf deux points, actés : le **timer
  éphémère** ne se règle plus depuis l'app (mautrix-signal applique les timers reçus, ne les pose
  pas) et l'**historique d'avant la liaison** n'apparaît plus (Signal ne garde rien côté serveur —
  aucun backfill possible ; l'ancien cache reste sur disque, simplement plus lu). Une migration
  jouée une fois purge les préférences qui indexaient les anciens identifiants et remet le curseur
  de `/sync` à zéro, sans quoi les salons créés avant l'ajout du descripteur resteraient invisibles.
- It. 4 : cible iOS (SwiftUI partagé, `MatrixClient` réutilisé tel quel, accès homeserver via Tailscale sur iPhone).

## Itération « Chrome Golden Gate » (UI, après l'it. 1, indépendante des bridges)

Objectif : le rendu « Apple 2026 » natif là où Beeper reste visiblement web. On adopte le chrome macOS 27 /
iOS 27 (Liquid Glass révisé) et on ne garde de Beeper que ce qui n'est pas du chrome.

### Prérequis
- **Xcode 27 beta** (macOS 27 SDK) : https://developer.apple.com/download/ — installer côte à côte
  (`/Applications/Xcode-27-beta.app`), sélectionner avec `sudo xcode-select -s`, ou `DEVELOPER_DIR=…` pour xcodebuild.
  Aujourd'hui : Xcode 26.6 sur macOS 26.6.2. Sans SDK 27, les modificateurs ci-dessous ne compilent pas → tous
  derrière `#available(macOS 27, iOS 27, *)` avec repli Tahoe, pour que le build Xcode 26 reste vert.
- Cible de déploiement inchangée (macOS 14) tant que l'app n'est pas publiée ; repli visuel Tahoe/Sonoma obligatoire.

### Ce que recommande Apple (vérifié, WWDC26 / macOS 27 Golden Gate)
- Sidebar **bord à bord** (plus d'inset ni de carte flottante) ; icônes de sidebar colorées seulement pour l'app active.
- Toolbar **uniforme givrée** au-dessus du contenu qui défile ; rayons de coin de fenêtre harmonisés ; bords de verre
  assombris + reflets plus vifs ; curseur système de transparence (respecter `Reduce Transparency` / `Increase Contrast`).
- Tout cela s'applique **automatiquement** aux apps compilées avec Xcode 27 : ne pas le réimplémenter à la main.
- SwiftUI WWDC26 : `.navigationTransition(.crossFade)`, `.toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)`,
  `ToolbarItem(placement: .topBarPinnedTrailing)`, `.visibilityPriority(.high)`, `ToolbarOverflowMenu`,
  environnement `appearsActive`, `.swipeActions` hors `List` (`.swipeActionsContainer()`), `.reorderable()`.

### Ce qu'on garde de Beeper (hors chrome)
- **Rail de réseaux** à gauche de la liste (Tous / iMessage / Signal / WhatsApp / Instagram / Messenger), filtre + badge non-lus.
  Remplace le picker `iMessage ⌃` en tête de liste. Icône réseau = `MessageNetwork.systemImage`.
- **Entête pilule** en tête de conversation (avatar + « Nom › »), cliquable → fiche contact / infos groupe.
- **Composer pilule** pleine largeur, bouton `+` séparé à gauche, envoi à droite ; hérite de `Features/Composer/`.
- Liste sans séparateurs lourds, aperçu sur 2 lignes, coche « vu » / « livré » dans l'aperçu.

### Chantier
1. `App/ContentView.swift` : `NavigationSplitView` natif (sidebar = rail + liste, détail = conversation), suppression du
   chrome maison qui simule l'inset ; `WindowChrome.swift` réduit à ce que Golden Gate ne fournit pas.
2. `Features/Inbox/NetworkRailView.swift` (nouveau) + `InboxStore.networkFilter`.
3. `ThreadView` : toolbar givrée + `.toolbarMinimizeBehavior(.onScrollDown…)` derrière `#available` ; entête pilule.
4. **Focus** : `FocusConversationView` devient l'état « chrome minimisé » du même écran, transition
   `.navigationTransition(.crossFade)` (repli : `withAnimation(.smooth)` sur Tahoe). Sidebar masquée
   (`columnVisibility = .detailOnly`), toolbar minimisée, composer seul. Aucune régression de la typo `Design/Writing*`.
5. `appearsActive` : chrome grisé fenêtre inactive ; états `Reduce Transparency` testés.
6. Vérification : build Xcode 26 **et** Xcode 27 verts ; captures light/dark/transparence réduite dans `docs/screens/`.

### Hors périmètre
- Refonte iOS (it. 4) : le rail et la pilule se transposent en `TabView` `.prominent` + `NavigationStack`, plus tard.
