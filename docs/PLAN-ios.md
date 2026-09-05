# Plan — Correspondance iOS (extraction Core + première build)

Décisions : `docs/PRODUCT.md` § « Révision iOS » · glossaire : `CONTEXT.md` · ADR : `docs/adr/0001`.
Tout se fait dans le worktree `../correspondance-ios`, branche `ios/core-extraction`. `main` ne bouge pas.

Règle des phases A et B : **zéro changement de comportement**. Une étape = un build vert de la cible Mac + tests verts = un commit. Si une étape ne passe pas, `git reset --hard` à la précédente.

---

## Phase A — Extraction `CorrespondanceCore` (déménagement, 1–2 jours)

### A0. Point de départ
- Commit de l'arbre `main` (fait par meffysto). `git worktree add ../correspondance-ios -b ios/core-extraction`.
- Build Mac + `xcodebuild test` : référence verte.

### A1. Package vide
- `Packages/CorrespondanceCore/Package.swift` : produits `CorrespondanceCore`, `CorrespondanceUI` ; plateformes `.macOS(.v14), .iOS(.v18)`.
- Ajout au projet, la cible Mac dépend de `CorrespondanceCore`.
- Sortie : build vert, rien n'a bougé.

### A2. `Domain/` → Core (1 722 lignes, 19 fichiers, dépendances sortantes : aucune)
- Déplacer les 19 fichiers de `Correspondance/Domain/` dans `Sources/CorrespondanceCore/Domain/`.
- Passer `public` les types et membres utilisés par l'app ; ajouter `import CorrespondanceCore` dans les fichiers appelants.
- Tests qui suivent : `ArchiveStateTests, ConversationSearchTests, ConversationTitleTests, EmojiTextTests, MentionTests, MergedContactTests, MessageGroupingTests, NotificationPolicyTests, QuotedReplyTests, ReactionTests, SenderPrefixTests, SendLaterTimeTests, TextLinksTests` → `Tests/CorrespondanceCoreTests/`.
- Sortie : build + tests verts.

### A3. `Services/Matrix/` → Core (2 602 lignes, 13 fichiers, dépendances sortantes : aucune)
- Déplacer dans `Sources/CorrespondanceCore/Matrix/`. Même traitement `public`.
- Tests : `MatrixSyncParserTests, MatrixTransactionLedgerTests, MatrixURLBuildingTests, MatrixCacheSeedingTests, MatrixBridgeInstagramTests, MatrixBridgeSignalTests, InstagramSessionCookiesTests` + `Fixtures/` nécessaires.
- Sortie : build + tests verts ; envoi d'un message WhatsApp depuis l'app Mac vérifié à la main.

### A4. Shim plateforme (fichiers qui ne bougent pas, mais deviennent portables)
- `Sources/CorrespondanceCore/Platform/Platform.swift` :
  `PlatformImage` (`NSImage`/`UIImage`), `PlatformImage.init?(data:)`, `.pngData()`, `Platform.open(url:)`, `Platform.copyToPasteboard(_:)`, `PlatformColor`, `PlatformFont`.
- Remplacer le symbole unique dans les 20 fichiers à une dépendance AppKit :
  `AttachmentImageView, WritingTypeface, ComposerControls, ConversationAvatarView, ConversationPillHeader, MessageAvatarView, MessageBubbleView, PermissionBanner, ThreadView (NSEvent : reste conditionnel), SettingsDictationPane, SettingsPermissionsPane, SettingsView, ContactDirectory, ConversationAvatarStore, InboxStore+IMessageAutomation, LaunchGate, ComposerDictation, LinkPreviewCard, Theme, WritingTheme`.
- Sortie : build vert, app Mac strictement identique. `grep -l "^import AppKit"` doit avoir baissé de ~20.

### A5. Stores portables → Core (un fichier = un commit)
- Sans dépendance : `DraftStore, HiddenMessageStore, ScheduledMessageStore, MergedContactStore, ConversationSession, SenderAvatarStore, ContactDirectoryDisk`.
- Avec shim : `ConversationAvatarStore`, `AttachmentThumbnailStore` (NSCache → `NSCache` existe sur iOS ; `NSBitmapImageRep` → `CGImage`/ImageIO), `LinkPreviewStore` (idem ; `LinkPresentation` existe sur iOS).
- `AvatarMosaic` (Design) : `NSBitmapImageRep` → CoreGraphics pur, puis → `CorrespondanceUI`.
- Tests : `DraftStoreTests, HiddenMessageStoreTests, ConversationSessionTests, AvatarStoreReadinessTests, AvatarMosaicTests`.
- **Restent dans la cible Mac** : `InboxStore*` (NSOpenPanel/NSWindow), `NotificationService` (NSApp), `ContactDirectory` (NSApplication — à scinder plus tard), tout `IMessage*`, `QuickReply*`, `DetachedWindowState`, `GlobalHotKey`, `DictusBridge`.

