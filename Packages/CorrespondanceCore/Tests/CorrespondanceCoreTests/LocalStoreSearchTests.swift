import XCTest
@testable import CorrespondanceCore

/// La recherche des fils du Relais, posée sur FTS5. Ce qu'on veut prouver :
/// on trouve dans une conversation **jamais ouverte**, et l'index suit les
/// messages qui changent ou disparaissent.
final class LocalStoreSearchTests: XCTestCase {
  private let selfUserID = "@meffysto:correspondance.local"
  private let roomID = "!camille:correspondance.local"
  private var conversationID: String { "whatsapp:\(roomID)" }

  private func makeStore() throws -> LocalStore {
    let store = try LocalStore.inMemory()
    var model = MatrixRoomModel(roomID: roomID)
    model.network = .whatsapp
    model.explicitName = "Camille"
    model.bridgeRoomType = "dm"
    store.commit(
      rooms: [StoredRoom(model: model, selfUserID: selfUserID)],
      messages: [roomID: corpus()],
      reactions: [:]
    )
    return store
  }

  private var conversation: Conversation {
    Conversation(
      id: conversationID,
      network: .whatsapp,
      address: roomID,
      title: "Camille",
      preview: "",
      lastMessageAt: Date(timeIntervalSince1970: 1_700_000_100),
      unreadCount: 0,
      isArchived: false,
      transportKey: roomID,
      isGroup: false
    )
  }

  private func message(
    _ id: String,
    _ text: String,
    at offset: Double,
    attachments: [MessageAttachment] = []
  ) -> ChatMessage {
    ChatMessage(
      id: id,
      conversationID: conversationID,
      network: .whatsapp,
      text: text,
      sentAt: Date(timeIntervalSince1970: 1_700_000_000 + offset),
      isFromMe: false,
      senderName: "Camille",
      attachments: attachments
    )
  }

  private func corpus() -> [ChatMessage] {
    [
      message("$1", "On se retrouve au restaurant à l'école ?", at: 1),
      message("$2", "", at: 2, attachments: [
        MessageAttachment(id: "mxc://s/1", contentType: "image/jpeg", filename: "vacances.jpg")
      ]),
      message("$3", "", at: 3, attachments: [
        MessageAttachment(id: "mxc://s/2", contentType: "video/mp4", filename: "plage.mp4")
      ]),
      message("$4", "", at: 4, attachments: [
        MessageAttachment(id: "mxc://s/3", contentType: "application/pdf", filename: "devis.pdf")
      ]),
      message("$5", "l'article : https://exemple.fr/article", at: 5),
      message("$6", "rien à voir", at: 6),
    ]
  }

  // MARK: - Plein texte

  func testFindsAMessageInAThreadThatWasNeverOpened() throws {
    let store = try makeStore()
    let hits = store.search(query: "restaurant")
    XCTAssertEqual(hits.map(\.message.id), ["$1"])
    XCTAssertEqual(hits.first?.conversationID, conversationID)
  }

  func testAccentsAndCaseDoNotMatter() throws {
    let store = try makeStore()
    XCTAssertEqual(store.search(query: "ECOLE").map(\.message.id), ["$1"])
    XCTAssertEqual(store.search(query: "école").map(\.message.id), ["$1"])
  }

  func testAPrefixIsEnough() throws {
    let store = try makeStore()
    XCTAssertEqual(store.search(query: "restau").map(\.message.id), ["$1"])
  }

  func testAFilenameIsSearchable() throws {
    let store = try makeStore()
    XCTAssertEqual(store.search(query: "devis").map(\.message.id), ["$4"])
  }

  /// Une question pleine de ponctuation ne doit pas faire tomber FTS5 : on ne
  /// lui passe jamais la saisie telle quelle.
  func testPunctuationDoesNotBreakTheQuery() throws {
    let store = try makeStore()
    XCTAssertNoThrow(store.search(query: "c'est-à-dire \"NEAR\" -*"))
    XCTAssertEqual(LocalStore.ftsQuery("c'est-à-dire"), "\"c\"* \"est\"* \"à\"* \"dire\"*")
    XCTAssertEqual(LocalStore.ftsQuery("   "), "")
  }

