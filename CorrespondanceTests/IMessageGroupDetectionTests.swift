import XCTest
@testable import Correspondance

/// Un groupe iMessage se reconnaît à `chat.style`, pas à son identifiant :
/// Messages nomme aujourd'hui ses groupes par un GUID hexadécimal nu.
final class IMessageGroupDetectionTests: XCTestCase {
  func testStyle43IsGroupWhateverTheIdentifier() {
    XCTAssertTrue(IMessageDatabase.isGroupChat(style: 43, identifier: "366e0734d4964948898b8d60b67b798a"))
    XCTAssertTrue(IMessageDatabase.isGroupChat(style: 43, identifier: "chat123456789"))
  }

  func testLegacyChatPrefixStillCountsAsGroup() {
    XCTAssertTrue(IMessageDatabase.isGroupChat(style: 0, identifier: "chat123456789"))
  }

  func testOneToOneIsNotAGroup() {
    XCTAssertFalse(IMessageDatabase.isGroupChat(style: 45, identifier: "+33612345678"))
    XCTAssertFalse(IMessageDatabase.isGroupChat(style: 45, identifier: "someone@icloud.com"))
  }
}
