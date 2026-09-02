import XCTest
@testable import CorrespondanceCore

#if os(macOS)
/// La preuve d'intégration de Tailcat : **le code d'appairage d'un vrai Relais
/// entre, `TailcatProxy` ouvre le chemin, `/versions` puis `/login` passent par
/// lui, et on coupe.**
///
/// Elle ne tourne pas toute seule — un test qui exige une machine distante et
/// un jeton de quinze minutes ne peut pas être dans la suite ordinaire, et le
/// faire échouer par défaut apprendrait à ignorer le rouge. Elle se déclenche
/// par l'environnement :
///
/// ```bash
/// CORRESPONDANCE_PREUVE_TAILCAT='correspondance://relais/…' \
/// CORRESPONDANCE_TAILCAT=/tmp/dd-unclic/Build/Products/Debug/Correspondance.app/Contents/Helpers/tailcat \
///   swift test --scratch-path /tmp/build-unclic-sanscrypto \
///   --filter PreuveTailcatTests
/// ```
///
/// Ce qu'elle prouve, et que le `curl` de l'installeur ne prouve pas : que
/// c'est **le code de l'app** — le processus enfant, la lecture du port dans sa
/// sortie, le dictionnaire SOCKS de CFNetwork — qui joint le Relais, et non un
/// outil en ligne de commande à côté.
final class PreuveTailcatTests: XCTestCase {

  @MainActor
  func testUnCodeDAppairageSuffitAJoindreLeRelais() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let brut = env["CORRESPONDANCE_PREUVE_TAILCAT"], !brut.isEmpty else {
      throw XCTSkip("CORRESPONDANCE_PREUVE_TAILCAT absent — preuve non demandée")
    }
    let code = try XCTUnwrap(RelayPairingCode(encoded: brut), "code d'appairage illisible")
    XCTAssertFalse(code.isExpired(), "le code a expiré — réémets-en un sur le Relais")
    let jeton = try XCTUnwrap(code.tailcat, "ce code ne porte pas de jeton Tailcat")
    XCTAssertEqual(code.chemin, .tailcat)

    let mandataire = TailcatProxy()
    defer { mandataire.arreter() }
    let port = try await mandataire.demarrer(jeton: jeton, delai: 30)
    XCTAssertTrue(mandataire.estActif)
    print("→ mandataire SOCKS sur 127.0.0.1:\(port)")

    // Le nom magique, jamais une IP : le mandataire de tailcat comprend une IP
    // littérale comme « sors par ce serveur vers cette adresse », c'est-à-dire
    // un nœud de sortie, que notre Relais ne sert pas.
    let base = "http://server.tailcat:\(code.homeserver.port ?? 8010)"
    let session = URLSession(configuration: MandataireSOCKS.configuration(port: port))
    defer { session.invalidateAndCancel() }

    // 1. /versions — le Relais est joignable.
    let (versions, reponse) = try await session.data(
      from: try XCTUnwrap(URL(string: base + "/_matrix/client/versions")))
    XCTAssertEqual((reponse as? HTTPURLResponse)?.statusCode, 200)
    let listees = try XCTUnwrap(
      (try JSONSerialization.jsonObject(with: versions) as? [String: Any])?["versions"] as? [String])
    XCTAssertFalse(listees.isEmpty)
    print("→ /versions par le mandataire : \(listees.count) versions, jusqu'à \(listees.last ?? "?")")

    // 2. /login — et c'est le point : le mot de passe part PAR le mandataire,
    // pas à côté. Posé après la connexion, il serait déjà parti par le chemin
    // qu'on voulait éviter.
    var requete = URLRequest(url: try XCTUnwrap(URL(string: base + "/_matrix/client/v3/login")))
    requete.httpMethod = "POST"
    requete.setValue("application/json", forHTTPHeaderField: "Content-Type")
    requete.httpBody = try JSONSerialization.data(withJSONObject: [
      "type": "m.login.password",
      "identifier": ["type": "m.id.user", "user": code.user],
      "password": code.password,
      "initial_device_display_name": "preuve tailcat",
    ])
    let (corps, reponseLogin) = try await session.data(for: requete)
    XCTAssertEqual((reponseLogin as? HTTPURLResponse)?.statusCode, 200,
                   String(decoding: corps, as: UTF8.self))
    let session_ = try XCTUnwrap(try JSONSerialization.jsonObject(with: corps) as? [String: Any])
    XCTAssertEqual(session_["user_id"] as? String, code.userID)
    print("→ /login par le mandataire : connecté comme \(session_["user_id"] as? String ?? "?")")

    // 3. On referme la session ouverte par la preuve : elle a servi, elle n'a
    // pas à rester dans la liste des appareils du compte.
    if let jetonSession = session_["access_token"] as? String {
      var sortie = URLRequest(url: try XCTUnwrap(URL(string: base + "/_matrix/client/v3/logout")))
      sortie.httpMethod = "POST"
      sortie.setValue("Bearer \(jetonSession)", forHTTPHeaderField: "Authorization")
      _ = try? await session.data(for: sortie)
      print("→ session de preuve refermée")
    }

    mandataire.arreter()
    XCTAssertFalse(mandataire.estActif)
    XCTAssertNil(mandataire.port)
    print("→ mandataire arrêté, aucun processus laissé")
  }
}
#endif
