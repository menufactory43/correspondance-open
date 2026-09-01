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
    config.peers = ["@hermes:correspondance.local"]
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
    config.peers = ["@hermes:s"]
    config.rooms["!r:s"] = .init(cwd: "/tmp/x", mode: .direct)

    guard let object = config.content().objectValue else { return XCTFail("un event est un objet") }
    XCTAssertEqual(
      Set(object.keys),
      ["version", "agent", "owners", "trigger", "hourlyCap", "defaultMode", "backend",
       "toolPreset", "model", "systemPrompt", "acpCommand", "peers", "rooms"]
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

  // MARK: - La voix par conversation

  func testSansReglageDeRoomLaVoixEstCelleParDefaut() {
    var config = AgentConsoleConfig(agent: "cc")
    config.defaultMode = .direct
    XCTAssertEqual(config.voice(in: "!une:local"), .direct)
  }

  func testLaVoixDUneRoomPrimeSurLeDefaut() {
    var config = AgentConsoleConfig(agent: "cc")
    config.defaultMode = .direct
    let reglee = config.settingVoice(.draft, in: "!une:local")
    XCTAssertEqual(reglee.voice(in: "!une:local"), .draft)
    XCTAssertEqual(reglee.voice(in: "!autre:local"), .direct, "les autres rooms gardent le défaut")
  }

  func testPoserLaVoixNeTouchePasAuDepotLie() {
    var config = AgentConsoleConfig(agent: "cc")
    config.rooms["!une:local"] = .init(cwd: "/Users/moi/projets/app", mode: nil)
    let reglee = config.settingVoice(.direct, in: "!une:local")
    XCTAssertEqual(reglee.rooms["!une:local"]?.cwd, "/Users/moi/projets/app")
    XCTAssertEqual(reglee.rooms["!une:local"]?.mode, .direct)
  }

  func testLaVoixSurvitALAllerRetourJSON() {
    let config = AgentConsoleConfig(agent: "cc").settingVoice(.direct, in: "!une:local")
    let relue = AgentConsoleConfig(content: config.content())
    XCTAssertEqual(relue?.voice(in: "!une:local"), .direct)
  }
}
