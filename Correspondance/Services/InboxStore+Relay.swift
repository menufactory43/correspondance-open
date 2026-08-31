import Foundation
import OSLog
import CorrespondanceCore

/// L'état de conversation vit dans le Relais (ADR 0001).
///
/// Le geste de l'utilisateur reste immédiat : on écrit d'abord chez nous, puis
/// on dépose une écriture dans `relayQueue`. Elle part au prochain moment
/// raisonnable, et tant qu'elle n'est pas partie elle **prime** sur ce que le
/// `/sync` raconte. `UserDefaults` n'est plus la vérité, seulement le cache qui
/// permet d'afficher l'inbox avant le premier `/sync`.
///
/// iMessage ne passe pas par le Relais : ses fils gardent leur état local, tel quel.
extension InboxStore {
  static let relayLog = Logger(subsystem: "com.correspondance.app", category: "relais")

  /// La sorte d'écriture qu'un geste produit — un drapeau, un salon.
  enum RelayFlag {
    case archived, pinned, muted
  }

  // MARK: - Identité

  /// Le salon d'un fil, ou `nil` s'il ne passe pas par le Relais.
  ///
  /// Purement syntaxique : un identifiant bridgé s'écrit `réseau:!salon:serveur`,
  /// un iMessage `imessage:+336…` — seul le premier porte un `!`. Pas besoin
  /// d'interroger le pont, donc pas de saut d'acteur au milieu d'un geste.
  nonisolated static func relayRoomID(ofConversation conversationID: String) -> String? {
    MatrixSyncParser.roomID(inConversationID: conversationID)
  }

  // MARK: - Écrire

  func relayNote(_ flag: RelayFlag, value: Bool, conversationIDs: [String]) {
    for id in conversationIDs {
      guard let roomID = Self.relayRoomID(ofConversation: id) else { continue }
      switch flag {
      case .archived: relayQueue.enqueue(.archived(roomID: roomID, value: value))
      case .pinned: relayQueue.enqueue(.pinned(roomID: roomID, value: value))
      case .muted: relayQueue.enqueue(.muted(roomID: roomID, value: value))
      }
    }
    saveRelayQueue()
    startRelayFlush()
  }

  /// Un rappel posé, ou levé. Même discipline que les drapeaux.
  func relayNoteReminder(_ reminder: ConversationReminder?, conversationIDs: [String]) {
    for id in conversationIDs {
      guard let roomID = Self.relayRoomID(ofConversation: id) else { continue }
      relayQueue.enqueue(.reminder(roomID: roomID, value: reminder))
    }
    saveRelayQueue()
    startRelayFlush()
  }

  func relayNoteMergedContacts(_ stored: MergedContactStore.Stored) {
    relayQueue.enqueue(.mergedContacts(stored))
    saveRelayQueue()
    startRelayFlush()
  }

