import XCTest
@testable import CorrespondanceCore

/// Caractérisation : un `/sync` porteur de tags, d'account data et de push rules
/// donne l'état de conversation que l'inbox affichera. Aucun réseau.
final class ConversationStateSnapshotTests: XCTestCase {
  private let alice = "!dm-alice:correspondance.local"
  private let bob = "!dm-bob:correspondance.local"
  private let groupe = "!groupe-vacances:correspondance.local"

  private func loadFixture(_ name: String = "matrix-sync-conversation-state") throws -> MatrixSyncResponse {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: name, withExtension: "json"),
      "fixture \(name).json absente du bundle de test"
    )
    return try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(contentsOf: url))
  }

  private func snapshot() throws -> ConversationStateSnapshot {
    var state = ConversationStateSnapshot()
    MatrixSyncParser(selfUserID: "@meffysto:correspondance.local")
      .applyConversationState(try loadFixture(), to: &state)
    return state
  }

  func testFavouriteTagMeansPinned() throws {
    XCTAssertEqual(try snapshot().pinned, [alice, groupe])
  }

  func testOurTagMeansArchived() throws {
    XCTAssertEqual(try snapshot().archived, [bob, groupe])
  }

  /// La sourdine vient des push rules : actions vides, ou `dont_notify` hérité.
  /// Une règle désactivée ne mute pas, une règle qui notifie non plus.
  func testMutedComesFromPushRules() throws {
    XCTAssertEqual(
      try snapshot().muted,
      ["!muet-actions-vides:correspondance.local", "!muet-dont-notify:correspondance.local"]
    )
  }

  func testDraftIsReadFromRoomAccountData() throws {
    XCTAssertEqual(try snapshot().drafts, [alice: "je te rappelle demain"])
  }

  func testHiddenEventIDsAreReadFromRoomAccountData() throws {
    XCTAssertEqual(try snapshot().hidden, [bob: ["$evt-a", "$evt-b"]])
  }

  func testMergedContactsSurviveTheRoundTrip() throws {
    let stored = try XCTUnwrap(try snapshot().mergedContacts)
    XCTAssertEqual(stored.merged.count, 1)
    XCTAssertEqual(stored.merged[0].title, "Alice")
    XCTAssertEqual(stored.merged[0].memberIDs, ["iMessage:+33600000001", "whatsapp:!dm-alice:correspondance.local"])
    XCTAssertEqual(stored.dismissedPairs, ["iMessage:+33600000002|signal:!dm-bob:correspondance.local"])
  }

  func testARoomWithoutAccountDataCarriesNoState() throws {
    let state = try snapshot()
    let mystere = "!sans-etat:correspondance.local"
    XCTAssertFalse(state.pinned.contains(mystere))
    XCTAssertFalse(state.archived.contains(mystere))
    XCTAssertNil(state.drafts[mystere])
  }

  /// `/sync` incrémental : ce qui n'est pas renvoyé garde sa valeur, ce qui l'est
  /// remplace. Un `m.tag` vide désépingle donc vraiment.
  func testAnEmptyTagEventClearsTheRoomsTags() throws {
    var state = try snapshot()
    let incremental = MatrixSyncResponse(
      nextBatch: "s2",
      rooms: .init(join: [
        alice: makeRoom(events: [MatrixEvent(type: "m.tag", content: .object(["tags": .object([:])]))])
      ])
    )
    state.apply(incremental)
    XCTAssertFalse(state.pinned.contains(alice))
    XCTAssertEqual(state.pinned, [groupe])
    // Le brouillon, lui, n'était pas dans ce sync : il reste.
    XCTAssertEqual(state.drafts[alice], "je te rappelle demain")
  }

  func testAnEmptyDraftClearsIt() throws {
    var state = try snapshot()
    state.apply(MatrixSyncResponse(nextBatch: "s2", rooms: .init(join: [
      alice: makeRoom(events: [MatrixEvent(type: ConversationStateKeys.draftType, content: ConversationStateCodec.draftContent(text: ""))])
    ])))
    XCTAssertNil(state.drafts[alice])
  }

  func testLeavingARoomForgetsItsState() throws {
    var state = try snapshot()
    state.apply(MatrixSyncResponse(nextBatch: "s2", rooms: .init(join: nil, leave: [bob: .object([:])])))
    XCTAssertFalse(state.archived.contains(bob))
    XCTAssertNil(state.hidden[bob])
  }

  // MARK: - Codec

  func testDraftContentIsTextOnly() {
    XCTAssertEqual(encoded(ConversationStateCodec.draftContent(text: "salut")), "{\"text\":\"salut\"}")
  }

  func testHiddenContentIsSorted() {
    XCTAssertEqual(
      encoded(ConversationStateCodec.hiddenContent(eventIDs: ["$b", "$a"])),
      "{\"event_ids\":[\"$a\",\"$b\"]}"
    )
  }

  func testMergedContactsEncodeThenDecode() throws {
    let stored = MergedContactStore.Stored(
      merged: [MergedContact(
        id: "merged:1",
        title: "Alice",
        memberIDs: ["iMessage:+33600000001", "whatsapp:!dm:correspondance.local"],
        defaultConversationID: "whatsapp:!dm:correspondance.local"
      )],
      dismissedPairs: ["a|b"]
    )
    let content = try XCTUnwrap(ConversationStateCodec.mergedContactsContent(stored))
    XCTAssertEqual(ConversationStateCodec.mergedContacts(in: content), stored)
  }

  // MARK: -

  private func makeRoom(events: [MatrixEvent]) -> MatrixSyncResponse.JoinedRoom {
    let json = """
    {"account_data":{"events":[]}}
    """
    var room = try! JSONDecoder().decode(MatrixSyncResponse.JoinedRoom.self, from: Data(json.utf8))
    room.accountData = MatrixSyncResponse.AccountData(events: events)
    return room
  }

  private func encoded(_ json: MatrixJSON) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(data: (try? encoder.encode(json)) ?? Data(), encoding: .utf8) ?? ""
  }
}
