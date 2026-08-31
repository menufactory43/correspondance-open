import Foundation

/// L'état de conversation tel que le Relais le raconte, salon par salon.
///
/// C'est la lecture de ce que `MatrixClient` écrit : tags (`m.tag`), push rules
/// (`m.push_rules`), account data de salon et account data global. Cumulatif —
/// un `/sync` incrémental ne renvoie que ce qui a changé, donc on fusionne
/// plutôt que de repartir de zéro. Les clés sont des **room IDs** (`!abc:serveur`),
/// jamais des identifiants de conversation : c'est l'appelant qui recolle le réseau.
public struct ConversationStateSnapshot: Codable, Sendable, Equatable {
  public var archived: Set<String>
  public var pinned: Set<String>
  public var muted: Set<String>
  /// Texte du brouillon seul. Les pièces jointes en attente sont des chemins
  /// locaux : elles n'ont aucun sens sur un autre appareil et restent au Mac.
  public var drafts: [String: String]
  public var hidden: [String: Set<String>]
  /// Rappels posés : le salon revient dans la file à l'heure dite.
  public var reminders: [String: ConversationReminder]
  /// Demandes tranchées : un salon absent d'ici attend encore une décision.
  public var requests: [String: ConversationRequest.Decision]
  /// Fusions de contacts — un seul objet global, tel que `MergedContactStore` l'écrit.
  public var mergedContacts: MergedContactStore.Stored?

  public init(
    archived: Set<String> = [],
    pinned: Set<String> = [],
    muted: Set<String> = [],
    drafts: [String: String] = [:],
    hidden: [String: Set<String>] = [:],
    reminders: [String: ConversationReminder] = [:],
    requests: [String: ConversationRequest.Decision] = [:],
    mergedContacts: MergedContactStore.Stored? = nil
  ) {
    self.archived = archived
    self.pinned = pinned
    self.muted = muted
    self.drafts = drafts
    self.hidden = hidden
    self.reminders = reminders
    self.requests = requests
    self.mergedContacts = mergedContacts
  }

  public var isEmpty: Bool {
    archived.isEmpty && pinned.isEmpty && muted.isEmpty
      && drafts.isEmpty && hidden.isEmpty && reminders.isEmpty && requests.isEmpty
      && mergedContacts == nil
  }

  /// Fusionne un payload `/sync`. Chaque event reçu **remplace** ce qu'il décrit :
  /// un `m.tag` porte tous les tags du salon, `m.push_rules` toutes les règles.
  /// Ce qui n'est pas mentionné garde sa valeur — le serveur ne le renvoie pas.
  public mutating func apply(_ response: MatrixSyncResponse) {
    for event in response.accountData?.events ?? [] {
      applyGlobal(event)
    }
    for (roomID, room) in response.rooms?.join ?? [:] {
      for event in room.accountData?.events ?? [] {
        applyRoom(event, roomID: roomID)
      }
    }
    // Un salon quitté n'a plus d'état à porter.
    for roomID in response.rooms?.leave?.keys ?? [:].keys {
      forget(roomID: roomID)
    }
  }

  public mutating func forget(roomID: String) {
    archived.remove(roomID)
    pinned.remove(roomID)
    muted.remove(roomID)
    drafts.removeValue(forKey: roomID)
    hidden.removeValue(forKey: roomID)
    reminders.removeValue(forKey: roomID)
    requests.removeValue(forKey: roomID)
  }

  private mutating func applyGlobal(_ event: MatrixEvent) {
    guard let content = event.content else { return }
    switch event.type {
    case ConversationStateKeys.pushRulesType:
      muted = Self.mutedRoomIDs(inPushRules: content)
    case ConversationStateKeys.mergedContactsType:
      mergedContacts = ConversationStateCodec.mergedContacts(in: content)
    default:
      break
    }
  }

  private mutating func applyRoom(_ event: MatrixEvent, roomID: String) {
    guard let content = event.content else { return }
    switch event.type {
    case ConversationStateKeys.tagType:
      let tags = content["tags"]?.objectValue ?? [:]
      setMembership(&pinned, roomID, tags[ConversationStateKeys.favouriteTag] != nil)
      setMembership(&archived, roomID, tags[ConversationStateKeys.archivedTag] != nil)
    case ConversationStateKeys.draftType:
      let text = ConversationStateCodec.draftText(in: content)
      if text.isEmpty { drafts.removeValue(forKey: roomID) } else { drafts[roomID] = text }
    case ConversationStateKeys.hiddenType:
      let ids = ConversationStateCodec.hiddenEventIDs(in: content)
      if ids.isEmpty { hidden.removeValue(forKey: roomID) } else { hidden[roomID] = ids }
    case ConversationStateKeys.reminderType:
      // Un corps vide, c'est le rappel levé : l'account data ne se supprime pas
      // chez Matrix, on l'écrase avec `{}`.
      if let reminder = ConversationStateCodec.reminder(in: content) {
        reminders[roomID] = reminder
      } else {
        reminders.removeValue(forKey: roomID)
      }
    case ConversationStateKeys.requestType:
      if let decision = ConversationStateCodec.requestDecision(in: content) {
        requests[roomID] = decision
      } else {
        requests.removeValue(forKey: roomID)
      }
    default:
      break
    }
  }

