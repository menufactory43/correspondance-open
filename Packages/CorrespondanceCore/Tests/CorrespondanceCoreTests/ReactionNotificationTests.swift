import XCTest
@testable import CorrespondanceCore

/// Ce qui sonne et ce qui se tait : une arrivée dans un groupe se tait, une
/// réaction sonne (« Alice a réagi 👍 à « … » ») — sauf fil muet ou archivé.
final class ReactionNotificationTests: XCTestCase {
  private let base = Date(timeIntervalSince1970: 1_756_400_000)
  private let me = "@gabriel:correspondance.local"
  private let alice = "@whatsapp_lid-1:correspondance.local"

  private func conversation(reaction: IncomingReaction? = nil, systemLast: Bool = false) -> Conversation {
    var c = Conversation(
      id: "whatsapp:!groupe:correspondance.local",
      network: .whatsapp,
      address: "!groupe:correspondance.local",
      title: "Famille",
      preview: "Alice a rejoint le groupe",
      lastMessageAt: base,
      unreadCount: 0,
      isArchived: false,
      transportKey: "!groupe:correspondance.local",
      isGroup: true
    )
    c.lastIncomingReaction = reaction
    c.lastMessageIsSystemEvent = systemLast
    return c
  }

  private func reaction(_ id: String, at offset: TimeInterval) -> IncomingReaction {
    IncomingReaction(
      id: id, senderName: "Alice", emoji: "👍", targetPreview: "On se voit demain ?",
      sentAt: base.addingTimeInterval(offset))
  }

  // MARK: - Arrivées

  func testSomeoneJoiningTheGroupDoesNotNotify() {
    var previous = conversation()
    previous.lastMessageAt = base.addingTimeInterval(-60)
    let current = conversation(systemLast: true)
    XCTAssertFalse(NotificationPolicy.shouldNotify(
      current: current, previous: previous, isMuted: false, isSelected: false,
      alreadyNotifiedAt: nil, now: base.addingTimeInterval(10)))
    // Le même mouvement, pour un vrai message : ça sonne.
    XCTAssertTrue(NotificationPolicy.shouldNotify(
      current: conversation(), previous: previous, isMuted: false, isSelected: false,
      alreadyNotifiedAt: nil, now: base.addingTimeInterval(10)))
  }

  // MARK: - Réactions

  private func decide(
    _ current: Conversation, previous: Conversation?, muted: Bool = false, selected: Bool = false
  ) -> Bool {
    NotificationPolicy.shouldNotifyReaction(
      current: current, previous: previous, isMuted: muted, isSelected: selected,
      now: base.addingTimeInterval(120))
  }

  func testANewReactionNotifies() {
    XCTAssertTrue(decide(conversation(reaction: reaction("$r1", at: 60)), previous: conversation()))
    XCTAssertTrue(decide(
      conversation(reaction: reaction("$r2", at: 60)),
      previous: conversation(reaction: reaction("$r1", at: 0))))
  }

  func testAMutedOrArchivedThreadStaysQuiet() {
    let current = conversation(reaction: reaction("$r1", at: 60))
    XCTAssertFalse(decide(current, previous: conversation(), muted: true))
    var archived = current
    archived.isArchived = true
    XCTAssertFalse(decide(archived, previous: conversation()))
    XCTAssertFalse(decide(current, previous: conversation(), selected: true))
  }

  /// Une réaction retirée laisse réapparaître la précédente : rien de neuf.
  func testARemovedReactionDoesNotReannounceThePreviousOne() {
    XCTAssertFalse(decide(
      conversation(reaction: reaction("$r1", at: 0)),
      previous: conversation(reaction: reaction("$r2", at: 60))))
  }

  func testAnOldReactionOrAFirstSightingIsSilent() {
    XCTAssertFalse(decide(conversation(reaction: reaction("$r1", at: -3600)), previous: conversation()))
    XCTAssertFalse(decide(conversation(reaction: reaction("$r1", at: 60)), previous: nil))
  }

  func testTheBodyNamesTheSenderTheEmojiAndTheMessage() {
    XCTAssertEqual(reaction("$r", at: 0).bodyFR, "Alice a réagi 👍 à « On se voit demain ? »")
    XCTAssertEqual(IncomingReaction.body(senderName: "Alice", emoji: "❤️", targetPreview: nil), "Alice a réagi ❤️")
    let long = String(repeating: "a", count: 100)
    let body = IncomingReaction.body(senderName: "Alice", emoji: "😂", targetPreview: long)
    XCTAssertTrue(body.hasSuffix("… »"), body)
    XCTAssertLessThan(body.count, 90)
  }

  // MARK: - Le modèle

