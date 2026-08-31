import Foundation

/// Une écriture d'état vers le Relais, en attente de départ.
///
/// Le geste de l'utilisateur est immédiat côté appareil ; l'aller-retour réseau
/// ne l'est pas. Chaque geste dépose donc une écriture ici, et la file la garde
/// jusqu'à ce que le Relais l'ait acceptée. Tant qu'elle y est, elle **prime**
/// sur ce que le `/sync` raconte : sinon archiver hors ligne se déferait tout
/// seul à la reconnexion.
public enum RelayWrite: Codable, Sendable, Equatable {
  case archived(roomID: String, value: Bool)
  case pinned(roomID: String, value: Bool)
  case muted(roomID: String, value: Bool)
  case draft(roomID: String, text: String)
  case hidden(roomID: String, eventIDs: Set<String>)
  /// Un rappel posé (`value`) ou levé (`nil`).
  case reminder(roomID: String, value: ConversationReminder?)
  /// Une demande acceptée, refusée, ou remise en attente (`nil`).
  case request(roomID: String, value: ConversationRequest.Decision?)
  case mergedContacts(MergedContactStore.Stored)

  /// Le salon visé, `nil` pour une écriture globale (les fusions).
  public var roomID: String? {
    switch self {
    case .archived(let roomID, _), .pinned(let roomID, _), .muted(let roomID, _),
         .draft(let roomID, _), .hidden(let roomID, _), .reminder(let roomID, _), .request(let roomID, _):
      roomID
    case .mergedContacts:
      nil
    }
  }

  /// Deux écritures de même clé disent la même chose autrement : seule la
  /// dernière part. Archiver puis désarchiver ne fait pas deux requêtes.
  public var coalescingKey: String {
    switch self {
    case .archived(let roomID, _): "archived:\(roomID)"
    case .pinned(let roomID, _): "pinned:\(roomID)"
    case .muted(let roomID, _): "muted:\(roomID)"
    case .draft(let roomID, _): "draft:\(roomID)"
    case .hidden(let roomID, _): "hidden:\(roomID)"
    case .reminder(let roomID, _): "reminder:\(roomID)"
    case .request(let roomID, _): "request:\(roomID)"
    case .mergedContacts: "merged"
    }
  }

  /// Pose cette écriture sur un instantané — c'est ainsi qu'une écriture non
  /// partie l'emporte sur ce que le Relais raconte encore.
  public func apply(to snapshot: inout ConversationStateSnapshot) {
    switch self {
    case .archived(let roomID, let value):
      if value { snapshot.archived.insert(roomID) } else { snapshot.archived.remove(roomID) }
    case .pinned(let roomID, let value):
      if value { snapshot.pinned.insert(roomID) } else { snapshot.pinned.remove(roomID) }
    case .muted(let roomID, let value):
      if value { snapshot.muted.insert(roomID) } else { snapshot.muted.remove(roomID) }
    case .draft(let roomID, let text):
      if text.isEmpty { snapshot.drafts.removeValue(forKey: roomID) } else { snapshot.drafts[roomID] = text }
    case .hidden(let roomID, let eventIDs):
      if eventIDs.isEmpty { snapshot.hidden.removeValue(forKey: roomID) } else { snapshot.hidden[roomID] = eventIDs }
    case .reminder(let roomID, let value):
      if let value { snapshot.reminders[roomID] = value } else { snapshot.reminders.removeValue(forKey: roomID) }
    case .request(let roomID, let value):
      if let value { snapshot.requests[roomID] = value } else { snapshot.requests.removeValue(forKey: roomID) }
    case .mergedContacts(let stored):
      snapshot.mergedContacts = stored
    }
  }
}

/// Les écritures qui n'ont pas encore atteint le Relais, dans l'ordre où elles
/// sont nées. Type pur : aucune requête, aucun `UserDefaults` caché — l'appelant
/// la persiste (`data`) et la rejoue quand il peut.
public struct RelayWriteQueue: Codable, Sendable, Equatable {
  public private(set) var writes: [RelayWrite]

  public init(writes: [RelayWrite] = []) {
    self.writes = writes
  }

  public var isEmpty: Bool { writes.isEmpty }
  public var count: Int { writes.count }

  /// Dépose une écriture. Une écriture de même clé encore en attente est
  /// remplacée — et repart en fin de file, l'ordre étant celui des gestes.
  public mutating func enqueue(_ write: RelayWrite) {
    writes.removeAll { $0.coalescingKey == write.coalescingKey }
    writes.append(write)
  }

  /// Le Relais a accepté cette écriture : elle sort de la file — **sauf** si un
  /// nouveau geste l'a remplacée entre-temps, auquel cas c'est le nouveau qui
  /// attend son tour.
  public mutating func complete(_ write: RelayWrite) {
    writes.removeAll { $0 == write }
  }

  /// L'état tel qu'il faut le montrer : celui du Relais, corrigé par ce qui
  /// n'est pas encore parti.
  public func applied(to snapshot: ConversationStateSnapshot) -> ConversationStateSnapshot {
    var result = snapshot
    for write in writes { write.apply(to: &result) }
    return result
  }

  // MARK: - Persistance

  public var data: Data? {
    try? JSONEncoder().encode(self)
  }

  public init(data: Data?) {
    guard let data, let decoded = try? JSONDecoder().decode(RelayWriteQueue.self, from: data) else {
      self.init()
      return
    }
    self = decoded
  }

  public static func load(from defaults: UserDefaults, key: String) -> RelayWriteQueue {
    RelayWriteQueue(data: defaults.data(forKey: key))
  }

  public func save(to defaults: UserDefaults, key: String) {
    if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
  }
}
