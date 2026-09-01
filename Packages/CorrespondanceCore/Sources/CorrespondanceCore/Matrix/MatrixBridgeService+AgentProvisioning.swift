import CorrespondanceMatrixClient
import Foundation

/// « Activer cc » : créer le compte du bot sur le Relais et rendre son amorce.
///
/// C'est ce qui remplace le `register_new_matrix_user` en SSH du montage
/// artisanal. Trois précautions, et elles ne sont pas décoratives :
/// vérifier qu'on est bien administrateur **avant** de promettre ; ne jamais
/// déconnecter les sessions existantes (`logout_devices: false`) ; ne pas
/// réinitialiser le mot de passe d'un bot qui tourne déjà ailleurs.
extension MatrixBridgeService {

  /// L'amorce d'un agent : les trois lignes que sa machine doit connaître.
  /// Tout le reste vient de sa room console.
  public struct AgentBootstrap: Sendable, Equatable {
    public var homeserver: URL
    public var user: String
    public var password: String
    public var owner: String

    /// Le `config.json` minimal, tel qu'on le pose sur l'hôte (ou qu'on
    /// l'affiche à coller sur un hôte distant).
    public func configJSON() -> String {
      let escaped = { (text: String) in
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
      }
      return """
        {
          "homeserver": "\(escaped(homeserver.absoluteString))",
          "user": "\(escaped(user))",
          "password": "\(escaped(password))",
          "owners": ["\(escaped(owner))"]
        }
        """
    }
  }

  public enum AgentProvisioningError: LocalizedError {
    case notServerAdmin
    case notConnected

    public var errorDescription: String? {
      switch self {
      case .notServerAdmin:
        "ce compte n'est pas administrateur du Relais — c'est lui qui crée les comptes des agents"
      case .notConnected:
        "pas encore connecté au Relais"
      }
    }
  }

  /// Vérifie le pouvoir avant de promettre quoi que ce soit.
  public func canProvisionAgents() async -> Bool {
    guard isConnected else { return false }
    return await client.isServerAdmin(userID: currentUserID)
  }

  /// Crée (ou retrouve) le compte de l'agent et rend son amorce.
  ///
  /// Si le compte existe déjà et qu'on a son mot de passe au Trousseau, on ne
  /// touche à rien : un agent qui tourne sur le NUC continue de tourner. Sinon
  /// on pose un mot de passe neuf — `logout_devices: false`, donc les sessions
  /// existantes survivent, mais elles ne pourront plus se reconnecter avec
  /// l'ancien secret, et c'est dit dans l'app.
  public func provisionAgent(named agent: String) async throws -> AgentBootstrap {
    guard isConnected else { throw AgentProvisioningError.notConnected }
    guard await client.isServerAdmin(userID: currentUserID) else {
      throw AgentProvisioningError.notServerAdmin
    }
    let userID = MatrixIdentity.agentUserID(named: agent, sameServerAs: currentUserID)
    let existing = await client.userExists(userID)
    let known = AgentSecretStore.password(for: agent)

    let password: String
    if existing, let known {
      password = known
    } else {
      password = AgentSecretStore.generatePassword()
      try await client.provisionUser(
        userID: userID, password: password, displayName: agent, admin: false
      )
      AgentSecretStore.save(password: password, for: agent)
    }
    guard let homeserver = await client.currentCredentials?.homeserver else {
      throw AgentProvisioningError.notConnected
    }
    return AgentBootstrap(
      homeserver: homeserver, user: agent, password: password, owner: currentUserID
    )
  }

  /// Le compte de cet agent existe-t-il déjà, et connaît-on son secret ?
  /// L'écran s'en sert pour dire « déjà créé » plutôt que de proposer une
  /// activation qui changerait un mot de passe pour rien.
  public func agentAccountState(named agent: String) async -> (exists: Bool, secretKnown: Bool) {
    guard isConnected else { return (false, false) }
    let userID = MatrixIdentity.agentUserID(named: agent, sameServerAs: currentUserID)
    return (await client.userExists(userID), AgentSecretStore.password(for: agent) != nil)
  }
}
