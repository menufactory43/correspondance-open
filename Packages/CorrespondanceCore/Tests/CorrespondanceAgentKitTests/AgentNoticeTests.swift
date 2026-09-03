import CorrespondanceMatrixClient
import XCTest

@testable import CorrespondanceAgentKit

/// Les échecs visibles : ce que l'agent dit de lui-même à ses propriétaires,
/// avec la cause et le geste. Une panne qui ne se voit pas passe pour de la lenteur.
final class AgentNoticeTests: XCTestCase {
  func testLAvisPorteLaCauseEtLeGeste() {
    let moteur = AgentEvents.notice(agent: "cc", body: "hermes n'est pas installé sur umbrel", reason: "engine_missing", action: "rescan")
    XCTAssertEqual(moteur.string(at: AgentWire.NoticeKey.agent), "cc")
    XCTAssertEqual(moteur.string(at: AgentWire.NoticeKey.body), "hermes n'est pas installé sur umbrel")
    XCTAssertEqual(moteur.string(at: AgentWire.NoticeKey.reason), "engine_missing")
    XCTAssertEqual(moteur.string(at: AgentWire.NoticeKey.action), "rescan", "le geste : relancer le scan des moteurs")

    let panne = AgentEvents.notice(agent: "cc", body: "Je n'ai pas pu répondre : claude a quitté avec le code 1", reason: "error", action: "retry")
    XCTAssertEqual(panne.string(at: AgentWire.NoticeKey.action), "retry")

    let delai = AgentEvents.notice(agent: "cc", body: "Claude n'a pas répondu en 300 s", reason: "timeout", action: "retry")
    XCTAssertEqual(delai.string(at: AgentWire.NoticeKey.reason), "timeout")

    let plafond = AgentEvents.notice(agent: "cc", body: "Plafond horaire atteint", reason: "cap")
    XCTAssertNil(plafond.string(at: AgentWire.NoticeKey.action), "un plafond n'a pas de geste : il faut attendre")
  }

  /// L'event est envoyable tel quel : que des chaînes dedans — pas un nombre,
  /// donc pas un flottant que Matrix refuserait (c'est ce qui avait rendu le
  /// journal muet).
  func testLAvisNePorteQueDesChaines() throws {
    let avis = AgentEvents.notice(agent: "cc", body: "x", reason: "cap", action: "retry")
    let champs = try XCTUnwrap(avis.objectValue)
    XCTAssertEqual(champs.count, 4)
    for (cle, valeur) in champs {
      XCTAssertNotNil(valeur.stringValue, "\(cle) n'est pas une chaîne")
    }
  }
}
