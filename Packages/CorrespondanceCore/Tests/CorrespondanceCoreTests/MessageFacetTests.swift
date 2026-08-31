import XCTest
@testable import CorrespondanceCore

/// Les onglets de la recherche : rien ne doit tomber entre deux.
final class MessageFacetTests: XCTestCase {
  private func message(
    _ id: String,
    text: String = "",
    at seconds: TimeInterval = 0,
    sender: String? = nil,
    attachments: [MessageAttachment] = []
  ) -> ChatMessage {
    ChatMessage(
      id: id,
      conversationID: "whatsapp:!x:s",
      network: .whatsapp,
      text: text,
      sentAt: Date(timeIntervalSince1970: 1_756_400_000 + seconds),
      isFromMe: false,
      senderName: sender,
      attachments: attachments
    )
  }

  private func conversation(
    _ id: String, _ title: String, _ network: MessageNetwork, _ seconds: TimeInterval
  ) -> Conversation {
    Conversation(
      id: id,
      network: network,
      address: "",
      title: title,
      preview: "",
      lastMessageAt: Date(timeIntervalSince1970: seconds),
      unreadCount: 0,
      isArchived: false,
      transportKey: id,
      isGroup: false
    )
  }

  private func attachment(_ id: String, _ type: String, filename: String? = nil) -> MessageAttachment {
    MessageAttachment(id: id, contentType: type, filename: filename)
  }

  // MARK: - Le tri

  func testEachFacetCatchesItsOwn() {
    let photo = message("1", attachments: [attachment("a", "image/jpeg")])
    let video = message("2", attachments: [attachment("b", "video/mp4")])
    let pdf = message("3", attachments: [attachment("c", "application/pdf", filename: "devis.pdf")])
    let vocal = message("4", attachments: [attachment("d", "audio/ogg")])
    let link = message("5", text: "regarde https://exemple.fr/article")
    let plain = message("6", text: "à tout à l'heure")

    XCTAssertTrue(FacetedSearch.matches(photo, facet: .images))
    XCTAssertTrue(FacetedSearch.matches(video, facet: .videos))
    XCTAssertTrue(FacetedSearch.matches(link, facet: .links))
    // Un vocal et un PDF sont des fichiers : aucun onglet ne leur est dédié,
    // et rien ne doit disparaître entre deux.
    XCTAssertTrue(FacetedSearch.matches(pdf, facet: .files))
    XCTAssertTrue(FacetedSearch.matches(vocal, facet: .files))

    // Et chacun reste chez soi.
    XCTAssertFalse(FacetedSearch.matches(photo, facet: .files))
    XCTAssertFalse(FacetedSearch.matches(video, facet: .files))
    XCTAssertFalse(FacetedSearch.matches(pdf, facet: .images))
    XCTAssertFalse(FacetedSearch.matches(plain, facet: .links))
    for facet in MessageFacet.allCases {
      XCTAssertFalse(FacetedSearch.matches(plain, facet: facet), "\(facet) attrape un texte nu")
    }
  }

  /// Un brouillon n'est pas dans le fil : aucun message ne peut l'être.
  func testDraftsAreNeverAMessage() {
    let any = message("1", text: "coucou", attachments: [attachment("a", "image/jpeg")])
    XCTAssertFalse(FacetedSearch.matches(any, facet: .drafts))
    XCTAssertTrue(MessageFacet.drafts.isConversationFacet)
    XCTAssertFalse(MessageFacet.images.isConversationFacet)
  }

  // MARK: - L'ordre et la requête

  /// Le plus récent d'abord : on cherche presque toujours quelque chose de récent.
  func testResultsComeNewestFirst() {
    let list = [
      message("vieux", at: 0, attachments: [attachment("a", "image/png")]),
      message("recent", at: 5_000, attachments: [attachment("b", "image/png")]),
      message("moyen", at: 1_000, attachments: [attachment("c", "image/png")]),
    ]
    XCTAssertEqual(
      FacetedSearch.messages(list, facet: .images).map(\.id),
      ["recent", "moyen", "vieux"]
    )
  }

  /// Un onglet seul est déjà une recherche : sans requête, tout ce qu'il y a.
  func testFacetWithoutQueryReturnsEverything() {
    let list = [message("1", attachments: [attachment("a", "image/png")])]
    XCTAssertEqual(FacetedSearch.messages(list, facet: .images, query: "  ").count, 1)
  }

