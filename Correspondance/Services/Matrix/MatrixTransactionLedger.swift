import Foundation

/// Registre des `txnId` Matrix. Pur et déterministe : c'est lui qui garantit
/// qu'un renvoi du même message optimiste ne crée pas un second event côté serveur.
///
/// Deux rôles complémentaires :
/// - dériver un `txnId` **stable** depuis l'identifiant local d'un message optimiste ;
/// - retenir les `txnId` déjà envoyés avec succès, pour court-circuiter un doublon.
struct MatrixTransactionLedger: Sendable {
  /// `txnId` attribué à un identifiant local (message optimiste).
  private var idsByLocalID: [String: String] = [:]
  /// `txnId` déjà consommés par un envoi réussi.
  private var used: Set<String> = []

  init() {}

  /// `txnId` stable pour un message optimiste : deux appels rendent le même identifiant.
  mutating func transactionID(forLocalID localID: String) -> String {
    if let existing = idsByLocalID[localID] { return existing }
    let value = "corr-\(localID)"
    idsByLocalID[localID] = value
    return value
  }

  /// Dérivé d'un `txnId` de base pour la n-ième pièce jointe du même message.
  func attachmentTransactionID(base: String, index: Int) -> String {
    "\(base)-att\(index)"
  }

  func isUsed(_ transactionID: String) -> Bool {
    used.contains(transactionID)
  }

  /// À appeler **après** un envoi réussi seulement : un échec réseau doit rester rejouable.
  mutating func markUsed(_ transactionID: String) {
    used.insert(transactionID)
  }

  mutating func reset() {
    idsByLocalID.removeAll()
    used.removeAll()
  }
}