### A6. `CorrespondanceUI` — vues partagées
- Déplacer : `Design/{Spacing, Typography, GlassSurface, LinkedText, MessageArrival, TopScrollFade, Theme, WritingTheme, WritingTypeface, AttachmentImageView, LinkPreviewCard, AvatarMosaic}`, `Features/Inbox/{ConversationRowView, ConversationAvatarView, MessageAvatarView, MessageBubbleView, AudioMessageView, ConversationPillHeader, ComposerBar}`, `Features/Composer/{ComposerControls, MentionMenu}`.
- Restent Mac : `HoverZone, WindowChrome, AttachmentVideoView (NSHostingController — à porter plus tard), FocusConversationView, ThreadView, DetachedConversationWindow, QuickReplyView, Settings*`.
- Test : `WritingThemeContrastTests`.

### A7. Cible iOS vide qui compile
- Nouvelle cible `Correspondance iOS` (bundle `com.correspondance.ios` à confirmer), dépend de Core + UI, un `ContentView` qui affiche « Core OK ».
- Sortie : **build iOS vert** = frontière prouvée. Ce qui refuse de compiler ressort de Core, on ne force jamais avec `#if`.
- **Fusion possible dans `main` ici** : la Mac est identique, le package existe.

---

## Phase B — État de conversation dans le Relais (code Mac, dans le worktree)

Référence ADR 0001. Pour les conversations Matrix uniquement ; iMessage garde `UserDefaults`.

| État | Stockage Matrix | Endpoint |
|---|---|---|
| Épinglé | room tag `m.favourite` | `PUT /user/{u}/rooms/{r}/tags/m.favourite` |
| Archivé | room tag `fr.correspondance.archived` | idem |
| Muet | push rule `room` avec `dont_notify` | `PUT /pushrules/global/room/{r}` |
| Brouillon | room account data `fr.correspondance.draft` | `PUT /user/{u}/rooms/{r}/account_data/…` |
| Fusions | global account data `fr.correspondance.merged_contacts` | `PUT /user/{u}/account_data/…` |
| Masqués (HiddenMessageStore) | room account data `fr.correspondance.hidden` | idem |

- `MatrixClient` : `setTag / removeTag / setRoomAccountData / setAccountData / setRoomPushRule`. Lecture via `/sync` (`account_data` par salon et global sont déjà dans la réponse).
- `InboxStore` : `UserDefaults` devient cache ; la vérité arrive par `/sync`. Migration une fois : au premier lancement, pousser l'état local existant vers le Relais.
- Tests : caractérisation sur `MatrixSyncParser` pour les `account_data` ; aller-retour tag → `/sync` → `ArchiveState`.
- Sortie : archiver sur le Mac, relancer l'app avec `UserDefaults` vidés → l'état revient du Relais.

---

## Phase C — iOS v1 (première TestFlight)

Ordre des écrans, chacun livrable seul :

1. **Connexion au Relais** (URL + identifiants, Keychain) — réutilise `MatrixCredentials`.
2. **Inbox liste** : `ConversationRowView` partagée, filtres en jetons sous le titre (Tous / Non lus / Sans réponse / Brouillons / Groupes), barre d'onglets du système (Inbox / Archive / Focus + recherche), menu « … » (réseaux, Demandes, Rappels, Programmés, Réglages).
3. **Fil** : `MessageBubbleView` partagée, en-tête flottant, réactions, citations, « Vu par », `ComposerBar` avec **+** (Photos / Caméra / Fichier / Plus tard) et micro.
4. **Adaptatif** : `NavigationSplitView` — compact = pile, regular = liste + fil ; état conservé au changement de size class (test : simulateur iPad Pro 13 + rotation ; Fold quand le simulateur existera).
5. **Focus** : un écran = une conversation, gestes archiver / suivante, atteint depuis la barre du bas.
6. **Archive, épingles, muet, fusions** : via l'état du Relais (Phase B). Les fusions se décident aussi depuis l'iPhone (fiche du fil › « Fusionner avec… », « Séparer », « Changer de chat » sous le composer) et partent au Relais par la même file d'écritures que les drapeaux (`RelayStore` § « Fusionner, séparer »).
7. **Push** : Sygnal dans `infra/matrix/docker-compose.yml`, clé APNs `.p8`, `MatrixClient.setPusher`, Notification Service Extension pour l'aperçu.
8. **Nouvelle conversation** : puces réseau, réutilise `createDM` / `startBridgeChat`.
9. **Recherche** : `ConversationSearch` (Core) + onglets médias.
10. **Envoyer plus tard** : `ScheduledMessageStore` (Core).