  /// La requête cherche dans le texte, l'auteur ET le nom du fichier — chercher
  /// « devis » doit trouver le PDF, dont le nom est tout ce qu'on en connaît.
  func testQueryReachesTheFilenameAndTheSender() {
    let list = [
      message("pdf", attachments: [attachment("a", "application/pdf", filename: "Devis-terrasse.pdf")]),
      message("autre", attachments: [attachment("b", "application/pdf", filename: "facture.pdf")]),
      message("vocal", sender: "Éléonore", attachments: [attachment("c", "audio/ogg")]),
    ]
    XCTAssertEqual(FacetedSearch.messages(list, facet: .files, query: "devis").map(\.id), ["pdf"])
    // Sans accent ni casse : « eleonore » trouve « Éléonore ».
    XCTAssertEqual(FacetedSearch.messages(list, facet: .files, query: "eleonore").map(\.id), ["vocal"])
  }

  // MARK: - Brouillons

  func testDraftsListOnlyKeepsWhatWasActuallyWritten() {
    let conversations = [
      conversation("a", "Alice", .whatsapp, 10),
      conversation("b", "Bruno", .signal, 20),
      conversation("c", "Carla", .signal, 30),
    ]
    // Un brouillon fait de blancs n'est pas un brouillon.
    let drafts = ["a": "je te réponds ce soir", "b": "   ", "c": "à demain"]
    XCTAssertEqual(
      FacetedSearch.conversationsWithDrafts(conversations, drafts: drafts).map(\.id),
      ["c", "a"]
    )
    XCTAssertEqual(
      FacetedSearch.conversationsWithDrafts(conversations, drafts: drafts, query: "soir").map(\.id),
      ["a"]
    )
    // La requête porte aussi sur le nom du fil, pas seulement sur le brouillon.
    XCTAssertEqual(
      FacetedSearch.conversationsWithDrafts(conversations, drafts: drafts, query: "carla").map(\.id),
      ["c"]
    )
  }
}

/// La recherche par médias : les mêmes résultats sur les deux plateformes,
/// parce que c'est le même code qui les produit.
final class FacetedSearchHitsTests: XCTestCase {
  private func conversation(_ id: String, _ title: String) -> Conversation {
    Conversation(
      id: id, network: .whatsapp, address: id, title: title, preview: "…",
      lastMessageAt: Date(timeIntervalSince1970: 1_800_000_000), unreadCount: 0,
      isArchived: false, transportKey: id, isGroup: false
    )
  }

  private func message(_ id: String, in conversationID: String, at seconds: TimeInterval, image: Bool) -> ChatMessage {
    ChatMessage(
      id: id,
      conversationID: conversationID,
      network: .whatsapp,
      text: image ? "" : "Le lien : https://exemple.fr/article",
      sentAt: Date(timeIntervalSince1970: seconds),
      isFromMe: false,
      attachments: image
        ? [MessageAttachment(id: "mxc://a/\(id)", contentType: "image/jpeg", filename: "plage.jpg")]
        : []
    )
  }

  func testLesResultatsViennentDeTousLesFilsDuPlusRecentAuPlusAncien() {
    let alice = conversation("whatsapp:!a:relais", "Alice")
    let bruno = conversation("whatsapp:!b:relais", "Bruno")
    let fils: [String: [ChatMessage]] = [
      alice.id: [message("$1", in: alice.id, at: 100, image: true)],
      bruno.id: [
        message("$2", in: bruno.id, at: 300, image: true),
        message("$3", in: bruno.id, at: 200, image: false),
      ],
    ]

    let hits = FacetedSearch.hits(in: [alice, bruno], facet: .images) { fils[$0.id] ?? [] }
    XCTAssertEqual(hits.map(\.message.id), ["$2", "$1"])
    XCTAssertEqual(hits.first?.conversation.title, "Bruno")

    let liens = FacetedSearch.hits(in: [alice, bruno], facet: .links) { fils[$0.id] ?? [] }
    XCTAssertEqual(liens.map(\.message.id), ["$3"])
  }

  func testLaRequeteFiltreAussiSurLeNomDuFichier() {
    let alice = conversation("whatsapp:!a:relais", "Alice")
    let fils = [alice.id: [message("$1", in: alice.id, at: 100, image: true)]]
    XCTAssertEqual(
      FacetedSearch.hits(in: [alice], facet: .images, query: "plage") { fils[$0.id] ?? [] }.count,
      1
    )
    XCTAssertTrue(
      FacetedSearch.hits(in: [alice], facet: .images, query: "montagne") { fils[$0.id] ?? [] }.isEmpty
    )
  }

  func testChaqueResultatAUnIdentifiantStable() {
    let alice = conversation("whatsapp:!a:relais", "Alice")
    let hit = FacetedSearch.Hit(conversation: alice, message: message("$1", in: alice.id, at: 1, image: true))
    XCTAssertEqual(hit.id, "whatsapp:!a:relais|$1")
  }
}
