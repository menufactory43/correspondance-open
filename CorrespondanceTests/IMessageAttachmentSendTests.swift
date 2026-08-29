import XCTest
@testable import Correspondance

/// Envoi de pièce jointe iMessage (lot M1.1) : le script AppleScript produit et
/// la mise à disposition du fichier pour Messages. Rien n'est envoyé ici.
final class IMessageAttachmentSendTests: XCTestCase {
  func testFileScriptTargetsAChatByItsGUID() {
    let script = IMessageSender.script(
      sending: "POSIX file \"/Users/moi/Images/vue.png\"",
      to: .chat("iMessage;+;chat900000000")
    )
    XCTAssertTrue(script.contains("chat id \"iMessage;+;chat900000000\""))
    XCTAssertTrue(script.contains("send POSIX file \"/Users/moi/Images/vue.png\" to theTarget"))
  }

  func testFileScriptTargetsAParticipantWithABuddyFallback() {
    let script = IMessageSender.script(
      sending: "POSIX file \"/Users/moi/Images/vue.png\"",
      to: .address("+33611111111")
    )
    XCTAssertTrue(script.contains("participant \"+33611111111\""))
    XCTAssertTrue(script.contains("buddy \"+33611111111\""))
  }

  func testQuotesInPathsAreEscaped() {
    let script = IMessageSender.script(sending: "\"bon\\jour\"", to: .address("a\"b"))
    XCTAssertTrue(script.contains("participant \"a\\\"b\""))
  }

  func testFileAlreadyInTheHomeFolderIsSentAsIs() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let directory = home.appendingPathComponent(
      "Library/Caches/Correspondance/Tests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("note.txt")
    try Data("bonjour".utf8).write(to: file)

    XCTAssertTrue(IMessageSender.isReachableByMessages(file))
    XCTAssertEqual(try IMessageSender.readableCopy(of: file).path, file.path)
  }

  func testTemporaryFileIsCopiedWhereMessagesCanReadIt() throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("correspondance-test-\(UUID().uuidString).txt")
    try Data("bonjour".utf8).write(to: temporary)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let copy = try IMessageSender.readableCopy(of: temporary)
    defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }

    XCTAssertNotEqual(copy.path, temporary.path)
    XCTAssertEqual(copy.lastPathComponent, temporary.lastPathComponent)
    XCTAssertTrue(copy.path.hasPrefix(IMessageSender.outgoingDirectory.path))
    XCTAssertEqual(try Data(contentsOf: copy), Data("bonjour".utf8))
  }

  func testMissingFileIsRefusedBeforeAnyAppleEvent() {
    let missing = URL(fileURLWithPath: "/nulle/part/absent.png")
    XCTAssertThrowsError(try IMessageSender.readableCopy(of: missing))
  }
}
