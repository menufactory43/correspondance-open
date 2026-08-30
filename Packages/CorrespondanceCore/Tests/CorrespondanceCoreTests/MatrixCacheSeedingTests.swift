import XCTest
@testable import CorrespondanceCore

/// À chaque lancement, l'app refait un sync initial — et Synapse n'y met qu'une
/// dizaine d'events par salon. Le cache disque doit donc être **semé** dans le
/// modèle avant ce sync, sinon `persist()` le réécrit presque vide et
/// l'historique backfillé disparaît à chaque rebuild.
final class MatrixCacheSeedingTests: XCTestCase {
  private let selfUserID = "@meffysto:correspondance.local"
  private let groupRoomID = "!groupe-parrots:correspondance.local"
  private var groupConversationID: String { "signal:\(groupRoomID)" }

  private func fixture() throws -> MatrixSyncResponse {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "matrix-sync-signal", withExtension: "json")
    )
    return try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(contentsOf: url))
  }

  private func cachedMessages(count: Int) -> [ChatMessage] {
    (0..<count).map { index in
      ChatMessage(
        id: "$cached-\(index)",
        conversationID: groupConversationID,
        network: .signal,
        text: "Ancien message \(index)",
        sentAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
        isFromMe: index.isMultiple(of: 2),
        reactions: index == 3 ? [MessageReaction(emoji: "🔥", senders: ["Alice"])] : []
      )
    }
  }

  func testRoomIDIsRecoveredFromConversationID() {
    XCTAssertEqual(MatrixSyncParser.roomID(inConversationID: groupConversationID), groupRoomID)
    XCTAssertNil(MatrixSyncParser.roomID(inConversationID: "iMessage:chat123"))
    XCTAssertNil(MatrixSyncParser.roomID(inConversationID: "sans-deux-points"))
  }

  func testInitialSyncAfterSeedingKeepsCachedHistory() throws {
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    var rooms: [String: MatrixRoomModel] = [:]
    parser.seed(cachedMessages: [groupConversationID: cachedMessages(count: 40)], into: &rooms)

    parser.apply(try fixture(), to: &rooms)

    let room = try XCTUnwrap(rooms[groupRoomID])
    XCTAssertEqual(room.network, .signal, "le sync installe l'état du salon par-dessus le semis")
    let ids = Set(room.sortedMessages.map(\.id))
    XCTAssertTrue(ids.isSuperset(of: (0..<40).map { "$cached-\($0)" }), "l'historique du cache survit au sync")
    XCTAssertGreaterThan(ids.count, 40, "et les events du sync s'y ajoutent")
    // Les réactions figées dans le cache restent visibles tant que le sync n'en
    // apporte pas de plus fraîches pour ce message.
    let reacted = try XCTUnwrap(room.sortedMessages.first { $0.id == "$cached-3" })
    XCTAssertEqual(reacted.reactions.map(\.emoji), ["🔥"])
  }

  func testSeedingIsIdempotentAndSkipsPendingSends() {
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    var rooms: [String: MatrixRoomModel] = [:]
    var list = cachedMessages(count: 5)
    list.append(
      ChatMessage(
        id: "txn-local-1",
        conversationID: groupConversationID,
        network: .signal,
        text: "jamais parti",
        sentAt: Date(),
        isFromMe: true,
        isPending: true
      )
    )
    parser.seed(cachedMessages: [groupConversationID: list], into: &rooms)
    parser.seed(cachedMessages: [groupConversationID: list], into: &rooms)
    XCTAssertEqual(rooms[groupRoomID]?.messagesByID.count, 5)
    XCTAssertNil(rooms[groupRoomID]?.messagesByID["txn-local-1"])
  }
}
