import Foundation
import CorrespondanceCore

/// Piloter un groupe depuis le Mac : le nommer, y ajouter quelqu'un, en
/// retirer quelqu'un.
///
/// Chaque geste est masqué là où le pont ne le relaie pas (`NetworkCapabilities`) :
/// renommer un groupe Instagram changerait le nom du portail chez nous et nulle
/// part ailleurs, et les autres membres continueraient de voir l'ancien.
@MainActor
extension InboxStore {
  /// Un correspondant d'un fil, tel que la fiche du groupe le montre.
  struct GroupMember: Identifiable, Hashable {
    let userID: String
    let displayName: String?
    var id: String { userID }
    var name: String { displayName ?? MatrixIdentity.localpart(userID) }
  }

  func presentGroupSheet(_ conversationID: String) {
    guard canManageGroup(conversationID) else { return }
    groupSheetID = conversationID
  }

  func dismissGroupSheet() { groupSheetID = nil }

  /// La fiche n'a de sens que sur un groupe du Relais dont au moins un geste
  /// est porté par le pont.
  func canManageGroup(_ conversationID: String) -> Bool {
    guard let conversation = conversations.first(where: { $0.id == conversationID }),
          conversation.isGroup, conversation.network.livesOnRelay
    else { return false }
    let capabilities = conversation.network.capabilities
    return capabilities.renamesGroup || capabilities.removesMember || capabilities.addsMember
  }

  func members(of conversationID: String) async -> [GroupMember] {
    await matrix.members(conversationID: conversationID)
      .map { GroupMember(userID: $0.userID, displayName: $0.displayName) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  func renameGroup(conversationID: String, name: String) async {
    do {
      try await matrix.renameGroup(conversationID: conversationID, name: name)
      await reloadFromRelay()
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  func removeMember(conversationID: String, userID: String) async {
    do {
      try await matrix.removeMember(conversationID: conversationID, userID: userID)
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  func inviteMember(_ identifier: String, conversationID: String) async {
    do {
      try await matrix.inviteMember(conversationID: conversationID, identifier: identifier)
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  /// Un geste « nouveau groupe » a-t-il un sens ? Seulement si au moins un
  /// pont branché sait vraiment créer un groupe.
  var canCreateGroup: Bool {
    isMatrixConnected && MessageNetwork.allCases.contains {
      $0.capabilities.createsGroup && hasConversations(on: $0)
    }
  }

  /// Crée le groupe, puis l'ouvre. Un échec ne laisse rien derrière lui : le
  /// service jette le salon qui n'est devenu le portail de rien.
  func createGroup(network: MessageNetwork, name: String, identifiers: [String]) async {
    do {
      let conversationID = try await matrix.createGroup(
        network: network, name: name, identifiers: identifiers
      )
      await reloadFromRelay()
      await select(conversationID)
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  /// Ce qu'on tape pour ajouter quelqu'un, réseau par réseau. Vide = le geste
  /// n'est pas offert ici.
  func invitePromptFR(for network: MessageNetwork) -> String {
    switch network {
    case .whatsapp: "Numéro au format international"
    case .instagram: "Pseudo ou identifiant Instagram"
    case .messenger: "Nom ou identifiant Messenger"
    case .twitter: "Pseudo X"
    case .slack: "Nom ou e-mail Slack"
    case .signal: "Identifiant Signal (UUID)"
    default: ""
    }
  }
}
