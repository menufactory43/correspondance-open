import XCTest
@testable import CorrespondanceCore

/// Un sondage, c'est trois events (MSC3381) et un dépouillement. Les voix
/// arrivent dans n'importe quel ordre ; le résultat, lui, ne bouge pas.
final class PollTests: XCTestCase {
  private let moi = "@meffysto:relais"

  private func sync(_ events: String, batch: String = "s1") throws -> MatrixSyncResponse {
    let json = """
    {"next_batch":"\(batch)","rooms":{"join":{"!a:relais":{
      "state":{"events":[{"type":"m.bridge","state_key":"","content":{"protocol":{"id":"whatsappgo"}}}]},
      "timeline":{"events":[\(events)]}}}}}
    """
    return try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(json.utf8))
  }

  private var start: String {
    """
    {"type":"org.matrix.msc3381.poll.start","event_id":"$poll","sender":"@whatsapp_lid-1:relais",
     "origin_server_ts":1800000000000,
     "content":{"org.matrix.msc3381.poll.start":{
       "kind":"org.matrix.msc3381.poll.disclosed","max_selections":1,
       "question":{"org.matrix.msc1767.text":"Quel jour ?"},
       "answers":[{"id":"a","org.matrix.msc1767.text":"Lundi"},
                  {"id":"b","org.matrix.msc1767.text":"Mardi"}]}}}
    """
  }

  private func vote(_ id: String, sender: String, answer: String, at ts: Int) -> String {
    """
    {"type":"org.matrix.msc3381.poll.response","event_id":"\(id)","sender":"\(sender)",
     "origin_server_ts":\(ts),
     "content":{"m.relates_to":{"rel_type":"m.reference","event_id":"$poll"},
       "org.matrix.msc3381.poll.response":{"answers":["\(answer)"]}}}
    """
  }

  private func parse(_ events: [String]) throws -> MatrixRoomModel {
    let parser = MatrixSyncParser(selfUserID: moi)
    var rooms: [String: MatrixRoomModel] = [:]
    parser.apply(try sync(events.joined(separator: ",")), to: &rooms)
    return try XCTUnwrap(rooms["!a:relais"])
  }

  func testLeSondageDevientUnMessageAvecSaQuestion() throws {
    let model = try parse([start])
    let message = try XCTUnwrap(model.sortedMessages.first)
    let poll = try XCTUnwrap(message.poll)
    XCTAssertEqual(poll.question, "Quel jour ?")
    XCTAssertEqual(poll.answers.map(\.text), ["Lundi", "Mardi"])
    XCTAssertEqual(poll.kind, .disclosed)
    XCTAssertEqual(message.sidebarPreviewText, "📊 Quel jour ?")
    XCTAssertTrue(message.hasVisibleBody)
  }

  func testChaquePersonneNAQuUneVoixLaDerniere() throws {
    let model = try parse([
      start,
      vote("$v1", sender: "@whatsapp_lid-1:relais", answer: "a", at: 1_800_000_001_000),
      vote("$v2", sender: "@whatsapp_lid-1:relais", answer: "b", at: 1_800_000_002_000),
    ])
    let poll = try XCTUnwrap(model.pollsByEventID["$poll"]?.poll)
    XCTAssertEqual(poll.voterCount, 1)
    XCTAssertEqual(poll.count(of: "a"), 0)
    XCTAssertEqual(poll.count(of: "b"), 1)
  }

  func testUneVoixPlusAncienneArriveeApresNEcrasePasLaDerniere() throws {
    let model = try parse([
      start,
      vote("$v2", sender: "@whatsapp_lid-1:relais", answer: "b", at: 1_800_000_002_000),
      // Une page remontée en arrière rend un vote plus vieux : il ne compte pas.
      vote("$v1", sender: "@whatsapp_lid-1:relais", answer: "a", at: 1_800_000_001_000),
    ])
    let poll = try XCTUnwrap(model.pollsByEventID["$poll"]?.poll)
    XCTAssertEqual(poll.count(of: "b"), 1)
    XCTAssertEqual(poll.count(of: "a"), 0)
  }

  func testUneVoixArriveeAvantSaQuestionEstGardee() throws {
    let model = try parse([
      vote("$v1", sender: "@whatsapp_lid-1:relais", answer: "a", at: 1_800_000_001_000),
      start,
    ])
    let poll = try XCTUnwrap(model.pollsByEventID["$poll"]?.poll)
    XCTAssertEqual(poll.question, "Quel jour ?")
    XCTAssertEqual(poll.count(of: "a"), 1)
  }

  func testMaVoixSeReconnaitEtSeBascule() throws {
    let model = try parse([
      start,
      vote("$v1", sender: moi, answer: "a", at: 1_800_000_001_000),
    ])
    let poll = try XCTUnwrap(model.pollsByEventID["$poll"]?.poll)
    XCTAssertEqual(poll.myAnswerIDs, ["a"])
    XCTAssertTrue(poll.hasVoted("a"))
    // Choix unique : toucher l'autre réponse remplace, toucher la sienne retire.
    XCTAssertEqual(poll.toggling("b"), ["b"])
    XCTAssertEqual(poll.toggling("a"), [])
    // Une réponse qui n'existe pas ne change rien.
    XCTAssertEqual(poll.toggling("z"), ["a"])
  }

  func testAChoixMultiplesLaPlusAncienneCedeSaPlace() {
    let poll = Poll(
      question: "Quoi ?",
      answers: [.init(id: "a", text: "A"), .init(id: "b", text: "B"), .init(id: "c", text: "C")],
      maxSelections: 2,
      myAnswerIDs: ["a", "b"]
    )
    XCTAssertEqual(poll.toggling("c"), ["b", "c"])
    XCTAssertEqual(poll.toggling("a"), ["b"])
  }

  func testUneVoixPosterieureALaClotureNeComptePas() throws {
    let end = """
    {"type":"org.matrix.msc3381.poll.end","event_id":"$end","sender":"@whatsapp_lid-1:relais",
     "origin_server_ts":1800000005000,
     "content":{"m.relates_to":{"rel_type":"m.reference","event_id":"$poll"},
       "org.matrix.msc3381.poll.end":{}}}
    """
    let model = try parse([
      start,
      vote("$v1", sender: "@whatsapp_lid-2:relais", answer: "a", at: 1_800_000_001_000),
      end,
      vote("$v2", sender: "@whatsapp_lid-3:relais", answer: "b", at: 1_800_000_009_000),
    ])
    let poll = try XCTUnwrap(model.pollsByEventID["$poll"]?.poll)
    XCTAssertTrue(poll.isClosed)
    XCTAssertEqual(poll.count(of: "a"), 1)
    XCTAssertEqual(poll.count(of: "b"), 0)
    XCTAssertTrue(poll.summaryFR().hasSuffix("clos"))
  }

  func testUnSondageSecretNeMontreRienAvantSaCloture() {
    var poll = Poll(
      question: "Quoi ?",
      answers: [.init(id: "a", text: "A")],
      kind: .undisclosed,
      votesByVoter: ["@x:relais": ["a"]]
    )
    XCTAssertFalse(poll.showsResults)
    XCTAssertEqual(poll.summaryFR(), "Résultats après la clôture")
    poll.isClosed = true
    XCTAssertTrue(poll.showsResults)
  }

  func testUneVoixPourUneReponseInconnueNeCompteNulPart() throws {
    let model = try parse([
      start,
      vote("$v1", sender: "@whatsapp_lid-2:relais", answer: "zz", at: 1_800_000_001_000),
    ])
    let poll = try XCTUnwrap(model.pollsByEventID["$poll"]?.poll)
    XCTAssertEqual(poll.voterCount, 0)
    XCTAssertEqual(poll.totalVotes, 0)
  }

  func testLaFormeStableSeLitAussi() throws {
    let stable = """
    {"type":"m.poll.start","event_id":"$p2","sender":"@whatsapp_lid-1:relais",
     "origin_server_ts":1800000000000,
     "content":{"m.poll.start":{"kind":"m.poll.undisclosed","max_selections":2,
       "question":{"m.text":"Où ?"},
       "answers":[{"id":"x","m.text":"Ici"},{"id":"y","m.text":"Là"}]}}}
    """
    let model = try parse([stable])
    let entry = try XCTUnwrap(model.pollsByEventID["$p2"])
    XCTAssertEqual(entry.poll.question, "Où ?")
    XCTAssertEqual(entry.poll.kind, .undisclosed)
    XCTAssertEqual(entry.poll.maxSelections, 2)
    XCTAssertEqual(entry.startType, PollEventTypes.startStable)
    // On répond dans la forme où l'on a lu : sinon la voix ne se rattache à rien.
    XCTAssertEqual(
      PollEventTypes.responseType(forStart: entry.startType),
      PollEventTypes.responseStable
    )
    XCTAssertEqual(
      PollEventTypes.responseType(forStart: PollEventTypes.startUnstable),
      PollEventTypes.responseUnstable
    )
  }

  func testUnSondageRedigeDisparaitAvecSesVoix() throws {
    let redaction = """
    {"type":"m.room.redaction","event_id":"$r","sender":"@whatsapp_lid-1:relais",
     "origin_server_ts":1800000009000,"redacts":"$poll","content":{}}
    """
    let model = try parse([
      start,
      vote("$v1", sender: "@whatsapp_lid-2:relais", answer: "a", at: 1_800_000_001_000),
      redaction,
    ])
    XCTAssertNil(model.pollsByEventID["$poll"])
    XCTAssertNil(model.messagesByID["$poll"])
  }

  func testLesPartsSeRapportentAuxVoixPasAuxPersonnes() {
    let poll = Poll(
      question: "Quoi ?",
      answers: [.init(id: "a", text: "A"), .init(id: "b", text: "B")],
      maxSelections: 2,
      votesByVoter: ["@x:relais": ["a", "b"], "@y:relais": ["a"]]
    )
    XCTAssertEqual(poll.totalVotes, 3)
    XCTAssertEqual(poll.voterCount, 2)
    XCTAssertEqual(poll.fraction(of: "a"), 2.0 / 3, accuracy: 0.001)
    XCTAssertEqual(poll.fraction(of: "a") + poll.fraction(of: "b"), 1, accuracy: 0.001)
  }
}
