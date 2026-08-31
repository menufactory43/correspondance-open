import XCTest
@testable import CorrespondanceCore

/// Synapse ne met que dix events par salon dans un `/sync` sans filtre, et pose
/// `limited: true` quand il en a laissé derrière. Après une nuit Mac éteint, un
/// groupe bavard perdait tout sauf ses dix derniers messages : le trou n'était
/// jamais signalé une seconde fois, ni comblé.
final class MatrixTimelineGapTests: XCTestCase {
  private let selfUserID = "@meffysto:correspondance.local"
  private let roomID = "!groupe:correspondance.local"

  private func sync(limited: Bool?, prevBatch: String?, otherRoom: Bool = false) throws -> MatrixSyncResponse {
    var timeline = "{\"events\": [{\"type\": \"m.room.message\", \"event_id\": \"$new\", \"sender\": \"@signal_x:correspondance.local\", \"origin_server_ts\": 1700000100000, \"content\": {\"msgtype\": \"m.text\", \"body\": \"salut\"}}]"
    if let limited { timeline += ", \"limited\": \(limited)" }
    if let prevBatch { timeline += ", \"prev_batch\": \"\(prevBatch)\"" }
    timeline += "}"
    var rooms = "\"\(roomID)\": {\"timeline\": \(timeline)}"
    if otherRoom {
      rooms += ", \"!autre:correspondance.local\": {\"timeline\": {\"events\": [], \"limited\": false}}"
    }
    let json = "{\"next_batch\": \"s2\", \"rooms\": {\"join\": {\(rooms)}}}"
    return try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(json.utf8))
  }

  private func event(_ id: String, ts: Double = 1700000000000) -> MatrixEvent {
    MatrixEvent(
      type: "m.room.message",
      eventID: id,
      sender: "@signal_x:correspondance.local",
      originServerTS: ts,
      content: try! JSONDecoder().decode(MatrixJSON.self, from: Data("{\"msgtype\": \"m.text\", \"body\": \"\(id)\"}".utf8))
    )
  }

  func testLimitedTimelineIsReportedAsGap() throws {
    let response = try sync(limited: true, prevBatch: "t42", otherRoom: true)
    let gaps = MatrixSyncParser.timelineGaps(in: response, rooms: [:])
    XCTAssertEqual(gaps, [.init(roomID: roomID, prevBatch: "t42", hasAnchor: false)])
  }

  func testCompleteTimelineIsNotAGap() throws {
    XCTAssertTrue(MatrixSyncParser.timelineGaps(in: try sync(limited: false, prevBatch: "t42"), rooms: [:]).isEmpty)
    XCTAssertTrue(MatrixSyncParser.timelineGaps(in: try sync(limited: nil, prevBatch: "t42"), rooms: [:]).isEmpty)
    // Sans curseur, rien à remonter — même si Synapse dit avoir tronqué.
    XCTAssertTrue(MatrixSyncParser.timelineGaps(in: try sync(limited: true, prevBatch: nil), rooms: [:]).isEmpty)
  }

  /// La borne se lit dans l'état **d'avant** la passe : un salon semé depuis le
  /// cache a une borne, un salon rejoint à l'instant n'en a pas.
  func testAnchorComesFromRoomsKnownBeforeApply() throws {
    let response = try sync(limited: true, prevBatch: "t42")
    var model = MatrixRoomModel(roomID: roomID)
    MatrixSyncParser(selfUserID: selfUserID).applyMessages([event("$old")], roomID: roomID, to: &model)
    let gaps = MatrixSyncParser.timelineGaps(in: response, rooms: [roomID: model])
    XCTAssertEqual(gaps.first?.hasAnchor, true)
  }

  /// Le critère d'arrêt de la pagination : une page qui n'apporte plus rien
  /// veut dire qu'on a rejoint l'historique connu. Une page mêlant du connu et
  /// du nouveau (trou ancien au milieu de l'historique) fait continuer.
  func testApplyMessagesReportsWhatThePageChanged() {
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    var model = MatrixRoomModel(roomID: roomID)
    XCTAssertEqual(
      parser.applyMessages([event("$a"), event("$b")], roomID: roomID, to: &model),
      .init(alreadyKnown: 0, added: 2)
    )
    XCTAssertEqual(
      parser.applyMessages([event("$c"), event("$b")], roomID: roomID, to: &model),
      .init(alreadyKnown: 1, added: 1)
    )
    XCTAssertEqual(
      parser.applyMessages([event("$a"), event("$b")], roomID: roomID, to: &model),
      .init(alreadyKnown: 2, added: 0)
    )
    XCTAssertEqual(model.messagesByID.count, 3, "la page se fusionne sans doublon")
  }
}
