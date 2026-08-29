# Parité Beeper Desktop — audit du bundle local 4.3.73

Source primaire : `/Applications/Beeper Desktop.app` (v4.3.73, `com.automattic.beeper.desktop`, Electron, arm64).
Sources secondaires : `developers.beeper.com`, `help.beeper.com`, `blog.beeper.com`, `docs.mau.fi` + `ROADMAP.md` des dépôts mautrix.
Cible comparée : `Correspondance` au 2026-08-29 (branche `main`, arbre de travail en cours de modification).

---

## Résumé

Correspondance a le socle transport : iMessage en lecture/écriture (chat.db + AppleScript), Signal via `signal-cli`,
WhatsApp via Matrix/mautrix avec long-poll `/sync`, cache disque des quatre sources, envoi optimiste, dictée,
mode Focus complet (précédent/suivant/archiver) et un chrome typographique déjà supérieur à Beeper.
Ce qui manque n'est pas du transport : c'est **la couche « inbox qu'on vide »**.
Beeper repose sur quatre piliers absents chez nous : notifications, recherche, archivage durable, et un fil
conversationnel réel (réactions, réponses, accusés).
Aujourd'hui l'app ne prévient de rien, ne retrouve rien, oublie ce qu'on archive au redémarrage, et affiche les
réactions Signal comme de faux messages texte.
Les cinq manques qui coûtent chaque jour, dans l'ordre : **1) notifications système + badge** (sans elles l'app
n'est jamais ouverte au bon moment et le « muet » existant est décoratif) ; **2) archivage persistant + vue Archivés**
(la promesse produit « tu réponds, tu archives » est aujourd'hui perdue au relancement) ; **3) recherche**
(aucune, alors que Beeper en fait son ⌘K central) ; **4) réponses citées + réactions** (envoi et affichage —
tout groupe devient illisible sans elles) ; **5) accusés de lecture** (envoi au réseau *et* affichage : le socle
`MessageDelivery` existe mais aucune vue ne le lit, et on n'a jamais marqué un message lu côté réseau).
Les brouillons par conversation arrivent juste derrière. Rien de tout cela n'est bloqué par mautrix.

---

## Tableau de parité

Légende effort : **S** ≤ 1 jour · **M** 2–4 jours · **L** ≥ 1 semaine.
Légende priorité : **P0** usage quotidien · **P1** confort · **P2** plus tard · **✗** hors-cible (contraire au Focus).

### 1. Réseaux & comptes

| Fonction | Beeper (preuve) | Correspondance | Effort | Prio |
|---|---|---|---|---|
| Réseaux supportés | 12 : Discord, Google Messages, Google Chat, Google Voice, Instagram, LinkedIn, Signal, Slack, Telegram, X, WhatsApp, LINE + iMessage macOS (help.beeper.com/en_US/chat-networks/which-chat-networks-can-you-connect-in-beeper). Bundle : chaînes `BridgeV2 <réseau> login flow name` pour Discord, Google Messages, Google Voice, LinkedIn, Signal, Telegram, WhatsApp, Instagram/Messenger, Facebook/Messenger, X/Twitter | **Partiel** : iMessage, Signal, WhatsApp — `Domain/MessageNetwork.swift` (`fromBridgeProtocol` ne mappe que `whatsapp`/`whatsappgo`) | — | — |
| Instagram / Messenger | `mautrix-meta`, chaînes `BridgeV2 Instagram/Messenger login flow name` | **Absent** (prévu it. 2 de `PLAN-matrix.md`, zéro code) | M | P2 |
| Bridge on-device vs cloud | Chaînes `Beeper On-Device: this account runs on your device.` / `Beeper Cloud` / `Only one account per network can use Beeper Cloud.` ; blog 2025-07-16 « the app connects directly to the messaging networks » | **Fait par construction** : tout est local (chat.db, signal-cli, Synapse perso) — c'est notre avantage structurel | — | — |
| Multi-comptes par réseau | `%d Account Per Network`, `SELECT_NEXT_ACCOUNT ⌘⇧]`, `FILTER_ACCOUNT ⌘⌥A` ; API `GET /v1/accounts` | **Absent** : `MatrixCredentialStore` a `account = "default"` en dur ; un seul `signal-cli` | M | P2 |
| Login guidé par réseau | Flows `login_flows.list` / `login_sessions.create` / `steps.submit` (developers.beeper.com/desktop-api-reference/resources/bridges) ; QR, code d'appairage, 2FA | **Partiel** : WhatsApp OK (`WhatsAppLoginSheet.swift` + `startWhatsAppLogin`), Matrix OK (`SettingsView.matrixSection`). Signal = instruction texte à recopier au terminal | S | P1 |
| Statut de compte | `status ∈ connected, connecting, backfilling, disconnected` + `statusText` (API `Account`) | **Fait** : `SettingsView` — `iMessageStatusFR`, `signalStatusFR`, `contactsStatusFR` | — | — |
| Fusion de chats multi-réseaux (Merge Chats) | `Merge Chats`, `Keep chats merged`, `Merged Chat` ; blog 2026-08-10 | **Absent** | L | P2 |

### 2. Inbox

| Fonction | Beeper (preuve) | Correspondance | Effort | Prio |
|---|---|---|---|---|
| Archivage | `TOGGLE_THREAD_ARCHIVE` = ⌘E ou `e` ; API `POST /v1/chats/{id}/archive` + champ `isArchived` ; « Anything you've handled is in your __ARCHIVE__. » | **Partiel — en mémoire seulement** : `InboxStore.archiveSelected()` met `isArchived = true`, jamais réappliqué au rechargement (`MatrixConversationCache.load()` force `isArchived: false`). Pas de vue Archivés, pas de désarchivage | M | **P0** |
| Archiver tout ce qui est lu | `ARCHIVE_ALL_READ_THREADS` ⌘⇧E, `Archive all read chats` | **Absent** | S | P1 |
| Auto-archivage par règle | `Auto-archive chats based on a rule`, `Archive __TYPE__ chats older than __DURATION__` | **Absent** | M | P2 |
| Sync de l'archivage avec la plateforme native | Réglage `Sync chat archive state with native platform` (clé `NATIVE_ARCHIVE`) | **Absent** | M | P2 |
| Action après archivage | Réglages `AFTER_ARCHIVE` / `AFTER_TOGGLE_READ` → `SELECT_NEXT_THREAD` par défaut | **Fait de fait** : le mode Focus enchaîne déjà (`focusNext()` après `archiveSelected()`) — c'est notre cœur | — | — |
| Recherche | ⌘K global (`SEARCH`), ⌘F dans le fil (`SEARCH_ROOM`) ; API `GET /v1/search`, `GET /v1/messages/search` (filtres `sender`, `mediaTypes`, `dateAfter`, `chatType`) ; « Only messages loaded in Beeper can be searched. » | **Absent** : aucun `.searchable`. Seule recherche = carnet d'adresses (`ContactDirectory.searchPeople`) | M | **P0** |
| Épingles | `TOGGLE_THREAD_PIN` ⌘P, `Pinned chats can't be archived` | **Fait + persisté** : `togglePinned`, `UserDefaults correspondance.pinnedConversationIDs` | — | — |
| Muet | `TOGGLE_THREAD_MUTE` ⌘⇧M | **Fait** : `mutedIDs` persistés, respectés par les notifications *et* par la pastille du Dock | — | — |
| Non-lus / marquer lu-non lu | `TOGGLE_THREAD_READ` ⌘⇧U, `SELECT_NEXT_UNREAD_THREAD` ⌘U, `Mark All as Read` | **Fait localement** : `clearUnread`, `markUnread`. iMessage renvoie toujours 0 non-lu | S | P1 |
| Rappels / snooze | `OPEN_REMIND_LATER_MENU` ⌘L ; « Remind Me marks this chat as new at the scheduled time, if there is no reply » ; API `POST /v1/chats/{id}/reminders` (`remindAt`, `dismissOnIncomingMessage`) + champ `snooze` | **Absent** | M | P1 |
| Filtres | `TOGGLE_FILTER_UNREAD` ⌘⇧Y, `CYCLE_TABS` ⌥⇥ ; jeu de dossiers `UNREAD, UNRESPONDED, DRAFTS, ARCHIVED, MUTED, HIDDEN, REQUESTS, LOW_PRIORITY, REMINDERS, SCHEDULED` ; API `chats/search?inbox=primary` / `low-priority` / `archive` | **Absent** (le rail de réseaux n'existe que dans `PLAN-matrix.md`) | M | P1 |
| Filtre par compte / réseau | `FILTER_ACCOUNT` ⌘⌥A | **Absent** | S | P1 |
| Tri / sections | Sections Pins / Inbox / Archive / Low Priority (help : Inbox tips) | **Fait, différemment** : `InboxStore.sortForInbox` + sections « Récents / Groupes Signal / Contacts » (`InboxListPane.section`) | — | — |
| Liste compacte | Réglage `COMPACT_CHAT_LIST` | **Fait** : `isSidebarCompact`, clé `correspondance.sidebarCompact` | — | — |
| Sélection multiple | `TOGGLE_CHAT_SELECTION_MODE`, `%d chat selected`, `Moved %d chat to Inbox` | **Absent** : `selectedConversationID: String?` | M | P2 |
| Low Priority | `Add chats to Low Priority to hide them from the inbox permanently` | **Absent** | S | ✗ (redondant avec l'archive ; deux poubelles = deux dettes) |
| Demandes de message / inconnus | `Requests`, `No mysterious strangers in your inbox`, réglage `ENABLE_MESSAGE_REQUESTS` | **Absent** | M | P2 |
| Labels / Spaces | `Create Label`, `Edit Spaces`, `TOGGLE_FILTER_BAR` ⌘S, `SWITCH_FIRST_9_ACCOUNTS` ; blog 2025-12-08 et 2026-08-10 | **Absent** | L | ✗ (organiser au lieu de traiter — anti-Focus) |
| Suppression / quitter | `Chat: Delete` (désactivé par défaut), `Leave Chat` | **Partiel Signal** : `leaveGroup` (`quitGroup --delete`), `clearChatHistory` | — | — |
| Messages éphémères | `%1$s set new messages to disappear after %2$s.` | **Fait pour Signal** : `setDisappearingMessages`, menu 30 s → 4 semaines | — | — |

### 3. Fil de conversation

| Fonction | Beeper (preuve) | Correspondance | Effort | mautrix | Prio |
|---|---|---|---|---|---|
| Réactions | `OPEN_REACTION_PICKER` (→), `QUICK_REACT_SELECTED` ⌘⇧R, `Quick reaction emoji`, `Remove %s reaction` ; API `POST /v1/chats/{c}/messages/{m}/reactions` (`reactionKey`) | **Partiel dégradé** : `SignalBridge.parseReceive` transforme `dataMessage.reaction.emoji` en faux message texte ; `MatrixSyncParser.applyMessage` ne traite que `m.room.message` → les `m.reaction` sont perdus. **Envoi absent** | M | ✅ `m.reaction` dans les deux sens sur WhatsApp, Meta, Signal, Telegram | **P0** |
| Réponses / citations | `QUOTE_AND_REPLY` ⌘R, `Message: Quote or Edit Selected Message` (Entrée) ; API `replyToMessageID` → champ `linkedMessageID` | **Absent** | M | ✅ `m.in_reply_to` WhatsApp, Meta, Telegram. Signal : non listé au ROADMAP mautrix-signal | **P0** |
| Édition de message | `EDIT_MESSAGE` ⌘T ; API `messages.update` (changelog 4.2.499) | **Absent et activement ignoré** : `MatrixSyncParser.applyMessage` fait `if rel_type == "m.replace" { return }` → l'original reste affiché, l'édition disparaît | M | ⚠️ `m.replace` OK sur Meta et Telegram ; **non supporté** WhatsApp ni Signal | P1 |
| Suppression | `Delete for Everyone` / `Delete for Me`, `Delete message is not supported for %s yet` ; API `messages.delete` | **Absent** | M | ✅ redaction supportée dans les deux sens sur WhatsApp, Meta, Signal, Telegram | P1 |
| Accusés de lecture | `Seen %s`, `Seen by %1$s & %2$d other`, `Delivered`, réglage `AVATAR_READ_RECEIPTS` ; API champ `seen` (map par participant) | **Partiel non branché** : `Domain/MessageDelivery.swift` + `Conversation.lastDelivery` alimentés par `IMessageDatabase.delivery(...)`, mais **aucune vue ne les lit** ; **aucun envoi** de `m.receipt` ni de read receipt Signal | M | ✅ `m.receipt` WhatsApp/Meta/Instagram. ⚠️ Signal : Matrix→Signal « only marks last message ». ⚠️ Telegram→Matrix : DM seulement. Accusés de *livraison* Signal : non bridgés | **P0** |
| Indicateurs de frappe | `SHOW_TYPING_INDICATOR`, `Notify when someone starts typing (supported platforms only)`, `Show recipients I'm typing` | **Absent** (le `isActivelyTyping` de `FocusConversationView` est local, il masque le chrome — rien n'est émis) | S | ✅ `m.typing` bidirectionnel sur WhatsApp, Meta, Instagram, Signal, Telegram | P1 |
| Pièces jointes — envoi | ⌘O `SEND_FILE`, `Could not attach %s — total size would exceed 90MB.` | **Partiel** : Signal (`-a`) et WhatsApp (upload Matrix) mais **images seulement** (`pickAttachments` : `allowedContentTypes = [.image]`) ; **iMessage bloqué** (message d'erreur explicite dans `sendDraft`) | M | ✅ médias et fichiers partout | P1 |
| Pièces jointes — affichage | Visionneuse (`Media viewer`, `Preview in Carousel`, `NEXT/PREVIOUS Carousel Item`), ⌘D `DOWNLOAD_ATTACHMENTS` | **Partiel** : images inline (`MessageBubbleView.attachmentView`) ; vidéo = étiquette qui ouvre le Finder ; audio/fichiers = trombone inerte | M | — | P1 |
| Messages vocaux | ⌘⇧A `Message: Record Audio`, `AUTO_PLAY_NEXT_VOICE_NOTE`, `Mark as played`, transcription | **Absent** (le parseur accepte `m.audio` mais l'UI ne le joue pas) | M | ✅ voix supportée WhatsApp, Meta, Instagram, Signal | P1 |
| Aperçus de liens | `DISABLE_LINK_PREVIEWS`, `Remove Preview`, `Message: Open First Link` ⌘⇧H | **Absent** | M | — | P2 |
| Mentions | `%d unread mention`, `unreadMentionsCount` (API) | **Absent** | M | ✅ Meta, Instagram, Signal, Telegram | P2 |
| Sondages | `Create Poll`, `Hide results until end of poll`, `%d vote`, badge `Poll` ; blog 2026-08-10 | **Absent** | M | ⚠️ **WhatsApp uniquement** (polls + votes, bidirectionnel). Meta, Signal, Telegram : ❌ | P2 |
| Transfert | `FORWARD_MESSAGES` ⌘⇧F, `Forwarding messages through Beeper will not include any attribution` | **Absent** | S | — | P2 |
| Stickers / GIF | ⌘⇧G `Send GIF` (KLIPY), ⌘⌥⇧S `Send Sticker`, `AUTO_SEND_GIFS` | **Absent** | M | ✅ techniquement | ✗ (le GIF est l'anti-Focus incarné) |
| Groupes | `CREATE_NEW_GROUP` ⌘⇧N, gestion de membres, `group_creation` (capabilities API) | **Partiel lecture** : détection de groupe (`MatrixRoomModel.isGroup`, préfixe `chat` iMessage, `-g` Signal). Pas de création, pas de fiche membres | M | ✅ | P2 |
| Avatars par expéditeur | Avatars dans le fil + `AVATAR_READ_RECEIPTS` | **Partiel** : `ConversationAvatarStore` alimente la sidebar seulement | S | — | P2 |
| Fiche conversation | `TOGGLE_THREAD_INFO` ⌘⇧I, `%s — Chat Info` | **Absent** (`ThreadView.header` = titre + réseau + Archiver) | M | — | P2 |
| Historique / backfill | `We're syncing your chats. This may take a while...` | **Fait Matrix** : `MatrixBridgeService.backfill(conversationID:limit:)` | — | — | — |

### 4. Composition

| Fonction | Beeper (preuve) | Correspondance | Effort | Prio |
|---|---|---|---|---|
| Brouillons par conversation | `Filter: Drafts`, `No drafts…`, champ `draft{text, attachments}` sur l'objet Chat (API), `PATCH /v1/chats/{id}` avec `draft` | **Partiel** : `InboxStore.draftText` est **un seul brouillon global**, remis à `""` à chaque `select(_:)`. Aucune persistance disque | M | **P0** |
| Envoi et nouvelle ligne | `SEND_MESSAGE` Entrée, `NEW_LINE` ⇧/⌥/⌃+Entrée | **Fait** : `onKeyPress(.return)`, `.shift` → `.ignored`, `TextField(axis: .vertical)` | — | — |
| Envoyer et archiver | `SEND_MESSAGE_AND_ARCHIVE` ⌘Entrée | **Absent** — pourtant c'est *exactement* le geste Focus | S | **P0** |
| Annuler l'envoi | `Allow undo send (%s) for`, `UNDO_SEND_DELAY_MS`, `Click pending messages to undo send` | **Absent** | S | P1 |
| Échec d'envoi / renvoi | `Message failed to send`, `Retry`, `Resend`, `Queued` | **Partiel** : `sendDraft()` retire le message optimiste, restaure texte et pièces jointes, alerte globale. Pas de badge d'échec persistant, pas de renvoi, pas de file hors-ligne | M | P1 |
| Dictée | `SHOW_TRANSCRIBE_BAR` ⌘⇧T « Talk to Type » (audio → OpenAI via serveurs Beeper) | **Fait, et mieux** : `ComposerDictation.swift`, `SFSpeechRecognizer` on-device + repli dictée système. Aucune donnée ne sort de la machine | — | — |
| Envoi planifié | `SCHEDULE_MESSAGE` ⌘⇧L, `Reschedule message`, `Cancel schedule message` | **Absent** | M | P2 |
| Réponses rapides / modèles | `Create New Quick Reply`, `QUICK_REPLIES` | **Absent** | S | ✗ (réponse mécanique — l'inverse du fil qu'on écrit) |
| Texte enrichi | ⌘B / ⌘I / ⌘⇧X / \` , `SHOW_FORMATTING_MENU`, Markdown accepté par l'API | **Absent** : `TextField` brut, envoi `m.text` sans `formatted_body` | M | P2 (et **Matrix→Signal perd le formatage** — ROADMAP mautrix-signal) |
| Emoji | `EMOJI_PICKER_OPEN_ON_HOVER`, `ENABLE_EMOJI_AUTOCOMPLETE`, `DISABLE_EMOTICON_REPLACEMENT` | **Absent** | S | P2 |
| Rédaction assistée par IA | `Draft response with AI`, `AI Mentions System Prompt`, `Beeper AI` (ChatGPT / OpenAI-compatible) | **Absent** | — | ✗ (décision produit gelée dans `PRODUCT.md` : « Ne pas reconstruire des Writing Tools ») |

### 5. Notifications & Focus

| Fonction | Beeper (preuve) | Correspondance | Effort | Prio |
|---|---|---|---|---|
| Notifications système | `Enable notifications`, `MESSAGE_NOTIFICATIONS`, `macOS Notifications`, `Open Notifications in System Preferences`, `notification replied` | **Fait** : `Services/NotificationService.swift` + `Domain/NotificationPolicy.swift`. Notification par message entrant, tous réseaux ; respecte `mutedIDs`, le fil ouvert et les messages sortants ; clic → sélection du fil. Autorisation au premier lancement + bouton dans Réglages | — | — |
| Badge Dock | `Dock badge count`, `BADGE_COUNT` | **Fait** : `NotificationService.updateDockBadge`, total des non-lus hors archivés et muets | — | — |
| Répondre depuis la notification | `notification replied`, `notification action button ⇒ Remind in 1 Hour / 8 Hours` | **Absent** | S | P1 |
| Regroupement / anti-spam | `DEBOUNCE_NOTIFICATIONS` (« delay and batch notifications for successive texts… OTP/2FA codes are always notified immediately »), `RENOTIFY_UNREAD_DELAY` | **Absent** | M | P1 — c'est la fonction la plus « Focus » de tout Beeper |
| Sons | `NOTIFICATION_SOUND_NAME`, sons par réseau (help/desktop) | **Absent** | S | P2 |
| Notifier quand l'app est au premier plan | `NOTIFY_IN_FOCUS` | **Absent** | S | ✗ (notifier ce qu'on regarde déjà) |
| Réagir aux réactions | `NOTIFY_FOR_REACTIONS` | **Absent** | S | ✗ |
| Mode Focus « une conversation » | **N'existe pas chez Beeper** | **Fait — notre différenciation** : `FocusConversationView`, chrome fantôme, atténuation à 0.34 pendant la frappe, `focusPrevious/focusNext/archiveSelected`, `FocusTranscriptView` en prose | — | — |
| Incognito (lecture sans accusé) | `Incognito mode keeps chats unread even when you click on them and doesn't notify recipients you've read them` | **Absent** | M | P2 (à considérer *après* les accusés de lecture, comme leur interrupteur) |
| Nudge / secouer la conversation | `Shake the conversation when someone sends you a nudge`, `You got nudged!` | **Absent** | — | ✗ |

### 6. Données

| Fonction | Beeper (preuve) | Correspondance | Effort | Prio |
|---|---|---|---|---|
| Sync temps réel | WebSocket local `ws://localhost:23373/v1/ws` : `chat.upserted`, `message.upserted`, `message.deleted` (developers.beeper.com/desktop-api/websocket-experimental) | **Partiel** : Matrix en long-poll `/sync` 30 s avec backoff 2→60 s (`startMatrixSync`) ; Signal en polling 10 s (`pollSignalOnce`) ; **iMessage sans temps réel** — lecture uniquement à `load()`/`refresh()`, aucun FSEvents sur chat.db | M | **P0** (iMessage est le réseau n°1 du dogfood) |
| Cache disque / démarrage instantané | `Storage by Chat`, `Clear storage older than` | **Fait** : `hydrateFromDiskCache()` sur 4 caches JSON (`imessage-`, `signal-`, `matrix-conversations.json`, `contacts-index.json`) | — | — |
| Hors-ligne | `Offline`, `Queued` | **Partiel** : lecture hors-ligne OK, **envoi sans file d'attente** (échec immédiat, texte restauré) | M | P1 |
| Export | `Export all loaded messages to .txt file` | **Absent** | S | P2 |
| Gestion du stockage | `Clear Storage`, `Storage by Chat`, `Calculating message storage...` | **Absent** | S | P2 |
| Chiffrement / clé de récupération | `Recovery Key`, `On-device encryption`, `Emoji Verification` ; API `app/setup/recovery_key`, `verifications/sas` | **Hors sujet** : nos salons de bridge sont non chiffrés par choix (`encryption.allow: false`, `PLAN-matrix.md`) — homeserver privé sur Tailscale | — | — |
| API locale / MCP | `A third-party app <app/> wants to access your chats through Beeper Desktop API.` ; `/v0/mcp` dans `build/main`, OpenAPI « Beeper Client API 5.0.0 » | **Absent** | L | P2 |

### 7. Multi-appareils

| Fonction | Beeper | Correspondance | Effort | Prio |
|---|---|---|---|---|
| iOS / Android | Apps natives, `UNNotificationServiceExtension` (blog 2025-10-01), CarPlay, swipe-to-archive, labels mobiles | **Absent** (it. 4 de `PLAN-matrix.md`) | L | P2 — mais le client Matrix REST pur (`MatrixClient`, `URLSession`, zéro binaire) a été choisi *pour* être portable |
| Métadonnées synchronisées entre appareils | help : en On-Device, « metadata (including archive status) syncs between Beeper apps » | **Absent** (état local `UserDefaults`) — à prévoir via `m.tag` / account data Matrix si iOS arrive | M | P2 |
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
Correspondance en a **8** (`App/CorrespondanceCommands.swift`) + Entrée / ⇧Entrée / Échap.

| Beeper | Correspondance | Prio |
|---|---|---|
| ⌘K `SEARCH` · ⌘F `SEARCH_ROOM` | absent | **P0** |
| ⌘J `TOGGLE_COMMAND_BAR` (barre de commandes) | absent | ✗ (une palette de commandes est un aveu de complexité) |
| ⌘E / `e` `TOGGLE_THREAD_ARCHIVE` | **⌘E Archiver** ✅ | — |
| ⌘⇧E `ARCHIVE_ALL_READ_THREADS` | absent | P1 |
| ⌘[ / ⌥↑ `SELECT_PREV_THREAD` · `SELECT_NEXT_THREAD` | **⌘↑ / ⌘↓** ✅ (touches différentes) | — |
| ⌘U `SELECT_NEXT_UNREAD_THREAD` | absent | P1 |
| ⌘⇧U `TOGGLE_THREAD_READ` · ⌘⇧M mute · ⌘P pin | absent (actions présentes au menu contextuel) | P1 |
| ⌘R `QUOTE_AND_REPLY` | **⌘R = Actualiser** ⚠️ collision à arbitrer | **P0** |
| ⌘T `EDIT_MESSAGE` · → `OPEN_REACTION_PICKER` · ⌘⇧R quick react | absent | P0/P1 |
| ⌘L `OPEN_REMIND_LATER_MENU` · ⌘⇧L `SCHEDULE_MESSAGE` | absent | P1/P2 |
| ⌘Entrée `SEND_MESSAGE_AND_ARCHIVE` | absent | **P0** |
| ⌘N `CREATE_NEW_CHAT` · ⌘, `TOGGLE_PREFS_PANE` | **⌘N / ⌘,** ✅ | — |
| ⌘O `SEND_FILE` · ⌘D `DOWNLOAD_ATTACHMENTS` | absent | P1 |
| ⌘⇧Y filtre non-lus · ⌥⇥ `CYCLE_TABS` · ⌘⌥A filtre compte | absent | P1 |
| ⌘/ `TOGGLE_HOTKEYS_MODAL` | absent | P2 |
| ⌘+ / ⌘- / ⌘0 zoom · ⌘⌥S sidebar · ⌘⇧I chat info | absent | P1/P2 |
| ⌃⇥ `CYCLE_CHATS` · ⌃⌥← / → historique de navigation | absent | P2 |
| ↑ / ↓ / ⇧↑ / ⇧↓ sélection de messages | absent | P1 |

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

## Feuille de route proposée

### Lot 1 — P0 : « l'inbox devient utilisable » (≈ 3 S + 5 M ≈ 3 semaines)

| # | Chantier | Effort | Note bridge |
|---|---|---|---|
| 1 | **Notifications système + badge Dock** : `UNUserNotificationCenter`, autorisation, catégorie avec action « Répondre », branchement de `mutedIDs` (aujourd'hui décoratif), regroupement anti-rafale | M + S | indépendant du transport |
| 2 | **Archivage durable** : persister `isArchived` dans les 3 caches (retirer le `isArchived: false` forcé de `MatrixConversationCache.load()`), vue « Archivés », désarchivage, ⌘⇧E « archiver tout ce qui est lu » | M | `m.tag` Matrix si sync inter-appareils plus tard |
| 3 | **Recherche** : ⌘F dans le fil + ⌘K global sur les caches disque (titres, participants, corps) | M | purement local |
| 4 | **Réactions** : parser `m.reaction` dans `MatrixSyncParser`, corriger le faux message texte de `SignalBridge.parseReceive`, affichage sous la bulle, envoi (picker) | M | ✅ WhatsApp, Signal, Meta (bidirectionnel) |
| 5 | **Réponses citées** : `m.in_reply_to` à l'envoi, résolution + rendu de la citation à la réception, ⌘R (arbitrer la collision avec Actualiser → déplacer Actualiser sur ⌘⇧R) | M | ✅ WhatsApp, Meta, Telegram ; ⚠️ non listé au ROADMAP mautrix-signal — dégrader proprement |
| 6 | **Accusés de lecture** : envoyer `POST /rooms/{id}/receipt/m.read` à la sélection, brancher `Conversation.lastDelivery` (déjà alimenté par `IMessageDatabase.delivery`) dans `ConversationRowView` et `MessageBubbleView` | M | ✅ WhatsApp/Meta ; ⚠️ Signal Matrix→réseau ne marque que le dernier message |
| 7 | **Brouillons par conversation, persistés** : remplacer le `draftText` global par un dictionnaire sauvé sur disque, filtre « Brouillons » plus tard | M | — |
| 8 | **iMessage en temps réel** : `FSEvents`/`DispatchSource` sur `chat.db` + relecture incrémentale (aujourd'hui ⌘R uniquement) | M | — |
| 9 | **⌘Entrée « Envoyer et archiver »** — le geste Focus par excellence, trivial une fois (2) fait | S | — |

### Lot 2 — P1 : « le fil devient un vrai fil » (≈ 4 S + 7 M ≈ 4 semaines)

Suppression de message (`m.redaction`, ✅ tous bridges) · Édition (`m.replace` — ✅ Meta/Telegram, ❌ WhatsApp et Signal : masquer le bouton via une table de capacités par réseau) · Indicateurs de frappe (`m.typing`, ✅ tous bridges, envoi + réception) · Pièces jointes non-images à l'envoi + **envoi iMessage de fichiers** (aujourd'hui bloqué) · Lecteur audio/vidéo intégré + messages vocaux · Filtres (non-lus / brouillons / sans réponse / groupes) + filtre par réseau + ⌥⇥ · Marquer lu-non lu et ⌘U « prochain non lu » · Rappels « Remind Me » (⌘L, `remindAt`, `dismissOnIncomingMessage`) · File d'envoi hors-ligne + badge d'échec + renvoi · Annuler l'envoi (délai réglable) · Accessibilité : labels composites sur `ConversationRowView` et les bulles, `ScaledMetric`/`Font.TextStyle` dans `Design/Typography.swift`, `accessibilityReduceTransparency` · Extension du jeu de raccourcis (⌘P, ⌘⇧U, ⌘⇧M, ⌘O, ⌘D, ↑/↓).

### Lot 3 — P2 : « on élargit » (≈ 3 S + 5 M + 3 L ≈ 6 semaines)

Instagram + Messenger via `mautrix-meta` (it. 2 de `PLAN-matrix.md`) · Multi-comptes (sortir `account = "default"` du `MatrixCredentialStore`) · Création de groupe et fiche conversation (⌘⇧I) · Mentions (✅ Meta/Signal/Telegram) · Aperçus de liens · Texte enrichi Markdown → `formatted_body` (⚠️ **perdu à l'envoi vers Signal**, le bridge ne porte pas le formatage) · Sondages (⚠️ **WhatsApp seulement** — ne pas promettre le sondage comme fonction générale) · Transfert de message · Envoi planifié · Sélection multiple · Export `.txt` · Demandes de message / inconnus · Sync des métadonnées via account data Matrix, en préparation d'iOS · Verrouillage biométrique.

---

## Annexe — méthode

### Version analysée
`Beeper Desktop 4.3.73`, `com.automattic.beeper.desktop`, Mach-O thin arm64, signature runtime durcie.
`package.json` : `"name": "BeeperTexts"`, `"author": "Automattic, Inc."`, dépendances `@beeper/beeper-client-sdk@3.0.0-latest`, `better-sqlite3`, `keytar`, `node-mac-contacts`, `node-mac-permissions`.
Analysé le 2026-08-29. Bundle **jamais modifié** ; extraction en scratchpad, supprimée à la fin.

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
