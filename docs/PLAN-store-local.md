# Plan — le magasin local (SQLite)

Glossaire : `CONTEXT.md`. Branche : `core/local-store`, partie de `core/phase-d`.
Tout est dans `Packages/CorrespondanceCore/Sources/CorrespondanceCore/Storage/`.

## Ce que ça remplace

`MatrixConversationCache` : un instantané JSON global
(`~/Library/Application Support/Correspondance/matrix-conversations.json`) qui portait le
`next_batch`, les conversations et **tous** les messages de **toutes** les conversations.

Trois défauts, chacun visible à l'usage :

1. **Relu en entier au lancement.** L'historique complet de tous les fils entrait en mémoire
   avant d'afficher quoi que ce soit.
2. **Réécrit en entier à chaque passe de `/sync`.** Un message reçu réécrivait le fichier.
3. **Le curseur ne reprenait pas.** Le fichier ne gardait aucun état de salon (ni membres, ni
   pont, ni marqueurs de lecture) : un `/sync` incrémental aurait laissé des salons anonymes.
   D'où un **sync initial complet à chaque lancement**, et le commentaire d'origine qui
   l'assumait.

## Le schéma

`~/Library/Application Support/Correspondance/correspondance.sqlite` sur Mac, le conteneur
équivalent sur iPhone (`FileManager.applicationSupportDirectory`, même code). Mode WAL,
`synchronous = NORMAL`, `busy_timeout` de 5 s.

Version installée dans `schema_version`, migrations numérotées jouées dans l'ordre, une fois
(`LocalStore.migrate`). **Plus de champ « absent des caches plus anciens »** : la forme est la
même pour tout le monde, c'est la migration qui la fait avancer.

### v1 — les tables

| Table | Ce qu'elle porte |
|---|---|
| `rooms` | `room_id` (clé), `conversation_id`, `network`, `title`, `preview`, `last_message_at`, `unread_count`, `transport_key`, `is_group`, `avatar_mxc`, `member_avatar_ids`, `state` |
| `messages` | `event_id` (clé), `room_id`, `conversation_id`, `sent_at`, `sender_id`, `sender_name`, `text`, `is_from_me`, `attachment_names`, `attachment_types`, `payload` |
| `reactions` | `event_id` (clé), `room_id`, `target_event_id`, `emoji`, `sender_id`, `sender_name`, `is_mine` |
| `sync_state` | `key` / `value` — le `next_batch`, les drapeaux de migration |

Index : `rooms(last_message_at DESC)`, `messages(room_id, sent_at DESC)`, `reactions(room_id)`.

**La règle de partage colonne / blob** : ce sur quoi on trie, filtre ou cherche a sa colonne ;
ce qui ne sert qu'à l'affichage vit dans un blob `Codable`.

- `rooms.state` (blob) = ce que `MatrixSyncParser` doit retrouver pour continuer : `members`,
  `heroes`, `readMarkerByUser`, `pollsByEventID`, `pendingEdits`, `unresolvedQuoteMessageIDs`,
  les champs de pont (`m.bridge`), `lastEventAt`. **C'est ce qui rend le curseur reprenable.**
- `messages.payload` (blob) = le `ChatMessage` entier : pièces jointes, citation, aperçu de
  lien, sondage, vocal, historique de modification.

Les réactions ont leur table plutôt qu'un champ du message : une `m.room.redaction` doit
pouvoir en retirer **une** précisément, ce qui était impossible avec un agrégat figé.

### v2 — l'index plein texte

`messages_fts`, table FTS5 externe (`content='messages'`, `content_rowid='rowid'`), colonnes
`text`, `sender_name`, `attachment_names`, `attachment_types`, tokenizer
`unicode61 remove_diacritics 2`. Trois déclencheurs (insert / delete / update) la tiennent à
jour ; la migration l'amorce avec ce que la base contient déjà.

FTS5 est compilé dans le SQLite système de macOS et d'iOS — `SQLiteDatabaseTests.testSystemSQLiteHasFTS5`
le prouve à chaque passe de tests plutôt que de le croire sur parole.

## Comment ça s'écrit

