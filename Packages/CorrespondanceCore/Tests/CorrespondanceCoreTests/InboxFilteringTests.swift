import XCTest
@testable import CorrespondanceCore

final class InboxFilteringTests: XCTestCase {
  private func conversation(
    _ id: String,
    title: String = "",
    network: MessageNetwork = .whatsapp,
    preview: String = "Salut",
    at seconds: TimeInterval = 0,
    unread: Int = 0,
    group: Bool = false,
    fromMe: Bool = false
  ) -> Conversation {
    Conversation(
      id: id,
      network: network,
      address: id,
      title: title.isEmpty ? id.capitalized : title,
      preview: preview,
      lastMessageAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
      unreadCount: unread,
      isArchived: false,
      transportKey: id,
      isGroup: group,
      lastMessageIsFromMe: fromMe
    )
  }

  // MARK: - Filtres

  func testFilterAllKeepsEverything() {
    let list = [conversation("a"), conversation("b", unread: 3)]
    for item in list {
      XCTAssertTrue(ConversationFilter.all.accepts(item, hasDraft: false))
    }
  }

  func testUnreadFilterKeepsOnlyUnread() {
    XCTAssertTrue(ConversationFilter.unread.accepts(conversation("a", unread: 2), hasDraft: false))
    XCTAssertFalse(ConversationFilter.unread.accepts(conversation("b"), hasDraft: false))
  }

  func testDraftFilterAsksTheCaller() {
    let item = conversation("a")
    XCTAssertTrue(ConversationFilter.drafts.accepts(item, hasDraft: true))
    XCTAssertFalse(ConversationFilter.drafts.accepts(item, hasDraft: false))
  }

  func testUnansweredMeansTheirLastWord() {
    XCTAssertTrue(ConversationFilter.unanswered.accepts(conversation("a", fromMe: false), hasDraft: false))
    XCTAssertFalse(ConversationFilter.unanswered.accepts(conversation("b", fromMe: true), hasDraft: false))
  }

  func testACatalogueConversationIsNotUnanswered() {
    let empty = conversation("c", preview: "Écrire sur WhatsApp…")
    XCTAssertFalse(ConversationFilter.unanswered.accepts(empty, hasDraft: false))
  }

  func testGroupFilter() {
    XCTAssertTrue(ConversationFilter.groups.accepts(conversation("a", group: true), hasDraft: false))
    XCTAssertFalse(ConversationFilter.groups.accepts(conversation("b"), hasDraft: false))
  }

  // MARK: - Tri

  func testPinnedComeFirst() {
    let list = [conversation("a", at: 100), conversation("b", at: 0)]
    let sorted = InboxOrdering.sorted(list, pinned: ["b"])
    XCTAssertEqual(sorted.map(\.id), ["b", "a"])
  }

  func testLiveConversationsBeatCatalogueOnes() {
    let live = conversation("live", at: 0)
    let catalogue = conversation("cat", preview: "Écrire sur WhatsApp…", at: 999)
    let sorted = InboxOrdering.sorted([catalogue, live], pinned: [])
    XCTAssertEqual(sorted.map(\.id), ["live", "cat"])
  }

  func testCatalogueGroupsBeatCatalogueContacts() {
    let group = conversation("g", title: "Zèbres", preview: "Groupe WhatsApp", group: true)
    let contact = conversation("c", title: "Alice", preview: "Écrire sur WhatsApp…")
    XCTAssertEqual(InboxOrdering.sorted([contact, group], pinned: []).map(\.id), ["g", "c"])
  }

  func testTheSortIsStableOnEqualDates() {
    let a = conversation("a", at: 5)
    let b = conversation("b", at: 5)
    XCTAssertEqual(InboxOrdering.sorted([b, a], pinned: []).map(\.id), ["a", "b"])
    XCTAssertEqual(InboxOrdering.sorted([a, b], pinned: []).map(\.id), ["a", "b"])
  }

  // MARK: - Liste

  func testArchiveScopeShowsOnlyArchivedOnes() {
    let list = [conversation("a"), conversation("b")]
    let state = InboxState(archived: ["b"])
    XCTAssertEqual(
      InboxOrdering.list(list, scope: .inbox, network: nil, filter: .all, state: state).map(\.id),
      ["a"]
    )
    XCTAssertEqual(
      InboxOrdering.list(list, scope: .archive, network: nil, filter: .all, state: state).map(\.id),
      ["b"]
    )
  }

