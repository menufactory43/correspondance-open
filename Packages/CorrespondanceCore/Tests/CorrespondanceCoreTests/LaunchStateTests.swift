import XCTest
@testable import CorrespondanceCore

/// Ce qui rend l'app à jour et fluide dès son ouverture, comme Signal : la base
/// fait foi. L'état de conversation (archive, épingles, fusions) est relu de
/// la base avec son curseur, et le rattrapage d'un trou s'arrête sur ce que
/// la base connaît déjà.
final class LaunchStateTests: XCTestCase {
  private let selfUserID = "@meffysto:correspondance.local"
  private let roomID = "!camille:correspondance.local"

  private func seededStore(conversationState: ConversationStateSnapshot?) throws -> LocalStore {
    let store = try LocalStore.inMemory()
    var model = MatrixRoomModel(roomID: roomID)
    model.network = .whatsapp
    model.explicitName = "Camille"
    let message = ChatMessage(
      id: "$vieux",
      conversationID: "whatsapp:\(roomID)",
      network: .whatsapp,
      text: "déjà là",
      sentAt: Date(timeIntervalSince1970: 1_700_000_000),
      isFromMe: false,
      senderName: "Camille"
    )
    let json = try conversationState.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
    store.commit(
      rooms: [StoredRoom(model: model, selfUserID: selfUserID)],
      messages: [roomID: [message]],
      reactions: [:],
      cursor: .some("s99_1"),
      conversationState: json
    )
    return store
  }

  func testTheConversationStateComesBackFromTheBase() async throws {
    var saved = ConversationStateSnapshot(archived: [roomID], pinned: [], muted: [roomID])
    saved.archiveSilenced = [roomID]
    let service = MatrixBridgeService(credentials: nil, store: try seededStore(conversationState: saved))
    let restored = await service.conversationState
    XCTAssertEqual(restored, saved, "l'archive et les muets sont là avant tout `/sync`")
    let isRestored = await service.conversationStateIsRestored
    XCTAssertTrue(isRestored, "inutile de relire tout le Relais au lancement")
  }

  func testWithoutASavedStateTheRelayIsReadInFull() async throws {
    let service = MatrixBridgeService(credentials: nil, store: try seededStore(conversationState: nil))
    let isRestored = await service.conversationStateIsRestored
    XCTAssertFalse(isRestored, "un appareil qui n'a rien gardé relit le Relais")
    let state = await service.conversationState
    XCTAssertEqual(state, ConversationStateSnapshot())
  }

  func testTheBaseTellsWhichEventsItAlreadyHas() throws {
    let store = try seededStore(conversationState: nil)
    XCTAssertEqual(store.knownEventIDs(["$vieux", "$neuf"]), ["$vieux"])
    XCTAssertEqual(store.knownEventIDs([]), [])
  }
}