  private func room() -> MatrixRoomModel {
    var model = MatrixRoomModel(roomID: "!groupe:correspondance.local")
    model.network = .whatsapp
    model.members[me] = .init(displayName: "Gabriel", membership: "join")
    model.members[alice] = .init(displayName: "Alice", membership: "join")
    model.members["@whatsapp_lid-2:correspondance.local"] = .init(displayName: "Bruno", membership: "join")
    model.messagesByID["$m1"] = ChatMessage(
      id: "$m1", conversationID: model.conversationID, network: .whatsapp,
      text: "On se voit demain ?", sentAt: base, isFromMe: true, senderID: me, senderName: "Moi")
    model.readMarkerByUser[me] = "$m1"
    return model
  }

  func testTheConversationCarriesTheLatestIncomingReaction() throws {
    var model = room()
    model.reactionsByEventID["$mine"] = .init(
      targetEventID: "$m1", emoji: "🔥", senderID: me, senderName: "Moi", isMine: true,
      sentAt: base.addingTimeInterval(90))
    model.reactionsByEventID["$r1"] = .init(
      targetEventID: "$m1", emoji: "👍", senderID: alice, senderName: "Alice", isMine: false,
      sentAt: base.addingTimeInterval(60))
    let reaction = try XCTUnwrap(model.conversation(selfUserID: me)?.lastIncomingReaction)
    XCTAssertEqual(reaction.id, "$r1")
    XCTAssertEqual(reaction.bodyFR, "Alice a réagi 👍 à « On se voit demain ? »")
  }

  /// Le Relais compte la réaction comme une notification ; l'inbox, non.
  func testAReactionDoesNotCountAsUnread() {
    var model = room()
    model.unreadCount = 1
    model.reactionsByEventID["$r1"] = .init(
      targetEventID: "$m1", emoji: "👍", senderID: alice, senderName: "Alice", isMine: false,
      sentAt: base.addingTimeInterval(60))
    XCTAssertEqual(model.conversation(selfUserID: me)?.unreadCount, 0)
  }

  func testAJoinLineIsFlaggedAsASystemEvent() {
    var model = room()
    model.messagesByID["$join"] = ChatMessage(
      id: "$join", conversationID: model.conversationID, network: .whatsapp, text: "",
      sentAt: base.addingTimeInterval(30), isFromMe: false, senderID: alice, senderName: "Alice",
      systemEventText: "Alice a rejoint le groupe")
    XCTAssertEqual(model.conversation(selfUserID: me)?.lastMessageIsSystemEvent, true)
  }

  // MARK: - La règle du Relais

  /// Une `underride` : la sourdine (règle de salon) passe avant elle.
  func testTheReactionPushRuleIsAnUnderride() throws {
    XCTAssertEqual(
      MatrixClient.reactionPushRulePath,
      "/_matrix/client/v3/pushrules/global/underride/fr.correspondance.reaction")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let body = String(data: try encoder.encode(MatrixClient.reactionPushRuleBody()), encoding: .utf8)
    XCTAssertEqual(
      body,
      #"{"actions":["notify"],"conditions":[{"key":"type","kind":"event_match","pattern":"m.reaction"}]}"#)
  }
}

/// Un fil archivé ne pousse plus rien : une règle `override` par salon, que
/// l'état du Relais relit.
final class ArchivePushRuleTests: XCTestCase {
  private let room = "!abc:correspondance.local"

  func testTheRuleSilencesTheWholeRoom() throws {
    XCTAssertEqual(
      MatrixClient.archivePushRulePath(roomID: room),
      "/_matrix/client/v3/pushrules/global/override/fr.correspondance.archived.%21abc%3Acorrespondance.local")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let body = String(data: try encoder.encode(MatrixClient.archivePushRuleBody(roomID: room)), encoding: .utf8)
    XCTAssertEqual(
      body,
      #"{"actions":[],"conditions":[{"key":"room_id","kind":"event_match","pattern":"!abc:correspondance.local"}]}"#)
  }

  func testTheSnapshotReadsOurOverrideRulesOnly() throws {
    let json = """
      {"global":{"override":[
        {"rule_id":".m.rule.master","enabled":false,"actions":[]},
        {"rule_id":"fr.correspondance.archived.!abc:correspondance.local","enabled":true,"actions":[]},
        {"rule_id":"fr.correspondance.archived.!off:correspondance.local","enabled":false,"actions":[]}
      ]}}
      """
    let content = try JSONDecoder().decode(MatrixJSON.self, from: Data(json.utf8))
    XCTAssertEqual(ConversationStateSnapshot.archiveSilencedRoomIDs(inPushRules: content), [room])
  }
}
