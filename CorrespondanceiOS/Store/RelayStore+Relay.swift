import CorrespondanceCore
import Foundation

/// L'état de conversation vit dans le Relais (ADR 0001) — et l'iPhone applique
/// exactement la discipline de la phase B, celle d'`InboxStore+Relay` :
///
/// 1. le geste s'écrit d'abord chez nous (`state`), tout de suite ;
/// 2. il dépose une écriture dans `relayQueue`, persistée sur le disque ;
/// 3. la file part au prochain moment raisonnable, dans l'ordre, et un échec
///    arrête la passe sans rien perdre ;
/// 4. tant qu'une écriture attend, elle **prime** sur ce que le `/sync` raconte ;
/// 5. l'instantané n'est adopté que pour les salons CONNUS de cette session.
///
/// Rien de neuf ici : l'iPhone n'invente aucun état, il lit et écrit les mêmes
/// clés Matrix que le Mac. Une seule différence assumée : aucune migration —
/// un appareil neuf n'a rien de local à pousser, il ne fait que lire.
extension RelayStore {
  enum RelayFlag {
    case archived, pinned, muted
  }

  // MARK: - Identité

  /// Le salon d'un fil, ou `nil` s'il ne passe pas par le Relais. Purement
  /// syntaxique, comme sur le Mac : pas de saut d'acteur au milieu d'un geste.
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

  /// Un rappel posé, ou levé. Même discipline que les drapeaux : le geste est
  /// déjà fait à l'écran, l'écriture attend son tour.
  func relayNoteReminder(_ reminder: ConversationReminder?, conversationIDs: [String]) {
    for id in conversationIDs {
      guard let roomID = Self.relayRoomID(ofConversation: id) else { continue }
      relayQueue.enqueue(.reminder(roomID: roomID, value: reminder))
    }
    saveRelayQueue()
    startRelayFlush()
  }

  /// Ce que j'ai décidé d'une demande : acceptée, refusée, ou remise en
  /// attente (`nil`).
  func relayNoteRequest(_ decision: ConversationRequest.Decision?, conversationIDs: [String]) {
    for id in conversationIDs {
      guard let roomID = Self.relayRoomID(ofConversation: id) else { continue }
      relayQueue.enqueue(.request(roomID: roomID, value: decision))
    }
    saveRelayQueue()
    startRelayFlush()
  }

  /// Les messages masqués d'un salon. L'ensemble local est global ; celui du
  /// Relais est par salon, et c'est lui qui fait autorité — on lui ajoute
  /// simplement ce qu'on vient de masquer.
  /// Les réglages de l'agent — account data globale, sans salon.
  func relayNoteAgentSettings(_ settings: AgentSettings) {
    relayQueue.enqueue(.agentSettings(settings))
    saveRelayQueue()
    startRelayFlush()
  }

