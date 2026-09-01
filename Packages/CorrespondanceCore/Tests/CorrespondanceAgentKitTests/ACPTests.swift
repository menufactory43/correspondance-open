import CorrespondanceMatrixClient
import XCTest

@testable import CorrespondanceAgentKit

/// La couche protocole de l'ACP, sans lancer aucun moteur. Les échantillons
/// viennent des vraies traces du spike (`docs/SPIKE-acp.md`).
final class ACPTests: XCTestCase {

  // MARK: - Lecture

  func testUneReponseEstReconnue() {
    let incoming = ACP.parse(line: #"{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}"#)
    guard case .result(let id, let value) = incoming else { return XCTFail("attendu un résultat, reçu \(incoming)") }
    XCTAssertEqual(id, 3)
    XCTAssertEqual(value["stopReason"]?.stringValue, "end_turn")
  }

  func testUneErreurPorteSonDetail() {
    let line = #"{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"Internal error","data":{"details":"Query closed before response received"}}}"#
    guard case .failure(let id, let message) = ACP.parse(line: line) else { return XCTFail("attendu un échec") }
    XCTAssertEqual(id, 2)
    XCTAssertTrue(message.contains("Query closed"), message)
  }

  func testUneRequeteDuMoteurSeDistingueDUneNotification() {
    let requete = ACP.parse(line: #"{"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{}}"#)
    guard case .request(_, let method, _) = requete else { return XCTFail("attendu une requête") }
    XCTAssertEqual(method, "session/request_permission")

    let notif = ACP.parse(line: #"{"jsonrpc":"2.0","method":"session/update","params":{}}"#)
    guard case .notification(let m, _) = notif else { return XCTFail("attendu une notification") }
    XCTAssertEqual(m, "session/update")
  }

  func testLeBruitDeDemarrageNEstPasDuJSONRPC() {
    guard case .noise = ACP.parse(line: "Error: something happened") else {
      return XCTFail("une ligne non-JSON est du bruit, pas un message")
    }
  }

  // MARK: - Pleine permission

  func testOnChoisitLOptionLaPlusPermissive() {
    let params = params(#"{"options":[{"kind":"allow_always","optionId":"allow_always"},{"kind":"allow_once","optionId":"allow"},{"kind":"reject_once","optionId":"reject"}]}"#)
    XCTAssertEqual(ACP.grantedOption(in: params), "allow_always")
  }

  func testSansAllowAlwaysOnPrendAllowOnce() {
    let params = params(#"{"options":[{"kind":"allow_once","optionId":"allow"},{"kind":"reject_once","optionId":"reject"}]}"#)
    XCTAssertEqual(ACP.grantedOption(in: params), "allow")
  }

  func testOnNeRefuseJamaisQuandUneOptionAutorise() {
    // Un moteur qui nomme ses options autrement : on ne doit pas tomber sur « reject ».
    let params = params(#"{"options":[{"optionId":"reject-tool"},{"optionId":"allow-tool"}]}"#)
    XCTAssertEqual(ACP.grantedOption(in: params), "allow-tool")
  }

  func testLaReponseDePermissionEstBienFormee() {
    let params = params(#"{"options":[{"kind":"allow_always","optionId":"allow_always"}]}"#)
    let line = ACP.permissionResponse(id: .number(7), params: params)
    XCTAssertTrue(line.contains(#""optionId":"allow_always""#), line)
    XCTAssertTrue(line.contains(#""outcome":"selected""#), line)
    XCTAssertTrue(line.hasSuffix("\n"), "une ligne JSON-RPC se termine par un saut de ligne")
  }

  // MARK: - Le mode se force, il ne se subit pas

  func testOnForceLePremierModeQueLeMoteurAnnonce() {
    var settings = AgentConfig.ACPSettings()
    settings.permissionModes = ["bypassPermissions", "acceptEdits", "default"]
    // claude-code-acp : pas de « bypassPermissions » dans sa liste ? on descend.
    XCTAssertEqual(settings.resolvedMode(available: ["default", "acceptEdits", "plan"]), "acceptEdits")
    XCTAssertEqual(settings.resolvedMode(available: ["default", "bypassPermissions"]), "bypassPermissions")
    XCTAssertEqual(settings.resolvedMode(available: ["plan"]), nil, "aucun mode acceptable : on ne force rien")
  }

  func testLesModesAnnoncesSontLus() {
    let result = params(#"{"modes":{"currentModeId":"auto","availableModes":[{"id":"auto"},{"id":"default"},{"id":"bypassPermissions"}]}}"#)
    let modes = ACP.modes(in: result)
    XCTAssertEqual(modes.current, "auto", "claude-agent-acp 0.70.0 démarre là — un classifieur décide")
    XCTAssertEqual(modes.available, ["auto", "default", "bypassPermissions"])
  }

  // MARK: - Ce qu'on lit d'un tour

  func testLeTexteSAssembleMorceauParMorceau() {
    let un = params(#"{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"PO"}}}"#)
    let deux = params(#"{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"NG"}}}"#)
    XCTAssertEqual((ACP.messageChunk(in: un) ?? "") + (ACP.messageChunk(in: deux) ?? ""), "PONG")
  }

  func testUnAutreTypeDeMiseAJourNEstPasDuTexte() {
    let usage = params(#"{"update":{"sessionUpdate":"usage_update","content":{"text":"pas du texte de réponse"}}}"#)
    XCTAssertNil(ACP.messageChunk(in: usage))
  }

  func testLOutilEmployeAlimenteLeJournal() {
    let call = params(#"{"update":{"sessionUpdate":"tool_call","title":"`echo bonjour`","kind":"execute"}}"#)
    XCTAssertEqual(ACP.toolCall(in: call), "`echo bonjour`")
  }

  func testLesJetonsDUnTourSontComptes() {
    let result = params(#"{"stopReason":"end_turn","usage":{"inputTokens":4,"outputTokens":158,"totalTokens":86167}}"#)
    XCTAssertEqual(ACP.totalTokens(in: result), 86167)
  }

  func testLaSessionEstRelueDuResultat() {
    let result = params(#"{"sessionId":"c27e29a3-a256-4457-820d-2c044a9223e9"}"#)
    XCTAssertEqual(ACP.sessionID(in: result), "c27e29a3-a256-4457-820d-2c044a9223e9")
  }

  // MARK: - Écriture

  func testLesRequetesPortentLeurMethodeEtLeurIdentifiant() {
    XCTAssertTrue(ACP.initializeRequest(id: 1).contains(#""method":"initialize""#))
    XCTAssertTrue(ACP.sessionNewRequest(id: 2, cwd: "/tmp/x").contains(#""cwd":"\/tmp\/x""# ) || ACP.sessionNewRequest(id: 2, cwd: "/tmp/x").contains(#""cwd":"/tmp/x""#))
    XCTAssertTrue(ACP.promptRequest(id: 3, sessionID: "s", text: "salut").contains(#""text":"salut""#))
    XCTAssertTrue(ACP.sessionLoadRequest(id: 4, sessionID: "s", cwd: "/tmp").contains(#""method":"session\/load""#) || ACP.sessionLoadRequest(id: 4, sessionID: "s", cwd: "/tmp").contains(#""method":"session/load""#))
  }

  func testOnNAnnoncePasDeCapaciteFichier() {
    let line = ACP.initializeRequest(id: 1)
    XCTAssertTrue(line.contains(#""readTextFile":false"#), "le moteur a ses propres outils fichier")
  }

  // MARK: -

  private func params(_ json: String) -> MatrixJSON {
    try! JSONDecoder().decode(MatrixJSON.self, from: Data(json.utf8))
  }
}
