import XCTest
@testable import CorrespondanceCore

/// Règles de notification : muet, fil ouvert, message de moi, doublons.
final class NotificationPolicyTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_756_400_000)

  private func conversation(
    id: String = "signal:+33600000000",
    preview: String = "On se voit demain ?",
    at offset: TimeInterval = 0,
    fromMe: Bool = false,
    archived: Bool = false
  ) -> Conversation {
    var c = Conversation(
      id: id,
      network: .signal,
      address: "+33600000000",
      title: "Alice",
      preview: preview,
      lastMessageAt: base.addingTimeInterval(offset),
      unreadCount: 1,
      isArchived: archived,
      transportKey: "+33600000000",
      isGroup: false
    )
    c.lastMessageIsFromMe = fromMe
    return c
  }

  private func decide(
    current: Conversation,
    previous: Conversation?,
    isMuted: Bool = false,
    isSelected: Bool = false,
    alreadyNotifiedAt: Date? = nil
  ) -> Bool {
    NotificationPolicy.shouldNotify(
      current: current,
      previous: previous,
      isMuted: isMuted,
      isSelected: isSelected,
      alreadyNotifiedAt: alreadyNotifiedAt
    )
  }

  func testNewIncomingMessageNotifies() {
    XCTAssertTrue(decide(current: conversation(at: 60), previous: conversation(at: 0)))
  }

  func testMutedConversationNeverNotifies() {
    XCTAssertFalse(decide(current: conversation(at: 60), previous: conversation(at: 0), isMuted: true))
  }

  func testOpenConversationNeverNotifies() {
    XCTAssertFalse(decide(current: conversation(at: 60), previous: conversation(at: 0), isSelected: true))
  }

  func testMyOwnMessageNeverNotifies() {
    XCTAssertFalse(decide(current: conversation(at: 60, fromMe: true), previous: conversation(at: 0)))
  }

  func testArchivedConversationNeverNotifies() {
    XCTAssertFalse(decide(current: conversation(at: 60, archived: true), previous: conversation(at: 0)))
  }

  /// Une simple resynchronisation (même horodatage) ne doit pas re-sonner.
  func testUnchangedTimestampDoesNotNotify() {
    XCTAssertFalse(decide(current: conversation(at: 0), previous: conversation(at: 0)))
  }

  /// Le même message déjà notifié ne sonne pas deux fois, même si l'état d'avant a été perdu.
  func testAlreadyNotifiedMessageDoesNotNotifyTwice() {
    XCTAssertFalse(
      decide(
        current: conversation(at: 60),
        previous: conversation(at: 0),
        alreadyNotifiedAt: base.addingTimeInterval(60)
      )
    )
  }

  /// Un fil qui apparaît (première sync, backfill) ne déclenche pas d'avalanche.
  func testBrandNewConversationDoesNotNotify() {
    XCTAssertFalse(decide(current: conversation(at: 60), previous: nil))
  }

  /// Un aperçu « catalogue » n'est pas un message reçu.
  func testPlaceholderPreviewDoesNotNotify() {
    XCTAssertFalse(
      decide(current: conversation(preview: "Écrire sur Signal…", at: 60), previous: conversation(at: 0))
    )
  }
}