  func testAnEmptyQueryWithoutAFacetFindsNothing() throws {
    XCTAssertTrue(try makeStore().search(query: "").isEmpty)
  }

  // MARK: - Onglets

  func testEachFacetCatchesItsOwn() throws {
    let store = try makeStore()
    let hits: (MessageFacet) -> [String] = { facet in
      store.facetHits(in: [self.conversation], facet: facet).map(\.message.id)
    }
    XCTAssertEqual(hits(.images), ["$2"])
    XCTAssertEqual(hits(.videos), ["$3"])
    XCTAssertEqual(hits(.files), ["$4"], "ni image ni vidéo : un fichier")
    XCTAssertEqual(hits(.links), ["$5"])
    XCTAssertTrue(hits(.drafts).isEmpty, "un brouillon n'est pas dans le fil")
  }

  func testAFacetNarrowsWithTheQuery() throws {
    let store = try makeStore()
    XCTAssertEqual(
      store.facetHits(in: [conversation], facet: .images, query: "vacances").map(\.message.id),
      ["$2"]
    )
    XCTAssertTrue(store.facetHits(in: [conversation], facet: .images, query: "plage").isEmpty)
  }

  func testAnIMessageThreadIsNeverAnsweredByThisBase() throws {
    let store = try makeStore()
    var imessage = conversation
    imessage = Conversation(
      id: "imessage:+33612345678",
      network: .iMessage,
      address: "+33612345678",
      title: "Camille",
      preview: "",
      lastMessageAt: .distantPast,
      unreadCount: 0,
      isArchived: false,
      transportKey: "chat123",
      isGroup: false
    )
    XCTAssertTrue(store.facetHits(in: [imessage], facet: .images).isEmpty)
  }

  // MARK: - L'index suit

  func testTheIndexFollowsAnEditAndARedaction() throws {
    let store = try makeStore()
    var corrected = message("$1", "On se retrouve à la piscine", at: 1)
    corrected.editedAt = Date()
    store.commit(rooms: [], messages: [roomID: [corrected]], reactions: [:])
    XCTAssertTrue(store.search(query: "restaurant").isEmpty, "l'ancien texte ne se trouve plus")
    XCTAssertEqual(store.search(query: "piscine").map(\.message.id), ["$1"])

    store.commit(rooms: [], messages: [:], reactions: [:], deletedEventIDs: ["$1"])
    XCTAssertTrue(store.search(query: "piscine").isEmpty, "un message rédigé sort de l'index")
  }

  /// La migration v2 se joue sur une base déjà remplie : l'index doit repartir
  /// de ce qui s'y trouve, pas seulement de ce qui arrivera après.
  func testTheIndexIsBuiltFromWhatWasAlreadyThere() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("fts-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try LocalStore(path: url.path)
    var model = MatrixRoomModel(roomID: roomID)
    model.network = .whatsapp
    store.commit(
      rooms: [StoredRoom(model: model, selfUserID: selfUserID)],
      messages: [roomID: corpus()],
      reactions: [:]
    )
    // Rouvrir la base rejoue le chemin complet, migrations comprises.
    let reopened = try LocalStore(path: url.path)
    XCTAssertEqual(reopened.search(query: "restaurant").map(\.message.id), ["$1"])
  }

  func testTheListIndexOnlyCarriesWhatTheQuestionFound() throws {
    let store = try makeStore()
    let index = store.searchIndex(query: "restaurant")
    XCTAssertEqual(index.keys.sorted(), [conversationID])
    XCTAssertEqual(
      ConversationSearch.filter([conversation], query: "restaurant", index: index).map(\.id),
      [conversationID]
    )
    XCTAssertTrue(ConversationSearch.filter([conversation], query: "aquarium", index: [:]).isEmpty)
  }
}
