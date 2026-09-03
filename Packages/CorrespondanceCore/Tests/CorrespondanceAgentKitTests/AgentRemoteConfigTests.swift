import CorrespondanceMatrixClient
import XCTest

@testable import CorrespondanceAgentKit

/// La config vient du Relais, l'amorce reste sur l'hôte. Ce qui est éprouvé
/// ici : le Relais corrige champ par champ, il ne remplace jamais l'identité,
/// et une config d'hier continue de tourner.
final class AgentRemoteConfigTests: XCTestCase {
  var fichier: AgentConfig {
    var config = AgentConfig(
      homeserver: URL(string: "http://100.64.0.1:8008")!, user: "cc", password: "secret",
      owners: ["@meffysto:correspondance.local"]
    )
    config.trigger = "@cc"
    config.hourlyCap = 30
    config.rooms["!ancienne:local"] = AgentConfig.RoomBinding(cwd: "/Users/moi/repo", mode: .direct)
    return config
  }

  func testUnEventVideNEfacePasLaConfig() {
    let remote = AgentRemoteConfig(agent: "cc")
    let apres = fichier.applying(remote)
    XCTAssertEqual(apres, fichier, "ce que le Relais ne dit pas, le fichier le dit encore")
  }

  func testLeRelaisCorrigeChampParChamp() {
    var remote = AgentRemoteConfig(agent: "cc")
    remote.hourlyCap = 100
    remote.toolPreset = "lire"
    let apres = fichier.applying(remote)
    XCTAssertEqual(apres.hourlyCap, 100)
    XCTAssertEqual(apres.claude.allowedTools, AgentConfig.Presets.lire)
    XCTAssertEqual(apres.trigger, "@cc", "le reste ne bouge pas")
    XCTAssertEqual(apres.rooms, fichier.rooms)
  }

  /// Les pairs viennent du Relais : c'est l'app qui les écrit quand plusieurs
  /// agents partagent un salon, et c'est ce qui arme la mention obligatoire et
  /// la non-relance mutuelle. Sans ce chemin, deux agents dans une même room se
  /// répondraient l'un l'autre jusqu'au plafond horaire.
  func testLesPairsArriventParLaConsole() {
    var remote = AgentRemoteConfig(agent: "cc")
    remote.peers = ["@hermes:correspondance.local"]
    XCTAssertEqual(fichier.applying(remote).peers, ["@hermes:correspondance.local"])
  }

  /// Et ils survivent à l'aller-retour par l'event : une clé lue d'un côté et
  /// écrite de l'autre est le genre de divergence qu'on ne voit qu'en vrai.
  func testLesPairsSurviventALEvent() {
    var remote = AgentRemoteConfig(agent: "cc")
    remote.peers = ["@hermes:s", "@codex:s"]
    XCTAssertEqual(AgentRemoteConfig(content: remote.content())?.peers, ["@hermes:s", "@codex:s"])
  }

  /// L'amorce est l'ancre : rien d'écrit dans une room ne fait pointer l'agent
  /// ailleurs ni ne change son identité.
  func testLAmorceNeBougeJamais() {
    var remote = AgentRemoteConfig(agent: "cc")
    remote.owners = ["@quelquun:ailleurs.tld"]
    let apres = fichier.applying(remote)
    XCTAssertEqual(apres.homeserver, fichier.homeserver)
    XCTAssertEqual(apres.user, "cc")
    XCTAssertEqual(apres.password, "secret")
    XCTAssertEqual(apres.owners, ["@quelquun:ailleurs.tld"], "qui déclenche, ça oui, ça se règle depuis l'app")
  }

  func testUneConfigTropRecenteEstIgnoreeEnBloc() {
    var remote = AgentRemoteConfig(agent: "cc", version: AgentRemoteConfig.currentVersion + 1)
    remote.hourlyCap = 999
    XCTAssertFalse(remote.isReadable)
    XCTAssertEqual(fichier.applying(remote), fichier, "mieux vaut la config d'hier qu'une moitié de celle de demain")
  }

  func testLAllerRetourParLEventConserveTout() throws {
    var remote = fichier.remoteConfig()
    remote.model = "claude-sonnet-5"
    let relu = AgentRemoteConfig(content: remote.content())
    XCTAssertEqual(relu, remote)
  }

  func testUnEventSansAgentNEstPasUneConfig() {
    let content = MatrixJSON.object(["version": .number(1), "hourlyCap": .number(10)])
    XCTAssertNil(AgentRemoteConfig(content: content), "une config sans nom d'agent ne configure personne")
  }

