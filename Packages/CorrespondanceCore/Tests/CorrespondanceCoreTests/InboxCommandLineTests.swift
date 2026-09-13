import XCTest

@testable import CorrespondanceCore

/// La ligne de commande traduit des mots en appel d'outil — le même que le
/// serveur MCP recevrait. On prouve la traduction, et que l'aiguillage commun
/// (`MCPInboxTools.call`) fait ce que le nom dit, contre le faux Relais.
final class InboxCommandLineTests: XCTestCase {

  // MARK: - La traduction

  func appel(_ mots: String, stdin: String? = nil) -> (tool: String, arguments: [String: Any])? {
    let (invocation, _) = InboxCommandLine.parse(mots.split(separator: " ").map(String.init), stdin: { stdin })
    guard case .call(let tool, let arguments) = invocation else { return nil }
    return (tool, arguments)
  }

  func testLaFileEstListQueue() {
    XCTAssertEqual(appel("file")?.tool, "list_queue")
    XCTAssertEqual(appel("queue")?.tool, "list_queue")
  }

  func testLireAvecUneLimite() {
    let a = appel("lire !camille:local --limite 5")
    XCTAssertEqual(a?.tool, "read_conversation")
    XCTAssertEqual(a?.arguments["conversation"] as? String, "!camille:local")
    XCTAssertEqual(a?.arguments["limit"] as? Int, 5)
  }

  func testLireSansConversationEstUneErreurDUsage() {
    let (invocation, _) = InboxCommandLine.parse(["lire", "camille"])
    guard case .usage(let message) = invocation else { return XCTFail("attendu : usage") }
    XCTAssertTrue(message.contains("conversation"), message)
  }

  func testChercherRecolleLesMots() {
    XCTAssertEqual(appel("chercher relevé de compte")?.arguments["query"] as? String, "relevé de compte")
  }

  func testArchiverEtAnnuler() {
    XCTAssertEqual(appel("archiver !x:local")?.arguments["on"] as? Bool, true)
    XCTAssertEqual(appel("archiver !x:local --annuler")?.arguments["on"] as? Bool, false)
  }

  func testRappelDansOuA() {
    XCTAssertEqual(appel("rappel !x:local --dans 30")?.arguments["in_minutes"] as? Int, 30)
    XCTAssertEqual(appel("rappel !x:local --a 2030-01-01T09:00:00Z")?.arguments["at"] as? String, "2030-01-01T09:00:00Z")
    let (sans, _) = InboxCommandLine.parse(["rappel", "!x:local"])
    guard case .usage = sans else { return XCTFail("un rappel sans heure est une erreur d'usage") }
  }

  func testBrouillonPrendLeTexteOuLEntreeStandard() {
    XCTAssertEqual(appel("brouillon !x:local oui je viens")?.arguments["text"] as? String, "oui je viens")
    XCTAssertEqual(appel("brouillon !x:local", stdin: "  lu sur stdin\n")?.arguments["text"] as? String, "lu sur stdin")
    let (vide, _) = InboxCommandLine.parse(["brouillon", "!x:local"], stdin: { "" })
    guard case .usage = vide else { return XCTFail("sans texte nulle part, c'est une erreur d'usage") }
  }

  func testEnvoyerEstSendMessage() {
    let a = appel("envoyer !x:local à tout à l'heure")
    XCTAssertEqual(a?.tool, "send_message")
    XCTAssertEqual(a?.arguments["text"] as? String, "à tout à l'heure")
  }

  func testOutilGeneriqueAvecDuJSON() {
    let (invocation, _) = InboxCommandLine.parse(["outil", "read_conversation", #"{"conversation":"!x:local","limit":3}"#])
    guard case .call(let tool, let arguments) = invocation else { return XCTFail("attendu : call") }
    XCTAssertEqual(tool, "read_conversation")
    XCTAssertEqual(arguments["limit"] as? Int, 3)
    let (casse, _) = InboxCommandLine.parse(["outil", "search", "pas du json"])
    guard case .usage = casse else { return XCTFail("un JSON cassé est une erreur d'usage") }
  }

  func testLesDrapeauxGlobaux() {
    let (_, options) = InboxCommandLine.parse(["--json", "file"])
    XCTAssertTrue(options.json)
    guard case .doctor = InboxCommandLine.parse(["--doctor"]).0 else { return XCTFail() }
    guard case .tools = InboxCommandLine.parse(["outils"]).0 else { return XCTFail() }
    guard case .help = InboxCommandLine.parse([]).0 else { return XCTFail("sans rien, l'aide") }
    guard case .usage = InboxCommandLine.parse(["danser"]).0 else { return XCTFail("commande inconnue") }
  }

  func testLaLigneJSON() {
    let ligne = InboxCommandLine.jsonLine(tool: "archive", outcome: .init(text: "!x:local sort de la file.", isError: false))
    XCTAssertEqual(ligne, #"{"ok":true,"outil":"archive","texte":"!x:local sort de la file."}"#)
  }

  // MARK: - L'aiguillage commun

  func relais() -> FauxRelais {
    let relais = FauxRelais(selfUserID: "@moi:local")
    relais.rooms = ["!camille:local"]
    relais.noms = ["!camille:local": "Camille"]
    relais.messages = ["!camille:local": [
      .init(eventID: "$c1", sender: "@camille:local", body: "tu viens ?", sentAt: Date().addingTimeInterval(-60), isMine: false)
    ]]
    return relais
  }

  func testLAiguillageArchiveVraiment() async {
    let faux = relais()
    let sortie = await MCPInboxTools(relay: faux).call(tool: "archive", arguments: ["conversation": "!camille:local"])
    XCTAssertFalse(sortie.isError)
    XCTAssertTrue(faux.tags["!camille:local"]?.contains(ConversationStateKeys.archivedTag) ?? false)
  }

  func testLAiguillageDitCeQuiManque() async {
    let outils = MCPInboxTools(relay: relais())
    let sans = await outils.call(tool: "read_conversation", arguments: [:])
    XCTAssertTrue(sans.isError)
    XCTAssertTrue(sans.text.contains("conversation"), sans.text)
    let inconnu = await outils.call(tool: "danser", arguments: [:])
    XCTAssertTrue(inconnu.isError)
  }

  func testLAiguillagePlafonneLaLecture() async {
    let sortie = await MCPInboxTools(relay: relais()).call(tool: "read_conversation", arguments: ["conversation": "!camille:local", "limit": 100_000])
    XCTAssertFalse(sortie.isError)
    XCTAssertTrue(sortie.text.contains("tu viens ?"), sortie.text)
  }

  func testLeBrouillonNePartPas() async {
    let faux = relais()
    let sortie = await MCPInboxTools(relay: faux, agent: "cli").call(tool: "draft_reply", arguments: ["conversation": "!camille:local", "text": "oui"])
    XCTAssertFalse(sortie.isError)
    XCTAssertEqual(faux.propositions.count, 1)
    XCTAssertTrue(faux.envoyes.isEmpty, "un brouillon n'envoie rien")
  }

  func testLeRappelEnMinutes() {
    let maintenant = Date()
    let date = MCPInboxTools.date(in: ["in_minutes": 30], now: maintenant)
    XCTAssertEqual(date, maintenant.addingTimeInterval(1800))
    XCTAssertNotNil(MCPInboxTools.date(in: ["at": "2030-01-01T09:00:00Z"]))
    XCTAssertNil(MCPInboxTools.date(in: [:]))
  }
}
