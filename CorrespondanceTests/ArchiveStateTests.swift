import XCTest
@testable import Correspondance

/// L'archivage survit à la fusion : aucun catalogue réseau ne le connaît.
final class ArchiveStateTests: XCTestCase {
  private func conversation(_ id: String, archived: Bool = false) -> Conversation {
    Conversation(
      id: id,
      network: .whatsapp,
      address: "+33600000000",
      title: id,
      preview: "Salut",
      lastMessageAt: Date(timeIntervalSince1970: 1_756_400_000),
      unreadCount: 0,
      isArchived: archived,
      transportKey: id,
      isGroup: false
    )
  }

  /// Le cas qui cassait : `MatrixConversationCache.load()` force `isArchived: false`.
  func testFreshlyMergedConversationsAreReArchived() throws {
    let merged = [conversation("a"), conversation("b")]
    let normalized = try XCTUnwrap(ArchiveState.normalized(merged, archivedIDs: ["a"]))
    XCTAssertTrue(normalized[0].isArchived)
    XCTAssertFalse(normalized[1].isArchived)
  }

  /// Un fil retiré de l'ensemble redevient actif, même si la fusion le disait archivé.
  func testRemovedIDIsUnarchived() throws {
    let merged = [conversation("a", archived: true)]
    let normalized = try XCTUnwrap(ArchiveState.normalized(merged, archivedIDs: []))
    XCTAssertFalse(normalized[0].isArchived)
  }

  /// Rien à corriger → `nil`, pour ne pas relancer une passe d'observation en boucle.
  func testAlreadyConsistentListReturnsNil() {
    let list = [conversation("a", archived: true), conversation("b")]
    XCTAssertNil(ArchiveState.normalized(list, archivedIDs: ["a"]))
    XCTAssertNil(ArchiveState.normalized([], archivedIDs: ["a"]))
  }

  /// Un identifiant archivé qui n'existe plus dans la liste ne casse rien.
  func testUnknownArchivedIDIsHarmless() {
    XCTAssertNil(ArchiveState.normalized([conversation("a")], archivedIDs: ["disparu"]))
  }
}
