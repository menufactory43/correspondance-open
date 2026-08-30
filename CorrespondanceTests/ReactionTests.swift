import XCTest
@testable import Correspondance

/// Agrégation commune aux trois réseaux, tapbacks iMessage, réactions Signal.
final class ReactionTests: XCTestCase {
  // MARK: - Agrégation

  func testAggregateGroupsByEmojiAndCounts() {
    let reactions = MessageReaction.aggregate([
      (emoji: "👍", sender: "Alice", isMine: false),
      (emoji: "👍", sender: "Bob", isMine: false),
      (emoji: "❤️", sender: "Moi", isMine: true),
    ])
    XCTAssertEqual(reactions.map(\.emoji), ["👍", "❤️"])
    XCTAssertEqual(reactions[0].count, 2)
    XCTAssertEqual(reactions[0].senders, ["Alice", "Bob"])
    XCTAssertTrue(reactions[1].isMine)
  }

  /// La même personne comptée deux fois reste une personne.
  func testAggregateDeduplicatesSenders() {
    let reactions = MessageReaction.aggregate([
      (emoji: "👍", sender: "Alice", isMine: false),
      (emoji: "👍", sender: "Alice", isMine: false),
    ])
    XCTAssertEqual(reactions.first?.count, 1)
  }

  func testAggregateIgnoresEmptyEmoji() {
    XCTAssertTrue(MessageReaction.aggregate([(emoji: "", sender: "Alice", isMine: false)]).isEmpty)
  }

  // MARK: - Tapbacks iMessage

  func testTapbackTargetGUIDStripsThePartPrefix() {
    XCTAssertEqual(IMessageDatabase.tapbackTargetGUID("p:0/ABC-123"), "ABC-123")
    XCTAssertEqual(IMessageDatabase.tapbackTargetGUID("bp:ABC-123"), "ABC-123")
    XCTAssertEqual(IMessageDatabase.tapbackTargetGUID("ABC-123"), "ABC-123")
    XCTAssertNil(IMessageDatabase.tapbackTargetGUID(""))
    XCTAssertNil(IMessageDatabase.tapbackTargetGUID("p:0/"))
  }

  /// 2000…2005 posent, 3000…3005 retirent : même famille, décalée de 1000.
  func testTapbackEmojiCoversBothFamilies() {
    XCTAssertEqual(IMessageDatabase.tapbackEmoji(type: 2000), "❤️")
    XCTAssertEqual(IMessageDatabase.tapbackEmoji(type: 2001), "👍")
    XCTAssertEqual(IMessageDatabase.tapbackEmoji(type: 2002), "👎")
    XCTAssertEqual(IMessageDatabase.tapbackEmoji(type: 2003), "😂")
    XCTAssertEqual(IMessageDatabase.tapbackEmoji(type: 2004), "‼️")
    XCTAssertEqual(IMessageDatabase.tapbackEmoji(type: 2005), "❓")
    XCTAssertEqual(IMessageDatabase.tapbackEmoji(type: 3001), "👍")
    XCTAssertNil(IMessageDatabase.tapbackEmoji(type: 2006))
  }

  /// Depuis Sonoma, un tapback peut porter un emoji libre.
  func testCustomTapbackEmojiWins() {
    XCTAssertEqual(IMessageDatabase.tapbackEmoji(type: 2000, custom: "🐙"), "🐙")
  }
}
