import XCTest
@testable import CorrespondanceAgentKit

/// Hermes sur le contrat `AgentBackend` : la forme `chat -Q` éprouvée au tir
/// (jamais `-z`, qui rend chaque tour amnésique), la session lue dans la
/// plomberie, et le choix du moteur dans la config.
final class HermesBackendTests: XCTestCase {

  // MARK: - Arguments

  func testUnTourPasseParChatJamaisParZ() {
    let args = HermesBackend.arguments(settings: .init(), sessionID: nil, prompt: "résume ce fil")
    XCTAssertEqual(args, ["chat", "-Q", "--oneshot", "-q", "résume ce fil"])
    XCTAssertFalse(args.contains("-z"))
  }

  func testUneSessionSeReprend() {
    var settings = AgentConfig.HermesSettings()
    settings.model = "Hermes-4-405B"
    let args = HermesBackend.arguments(settings: settings, sessionID: "abc-123", prompt: "et ensuite ?")
    XCTAssertEqual(args, ["chat", "-Q", "--oneshot", "-q", "et ensuite ?", "-r", "abc-123", "-m", "Hermes-4-405B"])
  }

  // MARK: - Plomberie de -Q

  func testLaSessionSeLitDansLaPlomberie() {
    XCTAssertEqual(HermesBackend.sessionID(in: "↻ Resumed session perchoir\nsession_id: s-42\n"), "s-42")
    XCTAssertEqual(HermesBackend.sessionID(in: "  session_id:   s-43  "), "s-43")
    XCTAssertNil(HermesBackend.sessionID(in: "rien à voir"))
    XCTAssertNil(HermesBackend.sessionID(in: "session_id:"))
  }

  func testLaReponseEcarteLaPlomberieOuQuElleSoit() {
    // Flux fusionnés (le cas vécu sur Perchoir) : la ligne est dans stdout.
    let brute = "session_id: s-42\nJe passe vers 18 h.\nÇa te va ?\n"
    XCTAssertEqual(HermesBackend.reply(from: brute), "Je passe vers 18 h.\nÇa te va ?")
  }

  // MARK: - Config

  func testLeMoteurParDefautEstClaude() throws {
    let config = try JSONDecoder().decode(
      AgentConfig.self,
      from: Data(#"{"homeserver":"http://x:8008","user":"cc","password":"p","owners":["@g:x"]}"#.utf8))
    XCTAssertEqual(config.backend, .claude)
  }

  func testLaConfigSaitDesignerHermes() throws {
    let config = try JSONDecoder().decode(
      AgentConfig.self,
      from: Data("""
      {"homeserver":"http://x:8008","user":"hermes","password":"p","owners":["@g:x"],
       "backend":"hermes","hermes":{"binary":"/opt/hermes/bin/hermes","timeoutSeconds":120}}
      """.utf8))
    XCTAssertEqual(config.backend, .hermes)
    XCTAssertEqual(config.hermes.binary, "/opt/hermes/bin/hermes")
    XCTAssertEqual(config.hermes.timeoutSeconds, 120)
    XCTAssertNil(config.hermes.model)
  }
}
