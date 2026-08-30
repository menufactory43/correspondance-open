import XCTest
@testable import Correspondance

/// Lecture d'une fixture `chat.db` au schéma macOS 26 (`scripts/make-imessage-fixture.py`) :
/// modifications, envois annulés, effets, groupes et événements de conversation.
final class IMessageChatDatabaseTests: XCTestCase {
  private let oneToOneGUID = "iMessage;-;+33611111111"
  private let groupGUID = "iMessage;+;chat900000000"

  private func database() throws -> IMessageDatabase {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "imessage-macos26", withExtension: "db"),
      "fixture imessage-macos26.db absente du bundle de test"
    )
    return IMessageDatabase(databaseURL: url)
  }

  private func messages(in chatGUID: String) throws -> [ChatMessage] {
    try database().fetchMessages(chatGUID: chatGUID)
  }

  private func message(_ guid: String, in chatGUID: String) throws -> ChatMessage {
    try XCTUnwrap(
      messages(in: chatGUID).first { $0.id == guid },
      "message \(guid) absent du fil"
    )
  }

  // MARK: - Éditions et annulations (lot M1.2)

  func testEditedMessageCarriesItsHistory() throws {
    let edited = try message("FIX-0002", in: oneToOneGUID)
    XCTAssertNotNil(edited.editedAt)
    XCTAssertEqual(edited.text, "Version finale")
    // La version courante n'est pas répétée dans l'historique.
    XCTAssertEqual(edited.editHistory, ["Premier jet"])
  }

  func testPlainMessageIsNotMarkedAsEdited() throws {
    let plain = try message("FIX-0001", in: oneToOneGUID)
    XCTAssertNil(plain.editedAt)
    XCTAssertTrue(plain.editHistory.isEmpty)
    XCTAssertFalse(plain.isRetracted)
  }

  func testRetractedMessageStaysInTheThreadWithoutBody() throws {
    let retracted = try message("FIX-0003", in: oneToOneGUID)
    XCTAssertTrue(retracted.isRetracted)
    XCTAssertTrue(retracted.text.isEmpty)
    // Le fil doit continuer à l'annoncer, ailleurs qu'en bulle.
    XCTAssertEqual(retracted.sidebarPreviewText, "Message annulé")
  }

  func testEditHistoryParsesTheTypedStreamBlob() {
    let versions = IMessageSummaryInfo.editedVersions(from: Data())
    XCTAssertTrue(versions.isEmpty, "un blob vide ne doit pas inventer de version")
  }

  // MARK: - Effets d'envoi (lot M1.5)

  func testKnownExpressiveEffectIsNamedInFrench() throws {
    let confetti = try message("FIX-0004", in: oneToOneGUID)
    XCTAssertEqual(confetti.expressiveEffectName, "Confettis")
    XCTAssertEqual(
      IMessageExpressiveEffect.label(for: "com.apple.messages.effect.CKConfettiEffect"),
      "envoyé avec Confettis"
    )
  }

  func testUnknownExpressiveEffectFallsBackToItsRawName() {
    XCTAssertEqual(
      IMessageExpressiveEffect.name(for: "com.apple.messages.effect.CKNouveauteEffect"),
      "CKNouveauteEffect"
    )
    XCTAssertNil(IMessageExpressiveEffect.name(for: ""))
    XCTAssertNil(IMessageExpressiveEffect.name(for: nil))
  }

  // MARK: - Messages audio (lot M1.3)

  func testAudioAttachmentIsRecognisedAndLabelled() throws {
    let audio = try message("FIX-0005", in: oneToOneGUID)
    let attachment = try XCTUnwrap(audio.attachments.first)
    XCTAssertTrue(attachment.isAudio)
    XCTAssertFalse(attachment.isImage)
    XCTAssertEqual(attachment.contentType, "audio/x-caf")
    XCTAssertEqual(audio.text, "🎤 Message audio")
  }

  // MARK: - Suppression « ici »

  /// Supprimer le dernier message d'un fil ne doit pas le laisser résumer la
  /// ligne de l'inbox : le catalogue repart sur le message d'avant.
  func testHiddenMessageStopsSummarisingItsRow() throws {
    let db = try database()
    let rowID = "imessage:\(oneToOneGUID)"
    let before = try XCTUnwrap(db.fetchConversations().first { $0.id == rowID })
    // Le message qui résume la ligne : le dernier que le catalogue sait montrer
    // (un texte, ou une pièce jointe — jamais un envoi annulé).
    let last = try XCTUnwrap(
      db.fetchMessages(chatGUID: oneToOneGUID).last {
        !$0.isRetracted && (!$0.text.isEmpty || !$0.attachments.isEmpty)
      }
    )

    let after = try XCTUnwrap(
      db.fetchConversations(hiddenMessageGUIDs: [last.id]).first { $0.id == rowID }
    )
    XCTAssertNotEqual(after.preview, before.preview)
    XCTAssertLessThan(after.lastMessageAt, before.lastMessageAt)
  }

  // MARK: - Groupes et événements (lot M1.4)

  func testGroupConversationExposesNameParticipantsAndPhoto() throws {
    let conversations = try database().fetchConversations()
    let group = try XCTUnwrap(
      conversations.first { $0.id == "imessage:\(groupGUID)" },
      "le groupe de la fixture n'apparaît pas dans l'inbox"
    )
    XCTAssertTrue(group.isGroup)
    XCTAssertEqual(group.title, "Les marmottes")
    XCTAssertEqual(
      group.participantHandles,
      ["+33611111111", "+33622222222", "camille@example.com"]
    )
  }

  func testGroupPhotoGUIDIsReadFromChatProperties() throws {
    let properties = try PropertyListSerialization.data(
      fromPropertyList: ["groupPhotoGuid": "at_0_FIXTURE-PHOTO"],
      format: .binary,
      options: 0
    )
    XCTAssertEqual(
      IMessageDatabase.groupPhotoGUID(inProperties: properties),
      "at_0_FIXTURE-PHOTO"
    )
    XCTAssertNil(IMessageDatabase.groupPhotoGUID(inProperties: nil))
  }

  func testGroupEventsBecomeReadableSeparators() throws {
    let thread = try messages(in: groupGUID)
    let byID = Dictionary(uniqueKeysWithValues: thread.map { ($0.id, $0) })

    XCTAssertEqual(byID["FIX-0006"]?.systemEventText, "+33611111111 a ajouté +33622222222")
    XCTAssertEqual(
      byID["FIX-0007"]?.systemEventText,
      "Vous avez nommé la conversation « Les marmottes »"
    )
    XCTAssertEqual(
      byID["FIX-0008"]?.systemEventText,
      "+33611111111 a changé la photo de la conversation"
    )
    // Un vrai message du groupe reste un message.
    XCTAssertNil(byID["FIX-0009"]?.systemEventText)
    XCTAssertEqual(byID["FIX-0009"]?.text, "On part quand ?")
  }

  func testGroupEventLabelCoversRemovalAndDeparture() {
    XCTAssertEqual(
      IMessageGroupEvent.label(
        itemType: 1, actionType: 1, groupTitle: nil, actor: "Léa", target: "Malo"
      ),
      "Léa a retiré Malo"
    )
    XCTAssertEqual(
      IMessageGroupEvent.label(
        itemType: 3, actionType: 0, groupTitle: nil, actor: "Léa", target: nil
      ),
      "Léa a quitté la conversation"
    )
    XCTAssertEqual(
      IMessageGroupEvent.label(
        itemType: 3, actionType: 0, groupTitle: nil, actor: nil, target: nil, isFromMe: true
      ),
      "Vous avez quitté la conversation"
    )
    XCTAssertNil(
      IMessageGroupEvent.label(
        itemType: 0, actionType: 0, groupTitle: nil, actor: "Léa", target: nil
      )
    )
  }

  /// Un événement ne se colle jamais aux bulles voisines : il s'écrit seul.
  func testSystemEventIsNeverGroupedWithMessages() throws {
    let thread = try messages(in: groupGUID)
    let groups = MessageGrouping.groups(for: thread, showsSenderNames: true)
    for group in groups where group.messages.contains(where: \.isSystemEvent) {
      XCTAssertEqual(group.messages.count, 1)
      XCTAssertNil(group.senderLabel)
    }
  }
}