Jamais globalement. `MatrixSyncParser` note au passage chaque event qu'il pose, corrige ou
retire (`MatrixRoomModel.pendingWrites` / `pendingDeletions`) ; les écritures optimistes du pont
(réaction posée, voix de sondage, chemin d'une pièce jointe téléchargée) font de même.
`MatrixBridgeService.persist(cursor:leftRoomIDs:)` ramasse ce lot et le passe à
`LocalStore.commit` : salons touchés, messages et réactions changés, rédactions, salons quittés,
**et le curseur**, dans une seule transaction.

Le curseur n'est écrit qu'après le traitement complet du lot, **invitations de portails
acceptées comprises** (`acceptBridgeInvites` passe avant). Synapse n'envoie une invitation de
portail qu'une fois : un curseur avancé sur un lot mal digéré la perdrait pour de bon.

## Comment ça se lit

- **Au lancement** : `LocalStore.rooms()` (les lignes de l'inbox, réseau compris) +
  `lastMessages()` (un message par salon, pour l'aperçu) + les messages pointés par les
  marqueurs de lecture (sans eux, la coche « Vu » retomberait à « Envoyé »). Rien d'autre.
- **À l'ouverture d'un fil** : `messages(roomID:limit:)`, une page de 300, du plus récent au
  plus ancien puis rendue dans l'ordre d'affichage.
- **En remontant** : `MatrixBridgeService.loadOlderMessages(conversationID:)` →
  `messages(roomID:limit:before:)`.
- **Le backfill** (`/rooms/{id}/messages`) écrit sa page : ce qui a été paginé une fois ne se
  redemandera plus.
- **La recherche** : `LocalStore.search(query:facet:roomIDs:)`. Le SQL pré-filtre (FTS MATCH +
  colonnes de pièces jointes), `FacetedSearch.matches` tranche ensuite — la définition d'un
  onglet reste en Swift, la même pour les deux plateformes.

## Le curseur, et le trou qu'il ouvre

Reprendre `next_batch` fait gagner un sync initial complet à chaque lancement. Mais un salon
**rejoint** pendant que l'app dormait — un portail créé par un pont, une invitation acceptée sur
l'autre appareil — n'apparaîtra dans aucun `/sync` incrémental.

`MatrixBridgeService.reconcileJoinedRooms()`, une fois par lancement et en arrière-plan :
`GET /joined_rooms`, et pour tout salon joint que la base ignore, `GET /rooms/{id}/state` +
une page de `/messages`. Trente salons au plus par passe.

Porte de secours : **Réglages → « Recharger depuis le Relais »**, sur les deux plateformes. La
base se vide, le curseur repart de zéro, le prochain `/sync` — initial — repeuple tout.

## La reprise de l'ancien fichier

`LocalStore.importLegacySnapshotIfNeeded` : au premier lancement, `matrix-conversations.json`
est versé dans la base (conversations, historique, réactions figées, pièces jointes) puis
renommé `.migrated` — rangé, pas supprimé. Un drapeau dans `sync_state` empêche de rejouer si
le fichier revenait (restauration Time Machine, dossier synchronisé).

**Le curseur ne traverse pas** : l'ancien fichier n'avait aucun état de salon. On refait un sync
initial, une fois, pendant que l'historique est déjà là.

## Mesures

Base synthétique de 120 salons × 400 messages (48 000 messages), Mac M-series, build `release` :

| | Avant (JSON) | Après (SQLite) |
|---|---|---|
| Lecture au lancement | 183 ms — 48 000 messages en mémoire | **11 ms** — 120 salons, 120 aperçus |
| Ouverture d'un fil | 0 (déjà en mémoire) | 2 ms (300 messages) |
| Une passe `/sync` (3 salons, 3 messages) | réécriture complète du fichier (~180 ms) | **4,9 ms** |
| Recherche plein texte | impossible hors mémoire | 5 ms |
| Taille sur disque | 12,2 Mo | 31,7 Mo |

La taille est le prix assumé : le texte vit à la fois en colonne (tri, filtre) et dans le blob
`payload`, et l'index FTS s'ajoute. Trente mégaoctets pour cinquante mille messages, contre un
lancement quinze fois plus rapide et une recherche qui trouve enfin.

**Non mesuré** : le volume du premier `/sync` contre le vrai Relais (voir « À vérifier »).

## Ce qui reste

- **Le défilement infini n'est pas branché à l'UI.** `loadOlderMessages` existe et est testé,
  mais aucune vue ne l'appelle : à 300 messages par page, un fil bridgé tient entier dans sa
  première page (le backfill en remonte 50 à la fois). Le jour où un fil dépassera, c'est le
  `ScrollView` du Mac et de l'iPhone qui devront le demander en atteignant le haut.
- **Un fil ouvert reste en mémoire jusqu'à la fin de la session.** La mémoire croît avec ce
  qu'on lit, ce qui est la bonne borne, mais rien ne libère un fil qu'on a quitté.
- **Le compactage.** Rien ne purge la base : elle grossit avec l'historique. `VACUUM` et une
  éventuelle rétention (« garder deux ans ») restent à décider.
- **L'extension de notification iOS** ne lit pas la base : elle se contente de
  `SharedRelayState` (App Group `UserDefaults`, salons en sourdine). Rien à faire tant qu'elle
  n'a pas besoin de l'historique ; le jour venu, il faudra déplacer le fichier dans le
  conteneur partagé de l'App Group.
- **iMessage n'entre pas dans cette base.** `chat.db` reste sa source, et la recherche par
  onglets garde son ancien chemin pour lui.

## À vérifier à la main contre le NUC

1. **Le volume du premier `/sync`.** Lancer l'app deux fois de suite et comparer : la seconde
   doit être un `/sync` incrémental (`?since=`), pas un initial.
2. **Les invitations de portails.** Connecter un pont, vérifier qu'un portail créé pendant que
   l'app est fermée apparaît au lancement suivant — par la réconciliation `/joined_rooms` si le
   `/sync` incrémental l'a manqué.
3. **La reprise du fichier JSON** sur un Mac qui a un vrai `matrix-conversations.json` : que
   l'historique soit intact et que le fichier soit renommé `.migrated`.
4. **La coche « Vu »** au lancement, sur un fil non ouvert : elle doit être là, pas retombée à
   « Envoyé ».
5. **« Recharger depuis le Relais »** : l'inbox se vide puis se remplit, sans doublon.
6. **La recherche** d'un mot présent seulement dans un fil jamais ouvert depuis l'installation.