  func testNetworkFilterKeepsOneNetwork() {
    let list = [conversation("a", network: .whatsapp), conversation("b", network: .signal)]
    let kept = InboxOrdering.list(list, scope: .inbox, network: .signal, filter: .all, state: InboxState())
    XCTAssertEqual(kept.map(\.id), ["b"])
  }

  func testDraftFilterReadsTheState() {
    let list = [conversation("a"), conversation("b")]
    let state = InboxState(drafts: ["b": "coucou", "a": "   "])
    let kept = InboxOrdering.list(list, scope: .inbox, network: nil, filter: .drafts, state: state)
    XCTAssertEqual(kept.map(\.id), ["b"])
  }

  func testSectionsSplitPinnedFromTheRest() {
    let list = [conversation("a"), conversation("b"), conversation("c")]
    let state = InboxState(pinned: ["b"])
    let sorted = InboxOrdering.list(list, scope: .inbox, network: nil, filter: .all, state: state)
    let sections = InboxOrdering.sections(sorted, state: state)
    XCTAssertEqual(sections.pinned.map(\.id), ["b"])
    XCTAssertEqual(sections.others.map(\.id), ["a", "c"])
  }

  // MARK: - File Focus

  func testFocusQueueIgnoresArchivedAndCatalogue() {
    let list = [
      conversation("a", at: 10),
      conversation("archivee", at: 20),
      conversation("cat", preview: "Écrire sur WhatsApp…", at: 30),
    ]
    let queue = InboxOrdering.focusQueue(list, state: InboxState(archived: ["archivee"]))
    XCTAssertEqual(queue.map(\.id), ["a"])
  }

  func testFocusQueueIgnoresPins() {
    let list = [conversation("vieille", at: 0), conversation("recente", at: 100)]
    let queue = InboxOrdering.focusQueue(list, state: InboxState(pinned: ["vieille"]))
    XCTAssertEqual(queue.map(\.id), ["recente", "vieille"])
  }

  func testNextAfterArchivingTakesThePlaceOfTheOneWeLeft() {
    let queue = [conversation("a", at: 30), conversation("b", at: 20), conversation("c", at: 10)]
    XCTAssertEqual(InboxOrdering.next(after: "a", in: queue), "b")
    XCTAssertEqual(InboxOrdering.next(after: "b", in: queue), "c")
  }

  func testArchivingTheLastOneGoesBackToTheOneBefore() {
    let queue = [conversation("a", at: 30), conversation("b", at: 20)]
    XCTAssertEqual(InboxOrdering.next(after: "b", in: queue), "a")
  }

  func testAnEmptiedQueueHasNoNext() {
    let queue = [conversation("a")]
    XCTAssertNil(InboxOrdering.next(after: "a", in: queue))
  }

  func testPreviousAndFollowingStopAtTheEdges() {
    let queue = [conversation("a", at: 30), conversation("b", at: 20)]
    XCTAssertNil(InboxOrdering.previous(before: "a", in: queue))
    XCTAssertEqual(InboxOrdering.previous(before: "b", in: queue), "a")
    XCTAssertEqual(InboxOrdering.following("a", in: queue), "b")
    XCTAssertNil(InboxOrdering.following("b", in: queue))
  }

  // MARK: - Projection de l'état du Relais

  func testProjectionOnlyKeepsKnownRooms() {
    var snapshot = ConversationStateSnapshot()
    snapshot.archived = ["!connu:s", "!inconnu:s"]
    snapshot.pinned = ["!connu:s"]
    snapshot.drafts = ["!connu:s": "à finir", "!inconnu:s": "perdu"]
    let state = InboxState.projected(snapshot, roomToConversation: ["!connu:s": "whatsapp:!connu:s"])
    XCTAssertEqual(state.archived, ["whatsapp:!connu:s"])
    XCTAssertEqual(state.pinned, ["whatsapp:!connu:s"])
    XCTAssertEqual(state.drafts, ["whatsapp:!connu:s": "à finir"])
    XCTAssertTrue(state.hasDraft("whatsapp:!connu:s"))
  }

  func testAWhitespaceDraftIsNoDraft() {
    let state = InboxState(drafts: ["a": "\n  "])
    XCTAssertFalse(state.hasDraft("a"))
  }
}
