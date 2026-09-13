import CorrespondanceCore
import CorrespondanceMatrixClient
import Foundation

/// Se connecter **à partir de la session d'une autre app de cette machine** —
/// le Mac, ou le serveur Linux — sans code d'appairage ni mot de passe.
///
/// La session de l'app n'est jamais reprise : elle sert une seule fois, à
/// demander au Relais un jeton de connexion pour un appareil neuf. Ce terminal
/// a ensuite sa propre session, sa propre base, ses propres clés ; l'app et lui
/// tournent en même temps sans se marcher dessus.
@MainActor
extension RelayStore {
  package enum IssueSessionExistante: Equatable {
    case connecte
    /// Le Relais veut le mot de passe du compte, une fois.
    case motDePasseRequis(sessionUIA: String?)
    case echec(String)
  }

  /// La session de l'app installée sur cette machine, si elle en a une : celle
  /// du dossier de données par défaut, quel que soit le dossier de ce processus.
  package static func sessionDeLApp() -> MatrixCredentials? {
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "CORRESPONDANCE_HOME")
    return MatrixCredentialStore.load(environment: environment)
  }

  package func connecterDepuisSession(
    _ parent: MatrixCredentials,
    motDePasse: String? = nil,
    sessionUIA: String? = nil
  ) async -> IssueSessionExistante {
    connectionError = nil
    if parent.homeserver.host == "server.tailcat" {
      return .echec("La session de l’app passe par Tailcat : utilise un code d’appairage pour ce terminal.")
    }
    session = .connecting
    let client = MatrixClient(credentials: parent)
    do {
      let jeton = try await client.demanderJetonDeConnexion(motDePasse: motDePasse, sessionUIA: sessionUIA)
      try await matrix.connect(homeserver: parent.homeserver, loginToken: jeton.jeton)
      UserDefaults.standard.set(parent.homeserver.absoluteString, forKey: Self.lastHomeserverKey)
      session = .connected
      await reloadRelayState()
      startSyncLoop()
      return .connecte
    } catch let erreur as MatrixClient.ErreurSessionExistante {
      session = .disconnected
      switch erreur {
      case .motDePasseRequis(let uia):
        return .motDePasseRequis(sessionUIA: uia)
      case .motDePasseRefuse:
        return .echec("Mot de passe refusé par le Relais.")
      case .nonProposee:
        return .echec("Le Relais ne permet pas encore de se connecter depuis une session existante (login_via_existing_session).")
      }
    } catch MatrixError.http(let status, _, _) where status == 401 {
      session = .disconnected
      return .echec("La session de l’app n’est plus valable sur le Relais — reconnecte l’app d’abord.")
    } catch {
      session = .disconnected
      return .echec(Self.readable(error))
    }
  }
}