  func relayNoteHidden(messageID: String, conversationID: String) {
    guard let roomID = Self.relayRoomID(ofConversation: conversationID),
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

  func saveRelayQueue() {
    relayQueue.save(to: .standard, key: Self.relayQueueKey)
  }

  // MARK: - Envoyer

  /// Envoie la file, dans l'ordre. Un échec arrête la passe : ce qui reste
  /// attendra le prochain `/sync` réussi, sans rien perdre ni rien dupliquer.
  func flushRelayWrites() async {
    guard session == .connected, !isDemo, !relayQueue.isEmpty, !isFlushingRelay else { return }
    isFlushingRelay = true
    defer { isFlushingRelay = false }
    for write in relayQueue.writes {
      do {
        try await matrix.perform(write)
        relayQueue.complete(write)
      } catch {
        Self.log.notice(
          "écriture d'état gardée en attente : \(Self.readable(error), privacy: .public)"
        )
        break
      }
    }
    saveRelayQueue()
  }

  /// Lance un envoi sans attendre — un geste ne doit jamais patienter sur le réseau.
  func startRelayFlush() {
    guard session == .connected, !isDemo else { return }
    Task { @MainActor [weak self] in
      await self?.flushRelayWrites()
      await self?.adoptRelayState()
    }
  }

  // MARK: - Lire

  /// Relit tout l'état depuis le Relais — au démarrage, et après une reconnexion.
  /// C'est ce qui fait qu'un iPhone neuf retrouve l'archive faite sur le Mac.
  func reloadRelayState() async {
    guard !isDemo else { return }
    do {
      _ = try await matrix.fetchConversationState()
      await adoptRelayState()
    } catch {
      Self.log.notice("état du Relais illisible : \(Self.readable(error), privacy: .public)")
    }
  }

  /// L'état du Relais remplace le nôtre pour les fils CONNUS. Un salon dont la
  /// conversation n'est pas encore chargée ne fait rien changer : on ne peut ni
  /// le montrer, ni le perdre.
  func adoptRelayState() async {
    guard !isDemo else { return }
    let snapshot = relayQueue.applied(to: await matrix.conversationState)
    // Les réglages de l'agent ne dépendent d'aucun salon : ils s'adoptent avant
    // qu'on renonce faute de conversation connue.
    installAgentSettings(snapshot.agentSettings)

    var roomToConversation: [String: String] = [:]
    for conversation in conversations {
      if let roomID = Self.relayRoomID(ofConversation: conversation.id) {
        roomToConversation[roomID] = conversation.id
      }
    }
    // Les fils réunis sous une ligne de fusion gardent leur salon, donc leur état.
    for contact in mergedContacts {
      for id in contact.memberIDs {
        if let roomID = Self.relayRoomID(ofConversation: id) { roomToConversation[roomID] = id }
      }
    }
    guard !roomToConversation.isEmpty else { return }

    var next = InboxState.projected(snapshot, roomToConversation: roomToConversation)
    // Ce qu'on ne sait pas rattacher à un salon garde ce qu'il avait : iMessage
    // n'existe pas ici, mais une ligne de fusion, elle, n'a pas de salon.
    let known = Set(roomToConversation.values)
    for id in state.pinned where !known.contains(id) { next.pinned.insert(id) }
    for id in state.muted where !known.contains(id) { next.muted.insert(id) }
    for id in state.archived where !known.contains(id) { next.archived.insert(id) }
    for (id, text) in state.drafts where !known.contains(id) { next.drafts[id] = text }
    for (id, reminder) in state.reminders where !known.contains(id) { next.reminders[id] = reminder }
    for (id, decision) in state.requestDecisions where !known.contains(id) { next.requestDecisions[id] = decision }
    // Recalculé juste après par `refreshPendingRequests` : on ne le perd pas ici.
    next.pendingRequests = state.pendingRequests

    // Une ligne de fusion porte l'état de ses membres : archivée si tous le sont.
    for contact in mergedContacts {
      let members = contact.memberIDs
      guard !members.isEmpty else { continue }
      if members.allSatisfy({ next.archived.contains($0) }) { next.archived.insert(contact.id) }
      else { next.archived.remove(contact.id) }
      if members.contains(where: { next.pinned.contains($0) }) { next.pinned.insert(contact.id) }
      if members.allSatisfy({ next.muted.contains($0) }) { next.muted.insert(contact.id) }
      // Une ligne de fusion dort quand tous ses fils dorment : le rappel qui
      // sonne le premier la ramène.
      let rappels = members.compactMap { next.reminders[$0] }
      if rappels.count == members.count, let premier = rappels.min(by: { $0.wakeAt < $1.wakeAt }) {
        next.reminders[contact.id] = premier
      } else {
        next.reminders.removeValue(forKey: contact.id)
      }
    }

    if next != state { state = next }
    refreshPendingRequests()

    // Le masquage s'ajoute, il ne se retire jamais : rien dans l'app ne démasque
    // un message, et un identifiant qu'on ne sait pas rattacher serait perdu.
    var hidden = hiddenMessageIDs
    for roomID in roomToConversation.keys { hidden.formUnion(snapshot.hidden[roomID] ?? []) }
    if hidden != hiddenMessageIDs { hiddenMessageIDs = hidden }

    if let stored = snapshot.mergedContacts { adoptMergedContacts(stored) }

    // Ce que l'extension de notification a le droit de savoir, et rien d'autre :
    // quels salons sont muets. Elle ne tient pas de `/sync` — c'est ce dépôt-là
    // qui lui permet de taire une notification déjà arrivée (SharedRelayState).
    SharedRelayState.saveMutedRoomIDs(SharedRelayState.mutedRoomIDs(in: snapshot))
    // Et ce que l'extension de partage a le droit de savoir : les fils, pour
    // sa liste (RelayStore+Partage).
    ecrireIndexDuPartage()
  }
}
