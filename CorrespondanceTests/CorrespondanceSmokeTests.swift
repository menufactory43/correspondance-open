import XCTest
@testable import Correspondance

final class CorrespondanceSmokeTests: XCTestCase {
  func testAllWritingThemesResolve() {
    for id in WritingThemeID.allCases {
      let theme = WritingTheme.resolve(id)
      XCTAssertEqual(theme.id, id)
      XCTAssertGreaterThan(theme.bodySize, 10)
    }
  }

  func testIMessageConversationIDParsing() {
    XCTAssertEqual(
      IMessageDatabase.guid(fromConversationID: "imessage:abc-guid"),
      "abc-guid"
    )
    XCTAssertNil(IMessageDatabase.guid(fromConversationID: "signal:1"))
  }

  func testAppleDateConversion() {
    let date = IMessageDatabase.dateFromApple(0)
    XCTAssertEqual(date.timeIntervalSinceReferenceDate, 0, accuracy: 0.001)
  }

  func testComposerTrailingAction() {
    XCTAssertEqual(ComposerTrailingAction.resolve(canSend: false, isListening: false), .dictation)
    XCTAssertEqual(ComposerTrailingAction.resolve(canSend: true, isListening: false), .send)
    XCTAssertEqual(ComposerTrailingAction.resolve(canSend: true, isListening: true), .dictation)
    XCTAssertEqual(ComposerTrailingAction.resolve(canSend: false, isListening: true), .dictation)
  }
}
