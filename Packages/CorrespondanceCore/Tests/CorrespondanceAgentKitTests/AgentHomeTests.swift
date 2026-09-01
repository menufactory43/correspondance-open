import XCTest

@testable import CorrespondanceAgentKit

/// Un plist de LaunchAgent est statique : il ne connaît ni `~`, ni les
/// variables d'environnement. Le dossier d'un agent se déduit donc de son nom.
final class AgentHomeTests: XCTestCase {
  let home = URL(fileURLWithPath: "/Users/moi")

  func testLAgentParDefautGardeSonAncienDossier() {
    // Le NUC tourne dessus : introduire `--agent` ne doit pas lui faire perdre
    // son état.
    XCTAssertEqual(AgentHome.directory(agent: "cc", home: home).path(), "/Users/moi/.correspondance-agent")
  }

  func testUnSecondAgentAUnDossierBienASoi() {
    XCTAssertEqual(AgentHome.directory(agent: "hermes", home: home).path(), "/Users/moi/.correspondance-hermes")
  }

  func testUnNomDAgentNeFabriquePasDeChemin() {
    let dossier = AgentHome.directory(agent: "../../etc/passwd", home: home).path()
    XCTAssertFalse(dossier.contains(".."))
    XCTAssertTrue(dossier.hasPrefix("/Users/moi/.correspondance-"), dossier)
  }

  func testLArgumentGagneSurLEnvironnement() {
    // Un plist passe `--agent` ; un environnement hérité ne doit pas le
    // détourner vers le dossier d'un autre agent.
    let resolu = AgentHome.resolve(
      arguments: ["correspondance-agent", "run", "--agent", "hermes"],
      environment: ["CORRESPONDANCE_AGENT_HOME": "/Users/moi/.correspondance-autre"],
      home: home
    )
    XCTAssertEqual(resolu.agent, "hermes")
    XCTAssertEqual(resolu.directory.path(), "/Users/moi/.correspondance-hermes")
  }

  func testLesDeuxEcrituresDeLArgument() {
    XCTAssertEqual(AgentHome.agentName(in: ["run", "--agent", "gem"]), "gem")
    XCTAssertEqual(AgentHome.agentName(in: ["run", "--agent=gem"]), "gem")
    XCTAssertNil(AgentHome.agentName(in: ["run"]))
    XCTAssertNil(AgentHome.agentName(in: ["run", "--agent"]), "un drapeau sans valeur ne nomme personne")
  }

  func testLeMontageHistoriqueDuNUCContinueDeMarcher() {
    let resolu = AgentHome.resolve(
      arguments: ["correspondance-agent", "run"],
      environment: ["CORRESPONDANCE_AGENT_HOME": "/Users/moi/.correspondance-hermes"],
      home: home
    )
    XCTAssertEqual(resolu.agent, "hermes", "le nom se relit du dossier")
    XCTAssertEqual(resolu.directory.path(), "/Users/moi/.correspondance-hermes")
  }

  func testSansRienCEstLAgentParDefaut() {
    let resolu = AgentHome.resolve(arguments: ["correspondance-agent"], environment: [:], home: home)
    XCTAssertEqual(resolu.agent, "cc")
    XCTAssertEqual(resolu.directory.path(), "/Users/moi/.correspondance-agent")
  }
}
