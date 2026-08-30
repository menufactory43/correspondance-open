import XCTest
@testable import CorrespondanceCore

/// Brouillons par conversation : ce qui mérite d'être gardé, et ce qui doit être jeté.
final class DraftStoreTests: XCTestCase {
  func testEmptyDraftIsDetected() {
    XCTAssertTrue(DraftStore.Draft().isEmpty)
    XCTAssertTrue(DraftStore.Draft(text: "   \n ").isEmpty)
    XCTAssertFalse(DraftStore.Draft(text: "Bonjour").isEmpty)
    // Une pièce jointe seule est un brouillon à part entière.
    XCTAssertFalse(DraftStore.Draft(attachmentPaths: ["/tmp/a.png"]).isEmpty)
  }

  func testSanitizedDropsEmptyDrafts() {
    let cleaned = DraftStore.sanitized([
      "a": DraftStore.Draft(text: "Bonjour"),
      "b": DraftStore.Draft(text: "  "),
    ])
    XCTAssertEqual(Array(cleaned.keys), ["a"])
  }

  /// Restaurer un chemin disparu ferait échouer l'envoi sans rien expliquer.
  func testSanitizedDropsVanishedAttachments() throws {
    let existing = FileManager.default.temporaryDirectory
      .appendingPathComponent("correspondance-draft-test-\(UUID().uuidString).txt")
    try Data("x".utf8).write(to: existing)
    defer { try? FileManager.default.removeItem(at: existing) }

    let cleaned = DraftStore.sanitized([
      "a": DraftStore.Draft(text: "Voilà", attachmentPaths: [existing.path, "/tmp/nexiste-pas-\(UUID().uuidString)"])
    ])
    XCTAssertEqual(cleaned["a"]?.attachmentPaths, [existing.path])
  }

  /// Un brouillon qui n'était qu'une pièce jointe disparue ne survit pas.
  func testDraftWithOnlyAVanishedAttachmentIsDropped() {
    let cleaned = DraftStore.sanitized([
      "a": DraftStore.Draft(attachmentPaths: ["/tmp/nexiste-pas-\(UUID().uuidString)"])
    ])
    XCTAssertTrue(cleaned.isEmpty)
  }

  func testDraftRoundTripsThroughJSON() throws {
    let draft = DraftStore.Draft(text: "À demain", attachmentPaths: [])
    let decoded = try JSONDecoder().decode(
      DraftStore.Draft.self,
      from: try JSONEncoder().encode(draft)
    )
    XCTAssertEqual(decoded, draft)
  }
}
