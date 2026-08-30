import XCTest
@testable import CorrespondanceCore

/// La file d'écritures en attente : ce qui n'est pas encore parti gouverne
/// l'affichage, et deux gestes sur le même fil ne font qu'une requête.
final class RelayWriteQueueTests: XCTestCase {
  private let alice = "!dm-alice:correspondance.local"
  private let bob = "!dm-bob:correspondance.local"

  func testTwoGesturesOnTheSameRoomCoalesce() {
    var queue = RelayWriteQueue()
    queue.enqueue(.archived(roomID: alice, value: true))
    queue.enqueue(.archived(roomID: alice, value: false))
    XCTAssertEqual(queue.count, 1)
    XCTAssertEqual(queue.writes, [.archived(roomID: alice, value: false)])
  }

  func testDifferentKindsCoexist() {
    var queue = RelayWriteQueue()
    queue.enqueue(.archived(roomID: alice, value: true))
    queue.enqueue(.pinned(roomID: alice, value: true))
    queue.enqueue(.archived(roomID: bob, value: true))
    XCTAssertEqual(queue.count, 3)
  }

  func testCompletingRemovesOnlyTheWriteThatLeft() {
    var queue = RelayWriteQueue()
    queue.enqueue(.archived(roomID: alice, value: true))
    queue.complete(.archived(roomID: alice, value: true))
    XCTAssertTrue(queue.isEmpty)
  }

  /// Un nouveau geste pendant l'envoi : la confirmation de l'ancien ne doit pas
  /// emporter le nouveau, sinon le désarchivage ne partirait jamais.
  func testANewerGestureSurvivesTheConfirmationOfTheOlderOne() {
    var queue = RelayWriteQueue()
    let inFlight = RelayWrite.archived(roomID: alice, value: true)
    queue.enqueue(inFlight)
    queue.enqueue(.archived(roomID: alice, value: false))
    queue.complete(inFlight)
    XCTAssertEqual(queue.writes, [.archived(roomID: alice, value: false)])
  }

  func testPendingWritesWinOverTheRelaySnapshot() {
    let relay = ConversationStateSnapshot(archived: [alice], pinned: [bob], drafts: [alice: "ancien"])
    var queue = RelayWriteQueue()
    queue.enqueue(.archived(roomID: alice, value: false))
    queue.enqueue(.muted(roomID: bob, value: true))
    queue.enqueue(.draft(roomID: alice, text: "nouveau"))
    let merged = queue.applied(to: relay)
    XCTAssertTrue(merged.archived.isEmpty)
    XCTAssertEqual(merged.pinned, [bob])
    XCTAssertEqual(merged.muted, [bob])
    XCTAssertEqual(merged.drafts[alice], "nouveau")
  }

  func testAnEmptyDraftWriteClearsTheDraft() {
    var queue = RelayWriteQueue()
    queue.enqueue(.draft(roomID: alice, text: ""))
    XCTAssertNil(queue.applied(to: ConversationStateSnapshot(drafts: [alice: "à jeter"])).drafts[alice])
  }

  func testTheQueueSurvivesARelaunch() {
    var queue = RelayWriteQueue()
    queue.enqueue(.hidden(roomID: bob, eventIDs: ["$a", "$b"]))
    queue.enqueue(.mergedContacts(MergedContactStore.Stored(
      merged: [MergedContact(
        id: "merged:1",
        title: "Alice",
        memberIDs: ["iMessage:+33600000001", "whatsapp:!dm:correspondance.local"],
        defaultConversationID: "whatsapp:!dm:correspondance.local"
      )],
      dismissedPairs: []
    )))
    XCTAssertEqual(RelayWriteQueue(data: queue.data), queue)
  }

  func testACorruptedQueueComesBackEmptyRatherThanCrashing() {
    XCTAssertTrue(RelayWriteQueue(data: Data("pas du JSON".utf8)).isEmpty)
    XCTAssertTrue(RelayWriteQueue(data: nil).isEmpty)
  }

  func testOnlyMergedContactsIsGlobal() {
    XCTAssertNil(RelayWrite.mergedContacts(MergedContactStore.Stored()).roomID)
    XCTAssertEqual(RelayWrite.pinned(roomID: alice, value: true).roomID, alice)
  }
}
