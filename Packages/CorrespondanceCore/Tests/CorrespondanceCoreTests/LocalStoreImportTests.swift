import XCTest
@testable import CorrespondanceCore

/// La reprise de `matrix-conversations.json`, jouée une fois sur une fixture de
/// l'ancien format. Personne ne doit perdre trois ans d'historique parce que
/// l'app a changé de magasin.
final class LocalStoreImportTests: XCTestCase {
  private func fixtureCopy() throws -> URL {
    let source = try XCTUnwrap(
      Bundle.module.url(forResource: "matrix-conversations-legacy", withExtension: "json")
    )
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("legacy-\(UUID().uuidString)")
      .appendingPathComponent("matrix-conversations.json")
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(at: source, to: destination)
    return destination
  }

  func testTheOldSnapshotBecomesRoomsAndMessages() throws {
    let store = try LocalStore.inMemory()
    let url = try fixtureCopy()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let outcome = store.importLegacySnapshot(at: url)
    XCTAssertEqual(outcome.rooms, 2)
    XCTAssertEqual(outcome.messages, 3)

    let rooms = store.rooms()
    XCTAssertEqual(rooms.map(\.title), ["Camille", "Les perruches"], "les plus récents d'abord")
    let perruches = try XCTUnwrap(rooms.first { $0.roomID == "!perruches:correspondance.local" })
    XCTAssertEqual(perruches.network, .signal, "le réseau traverse la reprise")
    XCTAssertTrue(perruches.isGroup)
    XCTAssertEqual(perruches.unreadCount, 2)
    XCTAssertEqual(perruches.memberAvatarIDs, ["mxc://correspondance.local/alice"])

    let history = store.messages(roomID: "!perruches:correspondance.local")
    XCTAssertEqual(history.map(\.id), ["$ancien1", "$ancien2"])
    XCTAssertEqual(history.first?.senderName, "Alice")
    XCTAssertEqual(history.first?.reactions.map(\.emoji), ["🔥"], "les réactions figées survivent")

    let camille = store.messages(roomID: "!camille:correspondance.local")
    XCTAssertEqual(camille.first?.attachments.first?.filename, "vacances.jpg")
  }

  /// Le curseur, lui, ne traverse pas : l'ancien fichier ne gardait aucun état
  /// de salon, et un curseur repris laisserait des salons anonymes. On refait
  /// un sync initial, une fois, et l'historique est déjà là.
  func testTheCursorIsNotCarriedOver() throws {
    let store = try LocalStore.inMemory()
    let url = try fixtureCopy()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    store.importLegacySnapshot(at: url)
    XCTAssertNil(store.syncCursor)
  }

  func testItRunsOnceAndRenamesTheFile() throws {
    let store = try LocalStore.inMemory()
    let url = try fixtureCopy()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let first = store.importLegacySnapshotIfNeeded(at: url)
    XCTAssertTrue(first.didRun)
    XCTAssertEqual(first.rooms, 2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "l'ancien fichier est rangé")
    let archived = url.deletingPathExtension().appendingPathExtension("json.migrated")
    XCTAssertTrue(FileManager.default.fileExists(atPath: archived.path), "rangé, pas supprimé")

    // Même si le fichier revenait (restauration), la reprise ne rejoue pas.
    try FileManager.default.copyItem(at: archived, to: url)
    let second = store.importLegacySnapshotIfNeeded(at: url)
    XCTAssertFalse(second.didRun)
    XCTAssertEqual(store.messageCount(roomID: "!perruches:correspondance.local"), 2)
  }

  func testNoFileIsNotAFailure() throws {
    let store = try LocalStore.inMemory()
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("absent-\(UUID().uuidString).json")
    let outcome = store.importLegacySnapshotIfNeeded(at: missing)
    XCTAssertFalse(outcome.didRun)
    XCTAssertEqual(store.roomCount(), 0)
    XCTAssertNotNil(store.flag(LocalStore.jsonImportFlag), "on ne reviendra pas y regarder")
  }
}