  func testLesLiaisonsDeRoomsFontLAllerRetour() {
    var remote = AgentRemoteConfig(agent: "cc")
    remote.rooms = [
      "!une:local": AgentConfig.RoomBinding(cwd: "/Users/moi/projet", mode: .direct),
      "!deux:local": AgentConfig.RoomBinding(cwd: nil, mode: .draft),
    ]
    let relu = AgentRemoteConfig(content: remote.content())
    XCTAssertEqual(relu?.rooms?["!une:local"]?.cwd, "/Users/moi/projet")
    XCTAssertEqual(relu?.rooms?["!deux:local"]?.mode, .draft)
    XCTAssertNil(relu?.rooms?["!deux:local"]?.cwd)
  }

  func testLePalierSurMesureNeCasseRien() {
    var config = fichier
    config.claude.allowedTools = ["Read", "Bash(git *)"]
    let remote = config.remoteConfig()
    XCTAssertEqual(remote.toolPreset, "sur mesure")
    // « sur mesure » ne se relit pas comme un palier : la liste du fichier reste.
    XCTAssertEqual(config.applying(remote).claude.allowedTools, ["Read", "Bash(git *)"])
  }

  func testLeMoteurSeChangeDepuisLApp() {
    var remote = AgentRemoteConfig(agent: "cc")
    remote.backend = .acp
    remote.acpCommand = "goose"
    let apres = fichier.applying(remote)
    XCTAssertEqual(apres.backend, .acp)
    XCTAssertEqual(apres.acp.command, "goose")
    // `goose` seul ouvre son interface : l'agent sait qu'il faut `goose acp`.
    XCTAssertEqual(apres.acp.arguments, ["acp"])
  }

  /// Vu en vrai : `grok` seul attend un clavier, `grok agent stdio` parle ACP.
  /// Ce que l'app dit gagne ; sinon ce que l'agent sait de la commande.
  func testLesArgumentsDeLAdaptateurSuiventLaCommande() {
    var remote = AgentRemoteConfig(agent: "grok")
    remote.backend = .acp
    remote.acpCommand = "grok"
    XCTAssertEqual(fichier.applying(remote).acp.arguments, ["agent", "stdio"])

    remote.acpArguments = ["agent", "stdio", "--verbose"]
    XCTAssertEqual(fichier.applying(remote).acp.arguments, ["agent", "stdio", "--verbose"])

    // Un adaptateur dédié n'a pas d'arguments, et un ancien `goose acp` du
    // fichier ne doit pas coller à la nouvelle commande.
    var config = fichier
    config.acp.arguments = ["acp"]
    remote.acpCommand = "codex-acp"
    remote.acpArguments = nil
    XCTAssertEqual(config.applying(remote).acp.arguments, [])
  }

  func testLesArgumentsFontLAllerRetourParLEvent() {
    var config = fichier
    config.backend = .acp
    config.acp.command = "grok"
    config.acp.arguments = ["agent", "stdio"]
    let remote = config.remoteConfig()
    XCTAssertEqual(remote.acpArguments, ["agent", "stdio"])
    let relu = AgentRemoteConfig(content: remote.content())
    XCTAssertEqual(relu?.acpArguments, ["agent", "stdio"])
  }

  /// Le contexte du fil vient du Relais, et **« 0 coupe »** : un zéro explicite
  /// est un choix — l'agent ne voit plus que ce qu'on lui adresse — pas une
  /// absence que le fichier devrait combler.
  func testLeContexteDuFilPasseEtZeroCoupe() {
    XCTAssertEqual(fichier.context, 50, "le défaut")
    var remote = AgentRemoteConfig(agent: "cc")
    XCTAssertEqual(fichier.applying(remote).context, 50, "rien dit : rien ne bouge")
    remote.context = 0
    XCTAssertEqual(fichier.applying(remote).context, 0, "0 coupe")
    remote.context = 20
    XCTAssertEqual(fichier.applying(remote).context, 20)
    remote.context = -3
    XCTAssertEqual(fichier.applying(remote).context, 50, "un nombre qui ne veut rien dire est ignoré")

    // Et par salon, à travers l'event.
    remote.rooms = ["!r:s": AgentConfig.RoomBinding(context: 0)]
    let relu = AgentRemoteConfig(content: remote.content())
    XCTAssertEqual(relu?.context, -3)
    XCTAssertEqual(relu?.rooms?["!r:s"]?.context, 0, "le 0 d'un salon survit à l'aller-retour")
  }
}
