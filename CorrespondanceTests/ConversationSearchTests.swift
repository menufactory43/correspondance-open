import XCTest
@testable import Correspondance

/// Recherche de l'inbox et du fil : accents, mots multiples, corps des messages.
final class ConversationSearchTests: XCTestCase {
  private func conversation(
    id: String = "signal:+33600000000",
    title: String = "Éléonore",
    address: String = "+33612345678",
    preview: String = "À demain !"
  ) -> Conversation {
    Conversation(
      id: id,
      network: .signal,
      address: address,
      title: title,
      preview: preview,
      lastMessageAt: Date(timeIntervalSince1970: 1_756_400_000),
      unreadCount: 0,
      isArchived: false,
      transportKey: address,
      isGroup: false
    )
  }

  // MARK: - Repli

  func testFoldIgnoresCaseAndDiacritics() {
    XCTAssertEqual(ConversationSearch.fold("  ÉLÉonore  "), "eleonore")
    XCTAssertEqual(ConversationSearch.fold("Ça va"), "ca va")
  }

  // MARK: - Filtrage de la liste

  func testTitleMatchIgnoresAccents() {
    XCTAssertTrue(ConversationSearch.matches(conversation(), query: "eleonore", messageBlob: nil))
    XCTAssertTrue(ConversationSearch.matches(conversation(), query: "ÉLÉO", messageBlob: nil))
  }

  func testAddressAndPreviewAreSearched() {
    XCTAssertTrue(ConversationSearch.matches(conversation(), query: "612345", messageBlob: nil))
    XCTAssertTrue(ConversationSearch.matches(conversation(), query: "demain", messageBlob: nil))
  }

  /// Le corps des messages en cache compte autant que le titre.
  func testMessageBodyIsSearched() {
    let blob = ConversationSearch.blob(for: [
      ChatMessage(id: "1", conversationID: "c", network: .signal, text: "On réserve le restaurant ?", sentAt: .now, isFromMe: false)
    ])
    XCTAssertTrue(ConversationSearch.matches(conversation(), query: "restaurant", messageBlob: blob))
    XCTAssertFalse(ConversationSearch.matches(conversation(), query: "cinema", messageBlob: blob))
  }

  /// Plusieurs mots = un ET, répartissable sur plusieurs champs.
  func testAllTermsMustMatchAcrossFields() {
    let blob = ConversationSearch.blob(for: [
      ChatMessage(id: "1", conversationID: "c", network: .signal, text: "au restaurant", sentAt: .now, isFromMe: false)
    ])
    XCTAssertTrue(ConversationSearch.matches(conversation(), query: "eleonore restaurant", messageBlob: blob))
    XCTAssertFalse(ConversationSearch.matches(conversation(), query: "eleonore cinema", messageBlob: blob))
  }

  func testEmptyQueryKeepsEverything() {
    let list = [conversation(id: "a"), conversation(id: "b", title: "Zoé")]
    XCTAssertEqual(ConversationSearch.filter(list, query: "   ", index: [:]).count, 2)
  }

  func testFilterUsesThePerConversationIndex() {
    let list = [conversation(id: "a", title: "Alice"), conversation(id: "b", title: "Bob")]
    let index = ["b": ConversationSearch.fold("le devis est signé")]
    let hits = ConversationSearch.filter(list, query: "devis", index: index)
    XCTAssertEqual(hits.map(\.id), ["b"])
  }

  // MARK: - Recherche dans le fil (⌘F)

  private func message(_ id: String, _ text: String) -> ChatMessage {
    ChatMessage(id: id, conversationID: "c", network: .signal, text: text, sentAt: .now, isFromMe: false)
  }

  func testMatchingMessageIDsKeepThreadOrder() {
    let thread = [
      message("1", "Bonjour"),
      message("2", "Le devis est prêt"),
      message("3", "Merci"),
      message("4", "Devis relu"),
    ]
    XCTAssertEqual(ConversationSearch.matchingMessageIDs(in: thread, query: "devis"), ["2", "4"])
    XCTAssertEqual(ConversationSearch.matchingMessageIDs(in: thread, query: ""), [])
  }

  func testHighlightRangesFindEveryOccurrence() {
    let text = "devis, puis DEVIS relu"
    let ranges = ConversationSearch.highlightRanges(in: text, query: "devis")
    XCTAssertEqual(ranges.count, 2)
    XCTAssertEqual(ranges.map { String(text[$0]) }, ["devis", "DEVIS"])
  }

  /// Le surlignage doit tomber juste sur un texte accentué : le repli conserve
  /// le nombre de caractères, sinon les positions dériveraient.
  func testHighlightRangesSurviveDiacritics() {
    let text = "Éléonore réserve"
    let ranges = ConversationSearch.highlightRanges(in: text, query: "eleonore")
    XCTAssertEqual(ranges.count, 1)
    XCTAssertEqual(ranges.map { String(text[$0]) }, ["Éléonore"])
  }

  func testHighlightRangesAreEmptyForNoQuery() {
    XCTAssertTrue(ConversationSearch.highlightRanges(in: "texte", query: "").isEmpty)
    XCTAssertTrue(ConversationSearch.highlightRanges(in: "", query: "x").isEmpty)
  }
}
