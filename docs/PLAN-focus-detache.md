# Plan — Focus détaché

Idée : Focus est « une conversation, rien d'autre ». Il n'a aucune raison de rester enfermé dans la fenêtre
inbox. Une conversation peut vivre dans **sa propre petite fenêtre**, posée à côté d'un document, et — version
forte — surgir en **réponse rapide** depuis n'importe où sans ouvrir l'inbox.

Principes : une seule source de vérité (`InboxStore` partagé), aucune duplication d'état ; jamais un mur de
fenêtres ; tout ce que Focus sait faire dans l'inbox, il le sait faire détaché (composer, dictée, pièces jointes,
⌘R répondre, réactions, accusés, brouillon par fil) ; Échap ferme, ⌘W ferme, ⌘⇧D bascule.

## État de départ (`App/CorrespondanceApp.swift`)
- Une seule `WindowGroup` (inbox) + `Settings`. Raccourcis déjà pris : ⌘N, ⌘R, ⌘⇧R, ⌘⌥R, ⌘F, ⌘⇧F, ⌘E, ⌘⇧E, ⌘↑/↓, ⌘Entrée, ⌘1…⌘4.
- `InboxStore.select(_:)`, `setMode(_:)`, `isFocusChromeRevealed`, notifications via `NotificationService` (délégué `UNUserNotificationCenter`).
- `FocusConversationView` = état « chrome minimisé » de `ThreadView` (toolbar fantôme).

## Lot F1 — Fenêtre détachée (effort S–M)
1. **Scène** : `WindowGroup("Conversation", for: String.self) { $conversationID in DetachedConversationWindow(id:) }`
   dans `CorrespondanceApp`, `.windowStyle(.hiddenTitleBar)`, `.windowResizability(.contentSize)`,
   `.defaultSize(width: 520, height: 640)`, `.windowToolbarStyle(.unifiedCompact)`. Ouverture par `openWindow(value: id)` ;
   rappel de la même valeur = fenêtre existante mise au premier plan (comportement natif de `WindowGroup(for:)`).
2. **Vue** : `Features/Focus/DetachedConversationWindow.swift` — `FocusConversationView` tel quel, sans sidebar ni rail,
   entête réduit à la pilule (nom + réseau) cliquable → fiche contact ; toolbar fantôme identique (survol du haut) avec
   trois actions : Épingler au-dessus, Ouvrir dans l'inbox, Archiver.
3. **Sélection indépendante** : aujourd'hui `messages`/`draftText` suivent `selectedConversationID` (une seule sélection).
   Introduire `ConversationSession` (`@Observable`, par fil : messages, brouillon, pièces jointes en attente, état d'envoi,
   accusés) fourni par `InboxStore.session(for:)` et partagé entre l'inbox et les fenêtres détachées. L'inbox garde
   `selectedConversationID` = session « principale » ; une fenêtre détachée tient sa propre session. `sendDraft()` devient
   `send(session:)`. C'est le vrai chantier du lot ; le reste est du câblage.
4. **Commandes** : ⌘⇧D « Détacher la conversation » (menu Fenêtre + menu contextuel de la liste + glisser la pilule
   d'entête hors de la fenêtre → `onDrag` avec `NSItemProvider` et dépôt sur le bureau = ouvrir). Échap / ⌘W ferment ;
   « Ramener dans l'inbox » (⌘⇧D dans la fenêtre détachée) ferme et sélectionne le fil dans l'inbox.
5. **Cadres mémorisés** par fil (`UserDefaults`, clé `detached.frame.<id>`) ; l'inbox peut se fermer sans quitter
   (`applicationShouldTerminateAfterLastWindowClosed = false` via `NSApplicationDelegateAdaptor`), le Dock ré-ouvre l'inbox.
6. **Notifications** : clic → si le fil a une fenêtre détachée, la mettre au premier plan ; sinon inbox (comportement actuel).
   Réglage « Ouvrir les notifications en fenêtre détachée » (off par défaut).
7. **Non-lus** : une fenêtre détachée au premier plan marque le fil lu et envoie l'accusé, comme l'inbox.
8. Tests : `ConversationSession` (brouillon isolé par fil, envoi depuis une session non sélectionnée, fusion des messages
   entrants dans deux sessions du même fil), restauration des cadres.

## Lot F2 — Toujours au-dessus (effort S)
1. `.windowLevel(.floating)` (macOS 15+) derrière `#available`, repli `NSWindow.level = .floating` via `WindowChromeApplicator`.
2. Bascule par fenêtre (bouton épingle dans la toolbar fantôme, ⌘⌥P), état mémorisé par fil.
3. Comportement : ne vole pas le focus clavier à l'app active tant qu'on ne clique pas dedans ; `collectionBehavior`
   `.canJoinAllSpaces` optionnel (réglage) pour suivre les bureaux.

## Lot F3 — Réponse rapide (effort M) — la version forte
1. **Panneau** `NSPanel` non activant (`.nonactivatingPanel`, `hidesOnDeactivate = false`, `level = .floating`,
   `.hudWindow` non — on garde le papier du thème), hébergeant `FocusConversationView` en mode compact (dernier
   groupe de messages + composer), 460×320, centré en haut de l'écran actif comme Spotlight.
2. **Déclencheur** : raccourci global (`⌃⌥Espace` par défaut, réglable) via `NSEvent.addGlobalMonitorForEvents` +
   enregistrement Carbon `RegisterEventHotKey` (pas de permission Accessibilité nécessaire pour un hotkey) ; icône de
   barre de menus optionnelle (`MenuBarExtra`) avec le compteur non lus.
3. **Contenu** : par défaut le **fil non lu le plus récent** ; ⌘↑/⌘↓ passent au suivant ; ⌘K ouvre un mini-sélecteur
   (recherche de la liste, réutilise l'index de recherche P0). Envoi = Entrée ; Échap ferme ; le panneau se ferme aussi
   après envoi si « Fermer après envoi » (on par défaut).
4. **Depuis une notification** : action « Répondre » inline (`UNTextInputNotificationAction`) déjà possible sans panneau ;
   « Ouvrir en réponse rapide » comme seconde action.
5. **Garde-fous** : un seul panneau ; jamais au-dessus d'une app plein écran si l'utilisateur l'a interdit (réglage) ;
   respecte Ne pas déranger (pas d'apparition spontanée — le panneau ne s'ouvre jamais seul, uniquement sur geste).

## Lot F4 — iOS (plus tard)
Le même concept devient : widget « Répondre à … » (App Intents), Live Activity pour le fil en cours, et une scène
`WindowGroup` compacte sur iPad (Stage Manager). `ConversationSession` du lot F1 est réutilisé tel quel.

## Ce qu'on ne fait pas
- Plusieurs fenêtres détachées du **même** fil (une seule, ramenée au premier plan).
- Fenêtre détachée avec sidebar ou rail : ce serait une seconde inbox.
- Panneau qui s'ouvre tout seul à la réception d'un message : c'est une notification, pas un Focus.

## Ordre et dépendances
F1.3 (`ConversationSession`) d'abord — il touche `InboxStore`, `ThreadView`, `FocusConversationView`, `Composer/` — puis F1 le reste,
F2 (trivial), F3. F1 est un chantier UI : à lancer seul sur le repo, pas en parallèle d'une autre passe UI. F3 peut
suivre dans la foulée ; F2 se glisse n'importe où.