/// Le texte d'une archive `typedstream` — c'est là que vivent les versions
/// successives d'un message modifié.
final class TypedStreamTextTests: XCTestCase {
  /// Même en-tête que celui écrit par Messages ; seule la longueur change de forme.
  private func archive(_ text: String) -> Data {
    let body = Array(text.utf8)
    var length: [UInt8]
    if body.count < 0x81 {
      length = [UInt8(body.count)]
    } else {
      length = [0x81, UInt8(body.count & 0xFF), UInt8((body.count >> 8) & 0xFF)]
    }
    var bytes = Array("\u{04}\u{0b}streamtyped".utf8)
    bytes += [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84]
    bytes += Array("\u{12}NSAttributedString\0\u{84}\u{84}\u{08}NSObject\0".utf8)
    bytes += [0x85, 0x92, 0x84, 0x84, 0x84]
    bytes += Array("\u{08}NSString".utf8)
    bytes += [0x01, 0x94, 0x84, 0x01, 0x2B]
    bytes += length + body
    bytes += [0x86, 0x84, 0x02]
    return Data(bytes)
  }

  func testShortStringIsExtracted() {
    XCTAssertEqual(TypedStreamText.string(in: archive("Premier jet")), "Premier jet")
  }

  func testAccentsSurviveTheRoundTrip() {
    XCTAssertEqual(TypedStreamText.string(in: archive("À bientôt — ça va ?")), "À bientôt — ça va ?")
  }

  /// Au-delà de 128 octets, la longueur passe sur deux octets préfixés de 0x81.
  func testLongStringUsesTheTwoByteLength() {
    let long = String(repeating: "é", count: 200)
    XCTAssertEqual(TypedStreamText.string(in: archive(long)), long)
  }

  func testGarbageYieldsNothingRatherThanNonsense() {
    XCTAssertNil(TypedStreamText.string(in: Data([0x00, 0x01, 0x02])))
    XCTAssertNil(TypedStreamText.string(in: Data()))
  }
}
