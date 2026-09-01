import CorrespondanceMatrixClient
import XCTest

@testable import CorrespondanceCore

/// La config qu'écrit l'app doit être exactement celle que lit l'agent. Les
/// deux types sont séparés (l'app tourne sur iOS, où `Process` n'existe pas),
/// mais ils partagent les clés d'`AgentWire` — c'est ce que ces tests tiennent.
final class AgentConsoleConfigTests: XCTestCase {

  func testLAllerRetourParLEventConserveTout() {
    var config = AgentConsoleConfig(agent: "cc")
    config.owners = ["@meffysto:correspondance.local"]
    config.trigger = "@cc"
    config.hourlyCap = 60
    config.defaultMode = .direct
    config.backend = "acp"
    config.toolPreset = "exécuter"
    config.acpCommand = "claude-code-acp"
    config.rooms["!une:local"] = .init(cwd: "/Users/moi/projet", mode: .draft)

    let relu = AgentConsoleConfig(content: config.content())
    XCTAssertEqual(relu, config)
  }

  func testUnEventSansAgentNeConfigurePersonne() {
    let content = MatrixJSON.object([AgentWire.ConfigKey.version: .number(1)])
    XCTAssertNil(AgentConsoleConfig(content: content))
  }

  /// Le contrat avec l'agent : ces noms-là, et pas d'autres. Si quelqu'un
  /// renomme un champ d'un seul côté, ce test tombe avant l'utilisateur.
  func testLesClesDuFormatSontCellesQueLAgentLit() {
    var config = AgentConsoleConfig(agent: "cc")
    config.owners = ["@g:s"]
    config.trigger = "@cc"
    config.hourlyCap = 30
    config.defaultMode = .draft
    config.backend = "claude"
    config.toolPreset = "lire"
    config.model = "claude-sonnet-5"
    config.systemPrompt = "Tu es cc."
    config.acpCommand = "goose"
    config.rooms["!r:s"] = .init(cwd: "/tmp/x", mode: .direct)

    guard let object = config.content().objectValue else { return XCTFail("un event est un objet") }
    XCTAssertEqual(
      Set(object.keys),
      ["version", "agent", "owners", "trigger", "hourlyCap", "defaultMode", "backend",
       "toolPreset", "model", "systemPrompt", "acpCommand", "rooms"]
    )
    XCTAssertEqual(object["version"]?.intValue, AgentWire.configVersion)
    // Les liaisons de rooms aussi : `cwd` et `mode`, pas autre chose.
    XCTAssertEqual(Set(object["rooms"]?["!r:s"]?.objectValue?.keys ?? [:].keys), ["cwd", "mode"])
  }

  func testUnePaletteDOutilsSeLitEtSAffiche() {
    XCTAssertEqual(AgentConsoleConfig.ToolPreset(rawValue: "exécuter"), .executer)
    XCTAssertEqual(AgentConsoleConfig.ToolPreset(rawValue: "écrire"), .ecrire)
    XCTAssertEqual(AgentConsoleConfig.ToolPreset(rawValue: "sur mesure"), nil)
    XCTAssertFalse(AgentConsoleConfig.ToolPreset.executer.subtitleFR.isEmpty)
  }

  func testLeMXIDDUnAgentSuitLeServeurDuProprietaire() {
    XCTAssertEqual(
      MatrixIdentity.agentUserID(named: "hermes", sameServerAs: "@meffysto:correspondance.local"),
      "@hermes:correspondance.local"
    )
    XCTAssertEqual(
      MatrixIdentity.agentUserID(named: "@ailleurs:autre.tld", sameServerAs: "@g:correspondance.local"),
      "@ailleurs:autre.tld"
    )
  }
}
