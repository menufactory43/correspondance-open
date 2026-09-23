import XCTest
@testable import CorrespondanceCore

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

  /// Le cas qui cassait : une conversation rechargée du magasin local arrive
  /// toujours avec `isArchived: false` — l'archive vit dans l'état de conversation.
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

  /// Le crash du 11 sept. : deux membres archivés, leur ligne fusionnée pas dans
  /// l'ensemble. `MergedContact.row(from:)` disait la ligne archivée, cette
  /// passe la désarchivait, et le `didSet` tournait jusqu'à épuiser la pile.
  /// La ligne fusionnée suit ses membres, et rien n'est à corriger.
  func testMergedRowFollowsItsMembers() {
    let row = conversation("merged:x", archived: true)
    let members = ["merged:x": ["a", "b"]]
    XCTAssertNil(ArchiveState.normalized([row], archivedIDs: ["a", "b"], mergedMembers: members))
    XCTAssertTrue(ArchiveState.isArchived("merged:x", archivedIDs: ["a", "b"], mergedMembers: members))
    // Un membre ressorti : la ligne ressort avec lui, même si son propre id est rangé.
    let normalized = ArchiveState.normalized([row], archivedIDs: ["merged:x", "a"], mergedMembers: members)
    XCTAssertEqual(normalized?.first?.isArchived, false)
  }

  // MARK: - Une ligne fusionnée n'a qu'un état

  /// Fusionner des fils rangés avec un fil dehors donne une ligne dehors : les
  /// rangés en sortent. Tous rangés, la ligne le reste.
  func testMergingIntoAnActiveRowUnarchivesTheArchivedMembers() {
    let members = ["imessage:any;-;+33600000000", "signal:!s:local", "messenger:!m:local"]
    XCTAssertEqual(
      ArchiveState.membersToUnarchiveOnMerge(members, archivedIDs: ["signal:!s:local", "messenger:!m:local"]),
      ["signal:!s:local", "messenger:!m:local"]
    )
    XCTAssertEqual(ArchiveState.membersToUnarchiveOnMerge(members, archivedIDs: Set(members)), [])
    XCTAssertEqual(ArchiveState.membersToUnarchiveOnMerge(members, archivedIDs: []), [])
  }

  /// L'iPhone range la ligne : tous les salons passent archivés d'un coup, le
  /// fil iMessage suit sur le Mac. Un état figé, ou un seul salon rangé
  /// (les autres tags n'étant pas encore arrivés), ne décide rien.
  func testArchivingElsewhereCarriesTheMembersWithoutARoom() {
    let members = ["imessage:any;-;+33600000000", "signal:!s:local", "messenger:!m:local"]
    let relay: (String) -> Bool = { $0.contains("!") }
    let rooms: Set<String> = ["signal:!s:local", "messenger:!m:local"]
    XCTAssertEqual(
      ArchiveState.localMembersToArchive(
        memberIDs: members, isRelayBacked: relay, archivedBefore: [], archivedNow: rooms),
      ["imessage:any;-;+33600000000"]
    )
    XCTAssertEqual(
      ArchiveState.localMembersToArchive(
        memberIDs: members, isRelayBacked: relay, archivedBefore: rooms, archivedNow: rooms),
      []
    )
    XCTAssertEqual(
      ArchiveState.localMembersToArchive(
        memberIDs: members, isRelayBacked: relay, archivedBefore: [], archivedNow: ["signal:!s:local"]),
      []
    )
  }
}
