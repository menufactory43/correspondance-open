import CorrespondanceMatrixClient
import XCTest

@testable import CorrespondanceAgentKit

/// Le point du matin : quand il sonne, et quels salons il relit.
final class HeartbeatTests: XCTestCase {
  let utc = TimeZone(identifier: "UTC")!
  // 2026-09-03T07:30:00Z, un jeudi.
  let matin = Date(timeIntervalSince1970: 1_788_420_600)

  func testLaProchaineOccurrenceEstAujourdhuiOuDemain() {
    let aujourdhui = Heartbeat.prochaineOccurrence(de: "08:00", apres: matin, timeZone: utc)
    XCTAssertEqual(aujourdhui, matin.addingTimeInterval(30 * 60), "08:00 n'est pas encore passé")
    let demain = Heartbeat.prochaineOccurrence(de: "07:00", apres: matin, timeZone: utc)
    XCTAssertEqual(demain, matin.addingTimeInterval(23 * 3600 + 30 * 60), "07:00 est passé : demain")
    let pile = Heartbeat.prochaineOccurrence(de: "07:30", apres: matin, timeZone: utc)
    XCTAssertEqual(pile, matin.addingTimeInterval(24 * 3600), "à l'heure pile, c'est déjà passé")
  }

  func testUneHeureIllisibleNeSonneJamais() {
    XCTAssertNil(Heartbeat.prochaineOccurrence(de: "8h", apres: matin, timeZone: utc))
    XCTAssertNil(Heartbeat.prochaineOccurrence(de: "25:00", apres: matin, timeZone: utc))
    XCTAssertNil(Heartbeat.prochaineOccurrence(de: "", apres: matin, timeZone: utc))
    XCTAssertNotNil(Heartbeat.prochaineOccurrence(de: " 8:05 ", apres: matin, timeZone: utc), "sans zéro devant, ça passe")
  }

  func message(_ sender: String, _ body: String, at: Date) -> MatrixEvent {
    MatrixEvent(type: "m.room.message", eventID: "$\(at.timeIntervalSince1970)", sender: sender, originServerTS: at.timeIntervalSince1970 * 1000, content: .object(["msgtype": .string("m.text"), "body": .string(body)]))
  }

  func testSeulsLesSalonsOuLeDernierMotNEstPasAuProprietaireComptent() {
    let owners: Set<String> = ["@meffysto:s"]
    let moi = "@cc:s"
    let attend = Heartbeat.Salon(roomID: "!a", nom: "Camille", events: [
      message("@meffysto:s", "je te dis", at: matin.addingTimeInterval(-100)),
      message("@whatsapp_1:s", "tu viens dimanche ?", at: matin.addingTimeInterval(-50)),
    ])
    let repondu = Heartbeat.Salon(roomID: "!b", nom: "Julie", events: [
      message("@whatsapp_2:s", "dispo ?", at: matin.addingTimeInterval(-100)),
      message("@meffysto:s", "oui", at: matin.addingTimeInterval(-50)),
    ])
    let pilote = Heartbeat.Salon(roomID: "!c", nom: nil, events: [
      message("@whatsapp_3:s", "ok pour 15 h ?", at: matin.addingTimeInterval(-100)),
      message(moi, "Oui, 15 h me va.", at: matin.addingTimeInterval(-50)),
    ])
    XCTAssertTrue(Heartbeat.attendUneReponse(attend, owners: owners, moi: moi))
    XCTAssertFalse(Heartbeat.attendUneReponse(repondu, owners: owners, moi: moi))
    XCTAssertFalse(Heartbeat.attendUneReponse(pilote, owners: owners, moi: moi), "ce que l'agent a envoyé seul n'attend pas")
    XCTAssertFalse(Heartbeat.attendUneReponse(Heartbeat.Salon(roomID: "!d", nom: nil, events: []), owners: owners, moi: moi))

    let prompt = Heartbeat.prompt(salons: [repondu, attend, pilote], owners: owners, moi: moi, noms: [:], timeZone: utc)
    XCTAssertTrue(prompt.hasPrefix(Heartbeat.prompt))
    XCTAssertTrue(prompt.contains("Conversation « Camille »"))
    XCTAssertTrue(prompt.contains("whatsapp_1 : tu viens dimanche ?"), "le fil, comme données")
    XCTAssertFalse(prompt.contains("Julie"), "on a déjà répondu à Julie")
    XCTAssertEqual(Heartbeat.prompt(salons: [repondu], owners: owners, moi: moi, noms: [:]), "", "rien à dire : pas de tour")
  }

  func testAuPlusDixSalonsLesPlusRecentsDAbord() {
    let salons = (0..<15).map { i in
      Heartbeat.Salon(roomID: "!\(i)", nom: "Salon \(i)", events: [message("@tiers\(i):s", "coucou", at: matin.addingTimeInterval(Double(i)))])
    }
    let prompt = Heartbeat.prompt(salons: salons, owners: ["@meffysto:s"], moi: "@cc:s", noms: [:], timeZone: utc)
    XCTAssertTrue(prompt.contains("« Salon 14 »"))
    XCTAssertTrue(prompt.contains("« Salon 5 »"))
    XCTAssertFalse(prompt.contains("« Salon 4 »"), "le onzième saute")
  }

  func testLePointNeCiteAucunEvent() {
    let proposition = AgentEvents.proposal(text: "Camille attend une réponse.", agent: "cc", inReplyTo: "", kind: AgentWire.ProposalKind.summary)
    XCTAssertEqual(proposition.string(at: AgentWire.ProposalKey.kind), "summary")
    XCTAssertNil(proposition["m.relates_to"], "sans event à citer, pas de citation vide")
  }
}
