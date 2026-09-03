import CorrespondanceMatrixClient
import XCTest
@testable import CorrespondanceAgentKit

/// L'aparté : ce qu'un propriétaire dit à un agent devant des humains, dans un
/// event que les ponts ne relaient pas. Pour l'agent, c'est un ordre comme un
/// autre — et la règle « qui est nommé » est la même des deux côtés.
final class AparteTests: XCTestCase {
  private var config: AgentConfig {
    var config = AgentConfig(
      homeserver: URL(string: "http://relais:8008")!, user: "cc", password: "x",
      owners: ["@meffysto:correspondance.local"]
    )
    config.trigger = "@cc"
    return config
  }

  private func event(type: String, sender: String, body: String) -> MatrixEvent {
    MatrixEvent(
      type: type, eventID: "$e", sender: sender,
      originServerTS: Date().timeIntervalSince1970 * 1000,
      content: .object(["msgtype": .string("m.text"), "body": .string(body)])
    )
  }

  func testUnAparteEstUnOrdreCommeUnMessage() {
    let since = Date().addingTimeInterval(-60)
    let demande = Trigger.request(
      from: event(type: AgentWire.asideType, sender: "@meffysto:correspondance.local", body: "@cc résume ce fil"),
      roomID: "!r", config: config, notBefore: since
    )
    XCTAssertEqual(demande?.prompt, "résume ce fil")
  }

  func testUnAparteDUnTiersNeDeclencheRien() {
    let since = Date().addingTimeInterval(-60)
    XCTAssertNil(Trigger.request(
      from: event(type: AgentWire.asideType, sender: "@camille:correspondance.local", body: "@cc résume ce fil"),
      roomID: "!r", config: config, notBefore: since
    ))
  }

  // MARK: - Qui est nommé (la règle partagée avec l'app)

  func testLaMentionSeReconnaitEnMotEntierNImporteOu() {
    XCTAssertEqual(AgentWire.agentsMentioned(in: "dis à @claude de voir", among: ["cc", "claude"]), ["claude"])
    XCTAssertEqual(AgentWire.agentsMentioned(in: "@CC, un résumé ?", among: ["cc", "claude"]), ["cc"])
    XCTAssertEqual(AgentWire.agentsMentioned(in: "regarde @cccile", among: ["cc"]), [], "@ccc n'est pas @cc")
    XCTAssertEqual(AgentWire.agentsMentioned(in: "mail@cc.fr", among: ["cc"]), [], "une adresse n'est pas une mention")
    XCTAssertEqual(AgentWire.agentsMentioned(in: "salut Jean, tu viens ?", among: ["cc", "claude"]), [])
  }

  func testCeuxQuiOuvrentLaPhraseSontLesDestinataires() {
    XCTAssertEqual(
      AgentWire.agentsAddressed(in: "@cc dis à @claude de faire un test de math", among: ["cc", "claude"]),
      ["cc"], "on parle à cc, de claude")
    XCTAssertEqual(
      AgentWire.agentsAddressed(in: "@claude @cc vous allez bien ?", among: ["cc", "claude"]),
      ["claude", "cc"])
    XCTAssertEqual(
      AgentWire.agentsAddressed(in: "@claude, @cc : vous allez bien ?", among: ["cc", "claude"]),
      ["claude", "cc"])
  }

  func testSansAgentEnTeteTousLesNommesSontAppeles() {
    XCTAssertEqual(
      Set(AgentWire.agentsAddressed(in: "hey @cc et @claude, un avis ?", among: ["cc", "claude"])),
      ["cc", "claude"])
    XCTAssertEqual(AgentWire.agentsAddressed(in: "je réfléchis tout haut", among: ["cc", "claude"]), [])
  }
}
