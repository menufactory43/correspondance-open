import XCTest
@testable import CorrespondanceMatrixClient

/// Connecter un appareil depuis une session existante, contre un vrai Relais
/// d'essai. Ne tourne que si on le demande :
///
///     CORRESPONDANCE_RELAIS_ESSAI=http://127.0.0.1:18448 \
///     CORRESPONDANCE_RELAIS_ESSAI_COMPTE=moi:mot-de-passe \
///     swift test --filter SessionExistanteTests
final class SessionExistanteTests: XCTestCase {
  private var relais: URL!
  private var utilisateur = ""
  private var motDePasse = ""

  override func setUpWithError() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let adresse = environment["CORRESPONDANCE_RELAIS_ESSAI"], let url = URL(string: adresse),
          let compte = environment["CORRESPONDANCE_RELAIS_ESSAI_COMPTE"]?.split(separator: ":", maxSplits: 1), compte.count == 2
    else { throw XCTSkip("pas de Relais d'essai (CORRESPONDANCE_RELAIS_ESSAI)") }
    relais = url
    utilisateur = String(compte[0])
    motDePasse = String(compte[1])
  }

  func testUnJetonDeLaSessionParenteConnecteUnNouvelAppareil() async throws {
    let parent = MatrixClient()
    let session = try await parent.login(homeserver: relais, user: utilisateur, password: motDePasse)

    let jeton: MatrixClient.JetonDeConnexion
    do {
      jeton = try await parent.demanderJetonDeConnexion()
    } catch MatrixClient.ErreurSessionExistante.motDePasseRequis(let uia) {
      // Continuwuity exige toujours le mot de passe ; un faux est refusé proprement.
      do {
        _ = try await parent.demanderJetonDeConnexion(motDePasse: "faux", sessionUIA: uia)
        XCTFail("un faux mot de passe a été accepté")
      } catch MatrixClient.ErreurSessionExistante.motDePasseRefuse {}
      jeton = try await parent.demanderJetonDeConnexion(motDePasse: motDePasse, sessionUIA: uia)
    }
    XCTAssertFalse(jeton.jeton.isEmpty)

    let enfant = MatrixClient()
    let nouvelle = try await enfant.login(homeserver: relais, loginToken: jeton.jeton)
    XCTAssertEqual(nouvelle.userID, session.userID)
    XCTAssertNotEqual(nouvelle.deviceID, session.deviceID, "le terminal doit être un appareil à part")
    let moi = try await enfant.whoami()
    XCTAssertEqual(moi, session.userID)

    // Le jeton ne sert qu'une fois.
    do {
      _ = try await MatrixClient().login(homeserver: relais, loginToken: jeton.jeton)
      XCTFail("un jeton a servi deux fois")
    } catch MatrixError.http(let status, _, _) {
      XCTAssertEqual(status, 403)
    }
  }
}
