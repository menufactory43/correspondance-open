# Parité Beeper Desktop — audit du bundle local 4.3.73

Source primaire : `/Applications/Beeper Desktop.app` (v4.3.73, `com.automattic.beeper.desktop`, Electron, arm64).
Sources secondaires : `developers.beeper.com`, `help.beeper.com`, `blog.beeper.com`, `docs.mau.fi` + `ROADMAP.md` des dépôts mautrix.
Cible comparée : `Correspondance` au 2026-08-31 (branche `main`).
Statuts revérifiés le 2026-08-31 contre le code du jour ET une ré-extraction du bundle 4.3.73 (voir Annexe).

---

## Résumé

Le socle quotidien est quasi à parité. Les quatre piliers jadis absents — notifications, recherche,
archivage durable, fil conversationnel réel — sont faits, ainsi que : rappels, demandes, sondages
(création + vote), frappe bidirectionnelle, mentions, aperçus de liens, pièces jointes tous types,
vocaux (lus partout, enregistrés sur iPhone), réponse depuis la notification, accusés de lecture
avec le détail « Vu par Alice et Bruno » en groupe, l'app iOS complète, et l'état de conversation
synchronisé entre appareils via le Relais.
Les paquets 1 à 3 de la revue du 2026-08-31 (cycle de vie du message, pilotage des groupes,
filtres d'inbox) ont été **implémentés le 2026-09-01** — commits `8a1b371`, `27adebc`, `c710f76`,
`b1992e1` : édition là où le pont la porte, transfert, annuler l'envoi, micro Mac, filtres et
pilules, archivage des fils lus, sélection multiple Mac, regroupement anti-rafale avec OTP
immédiats, renommage/retrait/ajout/création de groupe (WhatsApp et Signal), et les notifications
locales iOS. Ce qui manque encore :
**1) le réveil de l'iPhone** — le push de bout en bout attend trois gestes d'infra (clé APNs `.p8`,
bootstrap avec Sygnal, bascule production) : sans eux l'iPhone ne notifie que l'app ouverte ;
**2) les réseaux** — 5 chez nous (iMessage, Signal, WhatsApp, Instagram, Messenger) contre 14 chez
Beeper ; Telegram reste le levier mautrix évident ; pas de multi-comptes par réseau ;
**3) l'écosystème** — Beeper 4.3.73 embarque un serveur MCP local et des intégrations agents prêtes
à l'emploi (voir § « IA & écosystème ») ; nous avons l'agent cc *dans* les fils, mais aucune API locale.

---

## Tableau de parité

Légende effort : **S** ≤ 1 jour · **M** 2–4 jours · **L** ≥ 1 semaine.
Légende priorité : **P0** usage quotidien · **P1** confort · **P2** plus tard · **✗** hors-cible (contraire au Focus).

### 1. Réseaux & comptes

| Fonction | Beeper (preuve) | Correspondance | Effort | Prio |
|---|---|---|---|---|
| Réseaux supportés | 12 : Discord, Google Messages, Google Chat, Google Voice, Instagram, LinkedIn, Signal, Slack, Telegram, X, WhatsApp, LINE + iMessage macOS (help.beeper.com/en_US/chat-networks/which-chat-networks-can-you-connect-in-beeper). Bundle : chaînes `BridgeV2 <réseau> login flow name` pour Discord, Google Messages, Google Voice, LinkedIn, Signal, Telegram, WhatsApp, Instagram/Messenger, Facebook/Messenger, X/Twitter | **Partiel** : iMessage, Signal, WhatsApp, Instagram, Messenger (+ la note à soi) — manquent Telegram, Google Messages, LinkedIn, X, Discord, Slack, Google Chat, Google Voice, LINE. Telegram est désormais le pont mautrix évident qui reste | — | P1 (Telegram) |
| Instagram / Messenger | `mautrix-meta`, chaînes `BridgeV2 Instagram/Messenger login flow name` | **Fait pour les deux.** Instagram : `dock.mau.dev/mautrix/meta:ig-v26.08`, `@instagrambot`, `!ig`. Messenger : la **même image** en `:v26.08` (binaire mautrix-facebook), `@messengerbot`, `!fb`, base et port séparés. Un seul type de session pour les deux (`BridgeSessionCookies` et ses profils), une seule fenêtre de connexion (`BridgeWebLoginView`) : instagram.com ou facebook.com selon le réseau. Le flow est nommé explicitement (`login facebook`) — mautrix-facebook en expose quatre, et bridgev2 ne choisit tout seul que quand il n'y en a qu'un | — | — |
| Bridge on-device vs cloud | Chaînes `Beeper On-Device: this account runs on your device.` / `Beeper Cloud` / `Only one account per network can use Beeper Cloud.` ; blog 2025-07-16 « the app connects directly to the messaging networks » | **Fait par construction** : tout est local (chat.db, signal-cli, Synapse perso) — c'est notre avantage structurel | — | — |
| Multi-comptes par réseau | `%d Account Per Network`, `SELECT_NEXT_ACCOUNT ⌘⇧]`, `FILTER_ACCOUNT ⌘⌥A` ; API `GET /v1/accounts` | **Absent** : `MatrixCredentialStore` a `account = "default"` en dur ; un seul `signal-cli` | M | P2 |
| Login guidé par réseau | Flows `login_flows.list` / `login_sessions.create` / `steps.submit` (developers.beeper.com/desktop-api-reference/resources/bridges) ; QR, code d'appairage, 2FA | **Partiel** : WhatsApp OK (`WhatsAppLoginSheet.swift` + `startWhatsAppLogin`), Matrix OK (`SettingsView.matrixSection`). Signal = instruction texte à recopier au terminal | S | P1 |
| Statut de compte | `status ∈ connected, connecting, backfilling, disconnected` + `statusText` (API `Account`) | **Fait** : `SettingsView` — `iMessageStatusFR`, `signalStatusFR`, `contactsStatusFR` | — | — |
| Fusion de chats multi-réseaux (Merge Chats) | `Merge Chats`, `Keep chats merged`, `Merged Chat` ; blog 2026-08-10 | **Fait** : `Domain/PhoneNormalizer.swift` ramène `+33…`, `0…` et `@whatsapp_33…:serveur` à une seule clé, `MergeCandidates.detect` propose la fusion sous la pilule (✕ persistant), `MergedContact.apply` est rejoué dans le `didSet` de `conversations` comme `ArchiveState` — une ligne, un fil chronologique où le séparateur d'heure annonce « 15:48 · iMessage » à chaque bascule, et un sélecteur de chat dans le composer qui retient le dernier réseau utilisé (`Services/MergedContactStore.swift`) | — | — |

### 2. Inbox

