import XCTest

@testable import CorrespondanceAgentKit

/// Deux messages coup sur coup ne doivent ni perdre une demande, ni poster une
/// bulle qui remplit la file. Ils partent **ensemble**, en un tour — comme
/// `buzz-acp`.
final class RequestBatchTests: XCTestCase {
  func demande(_ texte: String, de qui: String = "@meffysto:local", eventID: String = "$e") -> AgentRequest {
    AgentRequest(roomID: "!fil:local", eventID: eventID, sender: qui, prompt: texte, sentAt: Date())
  }

  func testUneSeuleDemandeNePayeRienALaMecanique() {
    let lot = RequestBatch.merge([demande("test")])
    XCTAssertEqual(lot?.prompt, "test", "le cas courant garde son prompt tel quel")
    XCTAssertEqual(lot?.count, 1)
    XCTAssertEqual(lot?.dropped.count, 0)
  }

  /// Le cas de l'essai réel : `@cc test` puis `@cc ping`. Avant, la seconde
  /// recevait une bulle de refus et n'était jamais traitée.
  func testDeuxDemandesPartentEnUnSeulTour() {
    let lot = RequestBatch.merge([
      demande("test", eventID: "$un"),
      demande("ping", eventID: "$deux"),
    ])
    let prompt = try! XCTUnwrap(lot?.prompt)
    XCTAssertTrue(prompt.contains("test"), prompt)
    XCTAssertTrue(prompt.contains("ping"), prompt)
    XCTAssertEqual(lot?.count, 2)
  }

  func testLOrdreDesMessagesEstPreserve() {
    let lot = RequestBatch.merge([
      demande("premier", eventID: "$1"),
      demande("deuxième", eventID: "$2"),
      demande("troisième", eventID: "$3"),
    ])
    let prompt = try! XCTUnwrap(lot?.prompt)
    let un = prompt.range(of: "premier")!
    let deux = prompt.range(of: "deuxième")!
    let trois = prompt.range(of: "troisième")!
    XCTAssertTrue(un.lowerBound < deux.lowerBound)
    XCTAssertTrue(deux.lowerBound < trois.lowerBound)
  }

  func testChaqueMessageEstAttribueASonExpediteur() {
    let lot = RequestBatch.merge([
      demande("d'abord ça", de: "@meffysto:local"),
      demande("puis ça", de: "@camille:local"),
    ])
    let prompt = try! XCTUnwrap(lot?.prompt)
    XCTAssertTrue(prompt.contains("De @meffysto:local : d'abord ça"), prompt)
    XCTAssertTrue(prompt.contains("De @camille:local : puis ça"), prompt)
  }

  /// La citation désigne le **dernier** : c'est à celui-là qu'on s'attend à
  /// voir répondre, les précédents sont dans le corps du tour.
  func testLaCitationDesigneLeDernierMessage() {
    let lot = RequestBatch.merge([
      demande("test", eventID: "$un"),
      demande("ping", eventID: "$deux"),
    ])
    XCTAssertEqual(lot?.reply.eventID, "$deux")
  }

  func testLeMoteurSaitQuIlRepondAPlusieursChoses() {
    let prompt = try! XCTUnwrap(RequestBatch.merge([demande("a"), demande("b")])?.prompt)
    XCTAssertTrue(prompt.contains("Plusieurs demandes"), prompt)
    XCTAssertTrue(prompt.contains("un seul message"), prompt)
  }

  // MARK: - La borne de taille

  func testUnDelugeGardeLesPlusRecentes() {
    let long = String(repeating: "x", count: 3_000)
    let lot = RequestBatch.merge([
      demande(long, eventID: "$vieille"),
      demande(long, eventID: "$moyenne"),
      demande("la dernière", eventID: "$derniere"),
    ], tailleMax: 4_000)

    let garde = try! XCTUnwrap(lot)
    XCTAssertTrue(garde.prompt.contains("la dernière"), "la plus récente survit toujours")
    XCTAssertEqual(garde.dropped.count, 1, "la plus ancienne est écartée")
    XCTAssertEqual(garde.dropped.first?.eventID, "$vieille")
    XCTAssertEqual(garde.reply.eventID, "$derniere")
  }

  func testUneSeuleDemandeEnormeNEstJamaisJetee() {
    let enorme = String(repeating: "x", count: 50_000)
    let lot = RequestBatch.merge([demande(enorme), demande("suite")], tailleMax: 100)
    XCTAssertEqual(lot?.dropped.count, 1)
    XCTAssertEqual(lot?.count, 1, "on garde au moins la plus récente, quoi qu'il arrive")
  }

  func testUneListeVideNeDonneAucunTour() {
    XCTAssertNil(RequestBatch.merge([]))
  }
}
