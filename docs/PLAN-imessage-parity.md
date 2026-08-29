# Plan — parité « Messages » (iMessage dans Correspondance)

Objectif : que le réseau iMessage dans Correspondance fasse tout ce que Messages.app fait au quotidien,
sans SIP désactivé ni framework privé. Trois voies techniques, par ordre de robustesse :

| Voie | Ce qu'elle donne | Robustesse |
|---|---|---|
| **A. `chat.db` (lecture)** | tout l'historique : messages, pièces jointes, tapbacks, réponses (threads), éditions, lu/livré, groupes, effets | ★★★★ stable depuis des années ; accès disque complet requis |
| **B. Apple Events → Messages.app** | envoi de texte et de fichiers vers un handle ou un chat existant | ★★★★ officiel, permission Automation |
| **C. Accessibilité (AXUIElement) → Messages.app** | tout ce que l'UI de Messages sait faire et que B ne couvre pas : tapback, réponse citée, modifier, annuler l'envoi, lu/non-lu, création de groupe, renommage, quitter | ★★ fragile (arbre AX qui change à chaque macOS), permission Accessibilité ; c'est la voie de Beeper Desktop |

Règle : chaque fonction est implémentée par la voie la plus robuste qui la couvre ; C n'est utilisée que quand A+B ne suffisent pas,
avec **repli explicite** (message d'erreur clair, jamais d'échec silencieux) et un **test de santé** au démarrage
(« Automatisation Messages : OK / Accessibilité manquante / arbre AX inconnu — macOS 26.6 supporté »).

## État actuel (`Services/IMessageDatabase.swift`, `IMessageSender.swift`)

| Fonction | État | Voie |
|---|---|---|
| Lire fils, messages, pièces jointes images | Fait | A |
| Temps réel (WAL surveillé) | Fait | A |
| Envoyer du texte à un contact / groupe | Fait | B |
| Tapbacks reçus (agrégés sous la bulle) | Fait | A |
| Réponses citées reçues (`thread_originator_guid`) | Fait | A |
| Livré / lu sur mes envois | Fait (affiché) | A |
| Envoyer un tapback, une réponse citée | **Absent** | C |
| Marquer lu / non lu | **Absent** | C (lu) — le « lu » côté expéditeur n'est envoyé que si Messages.app affiche le fil |
| Envoyer une pièce jointe | **Absent** | B (`send POSIX file`) |
| Modifier / annuler l'envoi (15 min / 2 min) | **Absent** | A (lecture) + C (action) |
| Messages audio | **Absent** | A (lecture, `.caf`) ; envoi C |
| Effets (bulle/écran), stickers, Memoji | Lecture partielle | A ; envoi hors cible |
| Groupes : créer, nommer, ajouter/retirer, quitter | **Absent** | C |
| Indicateur de frappe | **Absent** | impossible sans API privée ; Beeper ne l'a pas non plus sur Mac |
| SMS/RCS via iPhone (Text Message Forwarding) | Fonctionne déjà si activé (même `chat.db`) | A/B |
| FaceTime, SharePlay, Apple Cash, localisation | hors cible | — |

## Lots