| Fonction | Beeper (preuve) | Correspondance | Effort | Prio |
|---|---|---|---|---|
| Archivage | `TOGGLE_THREAD_ARCHIVE` = ⌘E ou `e` ; API `POST /v1/chats/{id}/archive` + champ `isArchived` ; « Anything you've handled is in your __ARCHIVE__. » | **Fait + persisté** : `archivedIDs` (UserDefaults), réappliqué après chaque fusion par `Domain/ArchiveState.swift` — aucun catalogue réseau ne peut plus l'écraser. ⌘E bascule, ⌘⇧E ouvre la vue « Archivés » (bouton en pied de liste + menu contextuel « Désarchiver ») | — | — |
| Archiver tout ce qui est lu | `ARCHIVE_ALL_READ_THREADS` ⌘⇧E, `Archive all read chats` | **Fait** : `Domain/ArchiveSweep.swift` (testé) — ⌥⌘E sur Mac (⌘⇧E est pris par la vue Archivés), menu du titre sur iPhone, confirmation avec le compte. Épargne épinglés, non lus, rappels et demandes | — | — |
| Auto-archivage par règle | `Auto-archive chats based on a rule`, `Archive __TYPE__ chats older than __DURATION__` | **Absent** | M | P2 |
| Sync de l'archivage avec la plateforme native | Réglage `Sync chat archive state with native platform` (clé `NATIVE_ARCHIVE`) | **Absent** | M | P2 |
| Action après archivage | Réglages `AFTER_ARCHIVE` / `AFTER_TOGGLE_READ` → `SELECT_NEXT_THREAD` par défaut | **Fait de fait** : le mode Focus enchaîne déjà (`focusNext()` après `archiveSelected()`) — c'est notre cœur | — | — |
| Recherche | ⌘K global (`SEARCH`), ⌘F dans le fil (`SEARCH_ROOM`) ; API `GET /v1/search`, `GET /v1/messages/search` (filtres `sender`, `mediaTypes`, `dateAfter`, `chatType`) ; « Only messages loaded in Beeper can be searched. » | **Fait** : `.searchable` sur la liste (titre, adresse, aperçu, corps des messages) via `Domain/ConversationSearch.swift` — index en mémoire, insensible à la casse et aux accents, plusieurs mots = ET. ⌘F dans le fil : barre dédiée, surlignage, ⏎ / ⇧⏎ pour naviguer. Index iMessage par une passe SQL bornée (`fetchSearchIndex`), Signal et WhatsApp depuis leurs caches disque | — | — |
| Épingles | `TOGGLE_THREAD_PIN` ⌘P, `Pinned chats can't be archived` | **Fait + persisté** : `togglePinned`, `UserDefaults correspondance.pinnedConversationIDs` | — | — |
| Muet | `TOGGLE_THREAD_MUTE` ⌘⇧M | **Fait** : `mutedIDs` persistés, respectés par les notifications *et* par la pastille du Dock | — | — |
| Non-lus / marquer lu-non lu | `TOGGLE_THREAD_READ` ⌘⇧U, `SELECT_NEXT_UNREAD_THREAD` ⌘U, `Mark All as Read` | **Fait localement** : `clearUnread`, `markUnread`. iMessage renvoie toujours 0 non-lu | S | P1 |
| Rappels / snooze | `OPEN_REMIND_LATER_MENU` ⌘L ; « Remind Me marks this chat as new at the scheduled time, if there is no reply » ; API `POST /v1/chats/{id}/reminders` (`remindAt`, `dismissOnIncomingMessage`) + champ `snooze` | **Fait** : `ConversationReminder` (`Domain/InboxFiltering.swift`) — le fil revient dans la file à l'heure dite **si personne n'a répondu entre-temps**, section « Rappels » dans la liste (`InboxListPane`), état porté par le Relais (`ConversationStateSnapshot`) donc partagé Mac/iPhone. Vocabulaire « Rappel », pas « Snooze » (cf. contradiction bundle/API en annexe) | — | — |
| Filtres | `TOGGLE_FILTER_UNREAD` ⌘⇧Y, `CYCLE_TABS` ⌥⇥ ; jeu de dossiers `UNREAD, UNRESPONDED, DRAFTS, ARCHIVED, MUTED, HIDDEN, REQUESTS, LOW_PRIORITY, REMINDERS, SCHEDULED` ; API `chats/search?inbox=primary` / `low-priority` / `archive` | **Fait** : `.scheduled` ajouté à `ConversationFilter`, logique pure testée dans `Domain/InboxFiltering.swift`. Mac : rangée de pilules ⌘⇧Y (masquée par défaut) — Non-lus / Sans réponse / Brouillons / Programmés + un cran par réseau branché ; ne touche que la liste, jamais la file Focus. iOS : ces filtres sont des jetons sous le titre de l'inbox ; « Programmés » a son écran dans le menu « … » plutôt qu'un jeton | — | — |
| Filtre par compte / réseau | `FILTER_ACCOUNT` ⌘⌥A | **Fait** : pilule par réseau dans la rangée de filtres Mac ; `networkFilter` existait déjà sur iOS | — | — |
| Tri / sections | Sections Pins / Inbox / Archive / Low Priority (help : Inbox tips) | **Fait, différemment** : `InboxStore.sortForInbox` + sections « Récents / Groupes Signal / Contacts » (`InboxListPane.section`) | — | — |
| Liste compacte | Réglage `COMPACT_CHAT_LIST` | **Fait** : `isSidebarCompact`, clé `correspondance.sidebarCompact` | — | — |
| Sélection multiple | `TOGGLE_CHAT_SELECTION_MODE`, `%d chat selected`, `Moved %d chat to Inbox` | **Fait sur Mac** : mode sélection (case sur la ligne, barre de pied Archiver / Marquer lu / Muet — « Muet » coupe, il ne bascule pas). iOS non repris | — | P2 (iOS) |
| Low Priority | `Add chats to Low Priority to hide them from the inbox permanently` | **Absent** | S | ✗ (redondant avec l'archive ; deux poubelles = deux dettes) |
| Demandes de message / inconnus | `Requests`, `No mysterious strangers in your inbox`, réglage `ENABLE_MESSAGE_REQUESTS` | **Fait** : section « Demandes » dans la liste (`InboxListPane`, `store.requestsQueue`), fils annoncés comme demandes par le pont (`MatrixRoomModel.isNetworkFlaggedRequest` → `networkFlaggedRequestIDs`), tenus hors de la file tant qu'on n'accepte pas — le mot du domaine est « Demande » (`CONTEXT.md`) | — | — |
| Labels / Spaces | `Create Label`, `Edit Spaces`, `TOGGLE_FILTER_BAR` ⌘S, `SWITCH_FIRST_9_ACCOUNTS` ; blog 2025-12-08 et 2026-08-10 | **Absent** | L | ✗ (organiser au lieu de traiter — anti-Focus) |
| Suppression / quitter | `Chat: Delete` (désactivé par défaut), `Leave Chat` | **Partiel Signal** : `leaveGroup` (`quitGroup --delete`), `clearChatHistory` | — | — |
| Messages éphémères | `%1$s set new messages to disappear after %2$s.` | **Fait pour Signal** : `setDisappearingMessages`, menu 30 s → 4 semaines | — | — |

### 3. Fil de conversation

| Fonction | Beeper (preuve) | Correspondance | Effort | mautrix | Prio |
|---|---|---|---|---|---|
| Réactions | `OPEN_REACTION_PICKER` (→), `QUICK_REACT_SELECTED` ⌘⇧R, `Quick reaction emoji`, `Remove %s reaction` ; API `POST /v1/chats/{c}/messages/{m}/reactions` (`reactionKey`) | **Fait en lecture partout, en écriture sur 2 réseaux sur 3.** Réception : `m.reaction` + `m.room.redaction` (WhatsApp), `dataMessage.reaction` rattachée à sa cible et non plus muée en faux message (Signal), tapbacks `associated_message_type` 2000-3005 (iMessage). Envoi : `m.reaction` / redaction (WhatsApp), `sendReaction` (Signal). **iMessage en lecture seule** : Messages n'expose aucune commande AppleScript de tapback. UI : pastilles sous la bulle, menu contextuel, ⌘⇧R | — | ✅ `ReactionCount: 1` — un seul emoji par personne, appliqué | Partiel (iMessage) |
| Réponses / citations | `QUOTE_AND_REPLY` ⌘R, `Message: Quote or Edit Selected Message` (Entrée) ; API `replyToMessageID` → champ `linkedMessageID` | **Fait en lecture partout, en écriture sur 2 réseaux sur 3.** Réception : `m.in_reply_to` avec nettoyage du repli `> <@…>` (WhatsApp), `dataMessage.quote` (Signal), `thread_originator_guid` résolu contre le fil (iMessage). Envoi : `m.relates_to.m.in_reply_to` + repli (WhatsApp), `--quote-timestamp/-author/-message` (Signal). **iMessage en lecture seule** (AppleScript n'envoie qu'un message nu). ⌘R cite la bulle visée, bandeau annulable au-dessus du composer, citation compacte au-dessus des bulles | — | ✅ | Partiel (iMessage) |
| Édition de message | `EDIT_MESSAGE` ⌘T ; API `messages.update` (changelog 4.2.499) | **Fait, là où le pont le porte.** Réception : `m.replace` appliqué même quand la correction précède sa cible (`pendingEdits`). Envoi : mode correction du composer (bandeau annulable, Entrée envoie, Échap rend le brouillon mis de côté), ⌘T sur Mac — affiché **seulement** sur mes messages des réseaux capables via `Domain/NetworkCapabilities.swift` (testée) : **les quatre ponts la portent** — Meta, WhatsApp et Signal —, iMessage par son chemin d'automatisation à part. **Chacun avec son délai**, et c'est le pont qui le dit : chaque salon porte un `com.beeper.room_features` où se lisent `edit: 2` et `edit_max_age` — 900 s pour Meta et WhatsApp, 86 400 s (et 10 corrections) pour Signal. Relevé sur le relais le 2026-09-02 ; à relire après chaque montée de version d'un pont. Passé le délai le pont **jette la correction sans rien renvoyer** : ni notice, ni accusé d'échec. C'est ainsi qu'une correction envoyée 6 h 42 après coup est restée à `edit_count = 0` dans la base du pont Messenger — corrigée sur le Mac et l'iPhone, intacte dans Messenger. Le délai est maintenant dans la table (`editWindow`, testé) : le geste disparaît quand la fenêtre se ferme, et un envoi tardif est refusé avec un message plutôt qu'en silence | — | ⚠️ Longtemps noté « Meta seulement » : c'était faux pour WhatsApp et Signal | — |
| Suppression | `Delete for Everyone` / `Delete for Me`, `Delete message is not supported for %s yet` ; API `messages.delete` | **Fait.** Clic droit sur une bulle → « Supprimer pour tout le monde… » (mes messages bridgés : une `m.room.redaction` sur l'event, que les ponts traduisent en `revoke` / `remote delete` / `unsend`) et « Supprimer ici… » (tous réseaux : l'identifiant rejoint `Services/HiddenMessageStore.swift`, réappliqué à chaque relecture du fil comme `ArchiveState`, et écarté de la requête catalogue chat.db pour que l'aperçu de la ligne recule d'un message). Confirmation avant, dans les deux cas. iMessage n'a pas de suppression réseau — ni AppleScript ni AX — seule « Annuler l'envoi » (≤ 2 min) existe déjà. **Fenêtre par réseau**, lue dans le `com.beeper.room_features` du salon (`delete_max_age`) : Signal 24 h, WhatsApp 48 h, Meta sans limite. Passé là, `canDeleteEverywhere` retire l'entrée et le blocage se dit en clair — « Supprimer ici » reste, lui, toujours possible | — | ✅ redaction supportée dans les deux sens sur WhatsApp, Meta, Signal, Telegram | — |
| Accusés de lecture | `Seen %s`, `Seen by %1$s & %2$d other`, `Delivered`, réglage `AVATAR_READ_RECEIPTS` ; API champ `seen` (map par participant) | **Fait, détail de groupe compris.** Affichage : coche sous le dernier message sortant du fil ; en groupe, le détail des lecteurs façon Beeper — « Vu par Alice et Bruno », « Vu par Alice, Bruno et 2 autres », « Vu par tout le monde » (`MatrixRoomModel.seenByLabelFR`, Mac et iPhone). La lecture de l'agent cc et des bots ne compte pas comme un « Vu ». Réception : `m.receipt` de la section `ephemeral` du `/sync` → « Vu » sur WhatsApp ; `is_delivered` / `is_read` sur iMessage. Envoi à l'ouverture d'un fil : `POST /rooms/{id}/receipt/m.read/{eventId}` (WhatsApp) et `sendReceipt --type read` (Signal, DM seulement — la commande ne prend pas de groupe). iMessage : c'est Messages qui pose `is_read`, chat.db nous est en lecture seule | — | ✅ `m.receipt` bidirectionnel **sans double puppeting** (MSC2409, `ephemeral_events` par défaut) et le bridge marque tout l'intervalle, pas seulement le dernier message. ⚠️ Aucun accusé de **livraison** n'atteint un client Matrix tiers → on n'affiche jamais « Livré » sur WhatsApp. ✅ **Double puppeting actif** (méthode appservice, `infra/matrix/bootstrap.sh` — voir `docs/MATRIX-SETUP.md` §2 quinquies) : ce que j'envoie et lis depuis le téléphone est reposé sous `@meffysto:correspondance.local` au lieu de mon propre ghost. Ne vaut que pour les événements postérieurs à l'activation | — |
| Indicateurs de frappe | `SHOW_TYPING_INDICATOR`, `Notify when someone starts typing (supported platforms only)`, `Show recipients I'm typing` | **Fait, bidirectionnel** : réception par l'EDU `m.typing` avec expiration à 20 s (`MatrixRoomModel.typingLabelFR` — « Alice écrit… », « 3 personnes écrivent… »), affichée en bas du fil sur Mac et iPhone ; émission renouvelée au plus toutes les 10 s (`noteTyping` → `sendTyping`) | — | ✅ `m.typing` bidirectionnel sur WhatsApp, Meta, Instagram, Signal, Telegram | — |
| Pièces jointes — envoi | ⌘O `SEND_FILE`, `Could not attach %s — total size would exceed 90MB.` | **Fait, tout fichier** : `NSOpenPanel` sans restriction de type sur Mac (« Les trois réseaux acceptent n'importe quel fichier »), `.item` sur iOS ; iMessage passe par `send POSIX file` | — | ✅ médias et fichiers partout | — |
| Pièces jointes — affichage | Visionneuse (`Media viewer`, `Preview in Carousel`, `NEXT/PREVIOUS Carousel Item`), ⌘D `DOWNLOAD_ATTACHMENTS` | **Fait pour l'essentiel** : images inline, vidéo lue sur place (lecteur AppKit — le lecteur SwiftUI abattait l'app), audio joué dans la bulle (`AudioMessageView`). Pas de visionneuse plein écran type carrousel, pas de ⌘D « tout télécharger » | S | — | P2 |
| Messages vocaux | ⌘⇧A `Message: Record Audio`, `AUTO_PLAY_NEXT_VOICE_NOTE`, `Mark as played`, transcription | **Fait** : enregistrés et envoyés sur iPhone **et** sur Mac (bouton `waveform` du composer — le mic est déjà la dictée —, bandeau annulable, même pipeline), lus partout (`AudioMessageView`). Pas de transcription | — | ✅ voix supportée WhatsApp, Meta, Instagram, Signal | P2 (transcription) |
| Aperçus de liens | `DISABLE_LINK_PREVIEWS`, `Remove Preview`, `Message: Open First Link` ⌘⇧H | **Fait** : `LinkPreviewStore` (LinkPresentation, cache disque avec vignette), rendu sous la bulle sur Mac et iPhone, réglage d'apparence pour couper | — | — | — |
| Mentions | `%d unread mention`, `unreadMentionsCount` (API) | **Fait en composition** : `@` déclenche l'autocomplétion des membres (`Domain/Mention.swift` — candidats, requête accent-insensible, insertion). Pas de compteur « mentions non lues » dans la liste | S (badge) | ✅ Meta, Instagram, Signal, Telegram | P2 (badge) |
| Sondages | `Create Poll`, `Hide results until end of poll`, `%d vote`, badge `Poll` ; blog 2026-08-10 | **Fait** : création (`sendPoll` → `sendPollStart`), vote (`votePoll` → `sendPollResponse`), dépouillement au rendu du fil (`PollEvent` — la voix arrive souvent avant la question), clôture | — | ⚠️ **WhatsApp uniquement** (polls + votes, bidirectionnel). Meta, Signal, Telegram : ❌ | — |
| Transfert | `FORWARD_MESSAGES` ⌘⇧F, `Forwarding messages through Beeper will not include any attribution` | **Fait** : ⌘⇧F + « Transférer… » au menu de bulle, `ForwardSheet` (Mac et iOS) sur la recherche de conversations existante, renvoi par les chemins d'envoi du fil cible, sans attribution — comme Beeper. Le mode Focus est passé de ⌘⇧F à ⌘⇧O | — | — | — |
| Stickers / GIF | ⌘⇧G `Send GIF` (KLIPY), ⌘⌥⇧S `Send Sticker`, `AUTO_SEND_GIFS` | **Absent** | M | ✅ techniquement | ✗ (le GIF est l'anti-Focus incarné) |
| Groupes | `CREATE_NEW_GROUP` ⌘⇧N, gestion de membres, `group_creation` (capabilities API) | **Fait pour l'essentiel** : renommage (`setRoomName`) et retrait (`kick`) — 403 paré par `withRoomPower`, extrait de l'invitation de cc — depuis la fiche iPhone et la nouvelle `GroupSheet` Mac ; ajout des deux côtés. **Création** (⌥⌘N, Mac seulement) par la commande `create-group` de bridgev2 : WhatsApp (pont ≥ v0.12.5) et Signal (≥ v0.8.7, nom ≤ 32 signes) ; Instagram exclu, l'entrée se masque sans pont capable ; un échec nettoie le salon. Capacités par réseau dans `NetworkCapabilities` | — | ✅ | P2 (création iOS) |
| Avatars par expéditeur | Avatars dans le fil + `AVATAR_READ_RECEIPTS` | **Fait** : la photo de l'auteur dans la marge gauche de chaque prise de parole en Inbox (`Features/Inbox/MessageAvatarView.swift`). Tête-à-tête : le visage du fil ; groupe : celui du membre — carnet d'adresses pour un handle iMessage, `m.room.member` → `avatar_url` pour un ghost mautrix (`SenderAvatarStore`, même cache disque que les portails) ; à défaut les initiales sur une couleur tirée de l'auteur. Réglages › Apparence › Fil coupe l'affichage. La page Focus reste sans visages — elle se lit comme une lettre | — | — | — |
| Fiche conversation | `TOGGLE_THREAD_INFO` ⌘⇧I, `%s — Chat Info` | **Partiel** : fiche sur iPhone (`ThreadInfoSheet` — membres, médias du fil, inviter cc), tiroir du « + » sur Mac. Pas de ⌘⇧I ni de fiche complète sur Mac | S | — | P2 |
| Historique / backfill | `We're syncing your chats. This may take a while...` | **Fait Matrix** : `MatrixBridgeService.backfill(conversationID:limit:)` | — | — | — |

### 4. Composition

| Fonction | Beeper (preuve) | Correspondance | Effort | Prio |
|---|---|---|---|---|
| Brouillons par conversation | `Filter: Drafts`, `No drafts…`, champ `draft{text, attachments}` sur l'objet Chat (API), `PATCH /v1/chats/{id}` avec `draft` | **Fait** : `Services/DraftStore.swift` — texte **et** pièces jointes en attente, par `conversationID`, persistés en JSON dans Application Support et restaurés au retour sur le fil. Écriture différée (600 ms) pour ne pas écrire à chaque frappe ; les pièces jointes disparues du disque sont écartées au chargement. Filtre « Drafts » non repris | — | P1 (filtre) |
| Envoi et nouvelle ligne | `SEND_MESSAGE` Entrée, `NEW_LINE` ⇧/⌥/⌃+Entrée | **Fait** : `onKeyPress(.return)`, `.shift` → `.ignored`, `TextField(axis: .vertical)` | — | — |
| Envoyer et archiver | `SEND_MESSAGE_AND_ARCHIVE` ⌘Entrée | **Fait** : `InboxStore.sendDraftAndArchive()`, commande de menu ⌘Entrée (vaut donc en Inbox *et* en Focus). Un envoi échoué restaure le brouillon et n'archive pas | — | — |
| Annuler l'envoi | `Allow undo send (%s) for`, `UNDO_SEND_DELAY_MS`, `Click pending messages to undo send` | **Fait** : `Domain/UndoSendDelay.swift` (0/3/5/10 s, défaut 5, testé), Réglages › Envoi des deux côtés. Bulle optimiste immédiate, réseau différé, « Annuler » rend texte + pièces jointes + citation. ⌘Entrée archive tout de suite et l'annulation désarchive (la boucle Focus n'attend pas). Limite : le bouton n'apparaît que dans le fil de l'Inbox — Focus et fenêtres détachées diffèrent l'envoi sans le bouton | — | — |
| Échec d'envoi / renvoi | `Message failed to send`, `Retry`, `Resend`, `Queued` | **Partiel** : `sendDraft()` retire le message optimiste, restaure texte et pièces jointes, alerte globale. Pas de badge d'échec persistant, pas de renvoi, pas de file hors-ligne | M | P1 |
| Dictée | `SHOW_TRANSCRIBE_BAR` ⌘⇧T « Talk to Type » (audio → OpenAI via serveurs Beeper) | **Fait, et mieux** : `ComposerDictation.swift`, `SFSpeechRecognizer` on-device + repli dictée système. Aucune donnée ne sort de la machine | — | — |
| Envoi planifié | `SCHEDULE_MESSAGE` ⌘⇧L, `Reschedule message`, `Cancel schedule message`, `sendLaterConfig{sendOn, sendOnlyOnNoResponse}`, dossier `Send Later`, « can only send if app is running » | **Fait** : `Domain/SendLaterTime.swift` (« demain 9h », « lundi matin », « dans 2h », raccourcis) + `ScheduledMessage` persisté (`scheduled-messages.json`). ⌘⇧L ou l'horloge du composer pose l'heure sur le composer (bannière) ; Entrée programme, ⌘Entrée programme *et* archive. Bulle en pointillé en bas du fil (envoyer maintenant / reprogrammer / supprimer), bouton « Programmés » au bas du rail. Option « seulement s'il n'a pas répondu ». Boucle d'échéance dans `InboxStore` — même limite que Beeper : l'app doit tourner | — | — |
| Réponses rapides / modèles | `Create New Quick Reply`, `QUICK_REPLIES` | **Absent** | S | ✗ (réponse mécanique — l'inverse du fil qu'on écrit) |
| Texte enrichi | ⌘B / ⌘I / ⌘⇧X / \` , `SHOW_FORMATTING_MENU`, Markdown accepté par l'API | **Absent** : `TextField` brut, envoi `m.text` sans `formatted_body` | M | P2 (et **Matrix→Signal perd le formatage** — ROADMAP mautrix-signal) |
| Emoji | `EMOJI_PICKER_OPEN_ON_HOVER`, `ENABLE_EMOJI_AUTOCOMPLETE`, `DISABLE_EMOTICON_REPLACEMENT` | **Absent** | S | P2 |
| Rédaction assistée par IA | `Draft response with AI`, `AI Mentions System Prompt`, `Beeper AI` (ChatGPT / OpenAI-compatible) | **Autre chemin, volontairement** : pas de Writing Tools (décision gelée dans `PRODUCT.md`), mais l'agent « cc » vit *dans* les fils — invité sur MON invitation, ses propositions restent des brouillons à moi (`isAgentProposal` : jamais l'aperçu de la ligne, jamais la date du fil). Voir § « IA & écosystème » | — | — |

### 5. Notifications & Focus

| Fonction | Beeper (preuve) | Correspondance | Effort | Prio |
|---|---|---|---|---|
| Notifications système | `Enable notifications`, `MESSAGE_NOTIFICATIONS`, `macOS Notifications`, `Open Notifications in System Preferences`, `notification replied` | **Fait** : `Services/NotificationService.swift` + `Domain/NotificationPolicy.swift`. Notification par message entrant, tous réseaux ; respecte `mutedIDs`, le fil ouvert et les messages sortants ; clic → sélection du fil. Autorisation au premier lancement + bouton dans Réglages | — | — |
| Badge Dock | `Dock badge count`, `BADGE_COUNT` | **Fait** : `NotificationService.updateDockBadge`, total des non-lus hors archivés et muets | — | — |
| Répondre depuis la notification | `notification replied`, `notification action button ⇒ Remind in 1 Hour / 8 Hours` | **Fait** : `UNTextInputNotificationAction` dans `NotificationService` — on répond sans ouvrir l'app. Pas d'action « Me le rappeler » sur la notification | — | — |
| Regroupement / anti-spam | `DEBOUNCE_NOTIFICATIONS` (« delay and batch notifications for successive texts… OTP/2FA codes are always notified immediately »), `RENOTIFY_UNREAD_DELAY` | **Fait** : `Domain/NotificationGrouping.swift` + `Domain/OneTimeCode.swift` (testés) — rafale < 15 s du même fil = UNE notification qui remplace la précédente (« et N autres messages ») ; un code OTP/2FA détecté notifie immédiatement, sous sa propre identité. Branché sur Mac et sur les notifications locales iOS | — | — |
| Sons | `NOTIFICATION_SOUND_NAME`, sons par réseau (help/desktop) | **Absent** | S | P2 |
| Notifier quand l'app est au premier plan | `NOTIFY_IN_FOCUS` | **Absent** | S | ✗ (notifier ce qu'on regarde déjà) |
| Réagir aux réactions | `NOTIFY_FOR_REACTIONS` | **Absent** | S | ✗ |
| Mode Focus « une conversation » | **N'existe pas chez Beeper** | **Fait — notre différenciation** : `FocusConversationView`, chrome fantôme, atténuation à 0.34 pendant la frappe, `focusPrevious/focusNext/archiveSelected`, `FocusTranscriptView` en prose | — | — |
| Incognito (lecture sans accusé) | `Incognito mode keeps chats unread even when you click on them and doesn't notify recipients you've read them` | **Absent** | M | P2 (à considérer *après* les accusés de lecture, comme leur interrupteur) |
| Nudge / secouer la conversation | `Shake the conversation when someone sends you a nudge`, `You got nudged!` | **Absent** | — | ✗ |

### 6. Données

| Fonction | Beeper (preuve) | Correspondance | Effort | Prio |
|---|---|---|---|---|
| Sync temps réel | WebSocket local `ws://localhost:23373/v1/ws` : `chat.upserted`, `message.upserted`, `message.deleted` (developers.beeper.com/desktop-api/websocket-experimental) | **Fait sur les trois réseaux** : Matrix en long-poll `/sync` 30 s avec backoff 2→60 s ; Signal en polling 10 s ; **iMessage par `Services/IMessageWatcher.swift`** — `DispatchSource` sur `chat.db-wal`, debounce 500 ms, rafraîchissement incrémental (conversations iMessage + fil ouvert, sans toucher aux autres réseaux). Le point de contrôle SQLite qui recrée le WAL est géré par un ré-armement | — | — |
| Cache disque / démarrage instantané | `Storage by Chat`, `Clear storage older than` | **Fait** : `hydrateFromDiskCache()` sur 4 caches JSON (`imessage-`, `signal-`, `matrix-conversations.json`, `contacts-index.json`) | — | — |
| Hors-ligne | `Offline`, `Queued` | **Partiel** : lecture hors-ligne OK ; l'**état** (archive, épingle, rappel…) part dans une file persistée et rejouée dans l'ordre (`relayQueue`, `flushRelayWrites` — un échec arrête la passe sans rien perdre) ; les **messages** restent sans file (échec immédiat, texte restauré) | M | P1 (messages) |
| Export | `Export all loaded messages to .txt file` | **Absent** | S | P2 |
| Gestion du stockage | `Clear Storage`, `Storage by Chat`, `Calculating message storage...` | **Absent** | S | P2 |
| Chiffrement / clé de récupération | `Recovery Key`, `On-device encryption`, `Emoji Verification` ; API `app/setup/recovery_key`, `verifications/sas` | **Hors sujet** : nos salons de bridge sont non chiffrés par choix (`encryption.allow: false`, `PLAN-matrix.md`) — homeserver privé sur Tailscale | — | — |
| API locale / MCP | `A third-party app <app/> wants to access your chats through Beeper Desktop API.` ; `/v0/mcp` dans `build/main`, OpenAPI « Beeper Client API 5.0.0 ». Ré-audit 2026-08-31 : intégrations **prêtes à l'emploi** pour Claude Desktop, Claude Code, Cursor, Raycast, VS Code, Codex (`Copy Config` / `Copy Command`, transport `Streamable HTTP`) | **Absent** — voir § « IA & écosystème » | L | P2 |

### 7. Multi-appareils

| Fonction | Beeper | Correspondance | Effort | Prio |
|---|---|---|---|---|
| iOS / Android | Apps natives, `UNNotificationServiceExtension` (blog 2025-10-01), CarPlay, swipe-to-archive, labels mobiles | **Fait pour iOS** : app native complète (`CorrespondanceiOS` — Connexion, Inbox, Fil, Focus, Recherche, Réglages) + extension de notification (`CorrespondanceiOSNotificationService`), sur le pari gagné du client Matrix REST pur. Notifications : locales depuis la boucle `/sync` (politique du Mac réutilisée, regroupement + OTP compris), pusher posé au Relais, délégué qui ouvre le fil — mais le **réveil téléphone éteint attend l'infra** : clé APNs `.p8` + `bootstrap.sh` avec Sygnal sur le NUC (le service existe dans `infra/matrix/docker-compose.yml`, commit `3f659ed`, jamais déployé). Android hors-cible | — | P1 (infra push) |
| Métadonnées synchronisées entre appareils | help : en On-Device, « metadata (including archive status) syncs between Beeper apps » | **Fait** : l'état de conversation (archivée, épinglée, muette, fusionnée, rappel, brouillon) vit sur le Relais (`ConversationStateSnapshot`), adopté à chaque `/sync` (`adoptRelayState`) après une migration unique de l'état local — « cet état appartient à l'utilisateur, pas au réseau » (`CONTEXT.md`) | — | — |
| Verrouillage biométrique | `REQUIRE_TOUCH_ID_AUTH` | **Absent** | S | P2 |

### 8. Accessibilité

| Fonction | Beeper | Correspondance | Effort | Prio |
|---|---|---|---|---|
| Taille de texte | `FONT_SIZE`, ⌘+ / ⌘- / ⌘0 (`ZOOM_IN/OUT/RESET`) | **Partiel** : `themes.typeScale` (0.9→1.25) n'affecte que le corps Focus. `Design/Typography.swift` n'utilise que des **points fixes** (13.5, 11, 15…), aucun `ScaledMetric`, aucun `Font.TextStyle` | M | P1 |
| Réduire la transparence | `REDUCE_TRANSPARENCY` | **Absent** ; usage massif d'opacités faibles (`0.34`, `0.55`, `inkTertiary`) non vérifiées en contraste | S | P1 |
| Réduire les animations | `ENABLE_MESSAGE_ANIMATIONS` | **Fait** : `@Environment(\.accessibilityReduceMotion)` respecté en 4 points | — | — |
| VoiceOver | Electron/ARIA | **Faible** : 10 usages d'API d'accessibilité. Les lignes de conversation (`ConversationRowView`) n'ont pas de label composite ; les bulles n'annoncent ni expéditeur ni heure ; `ConversationAvatarView` annonce **le réseau, pas le contact** ; `SettingsView` n'est pas étiqueté | M | P1 |

### 9. Raccourcis clavier

Beeper expose **73 raccourcis réassignables** (registre extrait de `build/renderer/App-UJt62Rak.js`, réglages → Hotkeys, ⌘/ pour la liste).
Correspondance en a **19** (`App/CorrespondanceCommands.swift`, recompté 2026-08-31) + Entrée / ⇧Entrée / Échap.

| Beeper | Correspondance | Prio |
|---|---|---|
| ⌘K `SEARCH` · ⌘F `SEARCH_ROOM` | champ `.searchable` de la liste · **⌘F** ✅ | — |
| ⌘J `TOGGLE_COMMAND_BAR` (barre de commandes) | absent | ✗ (une palette de commandes est un aveu de complexité) |
| ⌘E / `e` `TOGGLE_THREAD_ARCHIVE` | **⌘E Archiver** ✅ | — |
| ⌘⇧E `ARCHIVE_ALL_READ_THREADS` | absent (⌘⇧E sert à ouvrir la vue « Archivés ») | P1 |
| ⌘[ / ⌥↑ `SELECT_PREV_THREAD` · `SELECT_NEXT_THREAD` | **⌘↑ / ⌘↓** ✅ (touches différentes) | — |
| ⌘U `SELECT_NEXT_UNREAD_THREAD` | absent | P1 |
| ⌘⇧U `TOGGLE_THREAD_READ` · ⌘⇧M mute · ⌘P pin | absent (actions présentes au menu contextuel) | P1 |
| ⌘R `QUOTE_AND_REPLY` | **⌘R** ✅ (« Actualiser » déplacé en ⌘⇧R, et le quick react en ⌘⌥R) | — |
| ⌘T `EDIT_MESSAGE` · → `OPEN_REACTION_PICKER` · ⌘⇧R quick react | **⌘⌥R** ✅ (menu contextuel pour le choix d'emoji) ; ⌘T absent | P1 |
| ⌘L `OPEN_REMIND_LATER_MENU` · ⌘⇧L `SCHEDULE_MESSAGE` | **⌘⇧L Envoyer plus tard** ✅ ; ⌘L absent | P1 |
| ⌘Entrée `SEND_MESSAGE_AND_ARCHIVE` | **⌘Entrée** ✅ | — |
| ⌘N `CREATE_NEW_CHAT` · ⌘, `TOGGLE_PREFS_PANE` | **⌘N / ⌘,** ✅ | — |
| ⌘O `SEND_FILE` · ⌘D `DOWNLOAD_ATTACHMENTS` | absent | P1 |
| ⌘⇧Y filtre non-lus · ⌥⇥ `CYCLE_TABS` · ⌘⌥A filtre compte | absent | P1 |
| ⌘/ `TOGGLE_HOTKEYS_MODAL` | absent | P2 |
| ⌘+ / ⌘- / ⌘0 zoom · ⌘⌥S sidebar · ⌘⇧I chat info | absent | P1/P2 |
| ⌃⇥ `CYCLE_CHATS` · ⌃⌥← / → historique de navigation | absent | P2 |
| ↑ / ↓ / ⇧↑ / ⇧↓ sélection de messages | absent | P1 |

---

## IA & écosystème — le vrai delta du ré-audit 2026-08-31

Le bundle 4.3.73 révèle une couche IA bien plus large que « Draft with AI » : c'est là que Beeper
investit, et c'est le seul terrain où l'écart se creuse au lieu de se refermer.

**Mais elle est verrouillée, à trois niveaux** (vérifié le 2026-08-31 sur un compte réel **Free** :
le panneau IA ne montre que traduction, transcription Whisper et Mentions IA, tous « + Plus ») :
les chats IA sont derrière un drapeau **serveur** `ai-in-beeper-chats` (`features[AI_IN_BEEPER_CHATS]?.use`
— déploiement progressif, pas un réglage local) ; le panneau « Integrations » (Desktop API / MCP)
n'apparaît que si le drapeau **Labs** `DESKTOP_LABS_BEEPER_CONNECT` est actif ; et la transcription
comme les Mentions IA exigent **Beeper Plus**. C'est l'illustration de la limite n° 2 de l'annexe :
une chaîne prouve une intention, pas une disponibilité. La couche décrite ci-dessous est donc
l'endroit où Beeper *va*, pas ce que voit un compte gratuit aujourd'hui — la doc publique de
`developers.beeper.com` (Desktop API, MCP) confirme que c'est un produit réel, en rollout.

**Ce que le bundle montre** (chaînes d'UI, ré-extraction du 2026-08-31) :
- **Chats IA de plein droit** : `New AI Chat`, `Start a new AI chat`, sélecteur `All models`,
  `Apple Intelligence`, `On-Device` — la conversation avec un modèle est un fil comme un autre.
- **Un agent outillé, pas un complèteur** : `Running agent`, `Calling LLM`, `Run command`,
  `Web search`, `Fetch web`, `Read file`, `Find files`, `Write`, `Generate image`,
  `Code interpreter`, `Update todos`, `Read chat context` — l'IA de Beeper lit les fils et agit.
- **Serveur MCP local + intégrations prêtes** (panneau « Integrations », Labs) : tuiles
  `Claude Desktop` (extension `.dxt` téléchargée), `Claude Code`, `Cursor`, `Raycast`, `VS Code`,
  `Codex`, transport `Streamable HTTP`, boutons `Copy Config` / `Copy Command`, flux OAuth
  d'approbation par app tierce, jetons révocables, option « Remote Access » (API exposée
  au-delà de la machine) — une fois le Labs actif, un agent extérieur se branche en deux clics.
- **Voix** : `Talk to Type` (dictée via serveurs Beeper) et `Transcribe` sur les vocaux.

**Notre position.** L'agent « cc » est l'inverse structurel de leur approche : il vit *dans* les
fils (un utilisateur Matrix invité par moi, salon par salon) plutôt que dans un panneau latéral,
et ses propositions restent des brouillons à moi. C'est plus radical — et invisible depuis
l'extérieur. Les deux manques réels par rapport à leur couche : **une API locale/MCP** pour que
nos fils soient pilotables par un agent extérieur (P2, tableau § 6), et la **transcription des
vocaux** (`SFSpeechRecognizer` ferait ça on-device, cohérent avec la dictée existante).
« Draft with AI » et « AI Mentions » restent hors-cible (`PRODUCT.md`) ; leur dictée passe par
les serveurs de Beeper, la nôtre reste sur la machine.

---

## Ce que Beeper fait et qu'on ne doit pas copier

| Fonction | Pourquoi c'est hors-cible |
|---|---|
| **Beeper AI / Ask AI / Draft response with AI / AI Mentions** | Décision déjà gelée dans `PRODUCT.md` (« Ne pas reconstruire des Writing Tools ») : Apple Writing Tools et iA Writer couvrent le terrain, et déléguer l'écriture à un modèle contredit une app dont la promesse est *que tu écrives*. Accessoirement, `Privacy: this will send your last n messages in a conversation to OpenAI via our servers` est l'inverse de notre « tout est local ». |
| **Labels, Spaces, barre d'espaces, 9 espaces au clavier** | Ranger n'est pas traiter. Notre file se vide, elle ne se classe pas. Chaque taxonomie ajoutée est une décision de plus par message. |
| **Low Priority** | Une seconde poubelle à côté de l'archive. Si un chat mérite d'être caché en permanence, il mérite d'être quitté. |
| **Barre de commandes ⌘J** | Une palette de commandes est le symptôme d'une surface trop large. Nos actions doivent tenir dans le chrome fantôme du Focus. |
| **GIF (KLIPY), stickers, `AUTO_SEND_GIFS`, emoji autocomplete, remplacement d'émoticônes** | Le contraire exact de l'écriture posée. On lit les réactions reçues ; on ne construit pas d'usine à GIF. |
| **Nudge (« secouer la conversation ») et notifications de réactions** | Interruptions fabriquées. On ne notifie que ce qui demande une réponse. |
| **`NOTIFY_IN_FOCUS`** | Notifier ce que l'utilisateur est en train de regarder. |
| **Quick Replies (réponses préenregistrées)** | Répondre mécaniquement à la place de répondre. |
| **Sound effects sur les messages, animations de bulles, fonds animés** | Notre identité est typographique et silencieuse. |
| **Tableaux de bord de stockage, statistiques d'usage (`@%s sends the most messages`, `*based on 30 days of messages`)** | Gamification du courrier. |
| **Comptes en cloud, clé de récupération, sauvegarde chiffrée serveur** | Nous n'avons pas de serveur : c'est un avantage, pas un manque. |
| **Extension navigateur, Raycast, CarPlay, montres connectées** | Surface de distribution, pas de produit — et pas pour un usage dogfood mono-machine. |

---

## Feuille de route — reste à faire (revue 2026-08-31)

Les lots 1 et 2 de la feuille de route initiale sont **faits** (à trois exceptions près, reprises
ci-dessous), ainsi qu'une bonne moitié du lot 3 (Instagram, sondages, mentions, aperçus de liens,
demandes, envoi planifié, fiche iPhone, sync des métadonnées, iOS lui-même). Voici ce qui reste,
par paquet et par ordre d'importance.

### Lots A, B, C — faits le 2026-09-01

Implémentés et testés (500 tests du package, builds Mac + iOS) — commits `8a1b371` (cycle de vie),
`27adebc` (filtres & gestes), `c710f76` (groupes), `b1992e1` (notifications iOS). Reliquats connus :
« Annuler l'envoi » n'a son bouton que dans le fil de l'Inbox (Focus et fenêtres détachées diffèrent
sans bouton) · sélection multiple Mac seulement · création de groupe Mac seulement, et à valider
contre les versions de ponts du Relais (mautrix-whatsapp ≥ v0.12.5, signal ≥ v0.8.7) · transcription
des vocaux absente · l'App Group `group.com.correspondance` n'est déclaré dans aucun entitlement
(l'extension de notification ne voit pas les muets — fail-open) : à créer au portail Apple puis
régénérer les deux profils.

### Lot D' — push iOS de bout en bout (infra, à faire à la main)

1. Créer une clé APNs `.p8` au portail Apple (Team ID `AKMNXGVVGX`). 2. La poser en
`nuc:~/correspondance-matrix/secrets/apns/apns.p8` (`chmod 600`). 3. `APNS_KEY_ID=… APNS_TEAM_ID=AKMNXGVVGX
APNS_PLATFORM=sandbox ./infra/matrix/bootstrap.sh` — le compose déployé est antérieur au service
`sygnal`, c'est le bootstrap qui l'installe. 4. Vérifier `http://sygnal:5000/health` depuis le
conteneur Synapse ; le pusher est déjà en base, redémarrer Synapse pour sauter le backoff.
5. Au passage App Store : `aps-environment` **et** `APNS_PLATFORM` basculent en production ensemble.

### Lot E — réseaux (P1/P2, ≈ 2 L)

**Messenger** (`mautrix-meta`) : ✅ fait — second conteneur de la même image, tag `v26.08` nu.
Reste **Telegram** (`mautrix-telegram`) · Multi-comptes par réseau (sortir `account = "default"`
de `MatrixCredentialStore`).

### Lot F — écosystème & finitions (P2)

API locale/MCP (nos fils pilotables par un agent extérieur — voir § « IA & écosystème ») ·
Transcription des vocaux on-device · Étendre « Annuler l'envoi » au Focus et aux fenêtres détachées · Texte enrichi Markdown → `formatted_body` (⚠️ perdu vers Signal) ·
Incognito (interrupteur des accusés) · Zoom ⌘+/⌘-/⌘0 et accessibilité (`ScaledMetric`, labels
composites VoiceOver, `accessibilityReduceTransparency`) · Verrouillage biométrique · Export `.txt` ·
Gestion du stockage · Sons de notification.

---

## Annexe — méthode

### Version analysée
`Beeper Desktop 4.3.73`, `com.automattic.beeper.desktop`, Mach-O thin arm64, signature runtime durcie.
`package.json` : `"name": "BeeperTexts"`, `"author": "Automattic, Inc."`, dépendances `@beeper/beeper-client-sdk@3.0.0-latest`, `better-sqlite3`, `keytar`, `node-mac-contacts`, `node-mac-permissions`.
Analysé le 2026-08-29. Bundle **jamais modifié** ; extraction en scratchpad, supprimée à la fin.

**Ré-audit du 2026-08-31** (même version 4.3.73, toujours sans exécution) : ré-extraction de l'asar,
inventaire par les littéraux des bundles `build-browser/*.js` (labels `label:`/`title:`, chaînes
localisées inline — il n'y a pas de catalogue i18n séparé dans `build-browser`). C'est ce ré-audit
qui a mis au jour la surface IA/MCP du § « IA & écosystème » (tuiles `Claude Desktop`, `Claude Code`,
`Cursor`, `Raycast`, `VS Code`, `Codex`, `Streamable HTTP`, outils d'agent). Côté Correspondance,
chaque statut modifié ce jour-là a été revérifié dans le code (fichier cité dans la cellule).

### Commandes exactes

```sh
# Version et signature
defaults read "/Applications/Beeper Desktop.app/Contents/Info.plist" CFBundleShortVersionString
codesign -dv "/Applications/Beeper Desktop.app"

# Extraction (lecture seule du bundle, écriture dans le scratchpad uniquement)
npx --yes @electron/asar extract \
  "/Applications/Beeper Desktop.app/Contents/Resources/app.asar" "$SCRATCH/beeper"

# Structure
du -sh "$SCRATCH"/beeper/build/*        # renderer 22M, main 12M, platform-imessage 4,7M, ffmpeg/ffprobe 11M
cat "$SCRATCH"/beeper/package.json

# Catalogue i18n complet (les msgid anglais servent d'inventaire de l'UI) :
# build/renderer/matrix-util-B0YOoZD2.js contient les catalogues de/es/fr/ja/pt sous la forme "msgid":["traduction"]
python3 -c 'import re,sys;s=open(sys.argv[1],encoding="utf8",errors="replace").read();
print("\n".join(sorted({k for k in re.findall(r"\"((?:[^\"\\\\]|\\\\.){2,200})\":\\[\"",s) if re.search(r"[A-Za-z]",k)})))' \
  "$SCRATCH"/beeper/build/renderer/matrix-util-B0YOoZD2.js > "$SCRATCH"/beeper-strings.txt   # 2446 chaînes

# Registre des raccourcis (73 entrées) — build/renderer/App-UJt62Rak.js
python3 -c 'import re,sys;s=open(sys.argv[1],encoding="utf8",errors="replace").read();
pat=re.compile(r"([A-Z][A-Z0-9_]{3,}):\\{key:(dt\\(\"([^\"]+)\"\\)|\"([^\"]+)\"),displayName:\\(\\)=>(?:z\\()?g\\(\"((?:[^\"\\\\]|\\\\.)*)\"");
[print(m.group(1), m.group(3) and "mod+"+m.group(3) or m.group(4), m.group(5)) for m in pat.finditer(s)]' \
  "$SCRATCH"/beeper/build/renderer/App-UJt62Rak.js

# Clés de réglages (énumération de 181 clés autour de AFTER_TOGGLE_READ, même fichier)
grep -o "PRIMARY_THREAD_ACTION.\{0,300\}" "$SCRATCH"/beeper/build/renderer/App-UJt62Rak.js

# API locale
grep -ohE '"/v0/[a-zA-Z0-9/{}._-]*"' "$SCRATCH"/beeper/build/main/*.mjs        # -> "/v0/mcp"
grep -oh "openapi.\{0,200\}" "$SCRATCH"/beeper/build/main/openapi-BU0ptpM4.mjs # -> "Beeper Client API" 5.0.0

# Nettoyage
rm -rf "$SCRATCH"/beeper
```

### Ce qui a servi de preuve
- **Chaînes d'UI** : les 2446 msgid du catalogue i18n — c'est l'inventaire le plus fiable, une fonction sans chaîne n'a pas d'UI.
- **Registre de raccourcis** : 73 entrées `ID:{key, displayName, group}` — donne les touches exactes que la doc publique ne publie pas.
- **Énumération des réglages** : 181 clés (`AFTER_ARCHIVE`, `NATIVE_ARCHIVE`, `DEBOUNCE_NOTIFICATIONS`, `UNDO_SEND_DELAY_MS`…), plus fiable que les libellés pour les comportements par défaut.
- **Arborescence de modules** : `build/platform-imessage/darwin-arm64` (bridge iMessage natif embarqué, avec les images de tapback), `build/ffmpeg`/`ffprobe`, `build/omr`, `build/opusdec` (notes vocales), `build/browser-session-import` (import de sessions via cookies navigateur), `build/ContactsServer`.

### Limites
1. **Aucune décompilation** au-delà des chaînes et de la structure des modules ; aucune recherche de secret, de clé ou de contournement d'authentification. Les bundles sont minifiés : les identifiants de fonctions sont illisibles, seules les chaînes littérales sont exploitables.
2. **Une chaîne prouve une intention, pas un comportement** : certaines fonctions peuvent être derrière un drapeau (`show_hidden_features`, `Enable hidden features`, `PRO_MODE`, `IN_WAITLIST`) ou réservées à Beeper Plus (`%s (Upgrade to Beeper Plus)`).
3. **Beeper 4.3.73 n'a pas été exécuté** — aucun compte connecté, aucune vérification empirique du comportement décrit.
4. `help.beeper.com/en_US/quick-references/beeper-chat-support-matrix` (la matrice officielle de support par réseau) **répond actuellement « We couldn't find that »** : le tableau mautrix ci-dessus vient donc des `ROADMAP.md` des dépôts, pas de Beeper.
5. `docs.mau.fi/bridges/general/features.html` est en **404** ; les matrices utilisées sont celles de `github.com/mautrix/{whatsapp,meta,signalgo,telegram}/blob/main/ROADMAP.md`.
6. L'inventaire Correspondance est un instantané : l'arbre de travail était modifié en parallèle (`Domain/MessageDelivery.swift` venait d'apparaître).

### Contradictions relevées entre le bundle et la documentation

| Point | Bundle | Doc publique | Lecture |
|---|---|---|---|
| Surface d'API | `build/main` n'expose que `/v0/mcp` + un OpenAPI « Beeper Client API 5.0.0 » aux `operationId` très Matrix (`createRoom`, `getRoomState`, `setAccountData`) | `developers.beeper.com` documente exclusivement `/v1/*` (migration gRPC `/v0` → REST `/v1` annoncée en 4.1.294) | `/v0/mcp` survit à la migration ; l'OpenAPI embarqué décrit la couche Matrix sous-jacente, pas l'API Desktop documentée. Les deux coexistent. |
| Périmètre de l'API vs de l'app | Sondages, labels, spaces, Send Later, incognito, typing, fusion de chats — tous présents en chaînes d'UI | Aucun endpoint documenté pour sondages, labels, spaces, Send Later, typing | L'API Desktop est un **sous-ensemble** délibéré de l'app. Ne pas la prendre pour l'inventaire des fonctions. |
| Snooze | **Aucune chaîne `Snooze`** dans le catalogue — l'UI ne parle que de `Remind Me`, `Reminders`, `Low Priority` | L'objet `Chat` de l'API porte un champ `snooze{snoozeUntil, userSnoozedAt}` | Le snooze est un concept d'API / de mobile sans surface sur le Desktop 4.3.73. Chez nous : implémenter le vocabulaire « Rappel », pas « Snooze ». |
| Réseaux | Chaînes `BridgeV2 … login flow name` pour 10 réseaux seulement (pas de Slack, Google Chat, LINE) ; iMessage via le binaire `build/platform-imessage/darwin-arm64` sans flow BridgeV2 | help.beeper.com annonce 12 réseaux + iMessage macOS ; blog 2026-06-23 ajoute LINE | Cohérent : Slack, Google Chat et LINE sont **Cloud uniquement** (help : « Cloud-only networks ») et n'ont donc pas de flow de login on-device dans le bundle. iMessage passe par un binaire natif, pas par un bridge Go. |
| Raccourcis clavier | Registre complet de 73 entrées extractible | `help.beeper.com/en_US/desktop/…keyboard-shortcuts` ne liste **rien** et renvoie à Réglages → Keyboard Shortcuts | Le bundle est ici plus informatif que la doc. |
