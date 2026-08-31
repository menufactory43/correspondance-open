import XCTest
@testable import CorrespondanceCore

/// Le magasin local, exercé sur une base en mémoire — aucun test ne touche au
/// Relais ni au disque de l'utilisateur.
final class LocalStoreTests: XCTestCase {
  private let selfUserID = "@meffysto:correspondance.local"
  private let roomID = "!parrots:correspondance.local"

  private func makeStore() throws -> LocalStore { try LocalStore.inMemory() }

  private func makeRoom(messages count: Int = 0) -> (StoredRoom, [ChatMessage]) {
    var model = MatrixRoomModel(roomID: roomID)
    model.network = .signal
    model.explicitName = "Les perruches"
    model.bridgeRoomType = "group"
    model.unreadCount = 3
    model.members = [
      "@signal_alice:correspondance.local": .init(displayName: "Alice", membership: "join", avatarMXC: "mxc://s/a"),
      "@signal_bruno:correspondance.local": .init(displayName: "Bruno", membership: "join", avatarMXC: nil),
    ]
    let list = (0..<count).map { index in
      ChatMessage(
        id: "$m\(index)",
        conversationID: "signal:\(roomID)",
        network: .signal,
        text: "Message \(index)",
        sentAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
        isFromMe: index.isMultiple(of: 3),
        senderName: "Alice",
        attachments: index == 2
          ? [MessageAttachment(id: "mxc://s/photo", contentType: "image/jpeg", filename: "vacances.jpg")]
          : []
      )
    }
    for message in list { model.messagesByID[message.id] = message }
    model.lastEventAt = list.last?.sentAt ?? .distantPast
    return (StoredRoom(model: model, selfUserID: selfUserID), list)
  }

  // MARK: - Schéma

  func testSchemaIsVersionedAndMigratedOnce() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("store-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try LocalStore(path: url.path)
    XCTAssertEqual(store.installedSchemaVersion, LocalStore.schemaVersion)
    // Rouvrir ne rejoue rien : la base retient où elle en est.
    let again = try LocalStore(path: url.path)
    XCTAssertEqual(again.installedSchemaVersion, LocalStore.schemaVersion)
    XCTAssertEqual(
      try again.database.scalarInt("SELECT COUNT(*) FROM schema_version;"),
      Int64(LocalStore.schemaVersion)
    )
  }

  // MARK: - Salons

  func testRoomSurvivesTheRoundTripWithItsNetworkAndMembers() throws {
    let store = try makeStore()
    let (room, messages) = makeRoom(messages: 4)
    store.commit(rooms: [room], messages: [roomID: messages], reactions: [:])

    let reloaded = try XCTUnwrap(store.rooms().first)
    XCTAssertEqual(reloaded.network, .signal, "un salon rechargé sait de quel réseau il vient")
    XCTAssertEqual(reloaded.conversationID, "signal:\(roomID)")
    XCTAssertEqual(reloaded.title, "Les perruches")
    XCTAssertEqual(reloaded.unreadCount, 3)
    XCTAssertTrue(reloaded.isGroup)
    XCTAssertEqual(reloaded.preview, messages.last?.listPreview(isGroup: true))

    // Et le modèle se reconstruit avec ses membres : sans eux, un curseur repris
    // laisserait un salon anonyme.
    let model = reloaded.model()
    XCTAssertEqual(model.members.count, 2)
    XCTAssertEqual(model.remoteMembers(selfUserID: selfUserID).count, 2)
    XCTAssertEqual(model.conversation(selfUserID: selfUserID)?.title, "Les perruches")
  }

  func testUpsertRewritesOnlyWhatChanged() throws {
    let store = try makeStore()
    var (room, messages) = makeRoom(messages: 3)
    store.commit(rooms: [room], messages: [roomID: messages], reactions: [:])
    room.unreadCount = 0
    room.title = "Perruches & compagnie"
    store.commit(rooms: [room], messages: [:], reactions: [:])

    XCTAssertEqual(store.roomCount(), 1)
    XCTAssertEqual(store.rooms().first?.title, "Perruches & compagnie")
    XCTAssertEqual(store.rooms().first?.unreadCount, 0)
    XCTAssertEqual(store.messageCount(roomID: roomID), 3, "les messages ne bougent pas")
    messages = []
  }

  func testLeavingARoomTakesItsMessagesAlong() throws {
    let store = try makeStore()
    let (room, messages) = makeRoom(messages: 5)
    store.commit(rooms: [room], messages: [roomID: messages], reactions: [:])
    store.deleteRooms([roomID])
    XCTAssertEqual(store.roomCount(), 0)
    XCTAssertEqual(store.messageCount(roomID: roomID), 0)
  }

  // MARK: - Messages

  func testMessagesComeBackAsAPageNewestFirstButReadOldestFirst() throws {
    let store = try makeStore()
    let (room, messages) = makeRoom(messages: 50)
    store.commit(rooms: [room], messages: [roomID: messages], reactions: [:])

    let page = store.messages(roomID: roomID, limit: 10)
    XCTAssertEqual(page.count, 10)
    XCTAssertEqual(page.map(\.id), (40..<50).map { "$m\($0)" }, "la page est la queue du fil, dans l'ordre")

    let older = store.messages(roomID: roomID, limit: 10, before: page[0].sentAt)
    XCTAssertEqual(older.map(\.id), (30..<40).map { "$m\($0)" }, "et on remonte plus haut à la demande")
  }

