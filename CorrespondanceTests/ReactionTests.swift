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

  // MARK: - Réactions Signal

  private func message(_ id: String) -> ChatMessage {
    ChatMessage(id: id, conversationID: "signal:+33600000000", network: .signal, text: "Salut", sentAt: .now, isFromMe: false)
  }

  func testSignalReactionAttachesByTimestampPrefix() {
    var messages = ["signal:+33600000000": [message("signal-1756400000123-42-")]]
    SignalBridge.applyReactions(
      ["signal:+33600000000": [
        .init(targetTimestamp: 1_756_400_000_123, emoji: "👍", sender: "Alice", isRemove: false)
      ]],
      to: &messages
    )
    let reactions = try? XCTUnwrap(messages["signal:+33600000000"]?.first?.reactions)
    XCTAssertEqual(reactions?.map(\.emoji), ["👍"])
    XCTAssertEqual(reactions?.first?.senders, ["Alice"])
  }

  /// Signal n'accepte qu'un emoji par personne : le second remplace le premier.
  func testSignalReactionReplacesThePreviousOneFromTheSamePerson() {
    var messages = ["c": [ChatMessage(id: "signal-1000000000000-x-", conversationID: "c", network: .signal, text: "a", sentAt: .now, isFromMe: false)]]
    SignalBridge.applyReactions(
      ["c": [
        .init(targetTimestamp: 1_000_000_000_000, emoji: "👍", sender: "Alice", isRemove: false),
        .init(targetTimestamp: 1_000_000_000_000, emoji: "❤️", sender: "Alice", isRemove: false),
      ]],
      to: &messages
    )
    XCTAssertEqual(messages["c"]?.first?.reactions.map(\.emoji), ["❤️"])
  }

  func testSignalReactionRemovalClearsIt() {
    var messages = ["c": [ChatMessage(id: "signal-1000000000000-x-", conversationID: "c", network: .signal, text: "a", sentAt: .now, isFromMe: false)]]
    SignalBridge.applyReactions(
      ["c": [
        .init(targetTimestamp: 1_000_000_000_000, emoji: "👍", sender: "Alice", isRemove: false),
        .init(targetTimestamp: 1_000_000_000_000, emoji: "👍", sender: "Alice", isRemove: true),
      ]],
      to: &messages
    )
    XCTAssertTrue(try! XCTUnwrap(messages["c"]?.first?.reactions).isEmpty)
  }

  /// Une réaction sans cible connue est ignorée, pas transformée en faux message.
  func testSignalReactionWithoutTargetIsDropped() {
    var messages = ["c": [message("signal-999-a-")]]
    SignalBridge.applyReactions(
      ["c": [.init(targetTimestamp: 1_234, emoji: "👍", sender: "Alice", isRemove: false)]],
      to: &messages
    )
    XCTAssertEqual(messages["c"]?.count, 1)
    XCTAssertTrue(try! XCTUnwrap(messages["c"]?.first?.reactions).isEmpty)
  }

  // MARK: - Identifiants Signal

  func testTimestampIsReadBackFromTheMessageID() {
    XCTAssertEqual(SignalBridge.timestamp(inMessageID: "signal-1756400000123-42-"), 1_756_400_000_123)
    XCTAssertEqual(SignalBridge.timestamp(inMessageID: "signal-1756400000123-me"), 1_756_400_000_123)
    XCTAssertNil(SignalBridge.timestamp(inMessageID: "local-ABC"))
  }

  /// `signal-cli send` répond par le timestamp : sans lui, réagir à nos propres
  /// messages n'aurait aucune cible.
  func testSentTimestampIsExtractedFromCLIOutput() {
    XCTAssertEqual(SignalBridge.sentTimestamp(in: "1756400000123\n"), 1_756_400_000_123)
    XCTAssertEqual(SignalBridge.sentTimestamp(in: "INFO ready\n1756400000123"), 1_756_400_000_123)
    XCTAssertNil(SignalBridge.sentTimestamp(in: "INFO ready\n42"))
    XCTAssertNil(SignalBridge.sentTimestamp(in: ""))
  }
}
