import Foundation
import CorrespondanceCore

/// Créer un groupe depuis l'iPhone — le même chemin que le Mac : un salon
/// nommé, le bot et les fantômes invités, `create-group` au pont.
@MainActor
extension RelayStore {
  /// Un geste « nouveau groupe » a-t-il un sens ici ? Seulement si au moins
  /// un pont branché sait vraiment créer un groupe. En démonstration, aucun.
  var canCreateGroup: Bool {
    guard !isDemo else { return false }
    return MessageNetwork.allCases.contains { network in
      network.capabilities.createsGroup
        && conversations.contains { $0.network == network }
    }
  }

  /// Le pont crée le groupe ; le salon, lui, arrive par le `/sync` qui suit —
  /// comme pour un fil en tête-à-tête (`startBridgeChat`).
  func createGroup(network: MessageNetwork, name: String, identifiers: [String]) async throws {
    guard !isDemo else { return }
    _ = try await matrix.createGroup(network: network, name: name, identifiers: identifiers)
  }
}
