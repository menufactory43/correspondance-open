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
    // Le masquage : ce qui vient du Relais pour les salons connus, plus ce que
    // les fils non bridgés (iMessage) avaient déjà chez nous.
    var hidden = hiddenMessageIDs.filter { !$0.hasPrefix("$") }
    for roomID in roomToConversation.keys {
      hidden.formUnion(snapshot.hidden[roomID] ?? [])
    }

    installRelayState(
      pinned: mapped(snapshot.pinned),
      muted: mapped(snapshot.muted),
      archived: mapped(snapshot.archived),
      known: known,
      drafts: drafts,
      hidden: hidden,
      merged: snapshot.mergedContacts
    )
  }
}