  func testEverythingAMessageCarriesSurvives() throws {
    let store = try makeStore()
    let (room, _) = makeRoom()
    let rich = ChatMessage(
      id: "$riche",
      conversationID: "signal:\(roomID)",
      network: .signal,
      text: "Regarde ça",
      sentAt: Date(timeIntervalSince1970: 1_700_000_500),
      isFromMe: false,
      senderID: "@signal_alice:correspondance.local",
      senderName: "Alice",
      attachments: [
        MessageAttachment(
          id: "mxc://s/vocal",
          contentType: "audio/ogg",
          filename: "note.ogg",
          voice: VoiceNote(duration: 4, waveform: [0.1, 0.9])
        )
      ],
      replyTo: QuotedMessage(messageID: "$m0", senderName: "Bruno", text: "quoi ?"),
      linkPreview: BridgedLinkPreview(url: "https://exemple.fr", title: "Exemple"),
      editedAt: Date(timeIntervalSince1970: 1_700_000_600),
      editHistory: ["Regarde"],
      poll: Poll(question: "On y va ?", answers: [.init(id: "oui", text: "Oui")])
    )
    store.commit(rooms: [room], messages: [roomID: [rich]], reactions: [:])

    let reloaded = try XCTUnwrap(store.messages(roomID: roomID).first)
    XCTAssertEqual(reloaded.text, "Regarde ça")
    XCTAssertEqual(reloaded.senderName, "Alice")
    XCTAssertEqual(reloaded.attachments.first?.voice?.duration, 4)
    XCTAssertEqual(reloaded.replyTo?.senderName, "Bruno")
    XCTAssertEqual(reloaded.linkPreview?.title, "Exemple")
    XCTAssertEqual(reloaded.editHistory, ["Regarde"])
    XCTAssertEqual(reloaded.poll?.question, "On y va ?")
  }

  func testAPendingSendIsNeverWritten() throws {
    let store = try makeStore()
    let (room, _) = makeRoom()
    let inFlight = ChatMessage(
      id: "txn-local-1",
      conversationID: "signal:\(roomID)",
      network: .signal,
      text: "jamais parti",
      sentAt: Date(),
      isFromMe: true,
      isPending: true
    )
    store.commit(rooms: [room], messages: [roomID: [inFlight]], reactions: [:])
    XCTAssertEqual(store.messageCount(roomID: roomID), 0)
  }

  func testLastMessagesGiveOneLinePerRoom() throws {
    let store = try makeStore()
    let (room, messages) = makeRoom(messages: 20)
    store.commit(rooms: [room], messages: [roomID: messages], reactions: [:])
    let last = store.lastMessages()
    XCTAssertEqual(last.count, 1)
    XCTAssertEqual(last[roomID]?.id, "$m19")
  }

  // MARK: - Réactions

  func testAReactionIsRemovedOnItsOwn() throws {
    let store = try makeStore()
    let (room, messages) = makeRoom(messages: 2)
    let reactions = [
      "$r1": MatrixRoomModel.ReactionEvent(
        targetEventID: "$m0", emoji: "🔥", senderID: "@a:s", senderName: "Alice", isMine: false
      ),
      "$r2": MatrixRoomModel.ReactionEvent(
        targetEventID: "$m0", emoji: "👍", senderID: "@b:s", senderName: "Bruno", isMine: false
      ),
    ]
    store.commit(rooms: [room], messages: [roomID: messages], reactions: [roomID: reactions])
    XCTAssertEqual(store.reactions(roomID: roomID).count, 2)

    store.commit(rooms: [], messages: [:], reactions: [:], deletedEventIDs: ["$r1"])
    XCTAssertEqual(store.reactions(roomID: roomID).map(\.key), ["$r2"])
  }

  // MARK: - Curseur

  func testTheCursorOnlyMovesWithItsBatch() throws {
    let store = try makeStore()
    XCTAssertNil(store.syncCursor)
    let (room, messages) = makeRoom(messages: 2)
    store.commit(rooms: [room], messages: [roomID: messages], reactions: [:], cursor: .some("s72_1"))
    XCTAssertEqual(store.syncCursor, "s72_1")
    // Un lot sans curseur ne touche pas au curseur.
    store.commit(rooms: [room], messages: [:], reactions: [:])
    XCTAssertEqual(store.syncCursor, "s72_1")
  }

  func testResetEmptiesEverything() throws {
    let store = try makeStore()
    let (room, messages) = makeRoom(messages: 5)
    store.commit(rooms: [room], messages: [roomID: messages], reactions: [:], cursor: .some("s72_1"))
    store.reset()
    XCTAssertEqual(store.roomCount(), 0)
    XCTAssertEqual(store.messageCount(roomID: roomID), 0)
    XCTAssertNil(store.syncCursor)
    XCTAssertEqual(store.installedSchemaVersion, LocalStore.schemaVersion, "le schéma reste en place")
  }
}
