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

  // MARK: - `--agent` et `CORRESPONDANCE_HOME` se multiplient

  /// L'incident de la phase 7a, dans le sens où il ne doit plus arriver.
  /// Un essai se dit avec `CORRESPONDANCE_HOME`, et il survit à `--agent` :
  /// le dossier de la production n'est jamais celui qu'on lit.
  func testUnEssaiSurvitALArgumentAgent() {
    for (agent, attendu) in [
      ("cc", "/Users/moi/.correspondance-agent-unclic"),
      ("hermes", "/Users/moi/.correspondance-hermes-unclic"),
    ] {
      let resolu = AgentHome.resolve(
        arguments: ["correspondance-agent", "run", "--agent", agent],
        environment: ["CORRESPONDANCE_HOME": "unclic"],
        home: home
      )
      XCTAssertEqual(resolu.agent, agent)
      XCTAssertEqual(resolu.directory.path(), attendu)
      XCTAssertNotEqual(
        resolu.directory.path(), "/Users/moi/.correspondance-agent",
        "un essai ne doit jamais tomber sur l'amorce de la production")
    }
  }

  /// La contradiction de la phase 7a : `--agent` **et**
  /// `CORRESPONDANCE_AGENT_HOME` vers ailleurs. La règle ne change pas —
  /// `--agent` gagne — mais elle cesse d'être silencieuse.
  func testLaContradictionDeLaPhase7aSeDit() {
    let alerte = AgentHome.contradiction(
      arguments: ["correspondance-agent", "run", "--agent", "cc"],
      environment: ["CORRESPONDANCE_AGENT_HOME": "/Users/moi/.correspondance-unclic"],
      home: home
    )
    XCTAssertNotNil(alerte, "le cas qui a connecté un cc d'essai au Relais de production")
    XCTAssertTrue(alerte!.contains("CORRESPONDANCE_HOME"), "il faut nommer la variable qui marche")
    XCTAssertTrue(alerte!.contains(".correspondance-agent"), "et le dossier réellement lu")
  }

  /// Elle ne crie pas pour rien : sans `--agent`, sans la variable, ou quand
  /// les deux désignent le même dossier, il n'y a aucune contradiction.
  func testAucuneAlerteQuandIlNYAPasDeContradiction() {
    XCTAssertNil(
      AgentHome.contradiction(
        arguments: ["correspondance-agent", "run"],
        environment: ["CORRESPONDANCE_AGENT_HOME": "/Users/moi/.correspondance-hermes"], home: home),
      "sans --agent, l'environnement gagne et fait foi")
    XCTAssertNil(
      AgentHome.contradiction(
        arguments: ["correspondance-agent", "run", "--agent", "hermes"], environment: [:], home: home),
      "sans la variable, rien à contredire")
    XCTAssertNil(
      AgentHome.contradiction(
        arguments: ["correspondance-agent", "run", "--agent", "hermes"],
        environment: ["CORRESPONDANCE_AGENT_HOME": "/Users/moi/.correspondance-hermes"], home: home),
      "les deux d'accord : personne n'est ignoré")
  }
}
