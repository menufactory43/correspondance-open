import CorrespondanceMatrixClient
import XCTest

@testable import CorrespondanceAgentKit

/// Le journal des tours est l'un des trois garde-fous qui restent depuis la
/// pleine permission. Ces tests tiennent deux choses : qu'il **écrit** quand il
/// peut, et qu'il **le dit** quand il ne peut pas.
///
/// La seconde compte autant que la première. Trois fois de suite, le même motif
/// a coûté cher — un garde-fou qui ne fonctionne pas *et qui se tait*.
final class AgentJournalTests: XCTestCase {

  /// Un client de laboratoire : il retient ce qu'on lui donne à poster.
  final class FauxClient: @unchecked Sendable {
    var postes: [(roomID: String, type: String, content: MatrixJSON)] = []
    var erreur: Error?

    func poster(_ roomID: String, _ type: String, _ content: MatrixJSON) async throws {
      if let erreur { throw erreur }
      postes.append((roomID, type, content))
    }
  }

  func testUnTourAvecConsoleEcritUnEventDeJournal() async {
    let faux = FauxClient()
    let carnet = AgentJournal(consoleRoomID: "!console:local", post: faux.poster)

    let issue = await carnet.record(
      agent: "cc", roomID: "!fil:local", sender: "@meffysto:local", prompt: "@cc test",
      tools: ["Bash"], seconds: 6.2, tokens: 4200
    )
    XCTAssertEqual(issue, .written(roomID: "!console:local"))
    XCTAssertEqual(faux.postes.count, 1)

    let poste = faux.postes[0]
    XCTAssertEqual(poste.roomID, "!console:local", "le journal va dans la console, pas dans le fil")
    XCTAssertEqual(poste.type, AgentEvents.journalType)
    XCTAssertEqual(poste.content.value(at: AgentWire.JournalKey.room)?.stringValue, "!fil:local")
    XCTAssertEqual(poste.content.value(at: AgentWire.JournalKey.sender)?.stringValue, "@meffysto:local")
    XCTAssertEqual(poste.content.value(at: AgentWire.JournalKey.durationMs)?.intValue, 6200)
    XCTAssertEqual(poste.content.nonIntegerNumberPaths(), [], "et jamais de flottant")
  }

  /// Le bug qui a rendu le journal muet : sans console, on sortait par un
  /// `return` sans un mot, et personne ne savait que le garde-fou manquait.
  func testSansConsoleOnLeDitAuLieuDeSeTaire() async {
    let faux = FauxClient()
    let carnet = AgentJournal(consoleRoomID: nil, post: faux.poster)

    let issue = await carnet.record(
      agent: "cc", roomID: "!fil:local", sender: "@g:local", prompt: "x",
      tools: [], seconds: 1, tokens: nil
    )
    guard case .impossible(let raison) = issue else {
      return XCTFail("l'impossibilité doit être une valeur, pas un silence")
    }
    XCTAssertTrue(raison.contains("console"), raison)
    XCTAssertTrue(raison.contains("plus rien ne relit"), "la raison nomme la conséquence")
    XCTAssertTrue(faux.postes.isEmpty, "on n'invente pas un endroit où déverser la conversation")
  }

  /// Et si le Relais refuse — c'est ce qui arrivait avec le flottant — la
  /// raison remonte au lieu d'être avalée.
  func testUnRefusDuRelaisRemonte() async {
    let faux = FauxClient()
    faux.erreur = MatrixError.http(status: 400, errcode: "M_BAD_JSON", message: "Bad JSON value: float")
    let carnet = AgentJournal(consoleRoomID: "!console:local", post: faux.poster)

    let issue = await carnet.record(
      agent: "cc", roomID: "!fil:local", sender: "@g:local", prompt: "x",
      tools: [], seconds: 1, tokens: nil
    )
    guard case .impossible(let raison) = issue else { return XCTFail("il fallait remonter l'erreur") }
    XCTAssertTrue(raison.contains("impostable"), raison)
  }

  func testLaRaisonEstUtilisableTelleQuelleDansLesReglages() {
    // Elle est montrée à quelqu'un : elle doit dire quoi faire, pas seulement
    // ce qui ne va pas.
    XCTAssertTrue(AgentJournal.sansConsole.contains("Réglages › Agent"))
    XCTAssertFalse(AgentJournal.sansConsole.contains("nil"))
  }
}
