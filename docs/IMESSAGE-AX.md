# Arbre d'accessibilité de Messages.app — relevé

Relevé le **30 août 2026**, sur **macOS 26.6.2 (25G83)**, Messages `com.apple.MobileSMS`,
langue système **français**. Sonde : `swift` en ligne de commande depuis un terminal
listé dans Confidentialité → Accessibilité (scripts jetables, section « Reproduire » en bas).

Ce document existe pour re-valider vite à chaque mise à jour système : quand une action
du Lot M2 casse, c'est ici qu'on regarde d'abord.

---

## 1. Le lancement caché — vérifié

C'est la mécanique de Beeper Desktop, et elle marche :

```swift
let cfg = NSWorkspace.OpenConfiguration()
cfg.activates = false        // ← ne passe jamais devant
cfg.hides = true
cfg.addsToRecentItems = false
NSWorkspace.shared.open([URL(string: "imessage://<handle>")!],
                        withApplicationAt: messagesURL, configuration: cfg) { … }
```

| Mesure | Résultat |
|---|---|
| `frontmostApplication` avant / après | **inchangée** (testé depuis Ghostty, Correspondance, Beeper au premier plan) |
| `isActive` de Messages après ouverture | `false` |
| `isHidden` après ouverture | `false` — `cfg.hides` **n'agit pas** sur une app déjà lancée |
| `NSRunningApplication.hide()` juste après | `isHidden == true`, `frontmostApplication` toujours inchangée |
| Fenêtre créée par le lien profond | oui (`CGWindowList` : 1024×768) |

**Conclusion** : lancer/piloter Messages sans jamais la montrer est possible. Le geste
complet est `open(url, activates:false, hides:true)` **puis** `hide()` explicite —
c'est ce que fait `IMessageAutomation.hideIfNeeded(pid:offscreen:)`.

Le lien profond `imessage://<chat_identifier>` sélectionne le fil sans activation
(`openDeepLink(_:activating:hiding:targeting:)` chez Beeper — même approche).
Il n'existe **aucune** commande Apple Events « set active chat ».

---

## 2. La barre de menus — lisible même app masquée

`AXUIElementCopyAttributeValue(app, kAXMenuBar…)` répond **toujours**, y compris
quand `isHidden == true` et que Messages n'a aucune fenêtre. C'est le chemin le plus
robuste de tout le Lot M2.

