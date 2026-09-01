import XCTest
@testable import CorrespondanceCore

/// Le pont branché sur une base en mémoire, sans jamais toucher au Relais.
/// Ce qu'on prouve : au lancement l'inbox est complète et connaît ses réseaux,
/// les fils ne se chargent qu'à l'ouverture, et on remonte plus haut à la demande.
final class MatrixBridgeLocalStoreTests: XCTestCase {
  private let selfUserID = "@meffysto:correspondance.local"
  private let roomID = "!camille:correspondance.local"
  private var conversationID: String { "whatsapp:\(roomID)" }

  private func seededStore(messages count: Int) throws -> LocalStore {
    let store = try LocalStore.inMemory()
    var model = MatrixRoomModel(roomID: roomID)
    model.network = .whatsapp
    model.explicitName = "Camille"
    model.bridgeRoomType = "dm"
    model.unreadCount = 2
    let list = (0..<count).map { index in
      ChatMessage(
        id: "$m\(index)",
        conversationID: conversationID,
        network: .whatsapp,
        text: "Message \(index)",
        sentAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
        isFromMe: false,
        senderName: "Camille"
      )
    }
    for message in list { model.messagesByID[message.id] = message }
    store.commit(
      rooms: [StoredRoom(model: model, selfUserID: selfUserID)],
      messages: [roomID: list],
      reactions: [:],
      cursor: .some("s99_1")
    )
    return store
  }

  func testTheInboxIsCompleteAtLaunchWithoutTheRelay() async throws {
    let store = try seededStore(messages: 5)
    let service = MatrixBridgeService(credentials: nil, store: store)
    let conversations = await service.conversations()
    XCTAssertEqual(conversations.map(\.id), [conversationID])
    let camille = try XCTUnwrap(conversations.first)
    XCTAssertEqual(camille.network, .whatsapp, "le réseau vient de la base, pas du serveur")
    XCTAssertEqual(camille.title, "Camille")
    XCTAssertEqual(camille.unreadCount, 2)
    XCTAssertEqual(camille.preview, "Message 4", "l'aperçu est le dernier message")
  }

  func testAThreadLoadsItsHistoryOnlyWhenOpened() async throws {
    let store = try seededStore(messages: 400)
    let service = MatrixBridgeService(credentials: nil, store: store)

    // Le lancement : une ligne d'inbox, un seul message en mémoire.
    _ = await service.conversations()
    let firstPage = await service.messages(conversationID: conversationID)
    XCTAssertEqual(
      firstPage.count,
      MatrixBridgeService.historyPageSize,
      "l'ouverture charge une page, pas les quatre cents messages"
    )
    XCTAssertEqual(firstPage.last?.id, "$m399", "et c'est la queue du fil")

    // On remonte : la page suivante vient du magasin.
    let older = await service.loadOlderMessages(conversationID: conversationID)
    XCTAssertEqual(older.count, 100)
    let full = await service.messages(conversationID: conversationID)
    XCTAssertEqual(full.count, 400)
    XCTAssertEqual(full.first?.id, "$m0")

    // Et il n'y a plus rien au-dessus.
    let none = await service.loadOlderMessages(conversationID: conversationID)
    XCTAssertTrue(none.isEmpty)
  }

  func testTheCursorComesBackFromTheBase() async throws {
    let store = try seededStore(messages: 3)
    let service = MatrixBridgeService(credentials: nil, store: store)
    _ = await service.conversations()
    XCTAssertEqual(store.syncCursor, "s99_1")
  }

  /// La porte de secours : tout se vide, base comprise.
  func testReloadingFromTheRelayEmptiesEverything() async throws {
    let store = try seededStore(messages: 3)
    let service = MatrixBridgeService(credentials: nil, store: store)
    _ = await service.conversations()
    await service.reloadFromRelay()
    let remaining = await service.conversations()
    XCTAssertTrue(remaining.isEmpty)
    XCTAssertEqual(store.roomCount(), 0)
    XCTAssertNil(store.syncCursor)
  }

  /// Le visage d'un membre se demande à froid : le fil d'un groupe se dessine
  /// depuis le disque avant la première passe `/sync`, et c'est à ce moment-là
  /// qu'il réclame ses photos. Un actor qui n'aurait pas encore relu ses salons
  /// répondrait « personne » — et le Mac gardait cette réponse toute la session.
  func testMembersAreKnownBeforeAnySyncOrConversationListing() async throws {
    let store = try LocalStore.inMemory()
    var model = MatrixRoomModel(roomID: roomID)
    model.network = .signal
    model.explicitName = "Les voisins"
    model.bridgeRoomType = "group"
    model.members["@signal_1:correspondance.local"] = .init(
      displayName: "Camille", membership: "join", avatarMXC: "mxc://relais/camille"
    )
    model.members[selfUserID] = .init(displayName: "meffysto", membership: "join")
    store.commit(
      rooms: [StoredRoom(model: model, selfUserID: selfUserID)],
      messages: [:], reactions: [:], cursor: .some("s1")
    )
    let service = MatrixBridgeService(credentials: nil, store: store)

    // Premier appel de la session, sans `conversations()` ni `/sync` avant lui.
    // (Sans identifiants, le service ne connaît pas encore « moi » : on cherche
    // Camille, sans supposer que je sois filtré.)
    let members = await service.members(conversationID: "signal:\(roomID)")
    let camille = members.first { $0.userID == "@signal_1:correspondance.local" }
    XCTAssertEqual(camille?.avatarMXC, "mxc://relais/camille")
    let hasAgent = await service.hasAgent(conversationID: "signal:\(roomID)")
    XCTAssertFalse(hasAgent)
  }
}
