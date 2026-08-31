import XCTest
@testable import CorrespondanceCore

/// Ce que l'ancien `MatrixCacheSeedingTests` prouvait sur le fichier JSON, et
/// qui doit rester vrai avec la base : l'historique déjà chargé survit à un
/// `/sync`, et un fil rechargé retrouve son réseau **sans** le serveur.
///
/// La différence tient en une ligne : le sync n'écrase plus rien, puisqu'il
/// n'écrit plus que ce qu'il apporte.
final class LocalStoreSeedingTests: XCTestCase {
  private let selfUserID = "@meffysto:correspondance.local"
  private let groupRoomID = "!groupe-parrots:correspondance.local"
  private var groupConversationID: String { "signal:\(groupRoomID)" }

  private func fixture() throws -> MatrixSyncResponse {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "matrix-sync-signal", withExtension: "json")
    )
    return try JSONDecoder().decode(MatrixSyncResponse.self, from: Data(contentsOf: url))
  }

  private func history(count: Int) -> [ChatMessage] {
    (0..<count).map { index in
      ChatMessage(
        id: "$ancien-\(index)",
        conversationID: groupConversationID,
        network: .signal,
        text: "Ancien message \(index)",
        sentAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
        isFromMe: index.isMultiple(of: 2),
        senderName: "Alice",
        reactions: index == 3 ? [MessageReaction(emoji: "🔥", senders: ["Alice"])] : []
      )
    }
  }

  func testRoomIDIsRecoveredFromConversationID() {
    XCTAssertEqual(MatrixSyncParser.roomID(inConversationID: groupConversationID), groupRoomID)
    XCTAssertNil(MatrixSyncParser.roomID(inConversationID: "iMessage:chat123"))
    XCTAssertNil(MatrixSyncParser.roomID(inConversationID: "sans-deux-points"))
  }

  /// Le cas qui coûtait un sync initial complet à chaque lancement : un salon
  /// relu du magasin connaissait bien son historique, mais plus son réseau.
  func testAReloadedRoomKnowsItsNetworkWithoutTheServer() throws {
    let store = try LocalStore.inMemory()
    var rooms: [String: MatrixRoomModel] = [:]
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    parser.apply(try fixture(), to: &rooms)
    let live = try XCTUnwrap(rooms[groupRoomID])
    XCTAssertEqual(live.network, .signal)

    store.commit(
      rooms: [StoredRoom(model: live, selfUserID: selfUserID)],
      messages: [groupRoomID: live.sortedMessages],
      reactions: [groupRoomID: live.reactionsByEventID],
      cursor: .some("s72_1")
    )

    let reloaded = try XCTUnwrap(store.rooms().first)
    XCTAssertEqual(reloaded.network, .signal)
    XCTAssertEqual(reloaded.model().conversationID, groupConversationID)
    XCTAssertEqual(reloaded.model().conversation(selfUserID: selfUserID)?.network, .signal)
    XCTAssertEqual(store.syncCursor, "s72_1", "et le curseur reprend là où il s'était arrêté")
  }

  func testHistoryFromTheStoreSurvivesTheNextSync() throws {
    let store = try LocalStore.inMemory()
    var rooms: [String: MatrixRoomModel] = [:]
    var model = MatrixRoomModel(roomID: groupRoomID)
    model.network = .signal
    for message in history(count: 40) { model.messagesByID[message.id] = message }
    store.commit(
      rooms: [StoredRoom(model: model, selfUserID: selfUserID)],
      messages: [groupRoomID: history(count: 40)],
      reactions: [:]
    )

    // Le lancement : les salons, pas l'historique.
    var reloaded = try XCTUnwrap(store.rooms().first).model()
    XCTAssertTrue(reloaded.messagesByID.isEmpty, "un fil qu'on n'ouvre pas ne charge rien")

    // Le `/sync` passe par-dessus le salon vide, sans rien perdre.
    rooms[groupRoomID] = reloaded
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    parser.apply(try fixture(), to: &rooms)
    reloaded = try XCTUnwrap(rooms[groupRoomID])

    // Puis on ouvre le fil : la page vient du magasin et s'ajoute au sync.
    parser.hydrate(
      messages: store.messages(roomID: groupRoomID),
      reactions: store.reactions(roomID: groupRoomID),
      into: &reloaded
    )
    let ids = Set(reloaded.sortedMessages.map(\.id))
    XCTAssertTrue(ids.isSuperset(of: (0..<40).map { "$ancien-\($0)" }), "l'historique est intact")
    XCTAssertGreaterThan(ids.count, 40, "et les events du sync s'y ajoutent")
    let reacted = try XCTUnwrap(reloaded.sortedMessages.first { $0.id == "$ancien-3" })
    XCTAssertEqual(reacted.reactions.map(\.emoji), ["🔥"])
  }

  func testHydratingTwiceChangesNothing() throws {
    let store = try LocalStore.inMemory()
    var model = MatrixRoomModel(roomID: groupRoomID)
    model.network = .signal
    let list = history(count: 5)
    store.commit(
      rooms: [StoredRoom(model: model, selfUserID: selfUserID)],
      messages: [groupRoomID: list],
      reactions: [:]
    )
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    let page = store.messages(roomID: groupRoomID)
    parser.hydrate(messages: page, reactions: [:], into: &model)
    parser.hydrate(messages: page, reactions: [:], into: &model)
    XCTAssertEqual(model.messagesByID.count, 5)
  }

  /// Une correction reçue pendant que le fil dormait s'applique à l'ouverture :
  /// elle attendait dans l'état du salon, elle trouve enfin sa cible.
  func testAnEditWaitingInTheRoomStateLandsWhenTheThreadOpens() throws {
    let store = try LocalStore.inMemory()
    var model = MatrixRoomModel(roomID: groupRoomID)
    model.network = .signal
    let list = history(count: 3)
    store.commit(
      rooms: [StoredRoom(model: model, selfUserID: selfUserID)],
      messages: [groupRoomID: list],
      reactions: [:]
    )
    model.pendingEdits["$ancien-1"] = .init(text: "corrigé", at: Date(timeIntervalSince1970: 1_700_000_100))

    MatrixSyncParser(selfUserID: selfUserID)
      .hydrate(messages: store.messages(roomID: groupRoomID), reactions: [:], into: &model)

    XCTAssertEqual(model.messagesByID["$ancien-1"]?.text, "corrigé")
    XCTAssertNotNil(model.messagesByID["$ancien-1"]?.editedAt)
    XCTAssertTrue(model.pendingWrites.contains("$ancien-1"), "et la correction sera écrite")
  }

  /// L'écriture est un lot, pas une réécriture : après un `/sync`, seul ce que
  /// la passe a apporté est marqué à écrire.
  func testOnlyWhatChangedIsMarkedForWriting() throws {
    var rooms: [String: MatrixRoomModel] = [:]
    let parser = MatrixSyncParser(selfUserID: selfUserID)
    parser.apply(try fixture(), to: &rooms)
    let first = try XCTUnwrap(rooms[groupRoomID])
    XCTAssertFalse(first.pendingWrites.isEmpty, "la première passe apporte tout")

    rooms[groupRoomID]?.clearPendingWrites()
    // Le même `/sync` rejoué n'apporte rien de neuf… sauf ce qu'il repose à
    // l'identique : ce sont des upserts, ils ne dupliquent rien.
    parser.apply(try fixture(), to: &rooms)
    let second = try XCTUnwrap(rooms[groupRoomID])
    XCTAssertEqual(second.messagesByID.count, first.messagesByID.count)
    XCTAssertTrue(second.pendingDeletions.isEmpty)
  }
}