  /// Les messages masqués d'un salon. L'ensemble local est global (tous réseaux
  /// confondus) ; celui du Relais est par salon, et c'est lui qui fait autorité
  /// pour ce salon — on lui ajoute simplement ce qu'on vient de masquer.
  func relayNoteHidden(messageID: String, conversationID: String) {
    guard let roomID = Self.relayRoomID(ofConversation: conversationID),
          // Un event Matrix commence par `$` ; le reste de l'ensemble global
          // appartient à iMessage et n'a rien à faire dans l'account data du salon.
          messageID.hasPrefix("$")
    else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      let known = self.relayQueue.applied(to: await self.matrix.conversationState).hidden[roomID] ?? []
      let updated = known.union([messageID])
      guard updated != known else { return }
      self.relayQueue.enqueue(.hidden(roomID: roomID, eventIDs: updated))
      self.saveRelayQueue()
      self.startRelayFlush()
    }
  }

  /// Le brouillon part une seconde après la dernière frappe, jamais à chaque touche.
  func scheduleRelayDraftPush(conversationID: String, text: String) {
    guard let roomID = Self.relayRoomID(ofConversation: conversationID) else { return }
    relayDraftTasks[conversationID]?.cancel()
    relayDraftTasks[conversationID] = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard let self, !Task.isCancelled else { return }
      self.relayDraftTasks.removeValue(forKey: conversationID)
      self.relayQueue.enqueue(.draft(roomID: roomID, text: text))
      self.saveRelayQueue()
      self.startRelayFlush()
    }
  }

  /// Un fil qu'on quitte n'a plus d'état à pousser.
  func relayForget(conversationID: String) {
    relayDraftTasks.removeValue(forKey: conversationID)?.cancel()
  }

  func saveRelayQueue() {
    relayQueue.save(to: .standard, key: "correspondance.relayWriteQueue")
  }

  // MARK: - Envoyer

  /// Envoie la file, dans l'ordre. Un échec arrête la passe : ce qui reste
  /// attendra le prochain `/sync` réussi, sans rien perdre ni rien dupliquer.
  func flushRelayWrites() async {
    guard isMatrixConnected, !relayQueue.isEmpty, !isFlushingRelay else { return }
    isFlushingRelay = true
    defer { isFlushingRelay = false }
    for write in relayQueue.writes {
      do {
        try await matrix.perform(write)
        relayQueue.complete(write)
      } catch {
        Self.relayLog.notice(
          "écriture d'état gardée en attente (\(String(describing: write.roomID), privacy: .private)) : \(error.localizedDescription, privacy: .public)"
        )
        break
      }
    }
    saveRelayQueue()
  }

  /// Lance un envoi sans attendre — un geste ne doit jamais patienter sur le réseau.
  func startRelayFlush() {
    guard isMatrixConnected else { return }
    Task { @MainActor [weak self] in
      await self?.flushRelayWrites()
      await self?.adoptRelayState()
    }
  }

  // MARK: - Migration unique

  /// Au premier lancement de cette version, l'état accumulé en local part vers
  /// le Relais — sans quoi une archive de trois ans n'existerait que sur ce Mac.
  ///
  /// Jouée une seule fois (`correspondance.stateMigratedToRelay.v1`), après le
  /// premier `/sync` : avant lui, aucun salon n'est connu et il n'y aurait rien
  /// à migrer. On ne pousse que ce que le Relais ne sait pas déjà — sur un
  /// compte qui a déjà servi ailleurs, c'est l'union qui gagne, pas l'écrasement.
  func migrateStateToRelayIfNeeded() async {
    let flag = "correspondance.stateMigratedToRelay.v1"
    guard !UserDefaults.standard.bool(forKey: flag), isMatrixConnected else { return }
    let relay = await matrix.conversationState

    var ids = conversations.map(\.id)
    ids.append(contentsOf: mergedMemberConversationIDs)
    var pushed = 0
    for id in Set(ids) {
      guard let roomID = Self.relayRoomID(ofConversation: id) else { continue }
      if archivedIDs.contains(id), !relay.archived.contains(roomID) {
        relayQueue.enqueue(.archived(roomID: roomID, value: true))
        pushed += 1
      }
      if pinnedIDs.contains(id), !relay.pinned.contains(roomID) {
        relayQueue.enqueue(.pinned(roomID: roomID, value: true))
        pushed += 1
      }
      if mutedIDs.contains(id), !relay.muted.contains(roomID) {
        relayQueue.enqueue(.muted(roomID: roomID, value: true))
        pushed += 1
      }
      if let reminder = remindersByID[id], relay.reminders[roomID] == nil, !reminder.isElapsed(now: Date()) {
        relayQueue.enqueue(.reminder(roomID: roomID, value: reminder))
        pushed += 1
      }
      let text = draftSnapshot[id]?.text ?? ""
      if !text.isEmpty, relay.drafts[roomID] == nil {
        relayQueue.enqueue(.draft(roomID: roomID, text: text))
        pushed += 1
      }
    }

    // Les masqués sont globaux chez nous, rangés par salon chez le Relais :
    // c'est le pont qui sait à quel salon appartient un event.
    for (roomID, eventIDs) in await matrix.roomIDs(ofMessages: hiddenMessageIDs) {
      let merged = (relay.hidden[roomID] ?? []).union(eventIDs)
      guard merged != relay.hidden[roomID] else { continue }
      relayQueue.enqueue(.hidden(roomID: roomID, eventIDs: merged))
      pushed += 1
    }

    let localMerges = MergedContactStore.Stored(merged: mergedContacts, dismissedPairs: dismissedMergePairs)
    if relay.mergedContacts == nil, !localMerges.merged.isEmpty || !localMerges.dismissedPairs.isEmpty {
      relayQueue.enqueue(.mergedContacts(localMerges))
      pushed += 1
    }

    UserDefaults.standard.set(true, forKey: flag)
    saveRelayQueue()
    Self.relayLog.notice("état local migré vers le Relais : \(pushed, privacy: .public) élément(s).")
    await flushRelayWrites()
    await adoptRelayState()
  }

  // MARK: - Lire

  /// Relit tout l'état depuis le Relais (démarrage, ou après une reconnexion).
  func reloadRelayState() async {
    do {
      _ = try await matrix.fetchConversationState()
      await adoptRelayState()
    } catch {
      Self.relayLog.notice("état du Relais illisible : \(error.localizedDescription, privacy: .public)")
    }
  }

  /// L'état du Relais remplace le nôtre pour les fils bridgés **connus**. Un
  /// salon dont la conversation n'est pas encore chargée ne fait rien changer :
  /// on ne peut ni le montrer ni le perdre.
  func adoptRelayState() async {
    let snapshot = relayQueue.applied(to: await matrix.conversationState)
    var roomToConversation: [String: String] = [:]
    for conversation in conversations {
      if let roomID = Self.relayRoomID(ofConversation: conversation.id) {
        roomToConversation[roomID] = conversation.id
      }
    }
    for id in mergedMemberConversationIDs {
      if let roomID = Self.relayRoomID(ofConversation: id) { roomToConversation[roomID] = id }
    }
    guard !roomToConversation.isEmpty else { return }

    let known = Set(roomToConversation.values)
    let mapped: (Set<String>) -> Set<String> = { rooms in
      Set(rooms.compactMap { roomToConversation[$0] })
    }
    var drafts: [String: String] = [:]
    for (roomID, text) in snapshot.drafts {
      if let id = roomToConversation[roomID] { drafts[id] = text }
    }
    var reminders: [String: ConversationReminder] = [:]
    for (roomID, reminder) in snapshot.reminders {
      if let id = roomToConversation[roomID] { reminders[id] = reminder }
    }
    // Le masquage s'ajoute, il ne se retire jamais : rien dans l'app ne
    // démasque un message, et un identifiant qu'on ne sait pas rattacher à un
    // salon (message pas encore chargé) serait perdu pour de bon.
    var hidden = hiddenMessageIDs
    for roomID in roomToConversation.keys {
      hidden.formUnion(snapshot.hidden[roomID] ?? [])
    }

    installRelayState(
      pinned: mapped(snapshot.pinned),
      muted: mapped(snapshot.muted),
      archived: mapped(snapshot.archived),
      known: known,
      drafts: drafts,
      reminders: reminders,
      hidden: hidden,
      merged: snapshot.mergedContacts
    )
  }
}