Simulateur : `simslim on <iPhone 17> --except store,pim,photos,web` (push, Contacts, Photos, liens universels gardés). Même chose pour l'iPad Pro 13. À lancer seulement au début de la phase C.

---

## Phase D — Backlog partagé (Core, les deux plateformes)

Dans l'ordre : rappels · demandes · recherche par médias · vocaux + transcription (Speech) · sondages · GIF · note à soi · indicateurs de frappe · édition de messages (réseaux qui le supportent).

Où vit chaque chose :

| Item | Matrix | Core | Vue |
|---|---|---|---|
| Rappels | room account data `fr.correspondance.reminder` | `ConversationReminder`, `InboxState.reminders`, portée `.reminders` | menu contextuel de la ligne, section « Rappels » |
| Demandes | room account data `fr.correspondance.request` | `RequestPolicy`, `RequestSignals`, portée `.requests` | menu contextuel, section « Demandes » |
| Recherche par médias | — (local) | `MessageFacet`, `FacetedSearch.hits` | rangée d'onglets des deux barres de recherche |
| Vocaux | `m.audio` + MSC3245 + MSC1767 | `VoiceNote`, `VoiceRecorder`, `VoiceTranscriber` | `AudioMessageView` (forme d'onde + « Lire »), micro du composer iOS |
| Sondages | MSC3381 (formes stable et instable) | `Poll`, `MatrixRoomModel.PollEvent` | `PollView` (partagée) |
| GIF | `m.image` + `info.mimetype: image/gif` | `MessageAttachment.isGIF` | `AnimatedImageView` (ImageIO) |
| Note à soi | account data global `fr.correspondance.self_note` | `MessageNetwork.selfNote`, `livesOnRelay` | ⇧⌘N (Mac), menu du titre (iPhone) |
| Frappe | EDU `m.typing` | `MatrixRoomModel.typingLabelFR` | ligne au bas du fil |
| Édition | `m.replace` (MSC2676) | `MatrixBridgeDescriptor.supportsEditing` | « Modifier… » du menu de bulle |

## Puis
Agents (utilisateurs Matrix sur le Relais) → E2EE (matrix-rust-sdk dans Core) → iMessage sur iPhone (pont depuis le Mac, à décider).

---

## Risques suivis
- `server_name = correspondance.local` gravé — à traiter avant toute exposition publique.
- Tailscale iOS tombé = app qui ne charge pas.
- `InboxStore` (Mac) et le futur store iOS divergent : extraction d'un store commun **après** que les deux existent, pas avant.
- 8 Go de RAM : un simulateur à la fois.

---

## État au 2026-08-31 (fin de la première passe A → C)

- **Phase A** ✅ 14 commits. Paquet `CorrespondanceCore` (Domain 19, Matrix 13, Services 7, Platform, Design) + `CorrespondanceUI`. AppKit : 40 → 21 fichiers. Écarts : Domain et Matrix déplacés ensemble (dépendance réelle) ; les vues liées à `InboxStore` restent Mac.
- **Phase B** ✅ 7 commits. État de conversation dans le Relais, file d'écritures, migration unique, ligne d'état dans Réglages. **À vérifier à la main contre le NUC** (voir bilan de session).
- **Phase C** ✅ 16 commits. App iOS : connexion, inbox + filtres + barre flottante, fil complet, adaptatif (iPhone/iPad), Focus, état du Relais, push (Sygnal + extension), nouvelle conversation, recherche par facettes, envoyer plus tard, réglages. Test UI de navigation. Captures dans `docs/screens/ios/`.
- **Non prouvé sur simulateur** : l'extension de notification (simctl ne la réveille pas), les entitlements App Group / Trousseau partagé (vides sur simulateur). À valider sur un vrai iPhone.
- **Dettes connues** : Team ID en dur dans `SharedRelayState`, pas d'icône iOS, `NSAllowsArbitraryLoads` (documenté, décision 6), contacts de « nouvelle conversation » = tête-à-tête seulement, `Platform.open` iOS non vérifié. (Le micro iOS, lui, est allumé — phase D.)
- **Phase D** ✅ 9 commits, un par item, dans l'ordre imposé. Tout le calcul est dans `CorrespondanceCore` (modèles purs + parsing `/sync`), les vues partageables dans `CorrespondanceUI` (`PollView`, `AnimatedImageView`, `AudioMessageView`), le reste une vue par plateforme. Aucune logique dupliquée entre Mac et iPhone. 40 tests unitaires de plus dans Core (fixtures `/sync`, aucune dépendance au NUC).
- **Magasin local** ✅ 7 commits (branche `core/local-store`). L'instantané JSON devient une base SQLite versionnée : le lancement ne lit plus que les lignes de l'inbox, une passe de `/sync` n'écrit que ce qu'elle change, le curseur `next_batch` reprend enfin, et la recherche (FTS5) trouve dans les fils jamais ouverts. Détails, mesures et ce qui reste : `docs/PLAN-store-local.md`.

### Écarts et dettes de la phase D

- **Demandes** : aucun pont mautrix v26.08 n'expose de drapeau « message request » (ni `m.bridge`, ni `com.beeper.room_type`). La demande se **prouve** donc : fil chargé, aucune ligne de moi dedans, personne de connu en face. Tant que le fil n'est pas ouvert, `hasWrittenBack` vaut `nil` et la conversation reste dans la file — on ne range jamais sur un soupçon. Les clés qu'un pont emploierait (`com.beeper.pending`, `fi.mau.pending`, `channel.type: request`) sont déjà lues : l'écran se remplira seul le jour venu. **À vérifier contre le NUC** : qu'un vrai fil de demande Instagram n'apparaisse pas comme une conversation ordinaire.
- **Demandes, iPhone** : pas de carnet d'adresses sur iOS en v1 (décision 2), donc `isKnownCorrespondent` y est toujours faux sauf pour un contact fusionné. Le Mac, lui, interroge `ContactDirectory`.
- **Recherche par médias, Mac** : l'index se remplit à la demande (salons du pont en mémoire, fils ouverts, puis une passe `fetchMessages` sur la base iMessage). Sur une grosse base, la première ouverture d'un onglet coûte une seconde. Pas de pagination : on cherche dans ce qui est chargé, jamais chez le Relais (décision 7).
- **Vocaux** : l'enregistrement et la transcription ne sont **pas prouvés sur simulateur** (micro virtuel, modèle Speech français à télécharger). `VoiceRecorder` produit du `.m4a` AAC ; **à vérifier contre le NUC** que mautrix-whatsapp et mautrix-signal le transcodent bien en vrai vocal et non en pièce jointe. Le micro du Mac reste sur Dictus (dictée), il n'enregistre pas encore de vocal.
- **Sondages** : on répond dans la forme sous laquelle le sondage est arrivé. mautrix-whatsapp bridge les sondages WhatsApp ; Signal et Instagram n'en ont pas. Poser un sondage depuis l'app existe côté client (`sendPollStart`) mais **n'a pas d'entrée dans l'UI** — rien ne prouve encore que le pont le relaie dans ce sens.
- **GIF** : afficher seulement. Aucun sélecteur de GIF (Giphy/Tenor) — ce serait un service tiers et une clé d'API, hors périmètre. Envoyer un `.gif` du disque marche déjà, par le chemin des pièces jointes.
- **Note à soi** : nouveau cas `MessageNetwork.selfNote` — un « réseau » qui n'en est pas un, documenté comme tel. `livesOnRelay` distingue désormais « ce fil passe par le Relais » de « ce réseau a un pont à connecter ». **À vérifier contre le NUC** : que `createRoom` sans invitation passe les rate-limits de Synapse, et que le salon n'apparaisse pas en double.
- **Frappe** : `m.typing` expire de lui-même au bout de 20 s côté client — une EDU ne revient qu'au changement. **À vérifier contre le NUC** : que mautrix-instagram reçoive bien la frappe (il l'envoie ; la recevoir n'est pas garanti).
- **Édition** : capacité par réseau dans le descripteur de pont. Instagram : `false` (Meta n'expose aucune modification de DM). **À vérifier contre le NUC** : la fenêtre de 15 min de WhatsApp — un `m.replace` hors fenêtre partira sans que le réseau le relaie, et l'app n'a aujourd'hui aucun moyen de l'apprendre.
- **Test de caractérisation changé** : `testEditedMessageDoesNotDuplicateTheOriginal` devient `testEditedMessageCorrectsTheOriginalInPlace`. C'est un vrai changement de comportement — les modifications reçues étaient jetées, elles corrigent maintenant.

- **Découverte ATS** : `NSAllowsLocalNetworking` ne couvre pas 100.64/10 **et** annule `NSAllowsArbitraryLoads` ; une exception par IP littérale fonctionne (le commentaire du plist Mac dit l'inverse — à corriger).