### Lot M1 — ce que A+B couvrent encore (effort S, aucune permission nouvelle)
1. **Pièces jointes en envoi** : `tell application "Messages" to send POSIX file … to chat id …` (`IMessageSender.send(fileURL:toChat:)`), images, PDF, tout fichier. Aperçu dans la bulle avant envoi (déjà là pour Signal).
2. **Éditions et annulations reçues** : `message.date_edited`, `message_summary_info` (blob plist : historique des éditions), `date_retracted` → bulle « Modifié » avec historique au survol, « Message annulé » en italique.
3. **Messages audio reçus** : pièce jointe `audio/x-caf` → lecteur inline (le lecteur audio est prévu au lot P1 Beeper, à mutualiser).
4. **Groupes en lecture** : nom, participants, photo (`chat.display_name`, `chat_handle_join`, `chat.group_photo_guid`), événements « X a ajouté Y » (`item_type` 1/2/3) affichés en séparateurs discrets.
5. **Effets reçus** : `expressive_send_style_id` → petite étiquette « envoyé avec Confettis » (pas de rendu de l'effet).
6. Tests : fixtures `chat.db` réduites (schéma macOS 26) dans `CorrespondanceTests/Fixtures/`.

### Lot M2 — automatisation Accessibilité (effort L, nouvelle permission)
Nouveau service `Services/IMessageAutomation.swift` (actor, `AXUIElement`), `Services/IMessageAutomationHealth.swift`,
entrée Réglages « Automatisation Messages » avec bouton vers Réglages Système › Confidentialité › Accessibilité.

Mécanique commune :
- Messages.app lancé en arrière-plan (`NSWorkspace.openApplication` avec `activates = false`), fenêtre déplacée hors écran principal si l'utilisateur le demande (option), jamais mise au premier plan.
- Ouvrir le fil : `open imessage://` ne cible pas un chat ; on pilote la liste AX (`AXOutline`/`AXTable` de la sidebar, ligne dont le titre = nom du fil) ou, plus fiable, Apple Events `set active chat` n'existe pas → sélection AX par identifiant de chat visible dans `AXIdentifier` quand présent, sinon par titre.
- Trouver la bulle : parcourir le transcript (`AXScrollArea` → éléments avec `AXValue` = texte du message, `AXDescription` contenant l'heure) ; on garde le `guid` côté `chat.db` pour vérifier après coup que l'action a bien produit une ligne (tapback : nouvelle ligne `associated_message_type` 2000–2005 ; réponse : `thread_originator_guid`).
- Chaque action = séquence AX + **vérification dans `chat.db` sous 3 s**, sinon erreur remontée à l'UI.

Fonctions, dans l'ordre :
1. **Tapback** (❤️ 👍 👎 😂 ‼️ ❓ + emoji libre depuis macOS 15) : clic secondaire sur la bulle → menu contextuel → « Tapback » → choisir ; ou `AXPress` sur le bouton de tapback qui apparaît au survol. Retrait = même geste sur le tapback actif.
2. **Réponse citée** : menu contextuel → « Répondre », saisie dans le champ (`AXTextArea` du composer), Entrée. Le texte est passé par le presse-papiers puis ⌘V (plus fiable que la frappe simulée avec les accents).
3. **Marquer lu** : sélectionner le fil dans Messages suffit (Messages envoie le `read receipt`) ; **non lu** : menu contextuel de la ligne → « Marquer comme non lu ».
4. **Modifier** (≤ 15 min) / **Annuler l'envoi** (≤ 2 min) : menu contextuel sur ma bulle → « Modifier » / « Annuler l'envoi ».
5. **Groupes** : créer (bouton Nouveau message + saisie des destinataires + premier message via B), renommer et ajouter/retirer (fiche du groupe : bouton « i » → champs), quitter.
6. Test de santé : au lancement et à chaque erreur, une sonde vérifie que la sidebar et le transcript sont localisables ; résultat dans Réglages, avec la version de macOS validée. Sur une version non validée, les actions C sont proposées mais marquées « expérimental ».

### Lot M3 — finitions (effort M)
1. Envoi de messages audio (C : bouton micro du composer Messages) — ou hors cible si trop fragile.
2. Aperçus de liens riches reçus (`payload_data` des balloons `com.apple.messages.URLBalloonProvider`) → carte lien.
3. Stickers/Memoji reçus comme images ; effets d'écran ignorés proprement.
4. Photos partagées iCloud (« Photos partagées ») : lecture seule via l'URL de la pièce jointe.

## Ce qui ne sera pas fait, et pourquoi
- **Indicateur de frappe iMessage** : aucun canal public ; Beeper Mac ne l'a pas.
- **Effets envoyés, Apple Cash, FaceTime, SharePlay, localisation, iMessage apps** : hors identité Focus.
- **Barcelona / IMCore** : SIP désactivé, projet abandonné par Beeper.

## Risques et garde-fous
- Les actions AX sont sérialisées (un seul pilotage à la fois), avec délai maximal de 5 s et annulation propre.
- Aucune action AX n'est lancée sans que `chat.db` confirme que le fil et le message existent.
- L'arbre AX est décrit dans `docs/IMESSAGE-AX.md` (chemins, attributs, version macOS) pour re-valider vite à chaque mise à jour système.
- Tout est derrière un réglage « Automatisation Messages » désactivable ; sans lui, l'app reste exactement ce qu'elle est aujourd'hui.

## Ordre conseillé
M1 (rapide, zéro risque) → M2.1 tapback → M2.2 réponse → M2.3 lu/non-lu → M2.4 modifier/annuler → M2.5 groupes → M3.
M1 et M2 peuvent se mener en parallèle du polish : nouveaux fichiers `Services/IMessageAutomation*.swift`, `IMessageSender.swift`, `IMessageDatabase.swift`, Réglages ; les vues n'ont besoin que d'un menu contextuel branché sur `InboxStore.react/reply` déjà existants.