Identifiants des menus (`AXIdentifier` de l'`AXMenuBarItem`) :

| `AXIdentifier` | Titre FR |
|---|---|
| `com.apple.menu.application` | Messages |
| `com.apple.menu.file` | Fichier |
| `com.apple.menu.edit` | Édition |
| `com.apple.menu.view` | Présentation |
| `com.messages.conversationsmenu` | **Conversation** |
| `com.messages.formatmenu` | Format |
| `com.apple.menu.window` | Fenêtre |
| `com.apple.menu.help` | Aide |

Entrées utiles au Lot M2 (les `AXMenuItem` n'ont **pas** d'`AXIdentifier` : on les
retrouve par titre, comparaison insensible à la casse et aux diacritiques) :

**Édition** — agit sur le message *sélectionné* dans le transcript :
- « Répondre au message… » ⌘R
- « Poursuivre dans la dernière réponse… » ⇧⌘R
- « Message Tapback… » ⌘T
- « Modifier le dernier message… » ⌘E
- « Envoyer plus tard… » ⌘L

**Conversation** :
- « Afficher les détails » ⌘I — fiche du groupe (renommer, ajouter/retirer, quitter)
- **« Marquer comme non lu » ⌘U**
- « Marquer tous comme lus » ⇧⌘U
- « Masquer les alertes » ⇧⌘M
- « Supprimer la conversation… », « Bloquer la personne… »

**Fichier** : « Nouveau message » ⌘N (création de groupe, fonction 5).
**Fenêtre** : « Messages » ⌘0 (rouvre la fenêtre principale quand elle est fermée).

⚠️ **Validation des entrées** : tant que le menu n'est pas ouvert et que Messages n'a
pas de fenêtre clé, tous ces `AXMenuItem` remontent `AXEnabled = false`. Ouvrir le menu
parent (`AXPress` sur l'`AXMenuBarItem`) **ne réactive pas** les entrées quand l'app est
masquée ou sans sélection. `IMessageAutomation.pressMenuItem` presse donc d'abord le
titre du menu, attend 250 ms, puis presse l'entrée — et annule le menu (`AXCancel`) si
elle est absente ou refuse le `AXPress`. Vérifié : cet `AXPress` sur un menu de Messages
**ne la fait pas passer au premier plan**.

---

## 3. La fenêtre : identifiants attendus

> ⚠️ **Non re-mesurés sur cette machine** — voir la section 4. Ils viennent de
> `IMessage.node` (le module natif Swift de Beeper Desktop 2026.8, `strings -a`),
> qui pilote la même app par la même API sur la même version de macOS.

Chemin : `AXUIElementCreateApplication(pid)` → `AXWindows` → première fenêtre de rôle
`AXWindow` → descendants.

| Rôle / `AXIdentifier` | Ce que c'est |
|---|---|
| `CKConversationListCollectionView` | **la sidebar** (liste des fils) |
| `TranscriptCollectionView` | **le transcript** (fil ouvert) |
| `MessageCell` | une **bulle** du transcript (`cellID`, `cellRole` chez Beeper) |
| `messageBodyField` | le **composer** (`AXTextArea`) |
| `editing.confirm.button` / `editing.reject.button` | validation / abandon d'une **modification** |
| `cancelEditButton` | sortie de l'édition en cours |
| `characterPickerSearchField` | sélecteur d'emoji (tapback libre) |
| `hide.alerts.collection.view.cell` | « Masquer les alertes » d'une ligne |
| `balloon.message.reply` | entrée **« Répondre »** du menu contextuel d'une bulle |
| `acknowledgment.type.heart` | tapback ❤️ |
| `acknowledgment.type.thumbs.up` | tapback 👍 |
| `acknowledgment.type.thumbs.down` | tapback 👎 |
| `acknowledgment.type.ha` | tapback 😂 |
| `acknowledgment.type.exclamation` | tapback ‼️ |
| `acknowledgment.type.question.mark` | tapback ❓ |
| `ACCESSIBILITY_ADD_EMOJI_TAPBACK` | bouton « + » (tapback emoji libre, macOS 15+) |
| `UNDO_SEND_ACTION` | **« Annuler l'envoi »** |

Séquence d'une action sur une bulle : `AXShowMenu` sur la `MessageCell` → un `AXMenu`
apparaît comme **enfant de l'élément application** → chercher l'entrée par
`AXIdentifier` puis par titre FR → `AXPress`. `AXCancel` sur le menu en cas d'échec.

Ce que Beeper fait, d'après ses symboles Swift — la carte de nos propres fonctions :
`setReaction(threadID:messageCell:reaction:on:)`, `editMessage(threadID:messageCell:newText:)`,
`undoSend(threadID:messageCell:)`, `toggleThreadRead(threadID:read:)`,
`assertSelectedThread(threadID:)`, `withMessageCell(threadID:messageCell:action:)`,
`waitUntilReplyTranscriptVisible()`, `closeReplyTranscriptView(wait:)`,
`HideDebouncer` (regroupe les demandes de masquage), et un `MenuMaintainer`
(`BEEPSettingsMenuItemInjection…`) qui maintient des entrées de menu injectées.

---

## 4. Ce qui n'a **pas** pu être mesuré, et pourquoi

Sur cette machine, l'arbre de la **fenêtre** de Messages est resté opaque à la sonde :

```
AXIsProcessTrusted()                      → true
app.AXChildren                            → [AXApplication (l'app elle-même !), AXMenuBar]
app.AXWindows                             → [AXApplication]        ← pseudo-élément
app.AXMainWindow                          → AXApplication, AXChildren illisible (-25205)
systemWide.AXFocusedApplication           → erreur -25204 (kAXErrorCannotComplete)
AXUIElementCopyElementAtPosition(700,400) → AXApplication (le même pseudo-élément)
```

Le même symptôme apparaît sur **toutes** les apps testées (TextEdit, Ghostty, Finder,
Beeper), et `System Events` répond « 0 fenêtre » pour Finder et Ghostty qui en ont
manifestement. `CGWindowListCopyWindowInfo` voit bien les fenêtres : elles existent,
c'est l'API AX qui refuse de les décrire.

**Diagnostic** : l'autorisation Accessibilité du terminal est **périmée** —
`AXIsProcessTrusted()` lit une ligne TCC obsolète et répond `true`, mais le serveur AX
refuse les arbres de fenêtres. C'est le cas classique d'un binaire resigné/mis à jour
après avoir été coché.

**Remède** : Réglages Système → Confidentialité et sécurité → Accessibilité → **retirer**
l'app (le terminal, et Correspondance quand elle y sera) avec le « − », puis la
**rajouter** avec le « + ». Un simple décochage/recochage suffit parfois.

C'est exactement l'état `IMessageAutomationHealth.treeUnreadable` : `trusted == true`
mais ni fenêtre, ni sidebar, ni transcript. La sonde le nomme, l'affiche dans Réglages
(« autorisation périmée, retire puis rajoute Correspondance ») et **interdit toute
action** — jamais d'échec silencieux.

Conséquence pour la relecture : **aucune** des fonctions 1, 2, 4 (tapback, réponse
citée, modifier, annuler) n'a pu être exercée en vrai. Il n'existe par ailleurs aucune
conversation à soi-même dans ce `chat.db` (aucun `chat` sur `meffysto@gmail.com`,
`+33699000001` ni `moi@travail.fr`), donc rien n'aurait pu être validé en
écriture sans écrire à un tiers.

---

## 5. Ce qui a été validé en vrai

| Point | Résultat |
|---|---|
| Messages lancée sans passer au premier plan | ✅ `frontmostApplication` inchangée |
| `hide()` après lancement → `isHidden == true` | ✅ front toujours inchangé |
| Lien profond `imessage://` sans activation | ✅ crée la fenêtre, ne vole pas le focus |
| Barre de menus lisible **app masquée** | ✅ titres, raccourcis, `AXEnabled` |
| `AXPress` sur un menu de Messages en arrière-plan | ✅ réussit, ne l'active pas |
| Entrées de menu validées quand l'app est masquée | ❌ toutes `AXEnabled = false` |
| Arbre de la fenêtre (sidebar, transcript, bulle) | ❌ inaccessible (section 4) |
| Colonnes de vérification dans le vrai `chat.db` | ✅ `associated_message_type` (74 tapbacks), `thread_originator_guid` (19 réponses), `date_edited` (2 éditions), `date_retracted`, `is_read` |

---

## 6. Repli « fenêtre hors écran »

Puisque les entrées de menu ne se valident pas quand l'app est masquée, l'option de
Réglages **« Fenêtre Messages hors écran »** existe : au lieu de `hide()`, la fenêtre est
`unhide()` puis déplacée au-delà du bord droit de l'écran principal
(`AXPosition` = `screen.frame.maxX + 64`). Messages a alors une fenêtre clé, dessinée,
donc des menus et des menus contextuels valides — sans jamais rien montrer à l'écran.
Ce repli n'a pas pu être mesuré ici (section 4) : il attend une autorisation
Accessibilité saine.

---

## 7. Reproduire

Scripts jetables, à relancer après toute mise à jour de macOS :

```bash
# 1. arbre complet d'une app (rôles, AXIdentifier, titres, valeurs, actions, cadres)
swift scripts/ax/axprobe.swift 8      # profondeur ; --hide pour masquer d'abord
# 2. menus (Fichier / Édition / Conversation / Fenêtre) + AXEnabled
swift scripts/ax/menus.swift
# 3. lancement caché : front avant/après, isHidden, fenêtres CGWindow
swift scripts/ax/hidden.swift
```

Le plus utile, `axprobe.swift`, dumpe pour chaque élément : `AXRole`, `AXSubrole`, `AXIdentifier`,
`AXTitle`, `AXDescription`, `AXValue`, `AXHelp`, la liste des actions et le cadre.
Le premier réflexe en cas de panne : lancer `axprobe` et comparer aux identifiants
de la section 3.