  private func setMembership(_ set: inout Set<String>, _ roomID: String, _ member: Bool) {
    if member { set.insert(roomID) } else { set.remove(roomID) }
  }

  /// Les salons muets, lus dans `m.push_rules`.
  ///
  /// Une règle de portée `room` dont les actions sont vides ne notifie rien ;
  /// `["dont_notify"]`, déprécié mais encore écrit par d'autres clients, dit la
  /// même chose. Une règle désactivée (`enabled: false`) ne compte pas.
  public static func mutedRoomIDs(inPushRules content: MatrixJSON) -> Set<String> {
    let rules = content.value(at: "global.room")?.arrayValue ?? []
    var result: Set<String> = []
    for rule in rules {
      guard let roomID = rule["rule_id"]?.stringValue else { continue }
      if rule["enabled"]?.boolValue == false { continue }
      let actions = rule["actions"]?.arrayValue ?? []
      let silent = actions.isEmpty || actions.contains { $0.stringValue == "dont_notify" }
      if silent { result.insert(roomID) }
    }
    return result
  }
}

/// Encodage et décodage des corps d'account data. Pur : c'est le contrat que le
/// Mac écrit et que l'iPhone relira.
public enum ConversationStateCodec {
  /// `fr.correspondance.draft` → `{ "text": "…" }`.
  public static func draftContent(text: String) -> MatrixJSON {
    .object(["text": .string(text)])
  }

  public static func draftText(in content: MatrixJSON) -> String {
    content.string(at: "text") ?? ""
  }

  /// `fr.correspondance.reminder` → `{ "wake_at": ms, "set_at": ms }`.
  /// Les dates partent en millisecondes depuis 1970, comme tous les temps Matrix.
  public static func reminderContent(_ reminder: ConversationReminder?) -> MatrixJSON {
    guard let reminder else { return .object([:]) }
    return .object([
      "wake_at": .number(reminder.wakeAt.timeIntervalSince1970 * 1000),
      "set_at": .number(reminder.setAt.timeIntervalSince1970 * 1000),
    ])
  }

  public static func reminder(in content: MatrixJSON) -> ConversationReminder? {
    guard let wake = content["wake_at"]?.doubleValue, wake > 0 else { return nil }
    let set = content["set_at"]?.doubleValue ?? wake
    return ConversationReminder(
      wakeAt: Date(timeIntervalSince1970: wake / 1000),
      setAt: Date(timeIntervalSince1970: set / 1000)
    )
  }

  /// `fr.correspondance.request` → `{ "decision": "accepted" | "declined" }`.
  public static func requestContent(_ decision: ConversationRequest.Decision?) -> MatrixJSON {
    guard let decision else { return .object([:]) }
    return .object(["decision": .string(decision.rawValue)])
  }

  public static func requestDecision(in content: MatrixJSON) -> ConversationRequest.Decision? {
    guard let raw = content.string(at: "decision") else { return nil }
    return ConversationRequest.Decision(rawValue: raw)
  }

  /// `fr.correspondance.hidden` → `{ "event_ids": ["…"] }`, trié pour que deux
  /// écritures du même ensemble produisent le même corps.
  public static func hiddenContent(eventIDs: Set<String>) -> MatrixJSON {
    .object(["event_ids": .array(eventIDs.sorted().map { .string($0) })])
  }

  public static func hiddenEventIDs(in content: MatrixJSON) -> Set<String> {
    Set((content["event_ids"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty })
  }

  /// `fr.correspondance.merged_contacts` → le `MergedContactStore.Stored` tel
  /// quel (`{ "merged": [...], "dismissedPairs": [...] }`).
  public static func mergedContactsContent(_ stored: MergedContactStore.Stored) -> MatrixJSON? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(MergedContactStore.sanitized(stored)),
          let json = try? JSONDecoder().decode(MatrixJSON.self, from: data)
    else { return nil }
    return json
  }

  public static func mergedContacts(in content: MatrixJSON) -> MergedContactStore.Stored? {
    guard let data = try? JSONEncoder().encode(content),
          let stored = try? JSONDecoder().decode(MergedContactStore.Stored.self, from: data)
    else { return nil }
    return MergedContactStore.sanitized(stored)
  }
}
